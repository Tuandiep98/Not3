-- Per-integration toggles (Settings → GitHub / Jira) + tighter integrations permissions.

alter table public.integrations add column settings jsonb not null default '{}';

-- The app may only change `settings` on its own rows. Before this, "own rows" allowed updating
-- every column, including vault_secret_id — which could point the server at another secret.
-- Inserts / deletes go through save_integration (service role) and disconnect_integration (RPC).
revoke insert, update, delete on public.integrations from authenticated;
grant update (settings) on public.integrations to authenticated;
drop policy "own rows" on public.integrations;
create policy "read own" on public.integrations for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "update own settings" on public.integrations for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Jira "ticket tôi theo dõi".
alter table public.external_items drop constraint external_items_role_check;
alter table public.external_items add constraint external_items_role_check
  check (role in ('author', 'assignee', 'reviewer', 'reporter', 'involved', 'watcher'));
