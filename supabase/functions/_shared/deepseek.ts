import { z } from "npm:zod@3.23.8";

// DeepSeek Chat Completions (OpenAI-compatible): JSON output + tool calling.
// Docs checked 2026-11-01: https://api-docs.deepseek.com
//
// Model names are NOT configured per tier. They are discovered from `GET /models` and picked
// by what the task needs, so a renamed model (e.g. deepseek-v4-flash → deepseek-flash) needs
// no redeploy. Optional override: DEEPSEEK_MODEL forces one model for every task.

export class AIUnavailable extends Error {}

/** What a task needs: `light` = short, cheap, high-volume; `deep` = best quality, low volume. */
export type Need = "light" | "deep";

export type ChatMessage =
  | { role: "system" | "user"; content: string }
  | {
    role: "assistant";
    content: string | null;
    reasoning_content?: string | null;
    tool_calls?: ToolCall[];
  }
  | { role: "tool"; tool_call_id: string; content: string };

export type ToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};

export type ToolSpec = {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
};

export type ModelInfo = {
  id: string;
  name?: string;
  context_window?: number;
  max_output_tokens?: number;
  input_modalities?: string[];
  effort?: { supported_levels: string[]; default_level?: string };
};

/** Last names seen in the docs; used only when `/models` cannot be reached. */
const FALLBACK: Record<Need, string> = {
  light: "deepseek-flash",
  deep: "deepseek-v4-pro",
};
const MODELS_TTL_MS = 6 * 3600 * 1000;

let modelCache: { models: ModelInfo[]; fetchedAt: number } | null = null;

function baseUrl() {
  return Deno.env.get("DEEPSEEK_BASE_URL") ?? "https://api.deepseek.com";
}

function apiKey(): string {
  const key = Deno.env.get("DEEPSEEK_API_KEY");
  if (!key) throw new AIUnavailable("DeepSeek chưa được cấu hình");
  return key;
}

export function aiConfigured(): boolean {
  return Boolean(Deno.env.get("DEEPSEEK_API_KEY"));
}

/** Test hook. */
export function resetModelCache() {
  modelCache = null;
}

async function listModels(force = false): Promise<ModelInfo[]> {
  if (
    !force && modelCache && Date.now() - modelCache.fetchedAt < MODELS_TTL_MS
  ) {
    return modelCache.models;
  }
  try {
    const res = await fetch(`${baseUrl()}/models`, {
      headers: { Authorization: `Bearer ${apiKey()}` },
      signal: AbortSignal.timeout(8_000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = (await res.json()) as { data?: ModelInfo[] };
    const models = (body.data ?? []).filter((m) => typeof m.id === "string");
    if (models.length) modelCache = { models, fetchedAt: Date.now() };
    return models;
  } catch (e) {
    if (e instanceof AIUnavailable) throw e;
    console.warn(
      "[deepseek] /models unavailable, using fallback names:",
      String(e),
    );
    return modelCache?.models ?? [];
  }
}

/**
 * Picks a model id for a need from the live model list:
 *  - light → a "flash"-family model (cheap, highest concurrency);
 *  - deep  → a "pro"-family model, else the largest by output limit / effort levels;
 *  - text input required; legacy aliases (vision-exp, dated v4-flash) are skipped when a current one exists.
 */
export function pickModel(models: ModelInfo[], need: Need): string {
  const override = Deno.env.get("DEEPSEEK_MODEL");
  if (override) return override;

  const usable = models.filter(
    (m) => !m.input_modalities || m.input_modalities.includes("text"),
  );
  if (!usable.length) return FALLBACK[need];

  const isLegacy = (m: ModelInfo) => /-exp\b|vision-exp/.test(m.id);
  const current = usable.filter((m) => !isLegacy(m));
  const pool = current.length ? current : usable;

  const family = (word: string) =>
    pool.filter((m) => m.id.toLowerCase().includes(word));
  const strength = (m: ModelInfo) =>
    (m.effort?.supported_levels?.length ?? 0) * 1e9 +
    (m.max_output_tokens ?? 0) +
    (m.context_window ?? 0) / 1e3;
  const byStrength = [...pool].sort((a, b) => strength(b) - strength(a));

  if (need === "light") {
    const flash = family("flash");
    if (flash.length) return shortestId(flash);
    return byStrength.at(-1)!.id;
  }
  const pro = family("pro");
  if (pro.length) {
    return [...pro].sort((a, b) => strength(b) - strength(a))[0].id;
  }
  return byStrength[0].id;
}

/** Prefer the plain alias ("deepseek-flash") over versioned ids ("deepseek-v4-flash"). */
function shortestId(models: ModelInfo[]): string {
  return [...models].sort(
    (a, b) => a.id.length - b.id.length || a.id.localeCompare(b.id),
  )[0].id;
}

export async function resolveModel(need: Need): Promise<string> {
  return pickModel(await listModels(), need);
}

type CompletionMessage = {
  content: string | null;
  reasoning_content?: string | null;
  tool_calls?: ToolCall[];
};

async function complete(
  need: Need,
  body: Record<string, unknown>,
  retryOnUnknownModel = true,
): Promise<CompletionMessage> {
  const key = apiKey();
  const model = await resolveModel(need);
  let res: Response;
  try {
    res = await fetch(`${baseUrl()}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      // Thinking is on by default; our tasks are short structured outputs, so turn it off:
      // lower latency/cost, and `temperature` only applies in non-thinking mode.
      body: JSON.stringify({
        model,
        thinking: { type: "disabled" },
        temperature: 0.3,
        ...body,
      }),
      signal: AbortSignal.timeout(25_000),
    });
  } catch (e) {
    throw new AIUnavailable(`DeepSeek không phản hồi: ${e}`);
  }
  if (!res.ok) {
    const text = await res.text();
    // A renamed/retired model: refresh the list once and retry with the new pick.
    if (
      retryOnUnknownModel &&
      (res.status === 400 || res.status === 404) &&
      /model/i.test(text)
    ) {
      await listModels(true);
      return complete(need, body, false);
    }
    throw new AIUnavailable(`DeepSeek ${res.status}: ${text}`);
  }
  const data = await res.json();
  const message = data?.choices?.[0]?.message;
  if (!message) throw new AIUnavailable("DeepSeek trả về rỗng");
  return message as CompletionMessage;
}

/**
 * One JSON-mode call validated with Zod. The fixed system prompt goes first so DeepSeek's
 * context cache is reused across users; per-user data goes in the user message.
 * JSON mode can return whitespace-only content — retried once, as the docs advise.
 */
export async function chatJSON<T>(opts: {
  need: Need;
  system: string;
  user: string;
  schema: z.ZodType<T>;
  maxTokens?: number;
}): Promise<T> {
  const request = {
    messages: [
      { role: "system", content: opts.system },
      { role: "user", content: opts.user },
    ],
    response_format: { type: "json_object" },
    max_tokens: opts.maxTokens ?? 800,
  };
  let content = "";
  for (let attempt = 0; attempt < 2 && !content.trim(); attempt++) {
    content = (await complete(opts.need, request)).content ?? "";
  }
  if (!content.trim()) throw new AIUnavailable("DeepSeek trả về JSON rỗng");
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    throw new AIUnavailable("DeepSeek trả về JSON không hợp lệ");
  }
  const result = opts.schema.safeParse(parsed);
  if (!result.success) {
    throw new AIUnavailable(`Sai schema: ${result.error.message}`);
  }
  return result.data;
}

/** Tool-calling loop: the model asks for data, we run the tool, until it answers. */
export async function chatWithTools(opts: {
  need: Need;
  messages: ChatMessage[];
  tools: ToolSpec[];
  runTool: (name: string, args: unknown) => Promise<unknown>;
  maxRounds?: number;
}): Promise<string> {
  const messages = [...opts.messages];
  for (let round = 0; round < (opts.maxRounds ?? 4); round++) {
    const message = await complete(opts.need, {
      messages,
      tools: opts.tools,
      max_tokens: 600,
    });
    if (!message.tool_calls?.length) return message.content ?? "";
    // If thinking is ever on, reasoning_content must be sent back with tool turns (else HTTP 400).
    messages.push({
      role: "assistant",
      content: message.content,
      ...(message.reasoning_content
        ? { reasoning_content: message.reasoning_content }
        : {}),
      tool_calls: message.tool_calls,
    });
    for (const call of message.tool_calls) {
      let args: unknown = {};
      try {
        args = JSON.parse(call.function.arguments || "{}");
      } catch {
        /* empty args */
      }
      const output = await opts
        .runTool(call.function.name, args)
        .catch((e) => ({ error: String(e) }));
      messages.push({
        role: "tool",
        tool_call_id: call.id,
        content: JSON.stringify(output),
      });
    }
  }
  throw new AIUnavailable("Quá nhiều vòng gọi công cụ");
}
