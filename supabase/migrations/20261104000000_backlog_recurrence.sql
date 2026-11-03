-- "Hộp chờ" and repeating tasks.
-- Someday tasks have no planned_at, so reminder / evening triggers already skip them.
-- Occurrences of a repeating task are generated on the device (Not3/Services/RecurrenceService.swift);
-- task_series is a backup so a reinstall gets the series back.

create table public.task_series (
  id uuid primary key,
  user_id uuid not null references auth.users on delete cascade,
  title text not null,
  chips text[] not null default '{}',
  hour smallint check (hour between 0 and 23),
  minute smallint check (minute between 0 and 59),
  duration_minutes smallint,
  rule text not null,
  start_day date not null,
  is_active boolean not null default true,
  add_to_calendar boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.task_series (user_id);
alter table public.task_series enable row level security;
create policy "own rows" on public.task_series for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

alter table public.tasks
  add column someday boolean not null default false,
  add column series_id uuid references public.task_series on delete set null;
