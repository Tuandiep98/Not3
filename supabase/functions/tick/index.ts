// Runs every 5 minutes (pg_cron). pg_cron is UTC-only, so tick picks the users whose
// *local* time has reached a milestone and fans out work (README §9).
import { checkinMessage } from "../_shared/notify.ts";
import {
  adminClient,
  invoke,
  json,
  requireServiceRole,
} from "../_shared/admin.ts";

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const db = adminClient();

  // 30 minutes before check-in: pull GitHub / Jira so build-checkin sees fresh items.
  const { data: syncUsers } = await db.rpc("users_due", { offset_minutes: 30 });
  if (syncUsers?.length) {
    await invoke("sync-integrations", { users: syncUsers });
  }

  // 15 minutes before check-in: build morning chips + afternoon suggestions.
  const { data: buildUsers, error: e1 } = await db.rpc("users_due", {
    offset_minutes: 15,
  });
  if (e1) return json({ error: e1.message }, 500);
  if (buildUsers?.length) {
    await invoke("build-checkin", { users: buildUsers });
  }

  // At check-in time: queue the 12:00 push (deduped per user per local day).
  const { data: checkinUsers, error: e2 } = await db.rpc("users_due", {
    offset_minutes: 0,
  });
  if (e2) return json({ error: e2.message }, 500);
  for (const u of checkinUsers ?? []) {
    const { data: done } = await db.from("checkins")
      .select("id").eq("user_id", u.user_id).eq("day", u.local_day).not(
        "mood",
        "is",
        null,
      ).maybeSingle();
    if (done) continue;
    const { count } = await db.from("suggestions")
      .select("id", { count: "exact", head: true })
      .eq("user_id", u.user_id).eq("day", u.local_day).eq(
        "kind",
        "morning_chip",
      );
    await db.from("push_queue").upsert({
      user_id: u.user_id,
      send_at: new Date().toISOString(),
      kind: "checkin",
      payload: checkinMessage(count ?? 0),
      dedupe_key: `checkin:${u.user_id}:${u.local_day}`,
    }, { onConflict: "dedupe_key", ignoreDuplicates: true });
  }

  // Every 15 min, 08:00–20:00 local: poll GitHub / Jira (main path for Jira, safety net for webhooks).
  const { data: pollUsers } = await db.rpc("users_poll_active");
  const preCheckin = new Set(
    (syncUsers ?? []).map((u: { user_id: string }) => u.user_id),
  );
  const poll = (pollUsers ?? []).filter((u: { user_id: string }) =>
    !preCheckin.has(u.user_id)
  );
  if (poll.length) {
    await invoke("sync-integrations", { users: poll });
  }

  // 02:00 local: reconcile every link of open tasks with the real external state.
  const { data: nightUsers } = await db.rpc("users_at_local_time", {
    p_hour: 2,
    p_minute: 0,
  });
  if (nightUsers?.length) {
    await invoke("sync-integrations", { users: nightUsers, mode: "reconcile" });
  }

  // Sunday 20:00 local: weekly summary.
  const { data: weeklyUsers } = await db.rpc("users_due_weekly");
  if (weeklyUsers?.length) {
    await invoke("weekly-summary", { users: weeklyUsers });
  }

  // Deliver everything due.
  const sent = await invoke("send-push", {});
  return json({
    build: buildUsers?.length ?? 0,
    checkin: checkinUsers?.length ?? 0,
    weekly: weeklyUsers?.length ?? 0,
    push: sent.status,
  });
});
