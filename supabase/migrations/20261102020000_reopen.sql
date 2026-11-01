-- Reopen tasks when GitHub / Jira goes back from finished to in progress (rejected review,
-- ticket moved back from Code Review, PR reopened, build red again). The app shows the reason.
alter table public.tasks
  add column reopened_at timestamptz,
  add column reopened_reason text;

-- The provider's own status name (Jira "Code Review", "Reopened"…) for readable reasons.
alter table public.external_items add column status_name text;
