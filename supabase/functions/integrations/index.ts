// Called by the app with the user's JWT.
//   { action: "connect", provider }  → { url } to open in ASWebAuthenticationSession
//   { action: "sync", timezone }     → pulls GitHub/Jira now (Settings → "Đồng bộ ngay")
//   { action: "status" }             → which providers the server is configured for
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { z } from "npm:zod@3.23.8";
import { adminClient, json, publishableKey } from "../_shared/admin.ts";
import {
  authorizeUrl,
  jiraStatuses,
  type Provider,
  providerConfigured,
  syncUser,
} from "../_shared/integrations.ts";

const Body = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("connect"),
    provider: z.enum(["github", "jira"]),
  }),
  z.object({
    action: z.literal("sync"),
    timezone: z.string().default("Asia/Ho_Chi_Minh"),
  }),
  z.object({ action: z.literal("status") }),
  z.object({ action: z.literal("jira_statuses") }),
]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const userDb = createClient(Deno.env.get("SUPABASE_URL")!, publishableKey(), {
    global: {
      headers: { Authorization: req.headers.get("Authorization") ?? "" },
    },
    auth: { persistSession: false },
  });
  const { data: { user } } = await userDb.auth.getUser();
  if (!user) return json({ error: "Chưa đăng nhập" }, 401);

  const parsed = Body.safeParse(await req.json().catch(() => ({})));
  if (!parsed.success) return json({ error: "Yêu cầu không hợp lệ" }, 400);
  const body = parsed.data;
  const db = adminClient();

  if (body.action === "jira_statuses") {
    try {
      return json({ statuses: await jiraStatuses(db, user.id) });
    } catch (e) {
      return json({
        statuses: [],
        error: e instanceof Error ? e.message : String(e),
      });
    }
  }

  if (body.action === "status") {
    return json({
      github: providerConfigured("github"),
      jira: providerConfigured("jira"),
    });
  }

  if (body.action === "connect") {
    const provider: Provider = body.provider;
    if (!providerConfigured(provider)) {
      return json({
        error: `${
          provider === "github" ? "GitHub" : "Jira"
        } chưa được cấu hình trên server.`,
      }, 400);
    }
    const state = crypto.randomUUID() + crypto.randomUUID();
    await db.from("oauth_states").delete().lt(
      "created_at",
      new Date(Date.now() - 3600_000).toISOString(),
    );
    const { error } = await db.from("oauth_states").insert({
      state,
      user_id: user.id,
      provider,
    });
    if (error) return json({ error: error.message }, 500);
    return json({ url: authorizeUrl(provider, state) });
  }

  const result = await syncUser(db, user.id, body.timezone);
  return json({ result });
});
