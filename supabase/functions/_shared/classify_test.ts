import { assertEquals } from "jsr:@std/assert@1.0.8";
import { type ClassifiableItem, classify, taskTitle } from "./classify.ts";
import { githubItem } from "./integrations.ts";

const item = (over: Partial<ClassifiableItem>): ClassifiableItem => ({
  source: "github",
  external_id: "https://github.com/acme/app/pull/57",
  kind: "pull_request",
  title: "Review PR #57 · app",
  url: null,
  status: "review_requested",
  role: "reviewer",
  scope: "acme/app",
  ...over,
});
const none = new Set<string>();

Deno.test("README rules: review request / own PR / assigned → task", () => {
  assertEquals(classify(item({}), none).decision, "task");
  const own = classify(item({ role: "author", status: "open" }), none);
  assertEquals([own.decision, own.decision === "task" && own.status], [
    "task",
    "doing",
  ]);
  assertEquals(
    classify(item({ kind: "issue", role: "assignee", status: "open" }), none)
      .decision,
    "task",
  );
  const jira = classify(
    item({
      source: "jira",
      kind: "issue",
      role: "assignee",
      status: "in_progress",
    }),
    none,
  );
  assertEquals([jira.decision, jira.decision === "task" && jira.status], [
    "task",
    "doing",
  ]);
});

Deno.test("finished work and commits → journal, never a task", () => {
  for (
    const status of ["merged", "closed", "completed", "not_planned", "done"]
  ) {
    assertEquals(classify(item({ status }), none).decision, "journal", status);
  }
  assertEquals(
    classify(item({ kind: "commits", status: null, role: null }), none)
      .decision,
    "journal",
  );
});

Deno.test("unclear cases stay unclassified with a reason", () => {
  const mention = classify(item({ role: "involved", status: "open" }), none);
  assertEquals([mention.decision, mention.reason], [
    null,
    "Bạn chỉ được nhắc đến",
  ]);
  const reporter = classify(
    item({ source: "jira", kind: "issue", role: "reporter", status: "todo" }),
    none,
  );
  assertEquals([reporter.decision, reporter.reason], [
    null,
    "Bạn tạo ticket, người khác làm",
  ]);
});

Deno.test("ignore rules: whole kind or one repo", () => {
  assertEquals(
    classify(item({}), new Set(["github|pull_request|"])).decision,
    "ignored",
  );
  assertEquals(
    classify(item({}), new Set(["github|pull_request|acme/app"])).decision,
    "ignored",
  );
  assertEquals(
    classify(item({}), new Set(["github|pull_request|acme/other"])).decision,
    "task",
  );
});

Deno.test("roles from GitHub data and task title without the repo tail", () => {
  const base = {
    number: 57,
    title: "Refactor",
    html_url: "https://github.com/acme/app/pull/57",
    state: "open",
    updated_at: "2026-11-02T02:00:00Z",
    user: { login: "bob" },
    repository_url: "https://api.github.com/repos/acme/app",
    pull_request: { merged_at: null },
  };
  const reviewer = githubItem({
    ...base,
    requested_reviewers: [{ login: "me" }],
  }, "me");
  assertEquals([reviewer.role, reviewer.status, reviewer.scope], [
    "reviewer",
    "review_requested",
    "acme/app",
  ]);
  assertEquals(githubItem(base, "me").role, "involved");
  assertEquals(
    githubItem({ ...base, user: { login: "me" } }, "me").status,
    "open",
  );
  assertEquals(taskTitle(item({})), "Review PR #57");
});
