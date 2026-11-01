// 15 minutes before check-in: gather the morning into chips and suggest 3 afternoon tasks.
// AI (DeepSeek Flash) first; rule-based fallback keeps the flow working (README §10).
import { adminClient, json, requireServiceRole } from "../_shared/admin.ts";
import {
  type AfternoonTask,
  canUseAI,
  type MorningItem,
  suggestCheckIn,
} from "../_shared/ai.ts";

type DueUser = { user_id: string; local_day: string; timezone: string };
type RecentTask = {
  title: string;
  chips: string[];
  status: string;
  completed_at: string | null;
  created_at: string;
};

const WORK = "Công việc";
const DEFAULT_CATEGORIES = [
  "Công việc",
  "Học ngôn ngữ",
  "Sở thích",
  "Sức khoẻ",
  "Đọc sách",
];
const DAY_MS = 24 * 3600 * 1000;

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const { users } = (await req.json()) as { users: DueUser[] };
  const db = adminClient();
  let viaAI = 0;

  for (const u of users ?? []) {
    // Idempotent: one batch of new suggestions per user per day.
    await db
      .from("suggestions")
      .delete()
      .eq("user_id", u.user_id)
      .eq("day", u.local_day)
      .eq("status", "new");

    const [
      { data: items },
      { data: recent },
      { data: chips },
      { data: rules },
    ] = await Promise.all([
      db
        .from("external_items")
        .select("source, external_id, kind, title, occurred_at, decision")
        .eq("user_id", u.user_id)
        .gte("occurred_at", new Date(Date.now() - DAY_MS).toISOString())
        .order("occurred_at"),
      db
        .from("tasks")
        .select("title, chips, status, completed_at, created_at")
        .eq("user_id", u.user_id)
        .gte("created_at", new Date(Date.now() - 30 * DAY_MS).toISOString()),
      db
        .from("chips")
        .select("label, use_count")
        .eq("user_id", u.user_id)
        .eq("group", "category")
        .order("use_count", { ascending: false }),
      db.from("content_rules").select("provider, kind").eq("user_id", u.user_id)
        .eq("action", "ignore"),
    ]);
    // "Luôn bỏ qua loại này" and items dismissed in the inbox never become chips.
    const ignored = new Set(
      (rules ?? []).map((r) => `${r.provider}|${r.kind}`),
    );
    const morning: MorningItem[] = (items ?? [])
      .filter((i) => localDay(i.occurred_at, u.timezone) === u.local_day)
      .filter((i) =>
        i.decision !== "ignored" && !ignored.has(`${i.source}|${i.kind ?? ""}`)
      )
      .map(({ source, external_id, title }) => ({
        source,
        external_id,
        title,
      }));
    const categories = chips?.length
      ? chips.map((c) => c.label)
      : DEFAULT_CATEGORIES;
    const tasks = (recent ?? []) as RecentTask[];

    const morningLabels = new Map(morning.map((m) => [m.external_id, m.title]));
    let afternoon = rulesAfternoon(categories, tasks);
    let source: "ai" | "rules" = "rules";

    if (await canUseAI(db, u.user_id)) {
      const ai = await suggestCheckIn({
        morning,
        categories,
        recentTasks: tasks
          .filter(
            (t) =>
              (t.completed_at ?? t.created_at) >=
                new Date(Date.now() - 14 * DAY_MS).toISOString(),
          )
          .map((t) => ({
            title: t.title,
            category: t.chips[0] ?? null,
            done: t.status === "done",
            day: localDay(t.completed_at ?? t.created_at, u.timezone),
          })),
      });
      if (ai) {
        for (const m of ai.morning) morningLabels.set(m.external_id, m.label);
        afternoon = ai.afternoon;
        source = "ai";
        viaAI++;
      }
    }

    const rows = [
      ...morning.map((i) => ({
        user_id: u.user_id,
        day: u.local_day,
        kind: "morning_chip",
        payload: {
          label: morningLabels.get(i.external_id) ?? i.title,
          source: i.source,
          external_id: i.external_id,
        },
      })),
      ...afternoon.map((t) => ({
        user_id: u.user_id,
        day: u.local_day,
        kind: "afternoon_task",
        payload: { ...t, source },
      })),
    ];
    if (rows.length) await db.from("suggestions").insert(rows);
  }
  return json({ users: users?.length ?? 0, via_ai: viaAI });
});

/** Categories missing in the last 7 days first, self-development before work. */
function rulesAfternoon(
  categories: string[],
  tasks: RecentTask[],
): AfternoonTask[] {
  const weekAgo = new Date(Date.now() - 7 * DAY_MS).toISOString();
  const usedThisWeek = new Set(
    tasks
      .filter((t) => (t.completed_at ?? t.created_at) >= weekAgo)
      .flatMap((t) => t.chips),
  );
  const ordered = [...categories].sort(
    (a, b) =>
      Number(usedThisWeek.has(a)) - Number(usedThisWeek.has(b)) ||
      Number(a === WORK) - Number(b === WORK),
  );
  return ordered.slice(0, 3).map((category) => ({
    title: frequentTitle(category, tasks) ?? category,
    category,
    duration_minutes: category === WORK ? 45 : 25,
  }));
}

function localDay(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(iso));
}

function frequentTitle(category: string, tasks: RecentTask[]): string | null {
  const counts = new Map<string, number>();
  for (const t of tasks) {
    if (t.chips.includes(category) && t.title !== category) {
      counts.set(t.title, (counts.get(t.title) ?? 0) + 1);
    }
  }
  let best: string | null = null;
  let max = 0;
  for (const [title, n] of counts) if (n > max) [best, max] = [title, n];
  return best;
}
