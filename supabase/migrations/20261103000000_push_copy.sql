-- Clearer reminder / evening pushes (same wording as _shared/notify.ts and NotificationService.swift):
--   reminder: "Bắt đầu: <task>"  ·  "<if-then sentence or 'Đến giờ bạn đã hẹn lúc 15:00'> · 25 phút"
--   evening:  "Xong chưa: <task>" ·  "Nhấn giữ để chọn Xong hoặc Dời sang mai."
-- Payload carries `link` (tap opens the task in Hôm nay). Level / sound / buttons are set by send-push.

create or replace function public.push_title(prefix text, task_title text) returns text
language sql immutable as $$
  select case when char_length(prefix || task_title) <= 64 then prefix || task_title
              else rtrim(left(prefix || task_title, 63)) || '…' end;
$$;

create or replace function public.queue_task_reminder() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  tz text;
  evening_on boolean;
  evening_at timestamptz;
  body text;
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

  select coalesce(p.timezone, 'Asia/Ho_Chi_Minh'), coalesce(p.evening_checkin, true)
    into tz, evening_on
  from profiles p where p.user_id = new.user_id;
  tz := coalesce(tz, 'Asia/Ho_Chi_Minh');

  -- Reminder at the planned time.
  if new.planned_at > now() then
    body := coalesce(nullif(trim(new.if_then_sentence), ''),
                     'Đến giờ bạn đã hẹn lúc ' || to_char(new.planned_at at time zone tz, 'HH24:MI'))
            || case when new.duration_minutes > 0 then ' · ' || new.duration_minutes || ' phút' else '' end;
    insert into push_queue (user_id, send_at, kind, payload, dedupe_key)
    values (new.user_id, new.planned_at, 'reminder',
            jsonb_build_object('title', push_title('Bắt đầu: ', new.title), 'body', body,
                               'task_id', new.id, 'link', 'not3://task/' || new.id),
            'reminder:' || new.id || ':' || extract(epoch from new.planned_at)::bigint)
    on conflict (dedupe_key) do update set status = 'pending', payload = excluded.payload
      where push_queue.status = 'cancelled';
  end if;

  -- Evening check: 21:00 local on the planned day, or 15 min after the task ends if later.
  if coalesce(evening_on, true) then
    evening_at := greatest(
      (((new.planned_at at time zone tz)::date + time '21:00') at time zone tz),
      new.planned_at + make_interval(mins => coalesce(new.duration_minutes, 0) + 15)
    );
    if evening_at > now() then
      insert into push_queue (user_id, send_at, kind, payload, dedupe_key)
      values (new.user_id, evening_at, 'evening',
              jsonb_build_object('title', push_title('Xong chưa: ', new.title),
                                 'body', 'Nhấn giữ để chọn Xong hoặc Dời sang mai.',
                                 'task_id', new.id, 'link', 'not3://task/' || new.id),
              'evening:' || new.id || ':' || extract(epoch from evening_at)::bigint)
      on conflict (dedupe_key) do update set status = 'pending', payload = excluded.payload
        where push_queue.status = 'cancelled';
    end if;
  end if;
  return new;
end $$;
