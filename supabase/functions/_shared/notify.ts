// Push copy + delivery style in one place (mirrored by NotificationService.swift for local fallbacks).
// Formula: the title says WHAT (the task itself when there is one), the body says WHY and the next
// step. Short sentences, no jargon, no emoji. Priority follows Apple's interruption levels:
// time-sensitive only for a time the user chose, passive for FYI, active for the rest.

export type PushKind =
  | "checkin"
  | "reminder"
  | "evening"
  | "weekly_summary"
  | "sync"
  | "silent";

export type Level = "passive" | "active" | "time-sensitive";

export type PushPayload = {
  title: string;
  body: string;
  subtitle?: string;
  task_id?: string;
  /** not3:// link opened when the notification is tapped. */
  link?: string;
  /** External page (PR / ticket) for the "Mở trên …" button. */
  url?: string;
  source?: string;
  /** Overrides the kind's default level (e.g. a reopened task is louder than a finished one). */
  level?: Level;
  /** 0–1: order inside the notification summary. */
  relevance?: number;
  category?: string;
};

type Style = {
  level: Level;
  relevance: number;
  thread: string;
  category?: string;
};

const STYLE: Record<Exclude<PushKind, "silent">, Style> = {
  // The user set this time themselves: allowed through Focus.
  reminder: {
    level: "time-sensitive",
    relevance: 1,
    thread: "tasks",
    category: "REMINDER",
  },
  checkin: {
    level: "active",
    relevance: 0.8,
    thread: "checkin",
    category: "CHECKIN",
  },
  evening: {
    level: "active",
    relevance: 0.6,
    thread: "tasks",
    category: "EVENING",
  },
  // Done by itself → FYI only; reopened overrides to active.
  sync: { level: "passive", relevance: 0.3, thread: "sync" },
  weekly_summary: { level: "active", relevance: 0.5, thread: "summary" },
};

const MAX_TITLE = 64;

export function clip(text: string, max = MAX_TITLE): string {
  const t = text.replace(/\s+/g, " ").trim();
  return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`;
}

/** The `aps` dictionary for an alert push. */
export function apsFor(
  kind: Exclude<PushKind, "silent">,
  p: PushPayload,
): Record<string, unknown> {
  const style = STYLE[kind] ?? STYLE.sync;
  const level = p.level ?? style.level;
  const category = p.category ?? style.category;
  return {
    alert: {
      title: p.title,
      ...(p.subtitle ? { subtitle: p.subtitle } : {}),
      body: p.body,
    },
    // Passive = quiet in the list: no sound.
    ...(level === "passive" ? {} : { sound: "default" }),
    "interruption-level": level,
    "relevance-score": p.relevance ?? style.relevance,
    "thread-id": style.thread,
    ...(category ? { category } : {}),
  };
}

/** One notification per task: a later one (evening, sync) replaces the earlier one. */
export function collapseIdFor(
  kind: PushKind,
  p: PushPayload,
): string | undefined {
  if (kind === "checkin") return "checkin";
  if (p.task_id) return `task-${p.task_id}`;
  return undefined;
}

// --- Copy ----------------------------------------------------------------------

export function checkinMessage(pending: number): PushPayload {
  return {
    title: "Check-in buổi trưa",
    body: pending > 0
      ? `Sáng nay có ${pending} việc chờ bạn xác nhận. Nhấn giữ để chọn tâm trạng, chạm để lên kế hoạch chiều.`
      : "Buổi sáng thế nào? Nhấn giữ để chọn tâm trạng, chạm để lên kế hoạch chiều.",
    link: "not3://checkin",
  };
}

export function weeklyMessage(meaningfulDays: number): PushPayload {
  const d = Math.max(0, Math.min(7, meaningfulDays));
  const verdict = d >= 5
    ? "Rất đều tay!"
    : d >= 3
    ? "Đang giữ nhịp tốt."
    : d >= 1
    ? "Tuần tới thử thêm một ngày nhé."
    : "Tuần tới bắt đầu bằng một việc nhỏ nhé.";
  return {
    title: "Tổng kết tuần đã sẵn sàng",
    body: `${d}/7 ngày có việc ý nghĩa. ${verdict} Chạm để xem lại tuần.`,
    link: "not3://summary",
  };
}

type Item = {
  source: string;
  kind: string | null;
  status: string | null;
  external_id: string;
  status_name?: string | null;
  url: string | null;
};

const SOURCE_LABEL: Record<string, string> = { github: "GitHub", jira: "Jira" };

/** Why the linked task is now done, as a plain sentence. */
export function doneReason(item: Item): string {
  if (item.source === "jira") {
    return `${item.external_id} đã chuyển sang ${
      item.status_name ?? "Done"
    } trên Jira`;
  }
  switch (item.status) {
    case "merged":
      return "PR đã được merge trên GitHub";
    case "reviewed":
      return "Bạn đã gửi review trên GitHub";
    case "replied":
      return "Bạn đã trả lời bình luận trên GitHub";
    case "succeeded":
      return item.kind === "deploy"
        ? "Deploy đã thành công trở lại"
        : "Build đã chạy xanh trở lại";
    case "completed":
      return "Issue đã được đóng trên GitHub";
  }
  return "Mục liên kết đã xong trên GitHub";
}

/** Why the task came back, as a plain sentence. */
export function reopenSentence(item: Item): string {
  if (item.source === "jira") {
    return `${item.external_id} bị chuyển về ${
      item.status_name ??
        (item.status === "in_progress" ? "In Progress" : "To Do")
    }`;
  }
  switch (item.kind) {
    case "build":
      return "Build bị lỗi lại";
    case "deploy":
      return "Deploy bị lỗi lại";
    case "mention":
      return "Có bình luận mới cần bạn trả lời";
    case "issue":
      return "Issue được mở lại";
  }
  return item.status === "review_requested"
    ? "Bạn được nhờ review lại"
    : "PR bị yêu cầu sửa hoặc được mở lại";
}

function external(
  item: Item,
): Pick<PushPayload, "url" | "source" | "category"> {
  const label = SOURCE_LABEL[item.source];
  return item.url && label
    ? {
      url: item.url,
      source: item.source,
      category: `SYNC_${item.source.toUpperCase()}`,
    }
    : {};
}

export function syncDoneMessage(
  task: { id: string; title: string },
  item: Item,
): PushPayload {
  return {
    title: clip(`Đã xong: ${task.title}`),
    body: `${doneReason(item)}. Not3 đã tự đánh dấu xong.`,
    task_id: task.id,
    link: `not3://task/${task.id}`,
    ...external(item),
  };
}

export function syncReopenedMessage(
  task: { id: string; title: string },
  item: Item,
): PushPayload {
  return {
    title: clip(`Cần làm lại: ${task.title}`),
    body: `${reopenSentence(item)}. Not3 đã bỏ tick để bạn không bỏ sót.`,
    task_id: task.id,
    link: `not3://task/${task.id}`,
    level: "active",
    relevance: 0.7,
    ...external(item),
  };
}
