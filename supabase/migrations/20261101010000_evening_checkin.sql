-- Evening "Đã làm chưa?" push + cancel stale reminders when a task moves or finishes.

alter table public.profiles add column evening_checkin boolean not null default true;

alter table public.push_queue drop constraint push_queue_status_check;
alter table public.push_queue add constraint push_queue_status_check
  check (status in ('pending', 'sent', 'failed', 'cancelled'));
create index on public.push_queue ((payload->>'task_id')) where status = 'pending';

create or replace function public.queue_task_reminder() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  tz text;
  evening_on boolean;
  evening_at timestamptz;
begin
  -- Task moved, finished or cancelled → drop its pending pushes.
  if tg_op = 'UPDATE'
     and (new.status <> 'todo' or new.planned_at is distinct from old.planned_at) then
    update push_queue set status = 'cancelled'
    where status = 'pending' and payload->>'task_id' = new.id::text;
  end if;

  if new.planned_at is null or new.status <> 'todo' then
    return new;
  end if;

  -- Reminder at the planned time.
  if new.planned_at > now() then
    insert into push_queue (user_id, send_at, kind, payload, dedupe_key)
    values (new.user_id, new.planned_at, 'reminder',
            jsonb_build_object('title', 'Đến giờ rồi', 'body', coalesce(new.if_then_sentence, new.title),
                               'task_id', new.id),
            'reminder:' || new.id || ':' || extract(epoch from new.planned_at)::bigint)
    on conflict (dedupe_key) do update set status = 'pending'
      where push_queue.status = 'cancelled';
  end if;

  -- Evening check: 21:00 local on the planned day, or 15 min after the task ends if later.
  select coalesce(p.timezone, 'Asia/Ho_Chi_Minh'), coalesce(p.evening_checkin, true)
    into tz, evening_on
  from profiles p where p.user_id = new.user_id;
  tz := coalesce(tz, 'Asia/Ho_Chi_Minh');
  if coalesce(evening_on, true) then
    evening_at := greatest(
      (((new.planned_at at time zone tz)::date + time '21:00') at time zone tz),
      new.planned_at + make_interval(mins => coalesce(new.duration_minutes, 0) + 15)
    );
    if evening_at > now() then
      insert into push_queue (user_id, send_at, kind, payload, dedupe_key)
      values (new.user_id, evening_at, 'evening',
              jsonb_build_object('title', 'Đã làm chưa?', 'body', new.title, 'task_id', new.id),
              'evening:' || new.id || ':' || extract(epoch from evening_at)::bigint)
      on conflict (dedupe_key) do update set status = 'pending'
        where push_queue.status = 'cancelled';
    end if;
  end if;
  return new;
end $$;
