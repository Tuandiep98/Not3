import { assertEquals } from "jsr:@std/assert@1.0.8";
import {
  effectiveStatus,
  mapStatus,
  ruleMatches,
  transition,
} from "./links.ts";

Deno.test("status map follows README §12", () => {
  assertEquals(mapStatus("github", "pull_request", "merged"), "done");
  assertEquals(mapStatus("github", "pull_request", "closed"), "cancelled");
  assertEquals(mapStatus("github", "issue", "completed"), "done");
  assertEquals(mapStatus("github", "issue", "not_planned"), "cancelled");
  assertEquals(mapStatus("jira", "issue", "done"), "done");
  assertEquals(mapStatus("jira", "issue", "in_progress"), "doing");
  assertEquals(mapStatus("github", "commits", null), null);
});

Deno.test("rule matches: Jira key and PR number in the task title", () => {
  const items = [
    {
      source: "jira",
      external_id: "JIRA-118",
      kind: "issue",
      title: "JIRA-118 → Done",
      url: null,
      status: "done",
      updated_at: "",
    },
    {
      source: "github",
      external_id: "https://github.com/me/app/pull/42",
      kind: "pull_request",
      title: "PR #42 đã merge · app",
      url: null,
      status: "merged",
      updated_at: "",
    },
    {
      source: "github",
      external_id: "commits:app:2026-11-02",
      kind: "commits",
      title: "3 commit · app",
      url: null,
      status: null,
      updated_at: "",
    },
  ];
  const task = (title: string) => ({
    id: "t",
    title,
    status: "todo" as const,
    created_at: "",
  });
  assertEquals(
    ruleMatches(task("Hoàn thành jira-118 login"), items).map((i) =>
      i.external_id
    ),
    ["JIRA-118"],
  );
  assertEquals(
    ruleMatches(task("Review PR #42"), items).map((i) => i.external_id),
    ["https://github.com/me/app/pull/42"],
  );
  assertEquals(ruleMatches(task("Viết test module login"), items), []);
  assertEquals(
    ruleMatches(task("Học 20 từ"), items),
    [],
    "numbers without # do not match",
  );
});

Deno.test("transition: forward moves and reopen on reject", async () => {
  const { transition } = await import("./links.ts");
  // Forward
  assertEquals(transition("todo", null, "done", "merged"), {
    status: "done",
    reopened: false,
  });
  assertEquals(transition("todo", "todo", "doing", "in_progress"), {
    status: "doing",
    reopened: false,
  });
  assertEquals(
    transition("doing", "doing", "todo", "todo"),
    null,
    "never back to todo while open",
  );
  // Jira Code Review (counted done) → back to In Progress: reopen as doing
  assertEquals(transition("done", "done", "doing", "in_progress"), {
    status: "doing",
    reopened: true,
  });
  // Review sent → re-requested: reopen as todo
  assertEquals(transition("done", "done", "todo", "review_requested"), {
    status: "todo",
    reopened: true,
  });
  // PR closed → reopened
  assertEquals(transition("cancelled", "cancelled", "todo", "open"), {
    status: "todo",
    reopened: true,
  });
  // Build green → red again
  assertEquals(transition("done", "done", null, "failed"), {
    status: "todo",
    reopened: true,
  });
  // Ticked by hand while the item was still open: an unrelated change does not reopen it
  assertEquals(transition("done", "doing", "todo", "todo"), null);
  // Still finished: nothing to do
  assertEquals(transition("done", "done", "done", "done"), null);
});

Deno.test("reopen reasons are readable", async () => {
  const { reopenReason } = await import("./links.ts");
  assertEquals(
    reopenReason({
      source: "jira",
      kind: "issue",
      status: "in_progress",
      external_id: "JIRA-120",
      status_name: "Reopened",
    }),
    "JIRA-120 → Reopened",
  );
  assertEquals(
    reopenReason({
      source: "jira",
      kind: "issue",
      status: "in_progress",
      external_id: "JIRA-120",
    }),
    "JIRA-120 → In Progress",
  );
  assertEquals(
    reopenReason({
      source: "github",
      kind: "pull_request",
      status: "review_requested",
      external_id: "x",
    }),
    "Được nhờ review lại",
  );
  assertEquals(
    reopenReason({
      source: "github",
      kind: "build",
      status: "failed",
      external_id: "x",
    }),
    "Build lỗi lại",
  );
});

Deno.test("synced Jira task: unassigned from me → cancelled, assigned back → reopened", () => {
  const synced = { source: "integration" };
  const issue = { source: "jira", kind: "issue", status: "todo" };
  assertEquals(effectiveStatus({ ...issue, role: "assignee" }, synced), "todo");
  for (const role of ["involved", "reporter", "watcher"]) {
    assertEquals(effectiveStatus({ ...issue, role }, synced), "unassigned");
  }
  // Unassigned → the open task is cancelled.
  const gone = mapStatus("jira", "issue", "unassigned");
  assertEquals(gone, "cancelled");
  assertEquals(transition("todo", "todo", gone, "unassigned"), {
    status: "cancelled",
    reopened: false,
  });
  assertEquals(transition("doing", "doing", gone, "unassigned"), {
    status: "cancelled",
    reopened: false,
  });
  // Assigned back → reopened.
  assertEquals(transition("cancelled", gone, "todo", "todo"), {
    status: "todo",
    reopened: true,
  });
  // A task the user ticked stays done.
  assertEquals(transition("done", "todo", gone, "unassigned"), null);
});

Deno.test("unassigned does not apply to done tickets, own tasks or an unknown role", () => {
  const issue = { source: "jira", kind: "issue", role: "involved" };
  // Finished then handed to QA: still done.
  assertEquals(
    effectiveStatus({ ...issue, status: "done" }, { source: "integration" }),
    "done",
  );
  // The user's own task that mentions the key.
  assertEquals(
    effectiveStatus({ ...issue, status: "todo" }, { source: "manual" }),
    "todo",
  );
  assertEquals(
    effectiveStatus({ ...issue, status: "todo" }, undefined),
    "todo",
  );
  // Account id unknown: role not set.
  assertEquals(
    effectiveStatus({ ...issue, role: null, status: "todo" }, {
      source: "integration",
    }),
    "todo",
  );
  // GitHub is unchanged.
  assertEquals(
    effectiveStatus(
      { source: "github", kind: "issue", role: "involved", status: "open" },
      { source: "integration" },
    ),
    "open",
  );
});
