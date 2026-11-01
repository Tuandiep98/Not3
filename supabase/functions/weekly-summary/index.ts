// Sunday 20:00 local: weekly stats + AI summary (DeepSeek Pro), rules when AI is off.
// Then pushes "Tổng kết đã sẵn sàng".
import { adminClient, json, requireServiceRole } from "../_shared/admin.ts";
import { canUseAI, summarizeWeek, summarizeWeekByRules, type WeekStats } from "../_shared/ai.ts";

type DueUser = { user_id: string; week_start: string; timezone: string };

const WEEKDAYS = ["T2", "T3", "T4", "T5", "T6", "T7", "CN"];

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const { users } = await req.json() as { users: DueUser[] };
  const db = adminClient();

  for (const u of users ?? []) {
    const stats = await weekStats(db, u);
    let summary: string | null = null;
    if (await canUseAI(db, u.user_id)) summary = await summarizeWeek(stats);
    const source = summary ? "ai" : "rules";
    summary ??= summarizeWeekByRules(stats);

    await db.from("weekly_summaries").upsert(
      { user_id: u.user_id, week_start: u.week_start, summary, stats, source },
      { onConflict: "user_id,week_start" },
    );
    await db.from("push_queue").upsert({
      user_id: u.user_id,
      send_at: new Date().toISOString(),
      kind: "weekly_summary",
      payload: { title: "Tổng kết tuần đã sẵn sàng", body: `${stats.meaningful_days}/7 ngày có việc ý nghĩa` },
      dedupe_key: `weekly:${u.user_id}:${u.week_start}`,
    }, { onConflict: "dedupe_key", ignoreDuplicates: true });
  }
  return json({ users: users?.length ?? 0 });
});

// deno-lint-ignore no-explicit-any
async function weekStats(db: any, u: DueUser): Promise<WeekStats> {
  const start = new Date(`${u.week_start}T00:00:00Z`);
  const days = [...Array(7)].map((_, i) => new Date(start.getTime() + i * 86400000).toISOString().slice(0, 10));
  // Query a wide UTC window, then bucket by the user's local day.
  const from = new Date(start.getTime() - 86400000).toISOString();
  const to = new Date(start.getTime() + 8 * 86400000).toISOString();

  const [{ data: tasks }, { data: checkins }] = await Promise.all([
    db.from("tasks").select("title, chips, completed_at").eq("user_id", u.user_id).eq("status", "done")
      .gte("completed_at", from).lt("completed_at", to),
    db.from("checkins").select("day, mood").eq("user_id", u.user_id).gte("day", days[0]).lte("day", days[6]),
  ]);

  const local = (iso: string) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: u.timezone, year: "numeric", month: "2-digit", day: "2-digit" })
      .format(new Date(iso));
  const byDay = new Map<string, string[]>(days.map((d) => [d, []]));
  const byCategory: Record<string, number> = {};
  for (const t of tasks ?? []) {
    const day = local(t.completed_at);
    if (!byDay.has(day)) continue;
    byDay.get(day)!.push(t.title);
    const category = t.chips?.[0] ?? "Khác";
    byCategory[category] = (byCategory[category] ?? 0) + 1;
  }
  const moods = new Map<string, string | null>((checkins ?? []).map((c: { day: string; mood: string | null }) => [c.day, c.mood]));
  const dayStats = days.map((day, i) => ({
    day,
    weekday: WEEKDAYS[i],
    done: byDay.get(day) ?? [],
    mood: moods.get(day) ?? null,
  }));
  return {
    week_start: u.week_start,
    meaningful_days: dayStats.filter((d) => d.done.length > 0).length,
    days: dayStats,
    by_category: byCategory,
    empty_days: dayStats.filter((d) => d.done.length === 0).map((d) => d.weekday),
  };
}
