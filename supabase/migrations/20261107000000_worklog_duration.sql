-- Jira work logs: one journal line per log (its comment, else the ticket) with the time spent.
alter table public.external_items add column if not exists duration_seconds integer;

-- The old lines were one per ticket per day ("worklog:KEY:2026-11-03"); the new ones are
-- "worklog:<id>". Drop the old ones so today's logs are not listed twice.
delete from public.external_items
where source = 'jira' and kind = 'worklog' and external_id ~ '^worklog:[^:]+:\d{4}-\d{2}-\d{2}$';
