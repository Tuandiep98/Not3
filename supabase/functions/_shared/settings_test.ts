import { assertEquals } from "jsr:@std/assert@1.0.8";
import { githubEventItems, jiraIssuesJql } from "./integrations.ts";
import { classify, taskTitle } from "./classify.ts";
import { mapStatus } from "./links.ts";
import {
  GITHUB_DEFAULTS,
  githubSettings,
  JIRA_DEFAULTS,
  jiraSettings,
} from "./settings.ts";

Deno.test("settings: unknown / non-boolean keys ignored, defaults filled", () => {
  assertEquals(githubSettings({ builds: true, prs: "yes", hack: true }), {
    ...GITHUB_DEFAULTS,
    builds: true,
  });
  assertEquals(jiraSettings(null), JIRA_DEFAULTS);
});

Deno.test("Jira JQL follows the toggles", () => {
  assertEquals(
    jiraIssuesJql(JIRA_DEFAULTS),
    "((assignee = currentUser() OR reporter = currentUser()) AND updated >= startOfDay()) ORDER BY updated DESC",
  );
  assertEquals(
    jiraIssuesJql({ ...JIRA_DEFAULTS, reported: false, sprint: true }),
    "((assignee = currentUser()) AND updated >= startOfDay()) OR (assignee = currentUser() AND sprint in openSprints() AND statusCategory != Done) ORDER BY updated DESC",
  );
  assertEquals(
    jiraIssuesJql({ ...JIRA_DEFAULTS, assigned: false, reported: false }),
    null,
  );
});

Deno.test("GitHub events: releases (tag folded in), merges of others, comments grouped, commits", () => {
  const ev = (
    type: string,
    payload: Record<string, unknown>,
    at = "2026-11-02T03:00:00Z",
  ) => ({ type, created_at: at, repo: { name: "acme/app" }, payload });
  const events = [
    ev("ReleaseEvent", {
      action: "published",
      release: {
        tag_name: "v1.2.0",
        html_url: "https://github.com/acme/app/releases/tag/v1.2.0",
      },
    }),
    ev("CreateEvent", { ref_type: "tag", ref: "v1.2.0" }),
    ev("CreateEvent", { ref_type: "tag", ref: "v1.2.1-beta" }),
    ev("PullRequestEvent", {
      action: "closed",
      pull_request: {
        number: 60,
        title: "x",
        html_url: "https://github.com/acme/app/pull/60",
        merged: true,
        user: { login: "bob" },
      },
    }),
    ev("PullRequestEvent", {
      action: "closed",
      pull_request: {
        number: 61,
        title: "y",
        html_url: "https://github.com/acme/app/pull/61",
        merged: true,
        user: { login: "me" },
      },
    }),
    ev("IssueCommentEvent", {
      issue: {
        number: 12,
        title: "Bug",
        html_url: "https://github.com/acme/app/issues/12",
      },
    }),
    ev("IssueCommentEvent", {
      issue: {
        number: 12,
        title: "Bug",
        html_url: "https://github.com/acme/app/issues/12",
      },
    }),
    ev("PushEvent", { size: 3 }),
  ];
  const all = githubEventItems(events as never, "me", "2026-11-02", {
    ...GITHUB_DEFAULTS,
    comments: true,
  });
  assertEquals(all.map((i) => [i.kind, i.title]), [
    ["release", "Phát hành v1.2.0 · app"],
    ["tag", "Tạo tag v1.2.1-beta · app"],
    ["merge", "Merge PR #60 · app"],
    ["commits", "3 commit · app"],
    ["comment", "2 bình luận #12 · app"],
  ]);
  const off = githubEventItems(events as never, "me", "2026-11-02", {
    ...GITHUB_DEFAULTS,
    releases: false,
    merges: false,
    commits: false,
  });
  assertEquals(off, [], "toggles off → nothing");
});

Deno.test("new kinds: finished work → journal; failures / mentions → task; recovery completes it", () => {
  const item = (kind: string, status: string) => ({
    source: "github",
    external_id: "x",
    kind,
    title: `iOS CI lỗi · app`,
    url: null,
    status,
    role: "author",
    scope: "acme/app",
  });
  for (
    const [kind, status] of [["release", "published"], ["merge", "merged"], [
      "comment",
      "done",
    ], ["build", "succeeded"]]
  ) {
    assertEquals(
      classify(item(kind, status), new Set()).decision,
      "journal",
      kind,
    );
  }
  assertEquals(classify(item("build", "failed"), new Set()).decision, "task");
  assertEquals(taskTitle(item("build", "failed")), "Sửa: iOS CI lỗi");
  assertEquals(classify(item("build", "running"), new Set()).decision, null);
  assertEquals(
    classify({ ...item("mention", "open"), role: "involved" }, new Set())
      .decision,
    "task",
  );
  assertEquals(mapStatus("github", "build", "succeeded"), "done");
  assertEquals(mapStatus("github", "mention", "replied"), "done");
  assertEquals(mapStatus("github", "pull_request", "reviewed"), "done");
});

Deno.test("done rules: Jira custom status and GitHub label / PR rules count as done", async () => {
  const { githubItem, jiraItem } = await import("./integrations.ts");
  const { doneRules } = await import("./settings.ts");
  const rules = doneRules({
    statuses: ["code review", " Release Testing "],
    labels: ["ready-for-qa"],
    pr_done_when: "ready_for_review",
  });
  assertEquals(rules.statuses, ["code review", "Release Testing"]);
  const jira = (name: string, key = "indeterminate") =>
    jiraItem(
      {
        key: "APP-7",
        fields: {
          summary: "Login",
          updated: "2026-11-02T03:00:00.000+0000",
          status: { name, statusCategory: { key } },
        },
      },
      "",
      "",
      rules,
    );
  assertEquals([jira("Code Review").status, jira("Code Review").title], [
    "done",
    "APP-7 → Code Review",
  ]);
  assertEquals(jira("Release Testing").status, "done");
  assertEquals(jira("In Progress").status, "in_progress");
  assertEquals(mapStatus("jira", "issue", jira("Code Review").status), "done");

  const pr = {
    number: 42,
    title: "Login",
    html_url: "https://github.com/me/app/pull/42",
    state: "open",
    updated_at: "2026-11-02T03:00:00Z",
    user: { login: "me" },
    repository_url: "https://api.github.com/repos/me/app",
    pull_request: { merged_at: null },
  };
  assertEquals(
    githubItem({ ...pr, draft: true }, "me", false, rules).status,
    "open",
    "draft is not ready",
  );
  assertEquals(
    githubItem({ ...pr, draft: false }, "me", false, rules).title,
    "PR #42 sẵn sàng review · app",
  );
  const labelled = githubItem(
    {
      ...pr,
      user: { login: "bob" },
      assignees: [{ login: "me" }],
      labels: [{ name: "Ready-For-QA" }],
    },
    "me",
    false,
    rules,
  );
  assertEquals([labelled.status, labelled.title], [
    "done",
    "PR #42 → Ready-For-QA · app",
  ]);
  assertEquals(
    githubItem(
      { ...pr, approved: true },
      "me",
      false,
      doneRules({ pr_done_when: "approved" }),
    ).status,
    "done",
  );
  assertEquals(
    githubItem({ ...pr, approved: true }, "me").status,
    "open",
    "default: only merged counts",
  );
});
