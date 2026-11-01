-- "Mới đồng bộ" → automatic classification (README §12, "Luật phân loại mặc định").

-- The user's role in the item (decides task vs. not) and its scope (repo / Jira project).
alter table public.external_items
  add column role text check (role in ('author', 'assignee', 'reviewer', 'reporter', 'involved')),
  add column scope text;

-- 'journal' = finished work recorded in "Nhật ký", no task needed.
alter table public.external_items drop constraint external_items_decision_check;
alter table public.external_items add constraint external_items_decision_check
  check (decision in ('task', 'note', 'ignored', 'journal'));

-- Ignore rules can be narrowed to one repo / project ('' = the whole kind).
alter table public.content_rules add column scope text not null default '';
alter table public.content_rules drop constraint content_rules_user_id_provider_kind_key;
alter table public.content_rules add constraint content_rules_user_scope_key unique (user_id, provider, kind, scope);
