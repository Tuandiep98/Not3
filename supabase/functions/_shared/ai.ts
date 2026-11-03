import { z } from "npm:zod@3.23.8";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { aiConfigured, AIUnavailable, chatJSON } from "./deepseek.ts";

// AI tasks (README §10). Each returns null when AI is off / failed so callers use rules.

export const DURATIONS = [15, 25, 45, 60] as const;
const DAILY_LIMIT = Number(Deno.env.get("AI_DAILY_LIMIT") ?? "30");

/** Same tone rule as the app: neutral, never blaming an empty morning. */
const TONE =
  "Viết tiếng Việt, ngắn, trung tính. Không chấm điểm, không trách móc khi người dùng làm ít.";

/** Checks the user's AI switch and takes one call from their daily quota. */
export async function canUseAI(
  db: SupabaseClient,
  userId: string,
): Promise<boolean> {
  if (!aiConfigured()) return false;
  const { data: profile } = await db
    .from("profiles")
    .select("ai_notes_enabled")
    .eq("user_id", userId)
    .maybeSingle();
  if (profile && profile.ai_notes_enabled === false) return false;
  const { data, error } = await db.rpc("try_consume_ai", {
    p_user: userId,
    p_limit: DAILY_LIMIT,
  });
  return !error && data === true;
}

async function guarded<T>(
  task: string,
  fn: () => Promise<T>,
): Promise<T | null> {
  try {
    return await fn();
  } catch (e) {
    if (!(e instanceof AIUnavailable)) console.error(`[ai:${task}]`, e);
    else console.warn(`[ai:${task}] fallback:`, e.message);
    return null;
  }
}

// --- Check-in chips ----------------------------------------------------------

export type MorningItem = {
  source: string;
  external_id: string;
  title: string;
};
export type AfternoonTask = {
  title: string;
  category: string;
  duration_minutes: number;
};

export async function suggestCheckIn(input: {
  morning: MorningItem[];
  categories: string[];
  recentTasks: {
    title: string;
    category: string | null;
    done: boolean;
    day: string;
  }[];
}): Promise<
  {
    morning: { external_id: string; label: string }[];
    afternoon: AfternoonTask[];
  } | null
> {
  const categories = input.categories;
  const schema = z.object({
    morning: z
      .array(
        z.object({ external_id: z.string(), label: z.string().min(1).max(40) }),
      )
      .max(12),
    afternoon: z
      .array(
        z.object({
          title: z.string().min(1).max(40),
          category: z
            .string()
            .refine((c) => categories.includes(c), "category not allowed"),
          duration_minutes: z
            .number()
            .int()
            .refine((d) => (DURATIONS as readonly number[]).includes(d)),
        }),
      )
      .min(1)
      .max(3),
  });
  const result = await guarded("checkin", () =>
    chatJSON({
      need: "light",
      system: [
        "Bạn giúp người dùng app ghi chú check-in lúc 12h trưa. Trả về JSON.",
        "morning: với mỗi mục buổi sáng, viết nhãn chip ≤ 40 ký tự, giữ mã ngắn (PR #42, JIRA-118), giữ đúng external_id.",
        "afternoon: đúng 3 việc nhỏ cho buổi chiều. Ưu tiên loại việc người dùng chưa làm trong 7 ngày,",
        "ưu tiên phát triển bản thân (học, sở thích, sức khoẻ) trước Công việc. Tiêu đề là câu hành động cụ thể,",
        "dựa trên việc người dùng từng làm. category phải nằm trong danh sách cho sẵn.",
        "duration_minutes ∈ {15, 25, 45, 60}.",
        TONE,
        'Định dạng: {"morning":[{"external_id":"...","label":"..."}],"afternoon":[{"title":"...","category":"...","duration_minutes":25}]}',
      ].join("\n"),
      user: JSON.stringify({
        categories,
        morning: input.morning.map(({ source, external_id, title }) => ({
          source,
          external_id,
          title,
        })),
        recent_tasks: input.recentTasks.slice(0, 60),
      }),
      schema,
    }));
  if (!result) return null;
  const known = new Set(input.morning.map((m) => m.external_id));
  return {
    morning: result.morning.filter((m) => known.has(m.external_id)),
    afternoon: result.afternoon,
  };
}

// --- Note chips --------------------------------------------------------------

export async function tagNote(input: {
  title: string;
  body: string | null;
  categories: string[];
}): Promise<string[] | null> {
  const categories = input.categories;
  const schema = z.object({
    chips: z.array(z.string().refine((c) => categories.includes(c))).max(2),
  });
  const result = await guarded("tag-note", () =>
    chatJSON({
      need: "light",
      system: [
        "Gắn tối đa 2 chip loại việc cho một ghi chú. Chỉ chọn trong danh sách categories.",
        'Không chắc thì trả mảng rỗng. Trả về JSON dạng {"chips": ["..."]}.',
      ].join("\n"),
      // Minimal data: body is only present when the user allowed note content on the server.
      user: JSON.stringify({
        categories,
        title: input.title,
        body: input.body?.slice(0, 1500) ?? null,
      }),
      schema,
      maxTokens: 100,
    }));
  return result ? [...new Set(result.chips)] : null;
}

// --- Weekly summary ----------------------------------------------------------

export type WeekStats = {
  week_start: string;
  meaningful_days: number;
  // mood: level (good / ok / empty); mood_label: the user's own name for the feeling.
  days: { day: string; weekday: string; done: string[]; mood: string | null; mood_label?: string | null }[];
  by_category: Record<string, number>;
  empty_days: string[];
};

export async function summarizeWeek(stats: WeekStats): Promise<string | null> {
  const schema = z.object({ summary: z.string().min(20).max(600) });
  const result = await guarded("weekly", () =>
    chatJSON({
      need: "deep",
      system: [
        'Viết nhận xét tổng kết tuần cho người dùng app ghi chú, 3–5 câu, trả về JSON {"summary": "..."}.',
        "Chỉ dùng số liệu được cho, không bịa số. Nêu một quy luật (ví dụ thời điểm hay làm việc ý nghĩa),",
        "lý do có thể của ngày trống nếu dữ liệu cho thấy, và đúng một gợi ý cụ thể cho tuần tới.",
        TONE,
      ].join("\n"),
      user: JSON.stringify(stats),
      schema,
      maxTokens: 400,
    }));
  return result?.summary ?? null;
}

/** Rule-based summary when AI is off: same facts, fixed wording. */
export function summarizeWeekByRules(stats: WeekStats): string {
  const top = Object.entries(stats.by_category).sort((a, b) => b[1] - a[1])[0];
  const parts = [
    `Tuần này bạn có ${stats.meaningful_days}/7 ngày có việc ý nghĩa.`,
  ];
  if (top) parts.push(`Bạn làm nhiều nhất ở nhóm ${top[0]} (${top[1]} buổi).`);
  if (stats.empty_days.length) {
    parts.push(
      `Ngày còn trống: ${
        stats.empty_days.join(", ")
      }. Thử chốt kế hoạch chiều ngay lúc check-in vào những ngày đó.`,
    );
  } else {
    parts.push("Không có ngày nào trống — giữ nhịp này nhé.");
  }
  return parts.join(" ");
}
