import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

/**
 * Silent push (content-available) so the app refreshes data and home-screen widgets in the
 * background. At most one per user per 10 minutes — iOS throttles frequent silent pushes anyway.
 */
export async function queueSilentRefresh(
  db: SupabaseClient,
  userId: string,
): Promise<void> {
  const bucket = Math.floor(Date.now() / (10 * 60 * 1000));
  await db.from("push_queue").upsert({
    user_id: userId,
    send_at: new Date().toISOString(),
    kind: "silent",
    payload: { reason: "sync" },
    dedupe_key: `silent:${userId}:${bucket}`,
  }, { onConflict: "dedupe_key", ignoreDuplicates: true });
}
