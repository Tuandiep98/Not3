import { assertEquals, assertMatch } from "jsr:@std/assert@1.0.8";
import {
  suggestCheckIn,
  summarizeWeekByRules,
  tagNote,
  type WeekStats,
} from "./ai.ts";
import {
  chatJSON,
  chatWithTools,
  type ModelInfo,
  pickModel,
  resetModelCache,
} from "./deepseek.ts";
import { z } from "npm:zod@3.23.8";

const CATEGORIES = ["Công việc", "Học ngôn ngữ", "Sở thích"];

/** Models as listed by GET /models on 2026-11-01 (plus legacy aliases still accepted). */
const LIVE_MODELS: ModelInfo[] = [
  {
    id: "deepseek-v4-pro",
    context_window: 1048576,
    max_output_tokens: 393216,
    input_modalities: ["text"],
    effort: { supported_levels: ["low", "high", "max"], default_level: "high" },
  },
  {
    id: "deepseek-flash",
    context_window: 1048576,
    max_output_tokens: 393216,
    input_modalities: ["text", "image"],
    effort: { supported_levels: ["low", "high"] },
  },
  {
    id: "deepseek-v4-flash",
    context_window: 1048576,
    max_output_tokens: 393216,
    input_modalities: ["text"],
  },
  { id: "deepseek-v4-flash-vision-exp", input_modalities: ["text", "image"] },
];

function mockDeepSeek(...replies: unknown[]) {
  Deno.env.set("DEEPSEEK_API_KEY", "test");
  Deno.env.delete("DEEPSEEK_MODEL");
  resetModelCache();
  const queue = [...replies];
  const bodies: Record<string, unknown>[] = [];
  const respond = (url: string, init?: RequestInit): Response => {
    if (url.endsWith("/models")) {
      return new Response(
        JSON.stringify({ object: "list", data: LIVE_MODELS }),
      );
    }
    bodies.push(JSON.parse(String(init?.body)));
    const next = queue.shift();
    if (next instanceof Response) return next;
    return new Response(JSON.stringify({ choices: [{ message: next }] }));
  };
  globalThis.fetch =
    ((input: RequestInfo | URL, init?: RequestInit) =>
      Promise.resolve(respond(String(input), init))) as typeof fetch;
  return bodies;
}

const json = (value: unknown) => ({ content: JSON.stringify(value) });

Deno.test("suggestCheckIn keeps valid AI output and drops unknown external ids", async () => {
  const bodies = mockDeepSeek(json({
    morning: [{ external_id: "pr-42", label: "Review PR #42" }, {
      external_id: "ghost",
      label: "Bịa",
    }],
    afternoon: [{
      title: "Học 20 từ vựng Anki",
      category: "Học ngôn ngữ",
      duration_minutes: 25,
    }],
  }));
  const result = await suggestCheckIn({
    morning: [{
      source: "github",
      external_id: "pr-42",
      title: "Add login tests (#42)",
    }],
    categories: CATEGORIES,
    recentTasks: [],
  });
  assertEquals(result?.morning, [{
    external_id: "pr-42",
    label: "Review PR #42",
  }]);
  assertEquals(result?.afternoon[0].category, "Học ngôn ngữ");
  assertEquals(
    (bodies[0].response_format as { type: string }).type,
    "json_object",
  );
  assertEquals(bodies[0].model, "deepseek-flash");
  assertEquals(bodies[0].thinking, { type: "disabled" });
});

Deno.test("suggestCheckIn returns null (rules fallback) when AI invents a category", async () => {
  mockDeepSeek(json({
    morning: [],
    afternoon: [{
      title: "Chơi game",
      category: "Giải trí",
      duration_minutes: 25,
    }],
  }));
  const result = await suggestCheckIn({
    morning: [],
    categories: CATEGORIES,
    recentTasks: [],
  });
  assertEquals(result, null);
});

Deno.test("tagNote returns null on broken JSON and when AI is not configured", async () => {
  mockDeepSeek({ content: "không phải json" });
  assertEquals(
    await tagNote({
      title: "Từ vựng tuần 44",
      body: null,
      categories: CATEGORIES,
    }),
    null,
  );
  Deno.env.delete("DEEPSEEK_API_KEY");
  assertEquals(
    await tagNote({ title: "x", body: null, categories: CATEGORIES }),
    null,
  );
});

Deno.test("chatWithTools runs the requested tool then returns the answer", async () => {
  const bodies = mockDeepSeek(
    {
      content: null,
      tool_calls: [{
        id: "c1",
        type: "function",
        function: {
          name: "query_tasks",
          arguments: '{"from":"2026-10-01","to":"2026-10-31"}',
        },
      }],
    },
    { content: "Tháng 10 bạn học tiếng Anh 8 buổi." },
  );
  const calls: unknown[] = [];
  const answer = await chatWithTools({
    need: "light",
    tools: [],
    messages: [{ role: "user", content: "Tháng 10 học mấy buổi?" }],
    runTool: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve({ count: 8 });
    },
  });
  assertEquals(answer, "Tháng 10 bạn học tiếng Anh 8 buổi.");
  assertEquals(calls, [{
    name: "query_tasks",
    args: { from: "2026-10-01", to: "2026-10-31" },
  }]);
  const second = bodies[1].messages as { role: string; content: string }[];
  assertEquals(second.at(-1)?.role, "tool");
  assertEquals(second.at(-1)?.content, '{"count":8}');
});

Deno.test("summarizeWeekByRules states the facts without blame", () => {
  const stats: WeekStats = {
    week_start: "2026-10-26",
    meaningful_days: 5,
    days: [],
    by_category: { "Công việc": 6, "Học ngôn ngữ": 4 },
    empty_days: ["T4", "T7"],
  };
  const text = summarizeWeekByRules(stats);
  assertMatch(text, /5\/7 ngày/);
  assertMatch(text, /Công việc \(6 buổi\)/);
  assertMatch(text, /T4, T7/);
});

Deno.test("pickModel: light → flash alias, deep → pro, legacy aliases skipped", () => {
  Deno.env.delete("DEEPSEEK_MODEL");
  assertEquals(pickModel(LIVE_MODELS, "light"), "deepseek-flash");
  assertEquals(pickModel(LIVE_MODELS, "deep"), "deepseek-v4-pro");
});

Deno.test("pickModel: renamed models still resolve without config", () => {
  Deno.env.delete("DEEPSEEK_MODEL");
  const renamed: ModelInfo[] = [
    {
      id: "deepseek-v5-mini",
      max_output_tokens: 65536,
      effort: { supported_levels: ["low"] },
    },
    {
      id: "deepseek-v5",
      max_output_tokens: 393216,
      effort: { supported_levels: ["low", "high", "max"] },
    },
  ];
  assertEquals(pickModel(renamed, "light"), "deepseek-v5-mini");
  assertEquals(pickModel(renamed, "deep"), "deepseek-v5");
  assertEquals(pickModel([], "deep"), "deepseek-v4-pro");
});

Deno.test("pickModel: DEEPSEEK_MODEL overrides everything", () => {
  Deno.env.set("DEEPSEEK_MODEL", "deepseek-custom");
  assertEquals(pickModel(LIVE_MODELS, "light"), "deepseek-custom");
  assertEquals(pickModel(LIVE_MODELS, "deep"), "deepseek-custom");
  Deno.env.delete("DEEPSEEK_MODEL");
});

Deno.test("chatJSON retries once when JSON mode returns blank content", async () => {
  const bodies = mockDeepSeek({ content: "   " }, json({ ok: true }));
  const result = await chatJSON({
    need: "light",
    system: "json",
    user: "x",
    schema: z.object({ ok: z.boolean() }),
  });
  assertEquals(result, { ok: true });
  assertEquals(bodies.length, 2);
});

Deno.test("an unknown-model error refreshes the model list and retries", async () => {
  const bodies = mockDeepSeek(
    new Response('{"error":{"message":"Model Not Exist"}}', { status: 400 }),
    json({ ok: true }),
  );
  const result = await chatJSON({
    need: "deep",
    system: "json",
    user: "x",
    schema: z.object({ ok: z.boolean() }),
  });
  assertEquals(result, { ok: true });
  assertEquals(bodies.map((b) => b.model), [
    "deepseek-v4-pro",
    "deepseek-v4-pro",
  ]);
});

Deno.test("chatWithTools passes reasoning_content back on tool turns", async () => {
  const bodies = mockDeepSeek(
    {
      content: null,
      reasoning_content: "cần đếm task",
      tool_calls: [{
        id: "c1",
        type: "function",
        function: { name: "query_tasks", arguments: "{}" },
      }],
    },
    { content: "Xong." },
  );
  await chatWithTools({
    need: "light",
    tools: [],
    messages: [{ role: "user", content: "?" }],
    runTool: () => Promise.resolve({}),
  });
  const assistant =
    (bodies[1].messages as { role: string; reasoning_content?: string }[])
      .find((m) => m.role === "assistant");
  assertEquals(assistant?.reasoning_content, "cần đếm task");
});
