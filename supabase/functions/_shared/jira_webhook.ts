import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

// Jira dynamic webhooks (OAuth 2.0 app): registered per user with the user's own token, so Jira
// pushes changes to issues the user is assignee / reporter of. They expire after 30 days, so they
// are refreshed from the regular sync. The 15-minute poll stays as the safety net (watching,
// transitions, worklogs are not covered by the webhook JQL subset).

export const JIRA_WEBHOOK_SCOPE = "manage:jira-webhook";
export const JIRA_WEBHOOK_EVENTS = [
  "jira:issue_created",
  "jira:issue_updated",
  "jira:issue_deleted",
];

const DAY = 24 * 60 * 60 * 1000;
/** Refresh when fewer than this many days remain (Jira gives 30). */
const REFRESH_BEFORE = 7 * DAY;
/** After a failed registration (e.g. missing scope), retry at most this often. */
const RETRY_AFTER = DAY;

export type JiraWebhookMeta = {
  webhook_ids?: number[];
  webhook_expires_at?: string;
  webhook_checked_at?: string;
  webhook_error?: string | null;
};

/** The webhook JQL only supports a subset (assignee, reporter, project… with =, !=, IN). */
export function jiraWebhookFilters(accountId: string): string[] {
  return [`assignee = "${accountId}"`, `reporter = "${accountId}"`];
}

export function jiraWebhookUrl(): string {
  const base = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  return `${base}/functions/v1/webhook-jira`;
}

export function webhookAction(
  meta: JiraWebhookMeta,
  now = Date.now(),
): "register" | "refresh" | "none" {
  if (meta.webhook_ids?.length) {
    const expires = Date.parse(meta.webhook_expires_at ?? "");
    return !Number.isFinite(expires) || expires - now < REFRESH_BEFORE
      ? "refresh"
      : "none";
  }
  const checked = Date.parse(meta.webhook_checked_at ?? "");
  return Number.isFinite(checked) && now - checked < RETRY_AFTER
    ? "none"
    : "register";
}

type Token = { access_token: string };

async function jiraApi(
  cloudId: string,
  token: Token,
  method: string,
  path: string,
  body?: unknown,
): Promise<Response> {
  return await fetch(
    `https://api.atlassian.com/ex/jira/${cloudId}/rest/api/3${path}`,
    {
      method,
      headers: {
        Authorization: `Bearer ${token.access_token}`,
        Accept: "application/json",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    },
  );
}

function describe(status: number, detail: string): string {
  if (status === 401 || status === 403) {
    return "Thiếu quyền manage:jira-webhook — thêm quyền trong Atlassian app rồi kết nối lại Jira";
  }
  return `Jira webhook ${status}: ${detail.slice(0, 200)}`;
}

/** Webhooks this app already registered for this user (e.g. before a reconnect). */
async function existingIds(cloudId: string, token: Token): Promise<number[]> {
  const res = await jiraApi(cloudId, token, "GET", "/webhook?maxResults=100");
  if (!res.ok) return [];
  const data = (await res.json().catch(() => ({}))) as {
    values?: { id: number }[];
  };
  return (data.values ?? []).map((w) => w.id);
}

async function register(
  cloudId: string,
  token: Token,
  accountId: string,
): Promise<JiraWebhookMeta> {
  // Start clean: the limit is 5 webhooks per app per user.
  const old = await existingIds(cloudId, token);
  if (old.length) {
    await jiraApi(cloudId, token, "DELETE", "/webhook", { webhookIds: old });
  }
  const res = await jiraApi(cloudId, token, "POST", "/webhook", {
    url: jiraWebhookUrl(),
    webhooks: jiraWebhookFilters(accountId).map((jqlFilter) => ({
      jqlFilter,
      events: JIRA_WEBHOOK_EVENTS,
    })),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(describe(res.status, text));
  const data = JSON.parse(text) as {
    webhookRegistrationResult?: {
      createdWebhookId?: number;
      errors?: string[];
    }[];
  };
  const results = data.webhookRegistrationResult ?? [];
  const ids = results.flatMap((r) =>
    r.createdWebhookId != null ? [r.createdWebhookId] : []
  );
  if (!ids.length) {
    const errors = results.flatMap((r) => r.errors ?? []).join("; ");
    throw new Error(`Jira không tạo webhook: ${errors || text.slice(0, 200)}`);
  }
  return {
    webhook_ids: ids,
    webhook_expires_at: new Date(Date.now() + 30 * DAY).toISOString(),
    webhook_error: null,
  };
}

async function refresh(
  cloudId: string,
  token: Token,
  ids: number[],
): Promise<JiraWebhookMeta> {
  const res = await jiraApi(cloudId, token, "PUT", "/webhook/refresh", {
    webhookIds: ids,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(describe(res.status, text));
  const data = JSON.parse(text) as { expirationDate?: string };
  return {
    webhook_ids: ids,
    webhook_expires_at: data.expirationDate ??
      new Date(Date.now() + 30 * DAY).toISOString(),
    webhook_error: null,
  };
}

/**
 * Registers or refreshes the user's Jira webhooks when needed. Never throws: a failure is kept in
 * integrations.meta.webhook_error (shown in Settings → Jira) and retried a day later.
 */
export async function ensureJiraWebhook(
  db: SupabaseClient,
  userId: string,
  token: Token,
  meta: Record<string, unknown>,
  accountId: () => Promise<string>,
): Promise<void> {
  const current = meta as JiraWebhookMeta;
  const action = webhookAction(current);
  const cloudId = String(meta.cloud_id ?? "");
  if (action === "none" || !cloudId) return;

  let patch: JiraWebhookMeta;
  try {
    const me = await accountId();
    if (!me) throw new Error("Không lấy được Jira accountId");
    patch = action === "refresh"
      ? await refresh(cloudId, token, current.webhook_ids ?? []).catch(() =>
        // Expired for good or deleted on Jira's side: register again.
        register(cloudId, token, me)
      )
      : await register(cloudId, token, me);
  } catch (e) {
    patch = {
      webhook_ids: [],
      webhook_error: e instanceof Error ? e.message : String(e),
    };
  }
  patch.webhook_checked_at = new Date().toISOString();

  // Merge into the latest meta (a token refresh may have rewritten it meanwhile).
  const { data: row } = await db
    .from("integrations")
    .select("meta")
    .eq("user_id", userId)
    .eq("provider", "jira")
    .maybeSingle();
  await db
    .from("integrations")
    .update({ meta: { ...(row?.meta ?? meta), ...patch } })
    .eq("user_id", userId)
    .eq("provider", "jira");
}
