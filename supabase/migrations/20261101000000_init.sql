-- Not3 phase 1 schema. Every table has RLS on auth.uid() (README §8).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- profiles ------------------------------------------------------------------
create table public.profiles (
  user_id uuid primary key references auth.users on delete cascade,
  timezone text not null default 'Asia/Ho_Chi_Minh',
  checkin_hour smallint not null default 12 check (checkin_hour between 0 and 23),
  checkin_minute smallint not null default 0 check (checkin_minute between 0 and 59),
  ai_notes_enabled boolean not null default true,
  sync_note_content boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- devices -------------------------------------------------------------------
create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  apns_token text not null unique,
  environment text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.devices (user_id);

-- notes (title + chips; body only when the user allows it) ------------------
create table public.notes (
  id uuid primary key,
  user_id uuid not null references auth.users on delete cascade,
  ck_record_name text,
  title text not null default '',
  chips text[] not null default '{}',
  body text,
  updated_at timestamptz not null default now()
);
create index on public.notes (user_id, updated_at desc);

-- tasks ---------------------------------------------------------------------
create table public.tasks (
  id uuid primary key,
  user_id uuid not null references auth.users on delete cascade,
  title text not null,
  chips text[] not null default '{}',
  planned_at timestamptz,
  duration_minutes smallint,
  status text not null default 'todo' check (status in ('todo', 'doing', 'done', 'cancelled')),
  source text not null default 'manual' check (source in ('manual', 'ai', 'integration')),
  if_then_sentence text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.tasks (user_id, planned_at);

-- checkins ------------------------------------------------------------------
create table public.checkins (
  id uuid primary key,
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  morning_items text[] not null default '{}',
  mood text check (mood in ('good', 'ok', 'empty')),
  afternoon_plan_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (user_id, day)
);

-- chips ---------------------------------------------------------------------
create table public.chips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  "group" text not null check ("group" in ('category', 'duration', 'time', 'mood', 'item', 'ai')),
  label text not null,
  use_count integer not null default 0,
  last_used_at timestamptz,
  unique (user_id, "group", label)
);

-- external_items (filled by sync-integrations in phase 3) -------------------
create table public.external_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  source text not null check (source in ('calendar', 'github', 'jira')),
  external_id text not null,
  title text not null,
  url text,
  occurred_at timestamptz not null,
  unique (user_id, source, external_id)
);

-- suggestions ---------------------------------------------------------------
create table public.suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  kind text not null check (kind in ('morning_chip', 'afternoon_task', 'note_chip')),
  payload jsonb not null,
  status text not null default 'new' check (status in ('new', 'picked', 'dismissed')),
  day date not null default current_date,
  created_at timestamptz not null default now()
);
create index on public.suggestions (user_id, day);

-- integrations (tokens live in Vault, never in this table) ------------------
create table public.integrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  provider text not null check (provider in ('github', 'jira')),
  account_name text,
  scopes text[] not null default '{}',
  vault_secret_id uuid,
  last_synced_at timestamptz,
  unique (user_id, provider)
);

-- push_queue ----------------------------------------------------------------
create table public.push_queue (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  send_at timestamptz not null,
  kind text not null check (kind in ('checkin', 'reminder', 'evening', 'weekly_summary', 'silent')),
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  dedupe_key text unique,
  attempts smallint not null default 0,
  created_at timestamptz not null default now()
);
create index on public.push_queue (status, send_at);

-- RLS -----------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','devices','notes','tasks','checkins','chips',
                           'external_items','suggestions','integrations','push_queue']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "own rows" on public.%I for all to authenticated
         using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- Reminder push for if–then plans: whenever a task gets a planned_at, queue a push.
create or replace function public.queue_task_reminder() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.planned_at is not null and new.status = 'todo' and new.planned_at > now() then
    insert into push_queue (user_id, send_at, kind, payload, dedupe_key)
    values (new.user_id, new.planned_at, 'reminder',
            jsonb_build_object('title', 'Đến giờ rồi', 'body', coalesce(new.if_then_sentence, new.title), 'task_id', new.id),
            'reminder:' || new.id || ':' || extract(epoch from new.planned_at)::bigint)
    on conflict (dedupe_key) do nothing;
  end if;
  return new;
end $$;

create trigger tasks_queue_reminder
after insert or update of planned_at, status on public.tasks
for each row execute function public.queue_task_reminder();

-- Users whose local time is inside [now, now + 5 min) for a given offset from their check-in time.
create or replace function public.users_due(offset_minutes integer)
returns table (user_id uuid, local_day date, timezone text)
language sql stable security definer set search_path = public as $$
  select p.user_id, (now() at time zone p.timezone)::date, p.timezone
  from profiles p
  where (
    ((p.checkin_hour * 60 + p.checkin_minute - offset_minutes + 1440) % 1440)
    - (extract(hour from now() at time zone p.timezone) * 60
       + extract(minute from now() at time zone p.timezone))::int
    + 1440
  ) % 1440 < 5;
$$;
revoke execute on function public.users_due(integer) from anon, authenticated;

-- Account deletion (App Store requirement). Cascades to every table.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from auth.users where id = auth.uid();
end $$;
revoke execute on function public.delete_account() from anon;
grant execute on function public.delete_account() to authenticated;

-- Meaningful days (≥ 1 finished task) per ISO week — read by the Summary screen.
create or replace view public.weekly_stats with (security_invoker = true) as
select t.user_id,
       date_trunc('week', (t.completed_at at time zone p.timezone))::date as week_start,
       count(distinct (t.completed_at at time zone p.timezone)::date) as meaningful_days,
       count(*) as done_tasks
from tasks t join profiles p using (user_id)
where t.status = 'done' and t.completed_at is not null
group by 1, 2;

-- Single cron every 5 minutes → Edge Function `tick` (pg_cron runs in UTC; tick handles time zones).
-- Store the project URL and a secret key in Vault first (sb_secret_… or the legacy service_role JWT):
--   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
--   select vault.create_secret('<secret key>', 'service_role_key');
select cron.schedule('tick', '*/5 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/tick',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- New sb_secret_ keys are read from `apikey`; a legacy service_role JWT from Authorization.
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb
  );
$$);

select cron.schedule('cleanup', '30 3 * * *', $$
  delete from public.suggestions where created_at < now() - interval '30 days';
  delete from public.push_queue where created_at < now() - interval '30 days';
$$);
