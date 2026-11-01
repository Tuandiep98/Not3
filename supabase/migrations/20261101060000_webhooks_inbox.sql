-- Phase 3 (end): webhooks, periodic polling, nightly reconcile, "Mới đồng bộ" inbox (README §12).

-- Webhook deliveries: unique per provider delivery id, so a redelivery is processed once.
create table public.sync_events (
  id bigint generated always as identity primary key,
  provider text not null check (provider in ('github', 'jira')),
  delivery_id text not null,
  event text not null,
  status text not null default 'pending' check (status in ('pending', 'done', 'skipped', 'failed')),
  attempts smallint not null default 0,
  error text,
  created_at timestamptz not null default now(),
  unique (provider, delivery_id)
);
alter table public.sync_events enable row level security;   -- service role only

-- "Luôn bỏ qua loại này": learned rules, applied by the app's inbox and by build-checkin.
create table public.content_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  provider text not null check (provider in ('github', 'jira', 'calendar')),
  kind text not null,
  action text not null check (action in ('ignore')),
  created_at timestamptz not null default now(),
  unique (user_id, provider, kind)
);
alter table public.content_rules enable row level security;
create policy "own rows" on public.content_rules for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Inbox decision per synced item: null = still in "Mới đồng bộ".
alter table public.external_items
  add column decision text check (decision in ('task', 'note', 'ignored'));

-- Users with an integration whose local time is 08:00–20:00 and on a 15-minute boundary (poll-active).
create or replace function public.users_poll_active()
returns table (user_id uuid, local_day date, timezone text)
language sql stable security definer set search_path = public as $$
  select distinct p.user_id, (now() at time zone p.timezone)::date, p.timezone
  from profiles p join integrations i on i.user_id = p.user_id
  where extract(hour from now() at time zone p.timezone) between 8 and 19
    and extract(minute from now() at time zone p.timezone)::int % 15 < 5;
$$;

-- Users whose local time is HH:MM–HH:MM+5 (nightly reconcile at 02:00).
create or replace function public.users_at_local_time(p_hour integer, p_minute integer)
returns table (user_id uuid, local_day date, timezone text)
language sql stable security definer set search_path = public as $$
  select p.user_id, (now() at time zone p.timezone)::date, p.timezone
  from profiles p
  -- minutes since the target local time, wrapped over midnight; due during the first 5 minutes
  where (((extract(hour from now() at time zone p.timezone) * 60
           + extract(minute from now() at time zone p.timezone))::int
          - (p_hour * 60 + p_minute)) % 1440 + 1440) % 1440 < 5;
$$;

revoke execute on function public.users_poll_active() from public, anon, authenticated;
revoke execute on function public.users_at_local_time(integer, integer) from public, anon, authenticated;
