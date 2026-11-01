-- Phase 3: task ↔ external item links + automatic status sync (README §12).

create table public.task_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  task_id uuid not null references public.tasks on delete cascade,
  provider text not null check (provider in ('github', 'jira', 'calendar')),
  external_id text not null,
  url text,
  title text,
  external_status text,
  external_updated_at timestamptz,
  link_source text not null check (link_source in ('auto', 'ai', 'manual')),
  confidence real not null default 1,
  created_at timestamptz not null default now(),
  unique (task_id, provider, external_id)
);
create index on public.task_links (user_id);
alter table public.task_links enable row level security;
create policy "own rows" on public.task_links for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Who changed a task last: the app, or the server sync (so the app only pulls server changes).
alter table public.tasks add column updated_by text not null default 'app'
  check (updated_by in ('app', 'sync'));

-- Link suggestions (0.6–0.85 confidence) reuse `suggestions`; status pushes reuse `push_queue`.
alter table public.suggestions drop constraint suggestions_kind_check;
alter table public.suggestions add constraint suggestions_kind_check
  check (kind in ('morning_chip', 'afternoon_task', 'note_chip', 'link'));
alter table public.push_queue drop constraint push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check
  check (kind in ('checkin', 'reminder', 'evening', 'weekly_summary', 'silent', 'sync'));

-- The app accepts a link suggestion with one tap.
create or replace function public.accept_link_suggestion(p_suggestion uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from suggestions where id = p_suggestion and user_id = auth.uid() and kind = 'link';
  if not found then raise exception 'suggestion not found'; end if;
  insert into task_links (user_id, task_id, provider, external_id, url, title, link_source, confidence)
  values (s.user_id, (s.payload->>'task_id')::uuid, s.payload->>'provider', s.payload->>'external_id',
          s.payload->>'url', s.payload->>'title', 'ai', coalesce((s.payload->>'confidence')::real, 0.7))
  on conflict (task_id, provider, external_id) do nothing;
  update suggestions set status = 'picked' where id = p_suggestion;
end $$;
revoke execute on function public.accept_link_suggestion(uuid) from public, anon;
grant execute on function public.accept_link_suggestion(uuid) to authenticated;
