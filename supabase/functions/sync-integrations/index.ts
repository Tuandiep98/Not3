// 30 minutes before check-in (from tick): pull GitHub / Jira for the due users.
import { adminClient, json, requireServiceRole } from "../_shared/admin.ts";
import { syncUser } from "../_shared/integrations.ts";
import { reconcileUser } from "../_shared/reconcile.ts";

type DueUser = { user_id: string; local_day: string; timezone: string };

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  // mode "sync": pull today's items (pre-check-in, poll-active); "reconcile": nightly full check.
  const { users, mode = "sync" } = await req.json() as {
    users: DueUser[];
    mode?: "sync" | "reconcile";
  };
  const db = adminClient();

  const { data: connected } = await db.from("integrations").select("user_id")
    .in("user_id", (users ?? []).map((u) => u.user_id));
  const withIntegrations = new Set((connected ?? []).map((r) => r.user_id));

  const results: Record<string, unknown> = {};
  for (const u of users ?? []) {
    if (!withIntegrations.has(u.user_id)) continue;
    results[u.user_id] = mode === "reconcile"
      ? await reconcileUser(db, u.user_id)
      : await syncUser(db, u.user_id, u.timezone);
  }
  return json({ synced: Object.keys(results).length });
});
