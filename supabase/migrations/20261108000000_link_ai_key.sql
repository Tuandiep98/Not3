-- Fingerprint of the tasks + items last sent to AI for link matching (links.ts). The same input
-- is not sent again, so pull to refresh no longer waits for an AI call on every sync.
alter table public.profiles add column if not exists link_ai_key text;
