-- Why a push failed (APNs status + reason, or a provider-token error), so failures are diagnosable.
alter table public.push_queue add column last_error text;
