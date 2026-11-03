import { z } from "npm:zod@3.23.8";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { canUseAI } from "./ai.ts";
import { AIUnavailable, chatJSON } from "./deepseek.ts";
import { mapStatus, type TaskStatus } from "./links.ts";

// Content cards (README §12, `build-cards`): one card per linked task, gathering its PRs and
// tickets — plus PRs that name a linked ticket's key — with a two-line summary (AI, else rules).
// Rebuilt after every sync; a card's summary is only rewritten when its items changed (version).

export type CardItem = {
  provider: "github" | "jira";
  external_id: string;
  label: string; // "PR #42", "Issue #7", "NOT-118"
  title: string;
  url: string | null;
  status: string | null;
  status_text: string; // "đã merge", "Code Review"…
};

export type Card = {
  task_id: string;
  title: string;
  status: TaskStatus;
  badges: string[]; // providers present
  items: CardItem[];
  version: string;
  summary: string;
  ai_summary: boolean;
};

type TaskRow = { id: string; title: string; status: TaskStatus; completed_at: string | null };
type LinkRow = { task_id: string; provider: string; external_id: string };
type ItemRow = {
  source: string;
  external_id: string;
  kind: string | null;
  title: string;
  url: string | null;
  status: string | null;
  status_name?: string | null;
};

const JIRA_KEY = /\b([A-Z][A-Z0-9]+-\d+)\b/g;

export function itemLabel(item: ItemRow): string {
  if (item.source === "jira") return item.external_id.toUpperCase();
  const m = item.external_id.match(/\/(pull|issues)\/(\d+)$/);
  if (!m) return "GitHub";
  return m[1] === "pull" ? `PR #${m[2]}` : `Issue #${m[2]}`;
}

export function statusText(item: ItemRow): string {
  if (item.status_name) return item.status_name;
  switch (item.status) {
    case "merged":
      return "đã merge";
    case "open":
      return "đang mở";
    case "review_requested":
      return "chờ review";
    case "reviewed":
      return "đã review";
    case "closed":
    case "not_planned":
      return "đã đóng";
    case "done":
      return "xong";
    case "in_progress":
      return "đang làm";
    case "todo":
      return "chưa làm";
    default:
      return item.status ?? "";
  }
}

const RANK: Record<TaskStatus, number> = { cancelled: 0, todo: 1, doing: 2, done: 3 };

/** FNV-1a: a short, stable fingerprint of what the card shows. */
export function fingerprint(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

/** "PR #42 đã merge · NOT-118 Code Review" */
export function ruleSummary(items: CardItem[]): string {
  return items.map((i) => `${i.label} ${i.status_text}`.trim()).join(" · ");
}

/** Pure grouping; summaries are filled by `buildCards`. */
export function groupCards(
  tasks: TaskRow[],
  links: LinkRow[],
  items: ItemRow[],
): Omit<Card, "summary" | "ai_summary">[] {
  const byKey = new Map(items.map((i) => [`${i.source}|${i.external_id}`, i]));
  const prs = items.filter((i) => i.source === "github" && i.kind !== "commits");
  const linksByTask = new Map<string, LinkRow[]>();
  for (const l of links) {
    linksByTask.set(l.task_id, [...(linksByTask.get(l.task_id) ?? []), l]);
  }

  const cards: Omit<Card, "summary" | "ai_summary">[] = [];
  for (const task of tasks) {
    const own = (linksByTask.get(task.id) ?? [])
      .map((l) => byKey.get(`${l.provider}|${l.external_id}`))
      .filter((i): i is ItemRow => i !== undefined);
    if (!own.length) continue;
    // PRs naming one of the task's tickets belong to the same piece of work.
    const keys = new Set(own.filter((i) => i.source === "jira").map((i) => i.external_id.toUpperCase()));
    const related = keys.size
      ? prs.filter((pr) => [...pr.title.toUpperCase().matchAll(JIRA_KEY)].some((m) => keys.has(m[1])))
      : [];
    const seen = new Set<string>();
    const all = [...own, ...related].filter((i) => {
      const k = `${i.source}|${i.external_id}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
    // Tickets first, then PRs / issues, each in a stable order.
    all.sort((a, b) =>
      a.source === b.source ? a.external_id.localeCompare(b.external_id) : a.source === "jira" ? -1 : 1
    );
    const cardItems: CardItem[] = all.map((i) => ({
      provider: i.source as "github" | "jira",
      external_id: i.external_id,
      label: itemLabel(i),
      title: i.title,
      url: i.url,
      status: i.status,
      status_text: statusText(i),
    }));
    const statuses = all
      .map((i) => mapStatus(i.source, i.kind, i.status))
      .filter((s): s is TaskStatus => s !== null);
    const live = statuses.filter((s) => s !== "cancelled");
    const status = (live.length ? live : statuses).sort((a, b) => RANK[b] - RANK[a])[0] ?? task.status;
    cards.push({
      task_id: task.id,
      title: task.title,
      status,
      badges: [...new Set(cardItems.map((i) => i.provider))],
      items: cardItems,
      version: fingerprint(
        [task.title, ...cardItems.map((i) => `${i.provider}|${i.external_id}|${i.title}|${i.status}|${i.status_text}`)]
          .join("\n"),
      ),
    });
  }
  return cards;
}

/** One AI call for every card that needs a new summary. Null when AI is unavailable. */
export async function summarizeCards(
  cards: Omit<Card, "summary" | "ai_summary">[],
): Promise<Map<string, string> | null> {
  if (!cards.length) return new Map();
  const schema = z.object({
    cards: z.array(z.object({ task_id: z.string(), summary: z.string().min(1).max(200) })).max(20),
  });
  try {
    const result = await chatJSON({
      need: "light",
      system: [
        "Tóm tắt tiến độ của từng việc trong 1–2 câu ngắn (tối đa 140 ký tự), tiếng Việt, trung tính.",
        "Nói việc đang ở đâu và bước tiếp theo nếu rõ (ví dụ: 'PR đã merge, ticket chờ QA kiểm tra').",
        "Chỉ dựa vào dữ liệu được đưa, không bịa. Trả về JSON.",
        'Định dạng: {"cards":[{"task_id":"...","summary":"..."}]}',
      ].join("\n"),
      // Titles and states only — no descriptions or comments leave the server.
      user: JSON.stringify(
        cards.slice(0, 20).map((c) => ({
          task_id: c.task_id,
          task: c.title,
          items: c.items.map((i) => ({ item: i.label, title: i.title, status: i.status_text })),
        })),
      ),
      schema,
      maxTokens: 900,
    });
    const ids = new Set(cards.map((c) => c.task_id));
    return new Map(
      result.cards.filter((c) => ids.has(c.task_id)).map((c) => [c.task_id, c.summary.trim()]),
    );
  } catch (e) {
    if (!(e instanceof AIUnavailable)) console.error("[cards] ai", e);
    return null;
  }
}

/** Rebuilds the user's cards. Returns how many changed (new, updated or removed). */
export async function buildCards(db: SupabaseClient, userId: string): Promise<number> {
  const since = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
  const [{ data: tasks }, { data: links }, { data: items }, { data: existing }] = await Promise.all([
    db
      .from("tasks")
      .select("id, title, status, completed_at")
      .eq("user_id", userId)
      // Open work, and work finished in the last week (still visible in the app).
      .or(`status.in.(todo,doing),completed_at.gte.${since}`),
    db.from("task_links").select("task_id, provider, external_id").eq("user_id", userId),
    db
      .from("external_items")
      .select("source, external_id, kind, title, url, status, status_name")
      .eq("user_id", userId)
      .in("source", ["github", "jira"]),
    db.from("cards").select("task_id, version, summary, ai_summary").eq("user_id", userId),
  ]);

  const cards = groupCards((tasks ?? []) as TaskRow[], (links ?? []) as LinkRow[], (items ?? []) as ItemRow[]);
  const previous = new Map(
    ((existing ?? []) as { task_id: string; version: string; summary: string; ai_summary: boolean }[])
      .map((c) => [c.task_id, c]),
  );
  const changed = cards.filter((c) => previous.get(c.task_id)?.version !== c.version);

  // AI only where it adds something: cards with more than one item.
  const needAI = changed.filter((c) => c.items.length > 1);
  const ai = needAI.length && (await canUseAI(db, userId)) ? await summarizeCards(needAI) : null;

  const now = new Date().toISOString();
  const rows = changed.map((c) => {
    const summary = ai?.get(c.task_id);
    return {
      user_id: userId,
      task_id: c.task_id,
      kind: "task",
      title: c.title,
      status: c.status,
      badges: c.badges,
      items: c.items,
      linked_item_ids: c.items.map((i) => `${i.provider}|${i.external_id}`),
      primary_action: c.items[0]?.url ? { kind: "open", url: c.items[0].url } : null,
      summary: summary ?? ruleSummary(c.items),
      ai_summary: summary !== undefined,
      version: c.version,
      updated_at: now,
    };
  });
  if (rows.length) {
    const { error } = await db.from("cards").upsert(rows, { onConflict: "task_id" });
    if (error) throw error;
  }
  const keep = new Set(cards.map((c) => c.task_id));
  const removed = [...previous.keys()].filter((id) => !keep.has(id));
  if (removed.length) {
    await db.from("cards").delete().eq("user_id", userId).in("task_id", removed);
  }
  return rows.length + removed.length;
}
