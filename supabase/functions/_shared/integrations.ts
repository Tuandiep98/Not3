import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { classifyAndApply } from "./classify.ts";
import { buildCards } from "./cards.ts";
import { linkAndSync } from "./links.ts";
import {
  type ActivityRow,
  githubActivity,
  type GithubActivityEvent,
  jiraWorklogs,
  saveActivity,
} from "./activity.ts";
import { ensureJiraWebhook, JIRA_WEBHOOK_SCOPE } from "./jira_webhook.ts";
import { queueSilentRefresh } from "./push.ts";
import {
  type DoneRules,
  doneRules,
  GITHUB_DEFAULTS,
  type GithubSettings,
  githubSettings,
  JIRA_DEFAULTS,
  type JiraSettings,
  jiraSettings,
  NO_DONE_RULES,
  sameName,
} from "./settings.ts";

// GitHub + Jira adapters (README §11). Every source returns ExternalItem[] so adding a source
// never touches the app. Read-only scopes; tokens are kept in Vault via save_integration().

export type Provider = "github" | "jira";

export type ExternalItem = {
  source: Provider;
  external_id: string;
  kind: string;
  title: string;
  url: string | null;
  status: string | null;
  occurred_at: string;
  /** The user's part in it: decides task vs. journal vs. "chưa phân loại". */
  role?:
    | "author"
    | "assignee"
    | "reviewer"
    | "reporter"
    | "involved"
    | "watcher";
  /** owner/repo or Jira project key — for scoped ignore rules. */
  scope?: string;
  /** Provider's own status name (Jira "Code Review"), for readable reasons. */
  status_name?: string;
};

export type TokenSet = {
  access_token: string;
  refresh_token?: string;
  /** epoch ms; absent = does not expire (classic GitHub OAuth App). */
  expires_at?: number;
};

export function callbackUrl(): string {
  return `${Deno.env.get("SUPABASE_URL")}/functions/v1/oauth-callback`;
}

export function providerConfigured(provider: Provider): boolean {
  const prefix = provider.toUpperCase();
  return Boolean(
    Deno.env.get(`${prefix}_CLIENT_ID`) &&
      Deno.env.get(`${prefix}_CLIENT_SECRET`),
  );
}

function client(provider: Provider) {
  const prefix = provider.toUpperCase();
  const id = Deno.env.get(`${prefix}_CLIENT_ID`);
  const secret = Deno.env.get(`${prefix}_CLIENT_SECRET`);
  if (!id || !secret) throw new Error(`${provider} chưa được cấu hình`);
  return { id, secret };
}

// --- OAuth -------------------------------------------------------------------

/** Every scope must also be added to the Atlassian app (Permissions → Jira API). */
export const JIRA_SCOPES = [
  "read:jira-work",
  "read:jira-user",
  JIRA_WEBHOOK_SCOPE,
  "offline_access",
];

export function authorizeUrl(provider: Provider, state: string): string {
  const { id } = client(provider);
  if (provider === "github") {
    // Works for a GitHub App (permissions set on the app, read-only) or an OAuth App.
    const q = new URLSearchParams({
      client_id: id,
      redirect_uri: callbackUrl(),
      state,
      allow_signup: "false",
    });
    return `https://github.com/login/oauth/authorize?${q}`;
  }
  const q = new URLSearchParams({
    audience: "api.atlassian.com",
    client_id: id,
    scope: JIRA_SCOPES.join(" "),
    redirect_uri: callbackUrl(),
    state,
    response_type: "code",
    prompt: "consent",
  });
  return `https://auth.atlassian.com/authorize?${q}`;
}

function toTokenSet(body: Record<string, unknown>): TokenSet {
  if (typeof body.access_token !== "string") {
    throw new Error(
      `Không nhận được token: ${JSON.stringify(body.error ?? body)}`,
    );
  }
  const expiresIn = Number(body.expires_in);
  return {
    access_token: body.access_token,
    refresh_token: typeof body.refresh_token === "string"
      ? body.refresh_token
      : undefined,
    expires_at: Number.isFinite(expiresIn) && expiresIn > 0
      ? Date.now() + expiresIn * 1000
      : undefined,
  };
}

async function tokenRequest(
  provider: Provider,
  params: Record<string, string>,
): Promise<TokenSet> {
  const { id, secret } = client(provider);
  const url = provider === "github"
    ? "https://github.com/login/oauth/access_token"
    : "https://auth.atlassian.com/oauth/token";
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ client_id: id, client_secret: secret, ...params }),
  });
  return toTokenSet(await res.json().catch(() => ({})));
}

export function exchangeCode(
  provider: Provider,
  code: string,
): Promise<TokenSet> {
  return tokenRequest(provider, {
    grant_type: "authorization_code",
    code,
    redirect_uri: callbackUrl(),
  });
}

/** Returns a valid access token, refreshing (and re-saving) it when it is about to expire. */
export async function validToken(
  db: SupabaseClient,
  userId: string,
  provider: Provider,
): Promise<TokenSet> {
  const { data, error } = await db.rpc("read_integration_token", {
    p_user: userId,
    p_provider: provider,
  });
  if (error || !data) throw new Error("Chưa kết nối");
  const token = data as TokenSet;
  if (!token.expires_at || token.expires_at - Date.now() > 5 * 60 * 1000) {
    return token;
  }
  if (!token.refresh_token) throw new Error("Cần đăng nhập lại");
  const fresh = await tokenRequest(provider, {
    grant_type: "refresh_token",
    refresh_token: token.refresh_token,
  });
  fresh.refresh_token ??= token.refresh_token;
  const { data: row } = await db
    .from("integrations")
    .select("account_name, scopes, meta")
    .eq("user_id", userId)
    .eq("provider", provider)
    .single();
  await db.rpc("save_integration", {
    p_user: userId,
    p_provider: provider,
    p_account: row?.account_name ?? null,
    p_scopes: row?.scopes ?? [],
    p_token: fresh,
    p_meta: row?.meta ?? {},
  });
  return fresh;
}

// --- Account info right after connecting ---------------------------------------

export async function accountInfo(
  provider: Provider,
  token: TokenSet,
): Promise<{ account: string; meta: Record<string, unknown> }> {
  if (provider === "github") {
    const me = await githubGet<{ login: string }>("/user", token);
    return { account: me.login, meta: { login: me.login } };
  }
  const sites = await jiraFetch<{ id: string; url: string; name: string }[]>(
    "https://api.atlassian.com/oauth/token/accessible-resources",
    token,
  );
  if (!sites.length) throw new Error("Tài khoản Jira không có site nào");
  const site = sites[0];
  const me = await jiraFetch<{ accountId: string; displayName?: string }>(
    `https://api.atlassian.com/ex/jira/${site.id}/rest/api/3/myself`,
    token,
  ).catch(() => null);
  return {
    account: site.name,
    meta: {
      cloud_id: site.id,
      site_url: site.url,
      site_name: site.name,
      account_id: me?.accountId,
    },
  };
}

// --- GitHub ------------------------------------------------------------------

async function githubGet<T>(path: string, token: TokenSet): Promise<T> {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: {
      Authorization: `Bearer ${token.access_token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "Not3",
    },
  });
  if (res.status === 401) throw new Error("Cần đăng nhập lại");
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as {
      message?: string;
      errors?: { message?: string }[];
    };
    const detail = body.errors
      ?.map((e) => e.message)
      .filter(Boolean)
      .join("; ") ||
      body.message ||
      "";
    throw new GithubError(
      res.status,
      `GitHub ${res.status}${detail ? `: ${detail}` : ""}`,
    );
  }
  return (await res.json()) as T;
}

class GithubError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/**
 * PRs / issues involving the user, updated since `day`. Search API first; on 422 retry with the
 * `is:pr` / `is:issue` split; if search is still refused (some GitHub App tokens), read the
 * installed repositories directly.
 */
async function githubTouchedToday(
  token: TokenSet,
  login: string,
  sinceIso: string,
): Promise<GithubSearchItem[]> {
  const day = sinceIso.slice(0, 10);
  const search = (extra: string) =>
    githubGet<{ items: GithubSearchItem[] }>(
      `/search/issues?q=${
        encodeURIComponent(
          `involves:${login} updated:>=${day}${extra}`,
        )
      }&per_page=50`,
      token,
    ).then((r) => r.items);
  try {
    return await search("");
  } catch (e) {
    if (!(e instanceof GithubError) || e.status !== 422) throw e;
    console.warn("[github] combined search refused:", e.message);
  }
  try {
    const [prs, issues] = await Promise.all([
      search(" is:pr"),
      search(" is:issue"),
    ]);
    return [...prs, ...issues];
  } catch (e) {
    if (!(e instanceof GithubError) || e.status !== 422) throw e;
    console.warn(
      "[github] split search refused, scanning installed repos:",
      e.message,
    );
  }
  return await githubScanInstalledRepos(token, login, sinceIso);
}

/** Fallback without Search: repos the GitHub App is installed on, items updated today. */
async function githubScanInstalledRepos(
  token: TokenSet,
  login: string,
  sinceIso: string,
): Promise<GithubSearchItem[]> {
  const { installations } = await githubGet<{
    installations: { id: number }[];
  }>("/user/installations?per_page=100", token);
  const repos: {
    full_name: string;
    pushed_at: string | null;
    updated_at: string;
  }[] = [];
  for (const inst of installations) {
    const page = await githubGet<{ repositories: typeof repos }>(
      `/user/installations/${inst.id}/repositories?per_page=100`,
      token,
    );
    repos.push(...page.repositories);
  }
  // Only repos with activity today, most recent first; cap API calls.
  const active = repos
    .filter((r) => (r.pushed_at ?? "") >= sinceIso || r.updated_at >= sinceIso)
    .sort((a, b) => (b.pushed_at ?? "").localeCompare(a.pushed_at ?? ""))
    .slice(0, 20);
  const items: GithubSearchItem[] = [];
  for (const repo of active) {
    const list = await githubGet<
      (GithubSearchItem & { assignees?: { login: string }[] })[]
    >(
      `/repos/${repo.full_name}/issues?state=all&since=${
        encodeURIComponent(
          sinceIso,
        )
      }&per_page=50`,
      token,
    );
    for (const it of list) {
      const involved = it.user?.login === login ||
        it.assignees?.some((a) => a.login === login);
      // Pull requests from the issues endpoint lack merged_at: read it from the PR itself.
      if (it.pull_request && involved) {
        const pr = await githubGet<{ merged_at: string | null }>(
          `/repos/${repo.full_name}/pulls/${it.number}`,
          token,
        ).catch(() => ({ merged_at: null }));
        items.push({ ...it, pull_request: { merged_at: pr.merged_at } });
      } else if (involved) {
        items.push(it);
      }
    }
    // PRs from others that ask this user for a review.
    const open = await githubGet<
      (GithubSearchItem & { requested_reviewers?: { login: string }[] })[]
    >(`/repos/${repo.full_name}/pulls?state=open&per_page=50`, token).catch(
      () => [],
    );
    for (const pr of open) {
      if (!pr.requested_reviewers?.some((r) => r.login === login)) continue;
      if (items.some((i) => i.html_url === pr.html_url)) continue;
      items.push({
        ...pr,
        repository_url: `https://api.github.com/repos/${repo.full_name}`,
        pull_request: { merged_at: null },
        review_requested: true,
      });
    }
  }
  return items;
}

export type GithubSearchItem = {
  number: number;
  title: string;
  html_url: string;
  state: string;
  state_reason?: string | null;
  updated_at: string;
  user?: { login: string };
  repository_url: string;
  pull_request?: { merged_at: string | null };
  assignees?: { login: string }[];
  requested_reviewers?: { login: string }[];
  /** Set by the fetcher when a review was requested from the user. */
  review_requested?: boolean;
  labels?: { name: string }[];
  draft?: boolean;
  /** Set by the fetcher when the user's own PR has an approving review. */
  approved?: boolean;
};

type GithubEvent = {
  type: string;
  created_at: string;
  repo: { name: string };
  payload: {
    size?: number;
    commits?: unknown[];
    action?: string;
    ref_type?: string;
    ref?: string;
    release?: { tag_name: string; name?: string | null; html_url: string };
    pull_request?: {
      number: number;
      title: string;
      html_url: string;
      merged?: boolean;
      user?: { login: string };
    };
    issue?: {
      number: number;
      title: string;
      html_url: string;
      pull_request?: unknown;
    };
    comment?: { html_url: string };
  };
};

/** One PR / issue → ExternalItem, worded from `login`'s point of view. Shared by sync and webhooks. */
export function githubItem(
  it: GithubSearchItem,
  login: string,
  reviewed = false,
  rules: DoneRules = NO_DONE_RULES,
): ExternalItem {
  const scope = it.repository_url.split("/repos/")[1] ?? "";
  const repo = scope.split("/").slice(-1)[0];
  const isPR = Boolean(it.pull_request);
  const merged = Boolean(it.pull_request?.merged_at);
  const role: ExternalItem["role"] = it.review_requested ||
      it.requested_reviewers?.some((r) => r.login === login)
    ? "reviewer"
    : it.assignees?.some((a) => a.login === login)
    ? "assignee"
    : it.user?.login === login
    ? "author"
    : "involved";
  let title: string;
  let status: string;
  if (isPR && merged) {
    title = `PR #${it.number} đã merge`;
    status = "merged";
  } else if (isPR && it.state === "closed") {
    title = `PR #${it.number} đã đóng`;
    status = "closed";
  } else if (isPR && role === "reviewer") {
    title = `Review PR #${it.number}`;
    status = "review_requested";
  } else if (isPR && reviewed && it.user?.login !== login) {
    // Review already sent (no longer pending): the "Review PR" task is done.
    title = `Đã review PR #${it.number}`;
    status = "reviewed";
  } else if (doneLabel(it, rules)) {
    // "Tính là hoàn thành": a label the user counts as done (e.g. ready-for-qa, deployed).
    title = `${isPR ? "PR" : "Issue"} #${it.number} → ${doneLabel(it, rules)}`;
    status = "done";
  } else if (
    isPR &&
    it.user?.login === login &&
    rules.pr_done_when === "approved" &&
    it.approved
  ) {
    title = `PR #${it.number} đã được duyệt`;
    status = "done";
  } else if (
    isPR &&
    it.user?.login === login &&
    rules.pr_done_when === "ready_for_review" &&
    it.draft === false
  ) {
    title = `PR #${it.number} sẵn sàng review`;
    status = "done";
  } else if (isPR) {
    title = `PR #${it.number}: ${it.title}`;
    status = "open";
  } else {
    title = it.state === "closed"
      ? `Issue #${it.number} đã đóng`
      : `Issue #${it.number}: ${it.title}`;
    status = it.state === "closed"
      ? it.state_reason === "not_planned" ? "not_planned" : "completed"
      : "open";
  }
  return {
    source: "github",
    external_id: it.html_url,
    kind: isPR ? "pull_request" : "issue",
    title: `${title} · ${repo}`.slice(0, 120),
    url: it.html_url,
    status,
    occurred_at: it.updated_at,
    role: reviewed && role === "involved" ? "reviewer" : role,
    scope,
  };
}

function doneLabel(it: GithubSearchItem, rules: DoneRules): string | undefined {
  if (it.state !== "open" || !rules.labels.length) return undefined;
  return it.labels?.find((l) => rules.labels.some((r) => sameName(r, l.name)))
    ?.name;
}

/** Marks the user's open PRs that have an approving review (only when that rule is on). */
async function markApproved(
  token: TokenSet,
  login: string,
  items: GithubSearchItem[],
): Promise<void> {
  const mine = items
    .filter(
      (it) =>
        it.pull_request && it.state === "open" && it.user?.login === login,
    )
    .slice(0, 15);
  for (const it of mine) {
    const path = it.repository_url.split("api.github.com")[1];
    const reviews = await githubGet<
      { state: string; user?: { login: string } }[]
    >(`${path}/pulls/${it.number}/reviews?per_page=100`, token).catch(() => []);
    // Latest review per reviewer decides (a later "changes requested" cancels an approval).
    const latest = new Map<string, string>();
    for (const r of reviews) {
      if (r.user?.login && r.state !== "COMMENTED") {
        latest.set(r.user.login, r.state);
      }
    }
    it.approved = [...latest.values()].includes("APPROVED") &&
      ![...latest.values()].includes("CHANGES_REQUESTED");
  }
}

/** html_urls of open PRs where a review is requested from the user (search; scan as fallback). */
async function githubReviewRequests(
  token: TokenSet,
  login: string,
  candidates: GithubSearchItem[],
): Promise<Set<string>> {
  try {
    const r = await githubGet<{ items: GithubSearchItem[] }>(
      `/search/issues?q=${
        encodeURIComponent(
          `is:pr is:open review-requested:${login}`,
        )
      }&per_page=50`,
      token,
    );
    return new Set(r.items.map((i) => i.html_url));
  } catch {
    // Search refused: ask each open PR we already have that is not the user's own.
    const urls = new Set<string>();
    for (
      const it of candidates
        .filter(
          (c) =>
            c.pull_request && c.state === "open" && c.user?.login !== login,
        )
        .slice(0, 20)
    ) {
      const path = it.repository_url.split("api.github.com")[1];
      const pr = await githubGet<{ requested_reviewers?: { login: string }[] }>(
        `${path}/pulls/${it.number}`,
        token,
      ).catch(() => null);
      if (pr?.requested_reviewers?.some((r) => r.login === login)) {
        urls.add(it.html_url);
      }
    }
    return urls;
  }
}

async function searchUrls(
  token: TokenSet,
  query: string,
): Promise<Set<string> | null> {
  try {
    const r = await githubGet<{ items: GithubSearchItem[] }>(
      `/search/issues?q=${encodeURIComponent(query)}&per_page=50`,
      token,
    );
    return new Set(r.items.map((i) => i.html_url));
  } catch {
    return null;
  }
}

/**
 * Everything enabled in Settings → GitHub, for today: PRs / issues, review requests and reviews sent,
 * commits, releases & tags, merges, comments, mentions, Actions builds, deployments.
 */
export async function fetchGithub(
  token: TokenSet,
  meta: Record<string, unknown>,
  sinceIso: string,
  settings: GithubSettings = GITHUB_DEFAULTS,
  rules: DoneRules = NO_DONE_RULES,
  /** Collects raw activity (time worked) when given. */
  activity?: ActivityRow[],
): Promise<ExternalItem[]> {
  const login = String(
    meta.login ?? (await githubGet<{ login: string }>("/user", token)).login,
  );
  const day = sinceIso.slice(0, 10);
  const items: ExternalItem[] = [];

  // --- PRs / issues (+ review requests, reviews sent) ---
  if (settings.prs || settings.review_requests || settings.reviews_submitted) {
    const touched = await githubTouchedToday(token, login, sinceIso);
    const unique = [
      ...new Map(touched.map((it) => [it.html_url, it])).values(),
    ];
    if (settings.review_requests) {
      const pending = await githubReviewRequests(token, login, unique);
      for (const it of unique) {
        it.review_requested = it.review_requested || pending.has(it.html_url);
      }
    } else {
      for (const it of unique) it.review_requested = false;
    }
    if (rules.pr_done_when === "approved") {
      await markApproved(token, login, unique);
    }
    const reviewed = settings.reviews_submitted
      ? ((await searchUrls(
        token,
        `is:pr reviewed-by:${login} updated:>=${day}`,
      )) ?? new Set<string>())
      : new Set<string>();
    for (const it of unique) {
      const item = githubItem(it, login, reviewed.has(it.html_url), rules);
      const isReview = item.status === "review_requested" ||
        item.status === "reviewed";
      if (
        isReview
          ? item.status === "review_requested"
            ? settings.review_requests
            : settings.reviews_submitted
          : settings.prs
      ) {
        items.push(item);
      }
    }
  }

  // --- Events feed: commits, releases & tags, merges, comments (one call) ---
  const needEvents = settings.commits ||
    settings.releases ||
    settings.merges ||
    settings.comments ||
    settings.mentions ||
    settings.builds ||
    settings.deploys;
  const events = needEvents || activity
    ? await githubGet<GithubEvent[]>(
      `/users/${login}/events?per_page=100`,
      token,
    ).catch((e) => {
      console.warn(
        "[github] events unavailable:",
        e instanceof Error ? e.message : e,
      );
      return [] as GithubEvent[];
    })
    : [];
  // Every event of the feed (up to 100, recent days too): timestamps for "Tổng kết tuần".
  activity?.push(...githubActivity(events as unknown as GithubActivityEvent[]));
  const today = needEvents
    ? events.filter((e) => e.created_at >= sinceIso)
    : [];
  items.push(...githubEventItems(today, login, day, settings));
  const commentedOn = new Set(
    today
      .filter(
        (e) =>
          e.type === "IssueCommentEvent" ||
          e.type === "PullRequestReviewCommentEvent",
      )
      .map((e) => (e.payload.issue ?? e.payload.pull_request)?.html_url ?? ""),
  );

  // --- Mentions → "Trả lời …" task, done once I comment there ---
  if (settings.mentions) {
    const mentioned = await githubGet<{ items: GithubSearchItem[] }>(
      `/search/issues?q=${
        encodeURIComponent(
          `mentions:${login} updated:>=${day}`,
        )
      }&per_page=30`,
      token,
    )
      .then((r) => r.items)
      .catch(() => [] as GithubSearchItem[]);
    const known = new Set(items.map((i) => i.external_id));
    for (const it of mentioned) {
      if (known.has(it.html_url) || it.user?.login === login) continue;
      const scope = it.repository_url.split("/repos/")[1] ?? "";
      const repo = scope.split("/").slice(-1)[0];
      const replied = commentedOn.has(it.html_url);
      items.push({
        source: "github",
        external_id: `mention:${it.html_url}`,
        kind: "mention",
        title: `${
          replied ? "Đã trả lời" : "Trả lời"
        } #${it.number}: ${it.title} · ${repo}`.slice(0, 120),
        url: it.html_url,
        status: replied ? "replied" : "open",
        occurred_at: it.updated_at,
        role: "involved",
        scope,
      });
    }
  }

  // --- Actions builds and deployments, in repos active today ---
  if (settings.builds || settings.deploys) {
    const repos = [
      ...new Set([
        ...today.map((e) => e.repo.name),
        ...items.map((i) => i.scope ?? "").filter((r) => r.includes("/")),
      ]),
    ].slice(0, 10);
    for (const full of repos) {
      if (settings.builds) {
        items.push(...(await githubBuilds(token, login, full, sinceIso, day)));
      }
      if (settings.deploys) {
        items.push(...(await githubDeploys(token, login, full, sinceIso)));
      }
    }
  }
  return items;
}

/** Commits (grouped per repo), releases & tags, merges of others' PRs, comments (grouped per thread). */
export function githubEventItems(
  events: GithubEvent[],
  login: string,
  day: string,
  settings: GithubSettings,
): ExternalItem[] {
  const items: ExternalItem[] = [];
  const pushes = new Map<string, { commits: number; last: string }>();
  const releaseTags = new Set<string>();
  const comments = new Map<
    string,
    { title: string; url: string; count: number; last: string; scope: string }
  >();

  for (const e of events) {
    const scope = e.repo.name;
    const repo = scope.split("/")[1] ?? scope;
    const base = {
      source: "github" as const,
      role: "author" as const,
      scope,
      occurred_at: e.created_at,
    };
    switch (e.type) {
      case "PushEvent": {
        if (!settings.commits) break;
        const prev = pushes.get(scope);
        pushes.set(scope, {
          commits: (prev?.commits ?? 0) +
            (e.payload.size ?? e.payload.commits?.length ?? 1),
          last: prev && prev.last > e.created_at ? prev.last : e.created_at,
        });
        break;
      }
      case "ReleaseEvent": {
        const r = e.payload.release;
        if (!settings.releases || e.payload.action !== "published" || !r) break;
        releaseTags.add(`${scope}@${r.tag_name}`);
        items.push({
          ...base,
          external_id: r.html_url,
          kind: "release",
          title: `Phát hành ${r.tag_name} · ${repo}`,
          url: r.html_url,
          status: "published",
        });
        break;
      }
      case "CreateEvent": {
        if (
          !settings.releases ||
          e.payload.ref_type !== "tag" ||
          !e.payload.ref
        ) {
          break;
        }
        if (releaseTags.has(`${scope}@${e.payload.ref}`)) break;
        items.push({
          ...base,
          external_id: `tag:${scope}:${e.payload.ref}`,
          kind: "tag",
          title: `Tạo tag ${e.payload.ref} · ${repo}`,
          url: `https://github.com/${scope}/releases/tag/${e.payload.ref}`,
          status: "published",
        });
        break;
      }
      case "PullRequestEvent": {
        const pr = e.payload.pull_request;
        if (
          !settings.merges ||
          e.payload.action !== "closed" ||
          !pr?.merged ||
          pr.user?.login === login
        ) {
          break;
        }
        items.push({
          ...base,
          external_id: `merge:${pr.html_url}`,
          kind: "merge",
          title: `Merge PR #${pr.number} · ${repo}`,
          url: pr.html_url,
          status: "merged",
        });
        break;
      }
      case "IssueCommentEvent":
      case "PullRequestReviewCommentEvent": {
        const thread = e.payload.issue ?? e.payload.pull_request;
        if (!settings.comments || !thread) break;
        const prev = comments.get(thread.html_url);
        comments.set(thread.html_url, {
          title: `#${thread.number}`,
          url: thread.html_url,
          count: (prev?.count ?? 0) + 1,
          last: prev && prev.last > e.created_at ? prev.last : e.created_at,
          scope,
        });
        break;
      }
    }
  }
  // Tags seen before their release in the feed (newest first) are dropped here.
  const kept = items.filter(
    (i) =>
      i.kind !== "tag" ||
      !releaseTags.has(`${i.scope}@${i.external_id.split(":").pop()}`),
  );
  for (const [scope, p] of pushes) {
    const repo = scope.split("/")[1] ?? scope;
    kept.push({
      source: "github",
      external_id: `commits:${repo}:${day}`,
      kind: "commits",
      title: `${p.commits} commit · ${repo}`,
      url: `https://github.com/${scope}`,
      status: null,
      occurred_at: p.last,
      role: "author",
      scope,
    });
  }
  for (const [url, c] of comments) {
    const repo = c.scope.split("/")[1] ?? c.scope;
    kept.push({
      source: "github",
      external_id: `comment:${url}:${day}`,
      kind: "comment",
      title: `${c.count} bình luận ${c.title} · ${repo}`,
      url,
      status: "done",
      occurred_at: c.last,
      role: "author",
      scope: c.scope,
    });
  }
  return kept;
}

type WorkflowRun = {
  id: number;
  name: string;
  workflow_id: number;
  status: string;
  conclusion: string | null;
  html_url: string;
  created_at: string;
  updated_at: string;
};

/** Actions runs I triggered today, one item per workflow: "iOS CI · 8 lần, 7 thành công" or "… lỗi". */
async function githubBuilds(
  token: TokenSet,
  login: string,
  full: string,
  sinceIso: string,
  day: string,
): Promise<ExternalItem[]> {
  const data = await githubGet<{ workflow_runs: WorkflowRun[] }>(
    `/repos/${full}/actions/runs?actor=${encodeURIComponent(login)}&created=${
      encodeURIComponent(
        `>=${sinceIso}`,
      )
    }&per_page=50`,
    token,
  ).catch(() => null); // 403 = Actions permission not granted yet
  if (!data) return [];
  const repo = full.split("/")[1] ?? full;
  const byWorkflow = new Map<number, WorkflowRun[]>();
  for (const run of data.workflow_runs) {
    byWorkflow.set(run.workflow_id, [
      ...(byWorkflow.get(run.workflow_id) ?? []),
      run,
    ]);
  }
  return [...byWorkflow.values()].map((runs) => {
    runs.sort((a, b) => b.created_at.localeCompare(a.created_at));
    const last = runs[0];
    const ok = runs.filter((r) => r.conclusion === "success").length;
    const status = last.status !== "completed"
      ? "running"
      : last.conclusion === "success"
      ? "succeeded"
      : "failed";
    const title = status === "failed"
      ? `${last.name} lỗi · ${repo}`
      : `${last.name} · ${runs.length} lần, ${ok} thành công · ${repo}`;
    return {
      source: "github" as const,
      external_id: `build:${full}:${last.workflow_id}:${day}`,
      kind: "build",
      title: title.slice(0, 120),
      url: last.html_url,
      status,
      occurred_at: last.updated_at,
      role: "author" as const,
      scope: full,
    };
  });
}

/** Deployments I created today with their latest state. */
async function githubDeploys(
  token: TokenSet,
  login: string,
  full: string,
  sinceIso: string,
): Promise<ExternalItem[]> {
  type Deployment = {
    id: number;
    environment: string;
    ref: string;
    created_at: string;
    creator?: { login: string };
    statuses_url: string;
  };
  const list = await githubGet<Deployment[]>(
    `/repos/${full}/deployments?per_page=30`,
    token,
  ).catch(() => null);
  if (!list) return [];
  const repo = full.split("/")[1] ?? full;
  const mine = list
    .filter((d) => d.created_at >= sinceIso && d.creator?.login === login)
    .slice(0, 10);
  const items: ExternalItem[] = [];
  for (const d of mine) {
    const [latest] = await githubGet<
      {
        state: string;
        created_at: string;
        target_url?: string;
        log_url?: string;
      }[]
    >(
      `${d.statuses_url.replace("https://api.github.com", "")}?per_page=1`,
      token,
    ).catch(() => []);
    const state = latest?.state ?? "pending";
    const status = state === "success"
      ? "succeeded"
      : state === "failure" || state === "error"
      ? "failed"
      : "running";
    items.push({
      source: "github",
      external_id: `deploy:${full}:${d.id}`,
      kind: "deploy",
      title: `Deploy ${d.environment} · ${d.ref}${
        status === "failed" ? " lỗi" : ""
      } · ${repo}`.slice(0, 120),
      url: latest?.log_url ??
        latest?.target_url ??
        `https://github.com/${full}/deployments`,
      status,
      occurred_at: latest?.created_at ?? d.created_at,
      role: "author",
      scope: full,
    });
  }
  return items;
}

// --- Jira --------------------------------------------------------------------

async function jiraFetch<T>(url: string, token: TokenSet): Promise<T> {
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token.access_token}`,
      Accept: "application/json",
    },
  });
  if (res.status === 401) throw new Error("Cần đăng nhập lại");
  if (!res.ok) throw new Error(`Jira ${res.status}`);
  return (await res.json()) as T;
}

type JiraIssue = {
  key: string;
  fields: {
    summary: string;
    updated: string;
    status: { name: string; statusCategory: { key: string } };
    assignee?: { accountId: string } | null;
    reporter?: { accountId: string } | null;
  };
};

/** JQL for the enabled ticket sources (updated today), plus open sprint work if enabled. */
export function jiraIssuesJql(settings: JiraSettings): string | null {
  const today: string[] = [];
  if (settings.assigned) today.push("assignee = currentUser()");
  if (settings.reported) today.push("reporter = currentUser()");
  if (settings.watching) today.push("watcher = currentUser()");
  const parts: string[] = [];
  if (today.length) {
    parts.push(`((${today.join(" OR ")}) AND updated >= startOfDay())`);
  }
  if (settings.sprint) {
    parts.push(
      "(assignee = currentUser() AND sprint in openSprints() AND statusCategory != Done)",
    );
  }
  return parts.length ? `${parts.join(" OR ")} ORDER BY updated DESC` : null;
}

/** The connected user's Jira accountId (stored in meta at connect; fetched for older connections). */
export async function jiraAccountId(
  token: TokenSet,
  meta: Record<string, unknown>,
): Promise<string> {
  if (typeof meta.account_id === "string") return meta.account_id;
  const me = await jiraFetch<{ accountId: string }>(
    `https://api.atlassian.com/ex/jira/${meta.cloud_id}/rest/api/3/myself`,
    token,
  ).catch(() => null);
  return me?.accountId ?? "";
}

async function jiraSearch(
  cloudId: string,
  token: TokenSet,
  jql: string,
  fields: string,
): Promise<JiraIssue[]> {
  const q = new URLSearchParams({ jql, fields, maxResults: "50" });
  const data = await jiraFetch<{ issues: JiraIssue[] }>(
    `https://api.atlassian.com/ex/jira/${cloudId}/rest/api/3/search/jql?${q}`,
    token,
  );
  return data.issues ?? [];
}

/**
 * Everything enabled in Settings → Jira. Tickets are mapped by statusCategory, not by name.
 * Status changes I made and my work logs today become journal lines.
 */
export async function fetchJira(
  token: TokenSet,
  meta: Record<string, unknown>,
  settings: JiraSettings = JIRA_DEFAULTS,
  rules: DoneRules = NO_DONE_RULES,
  /** Collects my work logs (real start + duration) when given. */
  activity?: ActivityRow[],
): Promise<ExternalItem[]> {
  const cloudId = String(meta.cloud_id ?? "");
  const site = String(meta.site_url ?? "");
  if (!cloudId) throw new Error("Thiếu Jira cloud id");
  const me = await jiraAccountId(token, meta);
  const day = new Date().toISOString().slice(0, 10);
  const items: ExternalItem[] = [];

  const jql = jiraIssuesJql(settings);
  if (jql) {
    const issues = await jiraSearch(
      cloudId,
      token,
      jql,
      "summary,status,updated,assignee,reporter",
    );
    items.push(
      ...issues.map((issue) => {
        const item = jiraItem(issue, site, me, rules);
        // Not mine to do, but I asked to follow it.
        if (item.role === "involved" && settings.watching) {
          item.role = "watcher";
        }
        return item;
      }),
    );
  }
  // Optional journal sources must never break the main sync.
  if (settings.transitions) {
    const changed = await jiraSearch(
      cloudId,
      token,
      "status CHANGED BY currentUser() AFTER startOfDay()",
      "summary,status,updated",
    ).catch(() => [] as JiraIssue[]);
    items.push(
      ...changed.map((issue) => ({
        source: "jira" as const,
        external_id: `transition:${issue.key}:${day}`,
        kind: "transition",
        title: `Chuyển ${issue.key} → ${issue.fields.status.name}`.slice(
          0,
          120,
        ),
        url: site ? `${site}/browse/${issue.key}` : null,
        status: "done",
        occurred_at: new Date(issue.fields.updated).toISOString(),
        role: "author" as const,
        scope: issue.key.split("-")[0],
      })),
    );
  }
  if (settings.worklogs) {
    const logged = await jiraSearch(
      cloudId,
      token,
      "worklogAuthor = currentUser() AND worklogDate >= startOfDay()",
      "summary,updated",
    ).catch(() => [] as JiraIssue[]);
    items.push(
      ...logged.map((issue) => ({
        source: "jira" as const,
        external_id: `worklog:${issue.key}:${day}`,
        kind: "worklog",
        title: `Log work ${issue.key}: ${issue.fields.summary}`.slice(0, 120),
        url: site ? `${site}/browse/${issue.key}` : null,
        status: "done",
        occurred_at: new Date(issue.fields.updated).toISOString(),
        role: "author" as const,
        scope: issue.key.split("-")[0],
      })),
    );
  }
  // Real time spent, for "Tổng kết tuần": started + timeSpentSeconds of my own logs (last 2 days,
  // so a log added late for yesterday is still picked up; upserts keep it to one row).
  if (activity && me) {
    const recent = await jiraSearch(
      cloudId,
      token,
      "worklogAuthor = currentUser() AND worklogDate >= -2d",
      "summary",
    ).catch(() => [] as JiraIssue[]);
    activity.push(
      ...(await jiraWorklogs(
        cloudId,
        token.access_token,
        me,
        recent.map((i) => ({ key: i.key, summary: i.fields.summary })),
        new Date(Date.now() - 3 * 86_400_000),
      )),
    );
  }
  return items;
}

export function jiraItem(
  issue: JiraIssue,
  site: string,
  myAccountId = "",
  rules: DoneRules = NO_DONE_RULES,
): ExternalItem {
  const category = issue.fields.status.statusCategory.key; // new | indeterminate | done
  const statusName = issue.fields.status.name;
  // "Tính là hoàn thành": e.g. a developer counts Code Review / Release Testing as done.
  const countedDone = rules.statuses.some((s) => sameName(s, statusName));
  const status = category === "done" || countedDone
    ? "done"
    : category === "indeterminate"
    ? "in_progress"
    : "todo";
  const title = category === "done"
    ? `${issue.key} → Done`
    : countedDone
    ? `${issue.key} → ${statusName}`
    : `${issue.key}: ${issue.fields.summary}`;
  return {
    source: "jira",
    external_id: issue.key,
    kind: "issue",
    title: title.slice(0, 120),
    url: site ? `${site}/browse/${issue.key}` : null,
    status,
    occurred_at: new Date(issue.fields.updated).toISOString(),
    // No accountId = unknown, not "involved": an unknown role must never read as "unassigned".
    role: !myAccountId
      ? undefined
      : issue.fields.assignee?.accountId === myAccountId
      ? "assignee"
      : issue.fields.reporter?.accountId === myAccountId
      ? "reporter"
      : "involved",
    scope: issue.key.split("-")[0],
    status_name: statusName,
  };
}

/**
 * The user's Jira statuses (all projects they can see), for the "Tính là hoàn thành" picker.
 * Category: new = To Do, indeterminate = In Progress, done = Done.
 */
export async function jiraStatuses(
  db: SupabaseClient,
  userId: string,
): Promise<{ name: string; category: string }[]> {
  const { data: row } = await db
    .from("integrations")
    .select("meta")
    .eq("user_id", userId)
    .eq("provider", "jira")
    .maybeSingle();
  const cloudId = String(
    (row?.meta as Record<string, unknown> | null)?.cloud_id ?? "",
  );
  if (!cloudId) throw new Error("Chưa kết nối Jira");
  const token = await validToken(db, userId, "jira");
  const list = await jiraFetch<
    { name: string; statusCategory?: { key: string } }[]
  >(`https://api.atlassian.com/ex/jira/${cloudId}/rest/api/3/status`, token);
  const byName = new Map<string, { name: string; category: string }>();
  for (const s of list) {
    const key = s.name.toLowerCase();
    if (!byName.has(key)) {
      byName.set(key, {
        name: s.name,
        category: s.statusCategory?.key ?? "new",
      });
    }
  }
  const order = { new: 0, indeterminate: 1, done: 2 } as Record<string, number>;
  return [...byName.values()].sort(
    (a, b) =>
      (order[a.category] ?? 1) - (order[b.category] ?? 1) ||
      a.name.localeCompare(b.name),
  );
}

/** Current state of one linked item, fetched directly (nightly reconcile). Null when gone. */
export async function fetchLinkedItem(
  provider: Provider,
  externalId: string,
  token: TokenSet,
  meta: Record<string, unknown>,
  rules: DoneRules = NO_DONE_RULES,
): Promise<ExternalItem | null> {
  if (provider === "github") {
    const m = externalId.match(
      /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/(pull|issues)\/(\d+)$/,
    );
    if (!m) return null;
    const [, owner, repo, type, number] = m;
    const login = String(meta.login ?? "");
    // The issues endpoint serves PRs too; merged_at needs the pulls endpoint.
    const it = await githubGet<GithubSearchItem>(
      `/repos/${owner}/${repo}/issues/${number}`,
      token,
    ).catch(() => null);
    if (!it) return null;
    if (type === "pull") {
      const pr = await githubGet<{ merged_at: string | null; draft?: boolean }>(
        `/repos/${owner}/${repo}/pulls/${number}`,
        token,
      );
      it.pull_request = { merged_at: pr.merged_at };
      it.draft = pr.draft;
    }
    it.repository_url ??= `https://api.github.com/repos/${owner}/${repo}`;
    if (type === "pull" && rules.pr_done_when === "approved") {
      await markApproved(token, login, [it]);
    }
    return githubItem(it, login, false, rules);
  }
  const cloudId = String(meta.cloud_id ?? "");
  if (!cloudId) return null;
  const issue = await jiraFetch<JiraIssue>(
    `https://api.atlassian.com/ex/jira/${cloudId}/rest/api/3/issue/${
      encodeURIComponent(
        externalId,
      )
    }?fields=summary,status,updated,assignee,reporter`,
    token,
  ).catch(() => null);
  return issue
    ? jiraItem(
      issue,
      String(meta.site_url ?? ""),
      await jiraAccountId(token, meta),
      rules,
    )
    : null;
}

/**
 * Open tasks linked to Jira tickets the searches did not return — typically because I was
 * unassigned (`assignee = currentUser()` no longer matches): re-read them one by one so the change
 * reaches the task (links.ts cancels a synced task that is no longer mine).
 */
async function linkedJiraNotReturned(
  db: SupabaseClient,
  userId: string,
  token: TokenSet,
  meta: Record<string, unknown>,
  rules: DoneRules,
  returned: ExternalItem[],
): Promise<ExternalItem[]> {
  const { data: links } = await db
    .from("task_links")
    .select("external_id, tasks!inner(status)")
    .eq("user_id", userId)
    .eq("provider", "jira")
    .in("tasks.status", ["todo", "doing"]);
  const seen = new Set(returned.map((i) => i.external_id));
  const missing = [...new Set((links ?? []).map((l) => String(l.external_id)))]
    .filter((key) => !seen.has(key))
    .slice(0, 20);
  const items: ExternalItem[] = [];
  for (const key of missing) {
    const item = await fetchLinkedItem("jira", key, token, meta, rules).catch(
      () => null,
    );
    if (item) items.push(item);
  }
  return items;
}

// --- Sync one user -----------------------------------------------------------

export async function syncUser(
  db: SupabaseClient,
  userId: string,
  timezone: string,
  only?: Provider,
): Promise<Record<Provider, number | string>> {
  let query = db
    .from("integrations")
    .select("provider, meta, settings, done_rules")
    .eq("user_id", userId);
  if (only) query = query.eq("provider", only);
  const { data: rows } = await query;
  const result = {} as Record<Provider, number | string>;
  const sinceIso = startOfLocalDay(timezone).toISOString();
  for (const row of rows ?? []) {
    const provider = row.provider as Provider;
    const activity: ActivityRow[] = [];
    try {
      const token = await validToken(db, userId, provider);
      const items = provider === "github"
        ? await fetchGithub(
          token,
          row.meta ?? {},
          sinceIso,
          githubSettings(row.settings),
          doneRules(row.done_rules),
          activity,
        )
        : await fetchJira(
          token,
          row.meta ?? {},
          jiraSettings(row.settings),
          doneRules(row.done_rules),
          activity,
        );
      if (provider === "jira") {
        items.push(
          ...(await linkedJiraNotReturned(
            db,
            userId,
            token,
            row.meta ?? {},
            doneRules(row.done_rules),
            items,
          )),
        );
      }
      await saveActivity(db, userId, activity);
      if (items.length) {
        const { error } = await db.from("external_items").upsert(
          items.map((i) => ({
            ...i,
            user_id: userId,
            updated_at: new Date().toISOString(),
          })),
          { onConflict: "user_id,source,external_id" },
        );
        if (error) throw error;
      }
      await db
        .from("integrations")
        .update({ last_synced_at: new Date().toISOString(), last_error: null })
        .eq("user_id", userId)
        .eq("provider", provider);
      result[provider] = items.length;
      if (provider === "jira") {
        // Near real-time updates: register / refresh the Jira webhook (never throws).
        const meta = row.meta ?? {};
        await ensureJiraWebhook(
          db,
          userId,
          token,
          meta,
          () => jiraAccountId(token, meta),
        );
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      await db
        .from("integrations")
        .update({ last_error: message })
        .eq("user_id", userId)
        .eq("provider", provider);
      result[provider] = message;
    }
  }
  // Link tasks to what was just pulled and apply external status (PR merged → task done).
  try {
    const changed = await linkAndSync(db, userId);
    // Then classify what is left: tasks / journal / ignored / "chưa phân loại".
    const created = await classifyAndApply(db, userId);
    // One card per linked task (PR ↔ ticket together, two-line summary).
    const cards = await buildCards(db, userId);
    // Tasks changed on the server → wake the app to refresh its data and widgets.
    if (changed.length > 0 || created > 0 || cards > 0) {
      await queueSilentRefresh(db, userId);
    }
  } catch (e) {
    console.error("[sync] link / classify", e);
  }
  return result;
}

export function startOfLocalDay(timeZone: string, now = new Date()): Date {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
  }).formatToParts(now);
  const get = (t: string) =>
    Number(parts.find((p) => p.type === t)?.value ?? 0);
  const elapsed = ((get("hour") * 60 + get("minute")) * 60 + get("second")) *
    1000;
  return new Date(Math.floor((now.getTime() - elapsed) / 1000) * 1000);
}
