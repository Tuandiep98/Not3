-- Re-create the cron job and note webhook so they send the Vault key on `apikey` too.
-- New `sb_secret_…` keys are not JWTs and are read from `apikey`; a legacy service_role JWT
-- still works through `Authorization`. Earlier projects ran the init migration before this change.
-- Both read Vault at run time: 'project_url' and 'service_role_key' must exist (CAN_BO_SUNG.md B3).

-- cron.schedule with an existing job name replaces that job.
select cron.schedule('tick', '*/5 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/tick',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb
  )
  where exists (select 1 from vault.decrypted_secrets where name = 'project_url')
    and exists (select 1 from vault.decrypted_secrets where name = 'service_role_key');
$$);

create or replace function public.notify_tag_note() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  base_url text := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url');
  secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key');
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
  -- Vault not configured yet: skip instead of failing the user's note save.
  if base_url is null or secret is null then
    return new;
  end if;
  perform net.http_post(
    url := base_url || '/functions/v1/tag-note',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', secret,
      'Authorization', 'Bearer ' || secret
    ),
    body := jsonb_build_object('note_id', new.id)
  );
  return new;
end $$;
