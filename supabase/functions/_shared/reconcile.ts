import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { fetchLinkedItem, type Provider, validToken } from "./integrations.ts";
import { doneRules } from "./settings.ts";
import { linkAndSync } from "./links.ts";

/**
 * Nightly (02:00 local): re-read the real state of every item linked to an open task — including
 * items that did not change today and so were missed by the daily queries — then apply statuses.
 */
export async function reconcileUser(
  db: SupabaseClient,
  userId: string,
): Promise<number> {
  const { data: links } = await db.from("task_links")
    .select("provider, external_id, tasks!inner(status)")
    .eq("user_id", userId)
    .in("tasks.status", ["todo", "doing"]);
  const { data: integrations } = await db.from("integrations").select(
    "provider, meta, done_rules",
  ).eq("user_id", userId);
  const metaByProvider = new Map(
    (integrations ?? []).map((i) => [i.provider, i.meta ?? {}]),
  );
  const rulesByProvider = new Map(
    (integrations ?? []).map((i) => [i.provider, doneRules(i.done_rules)]),
  );

  let refreshed = 0;
  for (const provider of ["github", "jira"] as Provider[]) {
    const ids = [
      ...new Set(
        (links ?? []).filter((l) => l.provider === provider).map((l) =>
          l.external_id
        ),
      ),
    ];
    if (!ids.length || !metaByProvider.has(provider)) continue;
    const token = await validToken(db, userId, provider).catch(() => null);
    if (!token) continue;
    for (const id of ids.slice(0, 50)) {
      const item = await fetchLinkedItem(
        provider,
        id,
        token,
        metaByProvider.get(provider)!,
        rulesByProvider.get(provider),
      ).catch(() => null);
      if (!item) continue;
      await db.from("external_items").upsert(
        { ...item, user_id: userId, updated_at: new Date().toISOString() },
        { onConflict: "user_id,source,external_id" },
      );
      refreshed++;
    }
  }
  await linkAndSync(db, userId);
  return refreshed;
}
