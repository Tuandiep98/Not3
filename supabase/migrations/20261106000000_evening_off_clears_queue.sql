-- "Khép lại hôm nay" replaces the per-task "Xong chưa?" push: the app then sends
-- profiles.evening_checkin = false. New tasks already skip the evening push (task trigger reads
-- the flag); this drops the ones queued before the switch so the user gets a single evening
-- notification from tonight on.

create or replace function public.drop_pending_evening_pushes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(old.evening_checkin, true) and not coalesce(new.evening_checkin, true) then
    delete from public.push_queue
    where user_id = new.user_id and kind = 'evening' and status = 'pending';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_evening_off on public.profiles;
create trigger profiles_evening_off
  after update of evening_checkin on public.profiles
  for each row execute function public.drop_pending_evening_pushes();
