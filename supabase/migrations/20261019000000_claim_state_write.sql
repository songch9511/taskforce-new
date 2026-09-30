-- Claim.state는 최초 스키마에 있으나 write_action은 기본값(active)에만 의존했다.
-- 확인이 필요한 Claim 상태(disputed)를 RPC 쓰기/읽기 경로에서도 보존한다.
create or replace function public.write_action(
  p_user_id uuid,
  p_action_id uuid,
  p_expected_version integer,
  p_action jsonb,
  p_claims jsonb default '[]',
  p_evidence jsonb default '[]',
  p_events jsonb default '[]'
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  current_version integer;
begin
  if p_expected_version is null then
    insert into public.actions (id, user_id, title, counterpart, owner, due_date, due_at, status, needs_confirmation,
                                confirm_reasons, resolution, embedding)
    values (
      p_action_id, p_user_id, p_action->>'title', p_action->>'counterpart', p_action->>'owner',
      (p_action->>'due_date')::date, (p_action->>'due_at')::timestamptz, p_action->>'status',
      (p_action->>'needs_confirmation')::boolean,
      array(select jsonb_array_elements_text(coalesce(p_action->'confirm_reasons', '[]'))),
      p_action->'resolution', (p_action->>'embedding')::extensions.vector
    );
  else
    select version into current_version from public.actions
      where id = p_action_id and user_id = p_user_id for update;
    if current_version is null then
      raise exception 'action not found' using errcode = 'P0002';
    end if;
    if current_version <> p_expected_version then
      return false;
    end if;
    update public.actions set
      title = p_action->>'title',
      owner = p_action->>'owner',
      due_date = (p_action->>'due_date')::date,
      due_at = (p_action->>'due_at')::timestamptz,
      status = p_action->>'status',
      needs_confirmation = (p_action->>'needs_confirmation')::boolean,
      confirm_reasons = array(select jsonb_array_elements_text(coalesce(p_action->'confirm_reasons', '[]'))),
      resolution = p_action->'resolution',
      last_activity_at = now(),
      version = version + 1
    where id = p_action_id and user_id = p_user_id;
  end if;

  insert into public.claims (id, user_id, action_id, source_id, field, value, quote, occurred_at,
                             speaker_role, certainty, directness, audience, origin, channel, state)
  select (c->>'id')::uuid, p_user_id, p_action_id, (c->>'source_id')::uuid, c->>'field', c->>'value', c->>'quote',
         (c->>'occurred_at')::timestamptz, c->>'speaker_role', c->>'certainty', c->>'directness', c->>'audience',
         coalesce(c->>'origin', 'source'), c->>'channel', coalesce(c->>'state', 'active')
  from jsonb_array_elements(p_claims) c;

  insert into public.evidence (user_id, action_id, source_id, quote, role)
  select p_user_id, p_action_id, (e->>'source_id')::uuid, e->>'quote', e->>'role'
  from jsonb_array_elements(p_evidence) e;

  insert into public.action_events (user_id, action_id, type, before, after, source_id, actor, rule)
  select p_user_id, p_action_id, v->>'type', v->'before', v->'after', (v->>'source_id')::uuid, v->>'actor', v->>'rule'
  from jsonb_array_elements(p_events) v;

  return true;
end;
$$;

revoke execute on function public.write_action from public, anon, authenticated;
grant execute on function public.write_action to service_role;
