import { syncDoneMessage, syncReopenedMessage } from "./notify.ts";
import { z } from "npm:zod@3.23.8";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { canUseAI } from "./ai.ts";
import { AIUnavailable, chatJSON } from "./deepseek.ts";

// Task ↔ external item links and status sync (README §12).
// - Links: rule match on "#42" / "JIRA-118" in the task title (confidence 1); otherwise AI:
//   ≥ 0.85 auto-link, 0.6–0.85 → a "Liên kết với PR #57?" suggestion, lower → ignored.
// - Status: the external side is the source of truth for linked tasks' status.

export type TaskStatus = "todo" | "doing" | "done" | "cancelled";

export const AUTO_LINK = 0.85;
export const SUGGEST_LINK = 0.6;

/** Maps an external item state to a task status; null = no change implied. */
export function mapStatus(
  provider: string,
  kind: string | null,
  status: string | null,
): TaskStatus | null {
  if (!status) return null;
  if (provider === "github") {
    switch (status) {
      case "merged":
      case "completed":
      case "reviewed": // review sent → the "Review PR" task is done
      case "replied": // answered the mention → "Trả lời …" task is done
      case "succeeded": // the failing build / deploy passed again → "Sửa: …" task is done
        return "done";
      case "closed":
      case "not_planned":
        return "cancelled";
      case "open":
      case "review_requested":
        return kind === "pull_request" || kind === "issue" ? "todo" : null;
    }
    return null;
  }
  if (provider === "jira") {
    if (status === "done") return "done";
    if (status === "unassigned") return "cancelled";
    if (status === "in_progress") return "doing";
    if (status === "todo") return "todo";
  }
  return null;
}

type ExternalRow = {
  source: string;
  external_id: string;
  kind: string | null;
  status_name?: string | null;
  title: string;
  url: string | null;
  status: string | null;
  role?: string | null;
  updated_at: string;
};

type TaskRow = {
  id: string;
  title: string;
  status: TaskStatus;
  created_at: string;
  /** "integration" = created by the sync from an assignment, not by the user. */
  source?: string | null;
};

const JIRA_KEY = /\b([A-Z][A-Z0-9]+-\d+)\b/g;
const PR_NUMBER = /#(\d+)\b/g;

/** Deterministic matches: a Jira key or "#N" in the task title that names an external item. */
export function ruleMatches(
  task: TaskRow,
  items: ExternalRow[],
): ExternalRow[] {
  const keys = new Set(
    [...task.title.toUpperCase().matchAll(JIRA_KEY)].map((m) => m[1]),
  );
  const numbers = new Set([...task.title.matchAll(PR_NUMBER)].map((m) => m[1]));
  return items.filter((item) => {
    if (item.source === "jira") return keys.has(item.external_id.toUpperCase());
    if (item.source === "github" && item.kind !== "commits") {
      const n = item.external_id.match(/\/(?:pull|issues)\/(\d+)$/)?.[1];
      return n !== undefined && numbers.has(n);
    }
    return false;
  });
}

/** AI matches; null when the call failed (so the same input is tried again next time). */
async function aiMatches(tasks: TaskRow[], items: ExternalRow[]) {
  const schema = z.object({
    links: z
      .array(
        z.object({
          task_id: z.string(),
          external_id: z.string(),
          confidence: z.number().min(0).max(1),
        }),
      )
      .max(20),
  });
  try {
    const result = await chatJSON({
      need: "light",
      system: [
        "Ghép mỗi việc cần làm của người dùng với PR / issue / ticket nói về CÙNG một việc. Trả về JSON.",
        "Chỉ ghép khi nội dung thật sự trùng (ví dụ 'Viết test module login' ↔ 'Add login tests').",
        "confidence 0–1: 0.9+ gần như chắc chắn, 0.6–0.85 có thể, dưới 0.6 thì bỏ.",
        'Định dạng: {"links":[{"task_id":"...","external_id":"...","confidence":0.9}]}',
      ].join("\n"),
      user: JSON.stringify({
        tasks: tasks.map((t) => ({ task_id: t.id, title: t.title })),
        items: items.map((i) => ({
          external_id: i.external_id,
          source: i.source,
          title: i.title,
        })),
      }),
      schema,
      maxTokens: 500,
    });
    const taskIds = new Set(tasks.map((t) => t.id));
    const itemIds = new Set(items.map((i) => i.external_id));
    return result.links.filter(
      (l) => taskIds.has(l.task_id) && itemIds.has(l.external_id),
    );
  } catch (e) {
    if (!(e instanceof AIUnavailable)) console.error("[links] ai", e);
    return null;
  }
}

/** Same tasks and items as the last AI attempt → the answer would be the same: skip the call. */
async function aiInputKey(tasks: TaskRow[], items: ExternalRow[]): Promise<string> {
  const text = JSON.stringify([
    tasks.map((t) => `${t.id}|${t.title}`).sort(),
    items.map((i) => `${i.source}|${i.external_id}`).sort(),
  ]);
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Creates new links, then applies external status changes to linked tasks. Returns changed task ids. */
export async function linkAndSync(
  db: SupabaseClient,
  userId: string,
): Promise<string[]> {
  const since = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
  const [{ data: items }, { data: tasks }, { data: links }] = await Promise.all(
    [
      db
        .from("external_items")
        .select(
          "source, external_id, kind, title, url, status, status_name, role, updated_at",
        )
        .eq("user_id", userId)
        .in("source", ["github", "jira"])
        .gte("updated_at", since),
      db
        .from("tasks")
        .select("id, title, status, created_at, source")
        .eq("user_id", userId)
        // Every open task, however old: unfinished work carries over until it is done, so its
        // link must keep following GitHub / Jira (no age limit for status sync).
        .in("status", ["todo", "doing"]),
      db
        .from("task_links")
        .select("task_id, provider, external_id, external_updated_at")
        .eq("user_id", userId),
    ],
  );
  const external = (items ?? []) as ExternalRow[];
  const open = (tasks ?? []) as TaskRow[];
  const linked = new Set((links ?? []).map((l) => l.task_id));

  // 1. New links for unlinked open tasks (only recent ones are matched automatically).
  const unlinked = open.filter(
    (t) => !linked.has(t.id) && t.created_at >= since,
  );
  const newLinks: Record<string, unknown>[] = [];
  const stillUnlinked: TaskRow[] = [];
  for (const task of unlinked) {
    const hits = ruleMatches(task, external);
    if (hits.length) {
      for (const hit of hits) {
        newLinks.push(linkRow(userId, task.id, hit, "auto", 1));
      }
    } else {
      stillUnlinked.push(task);
    }
  }
  const candidates = external.filter((i) => i.kind !== "commits");
  const aiTasks = stillUnlinked.slice(0, 15);
  const aiItems = candidates.slice(0, 30);
  // Every sync used to ask AI again about the same personal tasks that match nothing (seconds
  // on each pull to refresh). Ask only when a task or an item is new since the last answer.
  let aiKey: string | null = null;
  if (aiTasks.length && aiItems.length) {
    aiKey = await aiInputKey(aiTasks, aiItems);
    const { data: profile } = await db
      .from("profiles")
      .select("link_ai_key")
      .eq("user_id", userId)
      .maybeSingle();
    if (profile?.link_ai_key === aiKey) aiKey = null;
  }
  const matches = aiKey && (await canUseAI(db, userId))
    ? await aiMatches(aiTasks, aiItems)
    : null;
  if (matches) {
    await db.from("profiles").update({ link_ai_key: aiKey }).eq("user_id", userId);
    const byId = new Map(candidates.map((i) => [i.external_id, i]));
    const suggestions: Record<string, unknown>[] = [];
    for (const m of matches) {
      const item = byId.get(m.external_id)!;
      if (m.confidence >= AUTO_LINK) {
        newLinks.push(linkRow(userId, m.task_id, item, "ai", m.confidence));
      } else if (m.confidence >= SUGGEST_LINK) {
        suggestions.push({
          user_id: userId,
          kind: "link",
          payload: {
            task_id: m.task_id,
            provider: item.source,
            external_id: item.external_id,
            url: item.url,
            title: item.title,
            confidence: m.confidence,
          },
        });
      }
    }
    if (suggestions.length) {
      // One open suggestion per task: replace older ones.
      await db
        .from("suggestions")
        .delete()
        .eq("user_id", userId)
        .eq("kind", "link")
        .eq("status", "new");
      await db.from("suggestions").insert(suggestions);
    }
  }
  if (newLinks.length) {
    await db.from("task_links").upsert(newLinks, {
      onConflict: "task_id,provider,external_id",
      ignoreDuplicates: true,
    });
  }

  // 2. Status sync: external state → task status, newest event wins, stale events ignored.
  //    Forward: open task → doing / done / cancelled.
  //    Back (rejected / reopened): a task closed because the item was closed is reopened when the
  //    item goes back to in progress, so the user sees it unticked and continues.
  const { data: allLinks } = await db
    .from("task_links")
    .select(
      "id, task_id, provider, external_id, external_status, external_updated_at, title",
    )
    .eq("user_id", userId);
  const itemByKey = new Map(
    external.map((i) => [`${i.source}|${i.external_id}`, i]),
  );
  const linkedIds = [...new Set((allLinks ?? []).map((l) => l.task_id))];
  const taskById = new Map<string, TaskRow>(open.map((t) => [t.id, t]));
  for (let i = 0; i < linkedIds.length; i += 200) {
    const { data } = await db
      .from("tasks")
      .select("id, title, status, created_at, source")
      .eq("user_id", userId)
      .in("id", linkedIds.slice(i, i + 200));
    for (const t of (data ?? []) as TaskRow[]) taskById.set(t.id, t);
  }
  const changed: string[] = [];
  const now = () => new Date().toISOString();
  for (const link of allLinks ?? []) {
    const item = itemByKey.get(`${link.provider}|${link.external_id}`);
    if (!item) continue;
    if (
      link.external_updated_at && item.updated_at <= link.external_updated_at
    ) {
      continue;
    }
    const task = taskById.get(link.task_id);
    const status = effectiveStatus(item, task);
    await db
      .from("task_links")
      .update({
        external_status: status,
        external_updated_at: item.updated_at,
        url: item.url,
        title: item.title,
      })
      .eq("id", link.id);

    if (!task) continue;
    const next = mapStatus(item.source, item.kind, status);
    const before = mapStatus(
      item.source,
      item.kind,
      link.external_status ?? null,
    );
    const decision = transition(task.status, before, next, status);
    if (!decision) continue;

    await db
      .from("tasks")
      .update({
        status: decision.status,
        completed_at: decision.status === "done" ? now() : null,
        updated_at: now(),
        updated_by: "sync",
        ...(decision.reopened
          ? {
            reopened_at: now(),
            reopened_reason: link.external_status === "unassigned"
              ? `Được giao lại ${item.external_id}`
              : reopenReason(item),
          }
          : {}),
      })
      .eq("id", task.id);
    changed.push(task.id);

    if (decision.status === "done" || decision.reopened) {
      await db.from("push_queue").insert({
        user_id: userId,
        send_at: now(),
        kind: "sync",
        payload: decision.reopened
          ? syncReopenedMessage(task, item)
          : syncDoneMessage(task, item),
      });
    }
  }
  return changed;
}

/**
 * The item state that drives a linked task. A Jira ticket the sync turned into a task because it
 * was assigned to me reads "unassigned" (→ cancelled) once it is assigned to someone else or no
 * one; assigned back, the usual reopen path brings the task back. Done still wins (finished, then
 * handed to QA). The user's own tasks that merely mention the key are left alone.
 */
export function effectiveStatus(
  item: Pick<ExternalRow, "source" | "kind" | "status" | "role">,
  task: Pick<TaskRow, "source"> | undefined,
): string | null {
  if (
    item.source === "jira" &&
    item.kind === "issue" &&
    task?.source === "integration" &&
    item.role != null &&
    item.role !== "assignee" &&
    item.status !== "done"
  ) {
    return "unassigned";
  }
  return item.status;
}

/** Why a task came back, in the user's words: "JIRA-120 → In Progress", "Được nhờ review lại"… */
export function reopenReason(
  item: Pick<
    ExternalRow,
    "source" | "kind" | "status" | "external_id" | "status_name"
  >,
): string {
  if (item.source === "jira") {
    const name = item.status_name ??
      (item.status === "in_progress" ? "In Progress" : "To Do");
    return `${item.external_id} → ${name}`;
  }
  switch (item.kind) {
    case "build":
      return "Build lỗi lại";
    case "deploy":
      return "Deploy lỗi lại";
    case "mention":
      return "Có bình luận mới cần trả lời";
    case "issue":
      return "Issue được mở lại";
  }
  return item.status === "review_requested"
    ? "Được nhờ review lại"
    : "PR mở lại hoặc bị yêu cầu sửa";
}

/**
 * What a linked task becomes when its item changes, or null for no change.
 * `before` / `next` are the task statuses implied by the item's previous / new state.
 */
export function transition(
  current: TaskStatus,
  before: TaskStatus | null,
  next: TaskStatus | null,
  itemStatus: string | null,
): { status: TaskStatus; reopened: boolean } | null {
  const closed = (s: TaskStatus | null) => s === "done" || s === "cancelled";
  // Back: closed because the item was closed, and the item is active again → reopen.
  if (closed(current) && before === current && !closed(next)) {
    if (next === "doing") return { status: "doing", reopened: true };
    if (next === "todo" || itemStatus === "failed") {
      return { status: "todo", reopened: true };
    }
    return null; // e.g. a build that is running again: wait for its result
  }
  // Forward: open task → doing / done / cancelled (never back to todo on its own).
  if (!closed(current) && next && next !== "todo" && next !== current) {
    return { status: next, reopened: false };
  }
  return null;
}

function linkRow(
  userId: string,
  taskId: string,
  item: ExternalRow,
  source: "auto" | "ai",
  confidence: number,
) {
  return {
    user_id: userId,
    task_id: taskId,
    provider: item.source,
    external_id: item.external_id,
    url: item.url,
    title: item.title,
    link_source: source,
    confidence,
  };
}
