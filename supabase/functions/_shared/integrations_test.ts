import { assertEquals } from "jsr:@std/assert@1.0.8";
import {
  authorizeUrl,
  fetchGithub,
  fetchJira,
  startOfLocalDay,
} from "./integrations.ts";

const token = { access_token: "t" };

function mockFetch(routes: Record<string, unknown>) {
  const seen: string[] = [];
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = String(input);
    seen.push(url);
    const key = Object.keys(routes).find((k) => url.includes(k));
    return Promise.resolve(
      new Response(JSON.stringify(key ? routes[key] : {}), {
        status: key ? 200 : 404,
      }),
    );
  }) as typeof fetch;
  return seen;
}

Deno.test("GitHub: merged PR, review request, closed issue and commits per repo", async () => {
  const seen = mockFetch({
    "/search/issues": {
      items: [
        {
          number: 42,
          title: "Add login tests",
          html_url: "https://github.com/me/app-ios/pull/42",
          state: "closed",
          updated_at: "2026-11-02T03:00:00Z",
          user: { login: "me" },
          repository_url: "https://api.github.com/repos/me/app-ios",
          pull_request: { merged_at: "2026-11-02T03:00:00Z" },
        },
        {
          number: 57,
          title: "Refactor",
          html_url: "https://github.com/team/api/pull/57",
          state: "open",
          updated_at: "2026-11-02T02:00:00Z",
          user: { login: "bob" },
          repository_url: "https://api.github.com/repos/team/api",
          pull_request: { merged_at: null },
        },
        {
          number: 12,
          title: "Crash",
          html_url: "https://github.com/me/app-ios/issues/12",
          state: "closed",
          state_reason: "completed",
          updated_at: "2026-11-02T01:00:00Z",
          user: { login: "me" },
          repository_url: "https://api.github.com/repos/me/app-ios",
        },
      ],
    },
    "/users/me/events": [
      {
        type: "PushEvent",
        created_at: "2026-11-02T02:30:00Z",
        repo: { name: "me/app-ios" },
        payload: { size: 3 },
      },
      {
        type: "PushEvent",
        created_at: "2026-11-02T04:00:00Z",
        repo: { name: "me/app-ios" },
        payload: { size: 2 },
      },
      {
        type: "PushEvent",
        created_at: "2026-11-01T10:00:00Z",
        repo: { name: "me/old" },
        payload: { size: 9 },
      },
    ],
  });
  const items = await fetchGithub(
    token,
    { login: "me" },
    "2026-11-01T17:00:00.000Z",
  );
  assertEquals(items.map((i) => [i.title, i.status]), [
    ["PR #42 đã merge · app-ios", "merged"],
    ["Review PR #57 · api", "review_requested"],
    ["Issue #12 đã đóng · app-ios", "completed"],
    ["5 commit · app-ios", null],
  ]);
  assertEquals(
    seen[0].includes(encodeURIComponent("involves:me updated:>=2026-11-01")),
    true,
  );
});

Deno.test("Jira: statusCategory decides the state, not the status name", async () => {
  mockFetch({
    "/search/jql": {
      issues: [
        {
          key: "JIRA-118",
          fields: {
            summary: "Login",
            updated: "2026-11-02T10:40:00.000+0700",
            status: { name: "Đã xong", statusCategory: { key: "done" } },
          },
        },
        {
          key: "JIRA-120",
          fields: {
            summary: "Push 12h",
            updated: "2026-11-02T09:00:00.000+0700",
            status: {
              name: "Đang review",
              statusCategory: { key: "indeterminate" },
            },
          },
        },
      ],
    },
  });
  const items = (await fetchJira(token, {
    cloud_id: "c1",
    site_url: "https://team.atlassian.net",
  })).filter((i) => i.kind === "issue");
  assertEquals(items.map((i) => [i.title, i.status, i.url]), [
    ["JIRA-118 → Done", "done", "https://team.atlassian.net/browse/JIRA-118"],
    [
      "JIRA-120: Push 12h",
      "in_progress",
      "https://team.atlassian.net/browse/JIRA-120",
    ],
  ]);
  assertEquals(items[0].occurred_at, "2026-11-02T03:40:00.000Z");
});

Deno.test("authorize URLs carry state, callback and Jira scopes (read + webhooks only)", () => {
  Deno.env.set("SUPABASE_URL", "https://ref.supabase.co");
  Deno.env.set("GITHUB_CLIENT_ID", "gh");
  Deno.env.set("GITHUB_CLIENT_SECRET", "x");
  Deno.env.set("JIRA_CLIENT_ID", "jr");
  Deno.env.set("JIRA_CLIENT_SECRET", "y");
  const gh = new URL(authorizeUrl("github", "s1"));
  assertEquals(
    gh.searchParams.get("redirect_uri"),
    "https://ref.supabase.co/functions/v1/oauth-callback",
  );
  assertEquals(gh.searchParams.get("state"), "s1");
  const jira = new URL(authorizeUrl("jira", "s2"));
  assertEquals(
    jira.searchParams.get("scope"),
    "read:jira-work read:jira-user manage:jira-webhook offline_access",
  );
  assertEquals(jira.searchParams.get("audience"), "api.atlassian.com");
});

Deno.test("startOfLocalDay uses the user's time zone", () => {
  const now = new Date("2026-11-02T03:15:30Z"); // 10:15:30 in Ho Chi Minh (UTC+7)
  assertEquals(
    startOfLocalDay("Asia/Ho_Chi_Minh", now).toISOString(),
    "2026-11-01T17:00:00.000Z",
  );
});

Deno.test("GitHub: 422 on search falls back to installed repos and reports the real message", async () => {
  const seen: string[] = [];
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = String(input);
    seen.push(url);
    const ok = (body: unknown) =>
      Promise.resolve(new Response(JSON.stringify(body)));
    if (url.includes("/search/issues")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            message: "Validation Failed",
            errors: [{ message: "search not allowed" }],
          }),
          { status: 422 },
        ),
      );
    }
    if (url.endsWith("/user/installations?per_page=100")) {
      return ok({ installations: [{ id: 7 }] });
    }
    if (url.includes("/user/installations/7/repositories")) {
      return ok({
        repositories: [
          {
            full_name: "me/app-ios",
            pushed_at: "2026-11-02T03:00:00Z",
            updated_at: "2026-11-02T03:00:00Z",
          },
          {
            full_name: "me/old",
            pushed_at: "2026-10-01T00:00:00Z",
            updated_at: "2026-10-01T00:00:00Z",
          },
        ],
      });
    }
    if (url.includes("/repos/me/app-ios/issues")) {
      return ok([
        {
          number: 42,
          title: "Add login tests",
          html_url: "https://github.com/me/app-ios/pull/42",
          state: "closed",
          updated_at: "2026-11-02T03:00:00Z",
          user: { login: "me" },
          repository_url: "https://api.github.com/repos/me/app-ios",
          pull_request: {},
        },
        {
          number: 9,
          title: "Not mine",
          html_url: "https://github.com/me/app-ios/issues/9",
          state: "open",
          updated_at: "2026-11-02T02:00:00Z",
          user: { login: "bob" },
          assignees: [],
          repository_url: "https://api.github.com/repos/me/app-ios",
        },
      ]);
    }
    if (url.includes("/repos/me/app-ios/pulls/42")) {
      return ok({ merged_at: "2026-11-02T03:00:00Z" });
    }
    if (url.includes("/events")) {
      return Promise.resolve(new Response("{}", { status: 403 }));
    }
    return Promise.resolve(new Response("{}", { status: 404 }));
  }) as typeof fetch;

  const items = await fetchGithub(
    { access_token: "t" },
    { login: "me" },
    "2026-11-01T17:00:00.000Z",
  );
  assertEquals(items.map((i) => [i.title, i.status]), [[
    "PR #42 đã merge · app-ios",
    "merged",
  ]]);
  assertEquals(
    seen.some((u) => u.includes("/repos/me/old/")),
    false,
    "inactive repos are skipped",
  );
  assertEquals(
    seen.filter((u) => u.includes("/search/issues")).length,
    6,
    "combined + split searches, then review-request, reviewed-by and mentions searches",
  );
});

Deno.test("Jira work log → journal line with its comment (else the ticket) and duration", async () => {
  const { worklogItem } = await import("./integrations.ts");
  const issue = { key: "APP-120", summary: "Push 12h" };
  const log = {
    id: "10",
    started: "2026-11-03T09:00:00.000+0700",
    timeSpentSeconds: 1800,
  };
  const withComment = worklogItem(issue, {
    ...log,
    comment: {
      type: "doc",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: "Review API" }],
      }],
    },
  }, "https://x.atlassian.net");
  assertEquals(withComment.title, "Review API");
  assertEquals(withComment.duration_seconds, 1800);
  assertEquals(withComment.external_id, "worklog:10");
  assertEquals(withComment.status, "done");
  assertEquals(withComment.url, "https://x.atlassian.net/browse/APP-120");
  assertEquals(worklogItem(issue, log, "").title, "APP-120: Push 12h");
});
