-- Phase 2: AI via DeepSeek (README §10). AI only suggests; the user taps to accept.

-- Per-user daily quota ------------------------------------------------------
create table public.ai_usage (
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  calls integer not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;
create policy "read own usage" on public.ai_usage for select to authenticated
  using ((select auth.uid()) = user_id);

-- Atomically takes one call from today's quota; false when the limit is reached.
create or replace function public.try_consume_ai(p_user uuid, p_limit integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  insert into ai_usage (user_id, day, calls) values (p_user, current_date, 1)
  on conflict (user_id, day) do update set calls = ai_usage.calls + 1
    where ai_usage.calls < p_limit
  returning true into ok;
  return coalesce(ok, false);
end $$;
revoke execute on function public.try_consume_ai(uuid, integer) from public, anon, authenticated;

-- Weekly summaries ----------------------------------------------------------
create table public.weekly_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  week_start date not null,
  summary text not null,
  stats jsonb not null default '{}',
  source text not null check (source in ('ai', 'rules')),
  created_at timestamptz not null default now(),
  unique (user_id, week_start)
);
alter table public.weekly_summaries enable row level security;
create policy "read own summaries" on public.weekly_summaries for select to authenticated
  using ((select auth.uid()) = user_id);

-- Users whose local time is Sunday 20:00–20:05.
create or replace function public.users_due_weekly()
returns table (user_id uuid, week_start date, timezone text)
language sql stable security definer set search_path = public as $$
  select p.user_id,
         date_trunc('week', now() at time zone p.timezone)::date,
         p.timezone
  from profiles p
  where extract(isodow from now() at time zone p.timezone) = 7
    and (extract(hour from now() at time zone p.timezone) * 60
         + extract(minute from now() at time zone p.timezone)) between 1200 and 1204;
$$;
revoke execute on function public.users_due_weekly() from public, anon, authenticated;

-- AI chips on notes (kept apart from user chips; the app shows them as suggestions) --
alter table public.notes
  add column ai_chips text[] not null default '{}',
  add column ai_tagged_at timestamptz;

-- Database webhook: when a note's title/body changes, ask `tag-note` to suggest chips.
create or replace function public.notify_tag_note() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and new.title is not distinct from old.title
     and new.body is not distinct from old.body then
    return new;
  end if;
  if not exists (select 1 from profiles where user_id = new.user_id and ai_notes_enabled) then
    return new;
  end if;
  if coalesce(trim(new.title), '') = '' and coalesce(trim(new.body), '') = '' then
    return new;
  end if;
  perform net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/tag-note',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- New sb_secret_ keys are read from `apikey`; a legacy service_role JWT from Authorization.
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := jsonb_build_object('note_id', new.id)
  );
  return new;
end $$;

create trigger notes_tag_with_ai
after insert or update of title, body on public.notes
for each row execute function public.notify_tag_note();
