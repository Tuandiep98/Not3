-- Feelings the user names in check-in ("Tập trung", "Mệt"…). `mood` stays the level
-- (good / ok / empty) the weekly summary counts; `mood_label` is what the user picked.
alter table public.checkins add column if not exists mood_label text;
