import { assertEquals } from "jsr:@std/assert@1.0.8";
import { jiraWebhookFilters, webhookAction } from "./jira_webhook.ts";

const now = Date.parse("2026-11-03T08:00:00Z");
const days = (n: number) => new Date(now + n * 86_400_000).toISOString();

Deno.test("jira webhook: register when none, retry failures once a day", () => {
  assertEquals(webhookAction({}, now), "register");
  assertEquals(webhookAction({ webhook_ids: [] }, now), "register");
  assertEquals(
    webhookAction({ webhook_checked_at: days(-0.5), webhook_error: "x" }, now),
    "none",
  );
  assertEquals(
    webhookAction({ webhook_checked_at: days(-2), webhook_error: "x" }, now),
    "register",
  );
});

Deno.test("jira webhook: refresh only in the last week before expiry", () => {
  assertEquals(
    webhookAction({ webhook_ids: [1], webhook_expires_at: days(20) }, now),
    "none",
  );
  assertEquals(
    webhookAction({ webhook_ids: [1], webhook_expires_at: days(3) }, now),
    "refresh",
  );
  assertEquals(webhookAction({ webhook_ids: [1] }, now), "refresh");
});

Deno.test("jira webhook: JQL uses only the supported subset", () => {
  assertEquals(jiraWebhookFilters("abc-123"), [
    'assignee = "abc-123"',
    'reporter = "abc-123"',
  ]);
});
