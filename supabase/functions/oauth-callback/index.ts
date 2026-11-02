// OAuth redirect target (GitHub / Atlassian → here). Exchanges the code on the server,
// stores the token in Vault, then hands control back to the app via not3://oauth.
import { adminClient } from "../_shared/admin.ts";
import {
  accountInfo,
  exchangeCode,
  JIRA_SCOPES,
  type Provider,
  syncUser,
} from "../_shared/integrations.ts";

const STATE_TTL_MS = 15 * 60 * 1000;

function backToApp(params: Record<string, string>): Response {
  const target = `not3://oauth?${new URLSearchParams(params)}`;
  return new Response(null, { status: 302, headers: { Location: target } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const denied = url.searchParams.get("error");
  if (!state) return new Response("Thiếu state", { status: 400 });

  const db = adminClient();
  const { data: row } = await db.from("oauth_states").select(
    "user_id, provider, created_at",
  ).eq("state", state).maybeSingle();
  await db.from("oauth_states").delete().eq("state", state);
  if (!row || Date.now() - new Date(row.created_at).getTime() > STATE_TTL_MS) {
    return backToApp({
      status: "error",
      message: "Phiên kết nối đã hết hạn, thử lại.",
    });
  }
  const provider = row.provider as Provider;
  if (denied || !code) return backToApp({ provider, status: "cancelled" });

  try {
    const token = await exchangeCode(provider, code);
    const { account, meta } = await accountInfo(provider, token);
    const { error } = await db.rpc("save_integration", {
      p_user: row.user_id,
      p_provider: provider,
      p_account: account,
      p_scopes: provider === "jira" ? JIRA_SCOPES : [],
      p_token: token,
      p_meta: meta,
    });
    if (error) throw error;

    // First pull right away so the user sees data without waiting for the cron.
    const { data: profile } = await db.from("profiles").select("timezone").eq(
      "user_id",
      row.user_id,
    ).maybeSingle();
    await syncUser(db, row.user_id, profile?.timezone ?? "Asia/Ho_Chi_Minh")
      .catch(() => undefined);
    return backToApp({ provider, status: "ok", account });
  } catch (e) {
    console.error("[oauth-callback]", e);
    return backToApp({
      provider,
      status: "error",
      message: e instanceof Error ? e.message : "Lỗi kết nối",
    });
  }
});
