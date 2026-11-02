import { assertEquals } from "jsr:@std/assert@1.0.8";
import { githubActivity, worklogRows } from "./activity.ts";

Deno.test("activity: one row per own GitHub event, keyed by event id", () => {
  const rows = githubActivity([
    {
      id: "1",
      type: "PushEvent",
      created_at: "2026-11-03T02:00:00Z",
      repo: { name: "me/app-ios" },
      payload: { size: 3 },
    },
    {
      id: "2",
      type: "PullRequestReviewEvent",
      created_at: "2026-11-03T03:00:00Z",
      repo: { name: "me/app-ios" },
      payload: { pull_request: { number: 57, title: "Sync lịch" } },
    },
    {
      id: "3",
      type: "WatchEvent",
      created_at: "2026-11-03T03:10:00Z",
      repo: { name: "x/y" },
      payload: {},
    },
    {
      type: "PushEvent",
      created_at: "2026-11-03T04:00:00Z",
      repo: { name: "me/app-ios" },
      payload: {},
    },
  ]);
  assertEquals(
    rows.map((r) => [r.external_id, r.kind, r.title]),
    [
      ["1", "push", "3 commit · app-ios"],
      ["2", "review", "Review PR #57: Sync lịch · app-ios"],
    ],
  );
});

Deno.test("activity: only my Jira work logs, with real start and end", () => {
  const rows = worklogRows(
    [
      {
        id: "10",
        started: "2026-11-03T09:00:00.000+0700",
        timeSpentSeconds: 5400,
        author: { accountId: "me" },
      },
      {
        id: "11",
        started: "2026-11-03T10:00:00.000+0700",
        timeSpentSeconds: 600,
        author: { accountId: "someone" },
      },
    ],
    "me",
    { key: "APP-120", summary: "Push 12h" },
  );
  assertEquals(rows.length, 1);
  assertEquals(rows[0].external_id, "worklog:10");
  assertEquals(rows[0].started_at, "2026-11-03T02:00:00.000Z");
  assertEquals(rows[0].ended_at, "2026-11-03T03:30:00.000Z");
  assertEquals(rows[0].title, "APP-120: Push 12h");
});
