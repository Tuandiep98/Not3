-- Phase 3: GitHub / Jira integrations (README §11). Tokens live in Vault, never in tables or the app.

-- OAuth state (CSRF protection), service-role only.
create table public.oauth_states (
  state text primary key,
  user_id uuid not null references auth.users on delete cascade,
  provider text not null check (provider in ('github', 'jira')),
  created_at timestamptz not null default now()
);
alter table public.oauth_states enable row level security;

alter table public.integrations
  add column meta jsonb not null default '{}',
  add column last_error text,
  add column connected_at timestamptz not null default now();

-- external_items carries the item's state so the app can show "Đã merge", "Done"...
alter table public.external_items
  add column kind text,
  add column status text,
  add column updated_at timestamptz not null default now();

-- Stores (or rotates) a user's token JSON in Vault and upserts the integrations row.
create or replace function public.save_integration(
  p_user uuid, p_provider text, p_account text, p_scopes text[], p_token jsonb, p_meta jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select vault_secret_id into sid from integrations where user_id = p_user and provider = p_provider;
  if sid is null then
    sid := vault.create_secret(p_token::text, 'integration:' || p_user || ':' || p_provider);
  else
    perform vault.update_secret(sid, p_token::text);
  end if;
  insert into integrations (user_id, provider, account_name, scopes, vault_secret_id, meta, last_error, connected_at)
  values (p_user, p_provider, p_account, p_scopes, sid, coalesce(p_meta, '{}'), null, now())
  on conflict (user_id, provider) do update set
    account_name = excluded.account_name, scopes = excluded.scopes,
    vault_secret_id = excluded.vault_secret_id, meta = excluded.meta, last_error = null;
end $$;

create or replace function public.read_integration_token(p_user uuid, p_provider text)
returns jsonb language sql stable security definer set search_path = public as $$
  select s.decrypted_secret::jsonb
  from integrations i join vault.decrypted_secrets s on s.id = i.vault_secret_id
  where i.user_id = p_user and i.provider = p_provider;
$$;

revoke execute on function public.save_integration(uuid, text, text, text[], jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.read_integration_token(uuid, text) from public, anon, authenticated;

-- Called by the app: disconnect one source and delete its data (Settings → Dữ liệu đã kết nối).
create or replace function public.disconnect_integration(p_provider text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select vault_secret_id into sid from integrations where user_id = auth.uid() and provider = p_provider;
  if sid is not null then
    delete from vault.secrets where id = sid;
  end if;
  delete from integrations where user_id = auth.uid() and provider = p_provider;
  delete from external_items where user_id = auth.uid() and source = p_provider;
end $$;
revoke execute on function public.disconnect_integration(text) from public, anon;
grant execute on function public.disconnect_integration(text) to authenticated;

-- Deleting the account also removes integration secrets (auth.users cascade does not reach Vault).
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from vault.secrets where id in (select vault_secret_id from integrations where user_id = auth.uid());
  delete from auth.users where id = auth.uid();
end $$;

-- The app reads integrations (without secrets) to show connection state.
revoke select on public.integrations from anon;
