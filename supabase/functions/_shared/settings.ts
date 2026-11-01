// Per-integration toggles (Settings → GitHub / Jira in the app). Stored in integrations.settings;
// missing keys fall back to these defaults. Keep in sync with Not3/Data/IntegrationOptions.swift.

export const GITHUB_DEFAULTS = {
  prs: true, // PR & issue of mine (author / assignee)
  review_requests: true, // PR asking me for a review → task
  reviews_submitted: true, // reviews I sent → done (completes the "Review PR" task)
  commits: true,
  releases: true, // releases & tags I published
  merges: true, // PRs of others I merged
  comments: false, // my comments → journal
  mentions: true, // @mentions → task "Trả lời …", done when I comment back
  builds: false, // GitHub Actions runs I triggered (needs Actions: Read)
  deploys: false, // deployments I created (needs Deployments: Read)
};

export const JIRA_DEFAULTS = {
  assigned: true,
  reported: true,
  sprint: false, // my open tickets in active sprints, even if not updated today
  watching: false,
  transitions: true, // status changes I made → journal
  worklogs: false, // my work logs today → journal
};

export type GithubSettings = typeof GITHUB_DEFAULTS;
export type JiraSettings = typeof JIRA_DEFAULTS;

export function githubSettings(raw: unknown): GithubSettings {
  return { ...GITHUB_DEFAULTS, ...pickBooleans(raw, GITHUB_DEFAULTS) };
}

export function jiraSettings(raw: unknown): JiraSettings {
  return { ...JIRA_DEFAULTS, ...pickBooleans(raw, JIRA_DEFAULTS) };
}

function pickBooleans<T extends Record<string, boolean>>(
  raw: unknown,
  shape: T,
): Partial<T> {
  const out: Partial<T> = {};
  if (raw && typeof raw === "object") {
    for (const key of Object.keys(shape) as (keyof T)[]) {
      const value = (raw as Record<string, unknown>)[key as string];
      if (typeof value === "boolean") out[key] = value as T[keyof T];
    }
  }
  return out;
}

/** What counts as finished, per integration (integrations.done_rules). */
export type DoneRules = {
  /** Jira status names counted as done (case-insensitive), besides statusCategory Done. */
  statuses: string[];
  /** GitHub labels that mark a PR / issue as done. */
  labels: string[];
  /** When the user's own PR counts as done. */
  pr_done_when: "merged" | "approved" | "ready_for_review";
};

export const NO_DONE_RULES: DoneRules = {
  statuses: [],
  labels: [],
  pr_done_when: "merged",
};

export function doneRules(raw: unknown): DoneRules {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<
    string,
    unknown
  >;
  const strings = (v: unknown) =>
    Array.isArray(v)
      ? v.filter((x): x is string => typeof x === "string" && x.trim() !== "")
        .map((x) => x.trim()).slice(0, 50)
      : [];
  const when = r.pr_done_when;
  return {
    statuses: strings(r.statuses),
    labels: strings(r.labels),
    pr_done_when: when === "approved" || when === "ready_for_review"
      ? when
      : "merged",
  };
}

export const sameName = (a: string, b: string) =>
  a.localeCompare(b, undefined, { sensitivity: "base" }) === 0;
