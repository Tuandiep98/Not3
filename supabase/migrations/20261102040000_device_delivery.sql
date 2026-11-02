-- Per-device delivery state, written by send-push. The app keeps its on-device fallback
-- notifications until the server has actually delivered to this device (last_sent_at).
alter table public.devices add column last_sent_at timestamptz;
alter table public.devices add column last_error text;
