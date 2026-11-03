// Called by the app with the user's JWT. Today: "ask" — questions about the user's history.
// The model answers only through tools that query Postgres under RLS, so it never guesses numbers.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { z } from "npm:zod@3.23.8";
import { adminClient, json, publishableKey } from "../_shared/admin.ts";
import { canUseAI } from "../_shared/ai.ts";
import { AIUnavailable, chatWithTools, type ToolSpec } from "../_shared/deepseek.ts";

const Request = z.object({
  task: z.literal("ask"),
  question: z.string().min(2).max(300),
  timezone: z.string().default("Asia/Ho_Chi_Minh"),
});

const dateRange = {
  type: "object",
  properties: {
    from: { type: "string", description: "Ngày bắt đầu YYYY-MM-DD (bao gồm)" },
    to: { type: "string", description: "Ngày kết thúc YYYY-MM-DD (bao gồm)" },
  },
  required: ["from", "to"],
};

const tools: ToolSpec[] = [
  {
    type: "function",
    function: {
      name: "query_tasks",
      description: "Đếm và liệt kê việc của người dùng trong khoảng ngày. Lọc theo loại việc và trạng thái.",
      parameters: {
        ...dateRange,
        properties: {
          ...dateRange.properties,
          category: { type: "string", description: "Loại việc, ví dụ 'Học ngôn ngữ'" },
          status: { type: "string", enum: ["todo", "doing", "done", "cancelled"] },
        },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "query_checkins",
      description: "Các lần check-in 12h trong khoảng ngày: ngày, cảm nhận (good/ok/empty), việc buổi sáng.",
      parameters: dateRange,
    },
  },
];

const RangeArgs = z.object({
  from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  category: z.string().optional(),
  status: z.enum(["todo", "doing", "done", "cancelled"]).optional(),
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const authHeader = req.headers.get("Authorization") ?? "";
  const userDb = createClient(Deno.env.get("SUPABASE_URL")!, publishableKey(), {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user } } = await userDb.auth.getUser();
  if (!user) return json({ error: "Chưa đăng nhập" }, 401);

  const parsed = Request.safeParse(await req.json().catch(() => ({})));
  if (!parsed.success) return json({ error: "Yêu cầu không hợp lệ" }, 400);
  const { question, timezone } = parsed.data;

  if (!(await canUseAI(adminClient(), user.id))) {
    return json({ answer: null, error: "AI đang tắt hoặc đã hết lượt hôm nay." }, 200);
  }

  const today = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" })
    .format(new Date());

  try {
    const answer = await chatWithTools({
      need: "light",
      tools,
      messages: [
        {
          role: "system",
          content: [
            "Bạn trả lời câu hỏi của người dùng về lịch sử việc làm và check-in của chính họ.",
            "Mọi con số phải lấy từ công cụ; không có dữ liệu thì nói không có. Không đoán.",
            "Trả lời tiếng Việt, 1–3 câu, trung tính, không trách móc.",
          ].join("\n"),
        },
        { role: "user", content: `Hôm nay là ${today} (múi giờ ${timezone}). Câu hỏi: ${question}` },
      ],
      runTool: async (name, raw) => {
        const args = RangeArgs.parse(raw);
        // RLS: userDb only sees this user's rows.
        if (name === "query_tasks") {
          let q = userDb.from("tasks").select("title, chips, status, planned_at, completed_at", { count: "exact" })
            .gte("created_at", `${args.from}T00:00:00`).lte("created_at", `${args.to}T23:59:59`);
          if (args.category) q = q.contains("chips", [args.category]);
          if (args.status) q = q.eq("status", args.status);
          const { data, count, error } = await q.limit(50);
          if (error) throw error;
          return { count, items: data };
        }
        if (name === "query_checkins") {
          const { data, error } = await userDb.from("checkins").select("day, mood, mood_label, morning_items")
            .gte("day", args.from).lte("day", args.to).order("day");
          if (error) throw error;
          return { count: data?.length ?? 0, items: data };
        }
        throw new Error(`unknown tool ${name}`);
      },
    });
    return json({ answer });
  } catch (e) {
    if (e instanceof AIUnavailable) return json({ answer: null, error: "AI tạm thời không trả lời được." }, 200);
    console.error(e);
    return json({ error: "Lỗi máy chủ" }, 500);
  }
});
