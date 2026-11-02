// Jira dynamic webhook (issue created / updated / deleted): near real-time status for Jira, like
// webhook-github. The payload is only a trigger: after checking the JWT, the user's Jira data is
// pulled again with their own token, so nothing in the body is trusted. The 15-minute poll and the
// nightly reconcile stay as the safety net.
import { adminClient, json } from "../_shared/admin.ts";
import { syncUser } from "../_shared/integrations.ts";
import { verifyJwt } from "./jwt.ts";

type Payload = {
  webhookEvent?: string;
  matchedWebhookIds?: number[];
  issue?: { key?: string };
};

Deno.serve(async (req) => {
  const secret = Deno.env.get("JIRA_CLIENT_SECRET");
  if (!secret) return json({ error: "webhook not configured" }, 503);
  const auth = await verifyJwt(secret, req.headers.get("Authorization"));
  if (!auth.ok) {
    console.warn("[webhook-jira] rejected:", auth.reason);
    return json({ error: "unauthorized" }, 401);
  }

  const body = await req.text();
  let payload: Payload;
  try {
    payload = JSON.parse(body) as Payload;
  } catch {
    return json({ error: "bad body" }, 400);
  }
  const event = payload.webhookEvent ?? "";
  const delivery = req.headers.get("X-Atlassian-Webhook-Identifier") ??
    crypto.randomUUID();
  const db = adminClient();

  // Dedupe: Jira retries a failed delivery with the same identifier.
  const { error: dup } = await db.from("sync_events").insert({
    provider: "jira",
    delivery_id: delivery,
    event,
  });
  if (dup) return json({ ok: true, duplicate: true });
  const mark = (status: string, error?: string) =>
    db
      .from("sync_events")
      .update({ status, error, attempts: 1 })
      .eq("provider", "jira")
      .eq("delivery_id", delivery);

  const matched = new Set((payload.matchedWebhookIds ?? []).map(Number));
  if (!event.startsWith("jira:issue_") || matched.size === 0) {
    await mark("skipped");
    return json({ ok: true, skipped: event });
  }

  try {
    // The users whose registered webhook fired.
    const { data: rows } = await db
      .from("integrations")
      .select("user_id, meta")
      .eq("provider", "jira")
      .not("meta->webhook_ids", "is", null);
    const users = (rows ?? []).filter((r) =>
      ((r.meta as { webhook_ids?: number[] })?.webhook_ids ?? []).some((id) =>
        matched.has(Number(id))
      )
    );
    for (const u of users) {
      const { data: profile } = await db
        .from("profiles")
        .select("timezone")
        .eq("user_id", u.user_id)
        .maybeSingle();
      // Jira only: pulls, links, classifies and sends the silent push when tasks changed.
      await syncUser(
        db,
        u.user_id,
        profile?.timezone ?? "Asia/Ho_Chi_Minh",
        "jira",
      );
    }
    await mark(users.length ? "done" : "skipped");
    return json({ ok: true, users: users.length });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await mark("failed", message);
    // 200 so Jira does not hammer retries; the poll will catch up.
    return json({ ok: false, error: message });
  }
});
