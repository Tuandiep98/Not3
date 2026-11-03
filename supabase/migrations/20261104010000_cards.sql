-- Content cards (README §8 / §12, `_shared/cards.ts`): one per linked task, gathering its PRs and
-- tickets with a two-line summary. Written by the server after each sync; the app only reads.

create table public.cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  task_id uuid not null unique references public.tasks on delete cascade,
  kind text not null default 'task',
  title text not null,
  status text not null,
  badges text[] not null default '{}',
  items jsonb not null default '[]',
  linked_item_ids text[] not null default '{}',
  primary_action jsonb,
  summary text not null default '',
  ai_summary boolean not null default false,
  version text not null,
  seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.cards (user_id);
alter table public.cards enable row level security;
create policy "read own" on public.cards for select to authenticated
  using ((select auth.uid()) = user_id);
