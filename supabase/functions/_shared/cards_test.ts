import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.8";
import { fingerprint, groupCards, ruleSummary, summarizeCards } from "./cards.ts";
import { resetModelCache } from "./deepseek.ts";

const task = (id: string, title: string, status = "todo") => ({
  id,
  title,
  status: status as "todo" | "doing" | "done" | "cancelled",
  completed_at: null,
});

const ticket = {
  source: "jira",
  external_id: "NOT-118",
  kind: "issue",
  title: "Push 12h không tới máy",
  url: "https://acme.atlassian.net/browse/NOT-118",
  status: "in_progress",
  status_name: "Code Review",
};
const pr = {
  source: "github",
  external_id: "acme/app-ios/pull/42",
  kind: "pull_request",
  title: "NOT-118: fix APNs environment",
  url: "https://github.com/acme/app-ios/pull/42",
  status: "merged",
};
const otherPr = { ...pr, external_id: "acme/app-ios/pull/50", title: "Refactor widgets", status: "open" };

Deno.test("a ticket and the PR naming it make one card", () => {
  const cards = groupCards(
    [task("t1", "JIRA NOT-118 push"), task("t2", "Không liên kết")],
    [{ task_id: "t1", provider: "jira", external_id: "NOT-118" }],
    [ticket, pr, otherPr],
  );
  assertEquals(cards.length, 1);
  assertEquals(cards[0].items.map((i) => i.label), ["NOT-118", "PR #42"]);
  assertEquals(cards[0].badges, ["jira", "github"]);
  assertEquals(cards[0].status, "done", "most advanced item wins");
  assertEquals(ruleSummary(cards[0].items), "NOT-118 Code Review · PR #42 đã merge");
});

Deno.test("cancelled only counts when nothing else is live", () => {
  const closed = { ...otherPr, status: "closed" };
  const [card] = groupCards(
    [task("t1", "PR")],
    [
      { task_id: "t1", provider: "github", external_id: closed.external_id },
      { task_id: "t1", provider: "jira", external_id: "NOT-118" },
    ],
    [closed, { ...ticket, status: "todo", status_name: null }],
  );
  assertEquals(card.status, "todo");
  const [onlyClosed] = groupCards(
    [task("t1", "PR")],
    [{ task_id: "t1", provider: "github", external_id: closed.external_id }],
    [closed],
  );
  assertEquals(onlyClosed.status, "cancelled");
});

Deno.test("version changes with the items, not with unrelated data", () => {
  const link = [{ task_id: "t1", provider: "jira", external_id: "NOT-118" }];
  const a = groupCards([task("t1", "x")], link, [ticket, otherPr])[0].version;
  const b = groupCards([task("t1", "x")], link, [ticket, { ...otherPr, status: "merged" }])[0].version;
  const c = groupCards([task("t1", "x")], link, [{ ...ticket, status_name: "Done", status: "done" }])[0].version;
  assertEquals(a, b);
  assertNotEquals(a, c);
  assertEquals(fingerprint("abc"), fingerprint("abc"));
});

Deno.test("summaries come back per card; AI failure gives null (rules take over)", async () => {
  Deno.env.set("DEEPSEEK_API_KEY", "test");
  Deno.env.delete("DEEPSEEK_MODEL");
  resetModelCache();
  const replies = [
    { content: JSON.stringify({ cards: [{ task_id: "t1", summary: "PR đã merge, ticket chờ review." }, { task_id: "ghost", summary: "x" }] }) },
  ];
  let sent = "";
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.endsWith("/models")) {
      return Promise.resolve(new Response(JSON.stringify({ object: "list", data: [{ id: "deepseek-flash" }] })));
    }
    sent = String(init?.body);
    const next = replies.shift();
    return Promise.resolve(
      next ? new Response(JSON.stringify({ choices: [{ message: next }] })) : new Response("down", { status: 503 }),
    );
  }) as typeof fetch;

  const cards = groupCards([task("t1", "push")], [{ task_id: "t1", provider: "jira", external_id: "NOT-118" }], [ticket, pr]);
  const summaries = await summarizeCards(cards);
  assertEquals(summaries?.get("t1"), "PR đã merge, ticket chờ review.");
  assertEquals(summaries?.has("ghost"), false);
  assertEquals(sent.includes("Push 12h không tới máy"), true, "titles are sent");
  assertEquals(sent.includes("atlassian.net"), false, "links are not");

  assertEquals(await summarizeCards(cards), null);
});
