-- "Tính là hoàn thành": per-integration rules for what counts as finished (Settings → GitHub / Jira).
--   {"statuses": ["Code Review", "Release Testing"],     -- Jira status names (besides category Done)
--    "labels": ["ready-for-qa", "deployed"],              -- GitHub labels on PRs / issues
--    "pr_done_when": "merged" | "approved" | "ready_for_review"}
alter table public.integrations add column done_rules jsonb not null default '{}';
grant update (settings, done_rules) on public.integrations to authenticated;
