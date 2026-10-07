-- Per-Action user-authored Markdown notes. They are stored separately from Claims/Evidence:
-- notes are execution context, not a source-backed change to the Action's judged fields.
begin;
set local lock_timeout = '5s';

alter table public.actions
  add column notes_markdown text not null default '',
  add column notes_revision integer not null default 0,
  add constraint actions_notes_markdown_length check (char_length(notes_markdown) <= 10000),
  add constraint actions_notes_revision_nonnegative check (notes_revision >= 0);

alter table public.action_events
  drop constraint action_events_type_check,
  add constraint action_events_type_check check (type in (
    'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
    'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created',
    'user_unstarted', 'artifact_created', 'user_seen', 'user_notes_updated'
  ));

-- Notes writes must not make a completed Action appear recently changed to Ask's closed-Action window.
create or replace function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_schema = 'public'
    and tg_table_name = 'actions'
    and tg_op = 'UPDATE'
    and (
      to_jsonb(new)->'notes_markdown' is distinct from to_jsonb(old)->'notes_markdown'
      or to_jsonb(new)->'notes_revision' is distinct from to_jsonb(old)->'notes_revision'
    )
    and (to_jsonb(new) - array['notes_markdown', 'notes_revision', 'updated_at']::text[])
      is not distinct from (to_jsonb(old) - array['notes_markdown', 'notes_revision', 'updated_at']::text[]) then
    new.updated_at = old.updated_at;
  else
    new.updated_at = now();
  end if;
  return new;
end;
$$;

-- Compare-and-set notes save, metadata-only event, and note update commit together. `user_id` is
-- always checked even though the function is service-role-only; a missing/hidden Action is 404.
create function public.save_action_notes(
  p_user_id uuid,
  p_action_id uuid,
  p_markdown text,
  p_expected_revision integer
) returns table (status text, action_id uuid, markdown text, revision integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_markdown text;
  current_revision integer;
begin
  if p_user_id is null or p_action_id is null or p_markdown is null
    or p_expected_revision is null or p_expected_revision < 0
    or char_length(p_markdown) > 10000 then
    raise exception 'invalid action notes input' using errcode = '22023';
  end if;

  select a.notes_markdown, a.notes_revision
    into current_markdown, current_revision
    from public.actions as a
    where a.id = p_action_id and a.user_id = p_user_id
    for update;

  if not found then
    return query select 'not_found'::text, null::uuid, null::text, null::integer;
    return;
  end if;

  if current_revision <> p_expected_revision then
    return query select 'conflict'::text, p_action_id, null::text, current_revision;
    return;
  end if;

  if current_markdown = p_markdown then
    return query select 'saved'::text, p_action_id, current_markdown, current_revision;
    return;
  end if;

  update public.actions as a
    set notes_markdown = p_markdown, notes_revision = current_revision + 1
    where a.id = p_action_id and a.user_id = p_user_id;

  insert into public.action_events (user_id, action_id, type, before, after, actor, rule)
    values (
      p_user_id,
      p_action_id,
      'user_notes_updated',
      jsonb_build_object('revision', current_revision),
      jsonb_build_object('revision', current_revision + 1),
      'user',
      'user'
    );

  return query select 'saved'::text, p_action_id, p_markdown, current_revision + 1;
end;
$$;

revoke execute on function public.save_action_notes(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.save_action_notes(uuid, uuid, text, integer) to service_role;

commit;
