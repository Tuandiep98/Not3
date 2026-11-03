import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

// Raw activity for "Tổng kết tuần": timestamps of what I did, kept per event (the inbox groups
// commits per repo per day, which loses the times needed to estimate sessions).

export type ActivityRow = {
  source: "github" | "jira";
  external_id: string;
  kind: string;
  title: string;
  scope?: string | null;
  started_at: string;
  ended_at?: string | null;
};

export type GithubActivityEvent = {
  id?: string;
  type: string;
  created_at: string;
  repo: { name: string };
  payload: {
    size?: number;
    commits?: unknown[];
    action?: string;
    ref_type?: string;
    ref?: string;
    pull_request?: { number: number; title?: string };
    issue?: { number: number; title?: string };
    review?: unknown;
  };
};

/** One row per GitHub event that is my own work. Returns [] for events without an id. */
export function githubActivity(events: GithubActivityEvent[]): ActivityRow[] {
  const rows: ActivityRow[] = [];
  for (const e of events) {
    if (!e.id) continue;
    const scope = e.repo.name;
    const repo = scope.split("/")[1] ?? scope;
    const pr = e.payload.pull_request;
    const issue = e.payload.issue;
    let kind: string | null = null;
    let title = "";
    switch (e.type) {
      case "PushEvent": {
        const n = e.payload.size ?? e.payload.commits?.length ?? 1;
        kind = "push";
        title = `${n} commit`;
        break;
      }
      case "PullRequestEvent":
        kind = "pull_request";
        title = `PR #${pr?.number ?? "?"}${pr?.title ? `: ${pr.title}` : ""}`;
        break;
      case "PullRequestReviewEvent":
        kind = "review";
        title = `Review PR #${pr?.number ?? "?"}${
          pr?.title ? `: ${pr.title}` : ""
        }`;
        break;
      case "PullRequestReviewCommentEvent":
      case "IssueCommentEvent":
        kind = "comment";
        title = `Bình luận #${(issue ?? pr)?.number ?? "?"}${
          (issue ?? pr)?.title ? `: ${(issue ?? pr)?.title}` : ""
        }`;
        break;
      case "IssuesEvent":
        kind = "issue";
        title = `Issue #${issue?.number ?? "?"}${
          issue?.title ? `: ${issue.title}` : ""
        }`;
        break;
      case "CreateEvent":
        kind = "create";
        title = `Tạo ${e.payload.ref_type ?? "ref"} ${e.payload.ref ?? ""}`
          .trim();
        break;
      case "ReleaseEvent":
        kind = "release";
        title = "Phát hành";
        break;
    }
    if (!kind) continue;
    rows.push({
      source: "github",
      external_id: e.id,
      kind,
      title: `${title} · ${repo}`.slice(0, 160),
      scope,
      started_at: e.created_at,
    });
  }
  return rows;
}

export type JiraWorklog = {
  id: string;
  started: string;
  timeSpentSeconds: number;
  author?: { accountId?: string };
  /** Atlassian Document Format (REST v3). */
  comment?: unknown;
};

export type JiraIssueRef = { key: string; summary: string };

/** My work logs on these issues that started after `since`, with the issue they belong to. */
export async function jiraMyWorklogs(
  cloudId: string,
  accessToken: string,
  me: string,
  issues: JiraIssueRef[],
  since: Date,
): Promise<{ issue: JiraIssueRef; log: JiraWorklog }[]> {
  const out: { issue: JiraIssueRef; log: JiraWorklog }[] = [];
  for (const issue of issues.slice(0, 20)) {
    const res = await fetch(
      `https://api.atlassian.com/ex/jira/${cloudId}/rest/api/3/issue/${issue.key}/worklog?startedAfter=${since.getTime()}&maxResults=100`,
      {
        headers: {
          Authorization: `Bearer ${accessToken}`,
          Accept: "application/json",
        },
      },
    ).catch(() => null);
    if (!res?.ok) continue;
    const data = (await res.json().catch(() => ({}))) as {
      worklogs?: JiraWorklog[];
    };
    for (const log of data.worklogs ?? []) {
      if (log.author?.accountId === me && log.timeSpentSeconds > 0) {
        out.push({ issue, log });
      }
    }
  }
  return out;
}

/** Plain text of an Atlassian Document Format value (a work log comment); "" when empty. */
export function adfText(doc: unknown): string {
  if (typeof doc === "string") return doc.trim();
  const parts: string[] = [];
  const walk = (node: unknown) => {
    if (!node || typeof node !== "object") return;
    const n = node as { type?: string; text?: string; content?: unknown[] };
    if (typeof n.text === "string") parts.push(n.text);
    if (n.type === "hardBreak") parts.push(" ");
    for (const child of n.content ?? []) walk(child);
    if (n.type === "paragraph" || n.type === "listItem") parts.push(" ");
  };
  walk(doc);
  return parts.join("").replace(/\s+/g, " ").trim();
}

export function worklogRows(
  logs: JiraWorklog[],
  me: string,
  issue: { key: string; summary: string },
): ActivityRow[] {
  return logs
    .filter((w) => w.author?.accountId === me && w.timeSpentSeconds > 0)
    .map((w) => {
      const start = new Date(w.started);
      return {
        source: "jira" as const,
        external_id: `worklog:${w.id}`,
        kind: "worklog",
        title: `${issue.key}: ${issue.summary}`.slice(0, 160),
        scope: issue.key.split("-")[0],
        started_at: start.toISOString(),
        ended_at: new Date(
          start.getTime() + w.timeSpentSeconds * 1000,
        ).toISOString(),
      };
    });
}

export async function saveActivity(
  db: SupabaseClient,
  userId: string,
  rows: ActivityRow[],
): Promise<void> {
  if (!rows.length) return;
  const { error } = await db.from("activity_events").upsert(
    rows.map((r) => ({ ...r, user_id: userId })),
    { onConflict: "user_id,source,external_id" },
  );
  if (error) console.error("[activity] save", error.message);
}
