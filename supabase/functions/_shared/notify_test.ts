import { assertEquals } from "jsr:@std/assert@1.0.8";
import {
  apsFor,
  checkinMessage,
  clip,
  collapseIdFor,
  syncDoneMessage,
  syncReopenedMessage,
  weeklyMessage,
} from "./notify.ts";

const task = { id: "t1", title: "Review PR #42" };

Deno.test(
  "notify: reminders break through Focus, FYI pushes stay quiet",
  () => {
    const reminder = apsFor("reminder", { title: "Bắt đầu: Học", body: "x" });
    assertEquals(reminder["interruption-level"], "time-sensitive");
    assertEquals(reminder.category, "REMINDER");
    assertEquals(reminder.sound, "default");

    const done = apsFor(
      "sync",
      syncDoneMessage(task, {
        source: "github",
        kind: "pull_request",
        status: "merged",
        external_id: "o/r#42",
        url: "https://github.com/o/r/pull/42",
      }),
    );
    assertEquals(done["interruption-level"], "passive");
    assertEquals(done.sound, undefined);
    assertEquals(done.category, "SYNC_GITHUB");

    const reopened = apsFor(
      "sync",
      syncReopenedMessage(task, {
        source: "jira",
        kind: "issue",
        status: "in_progress",
        external_id: "APP-12",
        status_name: "In Progress",
        url: null,
      }),
    );
    assertEquals(reopened["interruption-level"], "active");
    assertEquals(reopened["relevance-score"], 0.7);
    assertEquals(reopened.category, undefined); // no URL → no "Mở trên…" button
  },
);

Deno.test("notify: copy says what, why and the next step", () => {
  const done = syncDoneMessage(task, {
    source: "jira",
    kind: "issue",
    status: "done",
    external_id: "APP-7",
    status_name: "Code Review",
    url: "https://x.atlassian.net/browse/APP-7",
  });
  assertEquals(done.title, "Đã xong: Review PR #42");
  assertEquals(
    done.body,
    "APP-7 đã chuyển sang Code Review trên Jira. Not3 đã tự đánh dấu xong.",
  );
  assertEquals(done.link, "not3://task/t1");

  const reopened = syncReopenedMessage(task, {
    source: "github",
    kind: "build",
    status: "failed",
    external_id: "b1",
    url: null,
  });
  assertEquals(reopened.title, "Cần làm lại: Review PR #42");
  assertEquals(
    reopened.body,
    "Build bị lỗi lại. Not3 đã bỏ tick để bạn không bỏ sót.",
  );

  assertEquals(
    checkinMessage(3).body,
    "Sáng nay có 3 việc chờ bạn xác nhận. Nhấn giữ để chọn tâm trạng, chạm để lên kế hoạch chiều.",
  );
  assertEquals(checkinMessage(0).link, "not3://checkin");
  assertEquals(
    weeklyMessage(5).body,
    "5/7 ngày có việc ý nghĩa. Rất đều tay! Chạm để xem lại tuần.",
  );
});

Deno.test("notify: long titles are clipped, one notification per task", () => {
  const long = clip(`Đã xong: ${"a".repeat(100)}`);
  assertEquals(long.length, 64);
  assertEquals(long.endsWith("…"), true);
  assertEquals(
    collapseIdFor("evening", { title: "", body: "", task_id: "t1" }),
    "task-t1",
  );
  assertEquals(collapseIdFor("checkin", { title: "", body: "" }), "checkin");
  assertEquals(
    collapseIdFor("weekly_summary", { title: "", body: "" }),
    undefined,
  );
});
