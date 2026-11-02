-- Weekly summary v2: time worked. Raw activity timestamps the app turns into time blocks
-- (Not3/Services/Activity/ActivityEngine.swift):
--   github: every event I made (push, PR, review, comment…) — sessions are estimated from these
--   jira:   my work logs, with their real start and duration
-- Calendar stays on the device (EventKit); tasks carry their own start / finish times.

create table public.activity_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  source text not null check (source in ('github', 'jira')),
  external_id text not null,
  kind text not null,
  title text not null default '',
  scope text,
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, source, external_id)
);
create index on public.activity_events (user_id, started_at);
alter table public.activity_events enable row level security;
create policy "read own" on public.activity_events for select to authenticated
  using ((select auth.uid()) = user_id);

-- "Bắt đầu" → "Xong" gives the real time spent on a task.
alter table public.tasks add column started_at timestamptz;

-- Keep about six months of history.
select cron.schedule('cleanup-activity', '45 3 * * *', $$
  delete from public.activity_events where started_at < now() - interval '200 days';
$$);
