import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

// Automatic classification of synced items (README §12, "Luật phân loại mặc định").
// Every item ends up as a task, a journal line, ignored — or "chưa phân loại" (decision null),
// which the app shows as a warning row the user can resolve with one tap.

export type Classification =
  | { decision: "task"; status: "todo" | "doing"; reason: string }
  | { decision: "journal"; reason: string }
  | { decision: "ignored"; reason: string }
  | { decision: null; reason: string };

export type ClassifiableItem = {
  source: string;
  external_id: string;
  kind: string | null;
  title: string;
  url: string | null;
  status: string | null;
  role: string | null;
  scope: string | null;
};

// Finished / past work → "Nhật ký" (reviewed = review sent, replied = answered a mention,
// published = release / tag, succeeded = build / deploy passed).
const FINISHED = new Set([
  "merged",
  "closed",
  "completed",
  "not_planned",
  "done",
  "reviewed",
  "published",
  "succeeded",
  "replied",
]);

/** `rules` holds "provider|kind|scope" ("" scope = the whole kind). */
export function classify(
  item: ClassifiableItem,
  rules: Set<string>,
): Classification {
  const kind = item.kind ?? "";
  if (
    rules.has(`${item.source}|${kind}|`) ||
    rules.has(`${item.source}|${kind}|${item.scope ?? ""}`)
  ) {
    return { decision: "ignored", reason: "Luật bỏ qua của bạn" };
  }
  if (kind === "commits") {
    return { decision: "journal", reason: "Commit trong ngày" };
  }
  if (item.status && FINISHED.has(item.status)) {
    return { decision: "journal", reason: "Đã xong" };
  }

  if (item.status === "running") return { decision: null, reason: "Đang chạy" };
  if (
    item.source === "github" && (kind === "build" || kind === "deploy") &&
    item.status === "failed"
  ) {
    return {
      decision: "task",
      status: "todo",
      reason: kind === "build" ? "Build lỗi" : "Deploy lỗi",
    };
  }
  if (item.source === "github" && kind === "mention") {
    return { decision: "task", status: "todo", reason: "Bạn được nhắc tên" };
  }

  if (item.source === "github") {
    if (kind === "pull_request" && item.role === "reviewer") {
      return {
        decision: "task",
        status: "todo",
        reason: "Bạn được nhờ review",
      };
    }
    if (kind === "pull_request" && item.role === "author") {
      return {
        decision: "task",
        status: "doing",
        reason: "PR của bạn đang mở",
      };
    }
    if (item.role === "assignee") {
      return { decision: "task", status: "todo", reason: "Được giao cho bạn" };
    }
    if (kind === "issue" && item.role === "author") {
      return { decision: null, reason: "Issue bạn tạo, chưa giao cho ai" };
    }
    return { decision: null, reason: "Bạn chỉ được nhắc đến" };
  }

  if (item.source === "jira") {
    if (item.role === "assignee") {
      return {
        decision: "task",
        status: item.status === "in_progress" ? "doing" : "todo",
        reason: "Được giao cho bạn",
      };
    }
    if (item.role === "reporter") {
      return { decision: null, reason: "Bạn tạo ticket, người khác làm" };
    }
    return { decision: null, reason: "Bạn chỉ được nhắc đến" };
  }
  return { decision: null, reason: "Không rõ loại" };
}

/** Task title: the item title without the " · repo" tail (the link badge shows the source). */
export function taskTitle(item: ClassifiableItem): string {
  const title = item.title.replace(/ · [^·]+$/, "");
  return item.kind === "build" || item.kind === "deploy"
    ? `Sửa: ${title}`
    : title;
}

/**
 * Classifies today's undecided, unlinked items. Tasks are created server-side (updated_by = 'sync')
 * with a link, so their status follows GitHub / Jira; the app pulls them on the next refresh.
 */
export async function classifyAndApply(
  db: SupabaseClient,
  userId: string,
): Promise<number> {
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const [{ data: items }, { data: rules }, { data: links }] = await Promise.all(
    [
      db
        .from("external_items")
        .select("source, external_id, kind, title, url, status, role, scope")
        .eq("user_id", userId)
        .in("source", ["github", "jira"])
        .is("decision", null)
        .gte("updated_at", since),
      db
        .from("content_rules")
        .select("provider, kind, scope")
        .eq("user_id", userId)
        .eq("action", "ignore"),
      db
        .from("task_links")
        .select("provider, external_id")
        .eq("user_id", userId),
    ],
  );
  const ruleSet = new Set(
    (rules ?? []).map((r) => `${r.provider}|${r.kind}|${r.scope ?? ""}`),
  );
  const linked = new Set(
    (links ?? []).map((l) => `${l.provider}|${l.external_id}`),
  );

  // Decisions are collected, then written in a few batched calls (was 1–3 calls per item, one
  // after another — seconds on a busy day).
  const decisions = new Map<string, Map<string, string[]>>(); // decision → source → ids
  const decide = (item: ClassifiableItem, decision: string) => {
    const bySource = decisions.get(decision) ?? new Map<string, string[]>();
    bySource.set(item.source, [...(bySource.get(item.source) ?? []), item.external_id]);
    decisions.set(decision, bySource);
  };
  const newTasks: { item: ClassifiableItem; row: Record<string, unknown> }[] = [];
  const now = new Date().toISOString();

  for (const item of (items ?? []) as ClassifiableItem[]) {
    if (linked.has(`${item.source}|${item.external_id}`)) {
      decide(item, "task");
      continue;
    }
    const result = classify(item, ruleSet);
    if (result.decision === null) continue; // "chưa phân loại" → warning row in the app
    if (result.decision === "task") {
      newTasks.push({
        item,
        row: {
          id: crypto.randomUUID(),
          user_id: userId,
          title: taskTitle(item),
          chips: ["Công việc"],
          status: result.status,
          source: "integration",
          created_at: now,
          updated_at: now,
          updated_by: "sync",
        },
      });
      continue; // decided once its task exists
    }
    decide(item, result.decision);
  }

  let created = 0;
  if (newTasks.length) {
    const { error } = await db.from("tasks").insert(newTasks.map((t) => t.row));
    // One bad row fails the batch: fall back to one insert per task, as before.
    const inserted = error
      ? (await Promise.all(newTasks.map(async (t) =>
        (await db.from("tasks").insert(t.row)).error ? null : t
      ))).filter((t): t is (typeof newTasks)[number] => t !== null)
      : newTasks;
    if (inserted.length) {
      await db.from("task_links").upsert(
        inserted.map(({ item, row }) => ({
          user_id: userId,
          task_id: row.id,
          provider: item.source,
          external_id: item.external_id,
          url: item.url,
          title: item.title,
          external_status: item.status,
          link_source: "auto",
          confidence: 1,
        })),
        { onConflict: "task_id,provider,external_id", ignoreDuplicates: true },
      );
      inserted.forEach(({ item }) => decide(item, "task"));
      created = inserted.length;
    }
  }

  await Promise.all(
    [...decisions].flatMap(([decision, bySource]) =>
      [...bySource].map(([source, ids]) =>
        db.from("external_items").update({ decision })
          .eq("user_id", userId).eq("source", source).in("external_id", ids)
      )
    ),
  );
  return created;
}
