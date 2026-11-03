// GitHub App webhook (pull_request, issues): near real-time status. The cron sync and the nightly
// reconcile stay as the safety net. Signature: HMAC SHA-256 of the raw body (X-Hub-Signature-256).
import { adminClient, json } from "../_shared/admin.ts";
import { githubItem, type GithubSearchItem } from "../_shared/integrations.ts";
import { classifyAndApply } from "../_shared/classify.ts";
import { buildCards } from "../_shared/cards.ts";
import { linkAndSync } from "../_shared/links.ts";
import { queueSilentRefresh } from "../_shared/push.ts";
import { doneRules } from "../_shared/settings.ts";
import { verifySignature } from "./signature.ts";

type Payload = {
  action?: string;
  sender?: { login: string };
  repository?: { url: string };
  pull_request?: GithubSearchItem & {
    merged_at: string | null;
    assignees?: { login: string }[];
    requested_reviewers?: { login: string }[];
  };
  issue?: GithubSearchItem & { assignees?: { login: string }[] };
};

Deno.serve(async (req) => {
  const secret = Deno.env.get("GITHUB_WEBHOOK_SECRET");
  if (!secret) return json({ error: "webhook not configured" }, 503);
  const body = await req.text();
  if (
    !(await verifySignature(
      secret,
      body,
      req.headers.get("X-Hub-Signature-256"),
    ))
  ) {
    return json({ error: "bad signature" }, 401);
  }
  const event = req.headers.get("X-GitHub-Event") ?? "";
  const delivery = req.headers.get("X-GitHub-Delivery") ?? crypto.randomUUID();
  const db = adminClient();

  // Dedupe: a redelivered event is acknowledged without processing it twice.
  const { error: dup } = await db.from("sync_events").insert({
    provider: "github",
    delivery_id: delivery,
    event,
  });
  if (dup) return json({ ok: true, duplicate: true });

  if (event !== "pull_request" && event !== "issues") {
    await db.from("sync_events").update({ status: "skipped" }).eq(
      "provider",
      "github",
    ).eq("delivery_id", delivery);
    return json({ ok: true, skipped: event });
  }

  try {
    const payload = JSON.parse(body) as Payload;
    const raw = payload.pull_request ?? payload.issue;
    if (!raw) throw new Error("no item in payload");
    const item: GithubSearchItem = {
      ...raw,
      repository_url: raw.repository_url ?? payload.repository?.url ?? "",
      pull_request: payload.pull_request
        ? { merged_at: payload.pull_request.merged_at }
        : undefined,
    };
    // Everyone involved who connected GitHub to Not3.
    const involved = new Set([
      raw.user?.login,
      payload.sender?.login,
      ...(raw.assignees ?? []).map((a) => a.login),
      ...(payload.pull_request?.requested_reviewers ?? []).map((r) => r.login),
    ].filter(Boolean) as string[]);
    const { data: users } = await db.from("integrations").select(
      "user_id, meta, done_rules",
    )
      .eq("provider", "github").in("meta->>login", [...involved]);

    for (const u of users ?? []) {
      const login = String((u.meta as Record<string, unknown>)?.login ?? "");
      await db.from("external_items").upsert(
        {
          ...githubItem(item, login, false, doneRules(u.done_rules)),
          user_id: u.user_id,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id,source,external_id" },
      );
      const changed = await linkAndSync(db, u.user_id);
      const created = await classifyAndApply(db, u.user_id);
      const cards = await buildCards(db, u.user_id);
      if (changed.length > 0 || created > 0 || cards > 0) {
        await queueSilentRefresh(db, u.user_id);
      }
    }
    await db.from("sync_events").update({ status: "done" }).eq(
      "provider",
      "github",
    ).eq("delivery_id", delivery);
    return json({ ok: true, users: users?.length ?? 0 });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await db.from("sync_events").update({
      status: "failed",
      error: message,
      attempts: 1,
    })
      .eq("provider", "github").eq("delivery_id", delivery);
    // 200 so GitHub does not hammer retries; the cron sync will catch up.
    return json({ ok: false, error: message });
  }
});
