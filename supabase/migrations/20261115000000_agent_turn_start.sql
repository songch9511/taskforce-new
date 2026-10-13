-- OA D1c-1: 대화 턴을 prepared까지 저장한다. bridge 호출 · task goal 확장 없음.
-- create_run · begin_call · sweep_expire는 그대로다.
begin;
set local lock_timeout = '5s';
-- 진행 중 metric insert와 교착하지 않고 마이그레이션만 재시도한다 (D1b 잠금 검토).
lock table public.metric_events in access exclusive mode nowait;

-- OA 공통 블록: metric_events 확장 (Assistant 계약 v3 8장). 코디네이터 Opus 소유, 2026-10-13.
-- 이 블록은 metric_events에 처음 쓰는 OA WP들이 **글자 그대로** 자기 마이그레이션에 넣는다(지금: D1c-1 · D4c-1s).
-- 레인이 달라 어느 쪽이 먼저 적용돼도 결과가 같게 만든다: 열은 if not exists, CHECK · 정책은 계약 8장 전체 목록으로 통째로 교체.
-- 목록을 바꿔야 하면 작업자는 멈추고 코디네이터가 이 파일을 고쳐 두 WP에 같이 반영한다.
-- 기준: main의 마지막 정의 20261020000000_source_failure_visibility.sql:26 (app_opened · action_started · handoff_used ·
-- connection_created · connection_reauth · reconnect_notified · source_failed), 앱 insert 정책 20261001000000_metric_events_client_app_opened.sql.

alter table public.metric_events
  add column if not exists props jsonb not null default '{}'::jsonb;

alter table public.metric_events drop constraint if exists metric_events_props_shape;
alter table public.metric_events add constraint metric_events_props_shape
  check (jsonb_typeof(props) = 'object');

alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved'
  ));

drop policy if exists "owner_insert_app_opened" on public.metric_events;
drop policy if exists "owner_insert_client_app_types" on public.metric_events;
create policy "owner_insert_client_app_types" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type in ('app_opened', 'assistant_opened'));

insert into public.execution_tools (provider, tool, effect_class) values
  ('agent:claude-code', 'message', 'external'), ('agent:codex', 'message', 'external');
insert into public.execution_controls (scope, key, blocked) values
  ('provider', 'agent:claude-code', true), ('provider', 'agent:codex', true);

-- task의 종류는 그대로, conversation에는 agent_message만 허용한다.
create or replace function public.append_step(p_run_id uuid, p_seq integer, p_step jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_user uuid;
  v_state text;
  v_step uuid;
begin
  select user_id, state into v_user, v_state from public.execution_runs where id = p_run_id for no key update;
  if v_state is null or v_state not in ('queued', 'running') then
    return null;
  end if;
  if p_seq <> (select coalesce(max(seq), 0) + 1 from public.execution_steps where run_id = p_run_id) then
    return null;
  end if;
  if p_step->>'kind' is null or not exists (
    select 1 from public.execution_runs where id = p_run_id
      and ((kind = 'conversation' and p_step->>'kind' = 'agent_message')
        or (kind = 'task' and p_step->>'kind' in ('plan', 'draft', 'external')))
  ) then
    raise exception 'append_step: 단계 종류 % 는 아직 붙이지 않는다 (plan · draft · external만)', p_step->>'kind' using errcode = '22023';
  end if;
  perform set_config('execution.gate', 'append', true);
  insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose,
                                      connection_id, recipients, body, args, source_revision, estimate_credits)
  values (
    v_user, p_run_id, p_seq, p_step->>'kind', p_step->>'provider', p_step->>'tool',
    coalesce((select t.effect_class from public.execution_tools t where t.provider = p_step->>'provider' and t.tool = p_step->>'tool'), 'external'),
    p_step->>'purpose', (p_step->>'connection_id')::uuid,
    coalesce(p_step->'recipients', '[]'), coalesce(p_step->>'body', ''), coalesce(p_step->'args', '{}'),
    coalesce((p_step->>'source_revision')::integer, 1), coalesce((p_step->>'estimate_credits')::integer, 0)
  )
  returning id into v_step;
  return v_step;
end;
$$;

-- 직접 보낸 에이전트 메시지의 전달은 사용자 결정이다. task 외부 승인은 유지한다.
create or replace function public.prepare_step(p_step uuid, p_version integer) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('execution.gate', 'prepare', true);
  update public.execution_steps s set
    state = 'prepared',
    version = s.version + 1,
    policy_version = p.version,
    intent_key = case
      when s.effect_class = 'internal' then concat_ws('|', 'internal', s.id)
      else concat_ws('|', r.action_id, s.provider, s.tool, s.purpose, public.norm_addresses(s.recipients)::text, s.occurrence)
    end
  from public.execution_runs r
  join public.execution_policies p on p.id = r.policy_id
  where s.id = p_step and s.state = 'pending' and s.version = p_version and r.id = s.run_id;
  if not found then
    return false;
  end if;
  update public.execution_steps
    set needs_approval = (effect_class = 'external' and not (kind = 'agent_message' and exists (
      select 1 from public.execution_runs r where r.id = run_id and r.kind = 'conversation'))
      and public.auto_allowed(id) is not true)
    where id = p_step;
  update public.execution_runs set state = 'running'
    where id = (select run_id from public.execution_steps where id = p_step) and state = 'queued';
  return true;
end;
$$;

-- create_run과 같은 정책 생성 · 예산 · queued 초기값 · create 이벤트를 쓴다.
-- 차이: goal=agent, kind=conversation, session/conversation 지정, request 빈 문자열, plan 없음. actor는 create_run처럼 begin_call에서 검사한다.
create function public.open_agent_conversation_run(
  p_user_id uuid, p_session_id uuid, p_action_id uuid, p_conversation_id uuid default null, p_budget_credits integer default null
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_policy uuid;
  v_run uuid;
begin
  perform 1 from public.agent_sessions where id = p_session_id and user_id = p_user_id;
  if not found then
    raise exception 'agent session not found' using errcode = 'P0002';
  end if;
  perform 1 from public.actions where id = p_action_id and user_id = p_user_id and status = 'open';
  if not found then
    raise exception 'open action not found' using errcode = 'P0002';
  end if;
  if p_conversation_id is not null and not exists (
    select 1 from public.conversations where id = p_conversation_id and user_id = p_user_id
      and target_kind = 'agent' and agent_session_id = p_session_id
  ) then raise exception 'agent conversation not found' using errcode = 'P0002'; end if;
  select id into v_run from public.execution_runs
   where user_id = p_user_id and agent_session_id = p_session_id and action_id = p_action_id
     and kind = 'conversation' and state not in ('done', 'failed', 'stopped');
  if found then return v_run; end if;
  perform set_config('execution.gate', 'create', true);
  insert into public.execution_policies (user_id) values (p_user_id) on conflict (user_id) do nothing;
  select id into v_policy from public.execution_policies where user_id = p_user_id;
  insert into public.execution_runs (user_id, action_id, policy_id, goal, request, budget_credits, kind, agent_session_id, conversation_id)
    values (p_user_id, p_action_id, v_policy, 'agent', '', p_budget_credits, 'conversation', p_session_id, p_conversation_id)
    on conflict (agent_session_id, action_id) where kind = 'conversation' and state not in ('done', 'failed', 'stopped') do nothing
    returning id into v_run;
  if v_run is null then
    select id into v_run from public.execution_runs
     where user_id = p_user_id and agent_session_id = p_session_id and action_id = p_action_id
       and kind = 'conversation' and state not in ('done', 'failed', 'stopped');
  end if;
  return v_run;
end;
$$;

-- 턴 접수/실패는 대화 run의 종료가 아니다. task 분기는 그대로다.
create or replace function public.finish_run(p_run_id uuid, p_outcome text default null) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(current_setting('execution.gate', true), '') = '' then
    perform set_config('execution.gate', 'finish', true);
  end if;
  -- run을 먼저 잠근다: 같은 run에 단계를 붙이는 append_step(run 잠금)이 commit된 뒤의 단계를 센다
  perform 1 from public.execution_runs where id = p_run_id for no key update;
  update public.execution_runs r set state = 'done', outcome = coalesce(p_outcome, r.outcome)
  where r.id = p_run_id and r.state = 'running' and r.kind = 'task'
    and not exists (select 1 from public.execution_steps s where s.run_id = p_run_id and s.state not in ('called', 'skipped'));
  return found;
end;
$$;

create or replace function public.settle_step(p_step uuid, p_owner text, p_state text, p_receipt jsonb, p_outcome text default null)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_run uuid;
  v_kind text;
begin
  if p_state not in ('called', 'failed') then
    raise exception 'settle_step: 잘못된 상태 %', p_state;
  end if;
  perform set_config('execution.gate', 'response', true);
  update public.execution_steps set state = p_state, receipt = p_receipt, version = version + 1, lease_owner = null, lease_expires_at = null
    where id = p_step and state = 'calling' and lease_owner = p_owner
    returning run_id, kind into v_run, v_kind;
  if v_run is null then
    return false;
  end if;
  if p_state = 'failed' then
    update public.execution_runs set state = 'failed' where id = v_run and state = 'running' and kind = 'task';
  elsif p_outcome is not null or v_kind <> 'plan' then
    perform public.finish_run(v_run, p_outcome);
  end if;
  return true;
end;
$$;

create function public.start_agent_turn(
  p_user_id uuid, p_message_id uuid, p_action_ids uuid[], p_context_ids uuid[], p_access text, p_live_limit integer
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages;
  v_conversation public.conversations;
  v_connection public.agent_connections;
  v_session public.agent_sessions;
  v_action uuid;
  v_note uuid;
  v_run uuid;
  v_task uuid;
  v_step uuid;
  v_seq integer;
  v_retry integer := 0;
  v_previous public.execution_steps;
  v_title text;
  v_claims jsonb;
  v_resolution jsonb;
  v_created boolean := false;
  v_candidates jsonb;
  v_context_version integer;
  v_membership record;
  v_reason text;
begin
  -- 1) 소유자 · 대상 · 전달 전 상태 · TTL. 거절된 메시지는 고치지 않는다.
  select * into v_message from public.conversation_messages
   where id = p_message_id and user_id = p_user_id and role = 'user' for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  select * into v_conversation from public.conversations
   where id = v_message.conversation_id and user_id = p_user_id;
  if v_conversation.target_kind is distinct from 'agent' then return jsonb_build_object('status', 'wrong_target'); end if;
  if v_message.delivery_state not in ('queued', 'not_sent') then return jsonb_build_object('status', 'already_dispatched'); end if;
  if v_message.delivery_expires_at is null or v_message.delivery_expires_at <= public.db_now() then
    return jsonb_build_object('status', 'expired');
  end if;
  if p_access is null or p_access not in ('write', 'read_only') then
    raise exception 'start_agent_turn: invalid access' using errcode = '22023';
  end if;
  if p_live_limit is null or p_live_limit < 1 then
    raise exception 'start_agent_turn: invalid live limit' using errcode = '22023';
  end if;
  select coalesce(array_agg(id order by ordinal), '{}'::uuid[]) into p_action_ids from (
    select id, min(n) as ordinal from unnest(p_action_ids) with ordinality a(id,n) group by id
  ) ids;
  select coalesce(array_agg(id order by ordinal), '{}'::uuid[]) into p_context_ids from (
    select id, min(n) as ordinal from unnest(p_context_ids) with ordinality c(id,n) group by id
  ) ids;
  -- 호출자가 정규화했어도 소유권은 DB에서 다시 본다. 없는/보관한 context는 Ungrouped, 남의 칩은 거절한다.
  if exists (select 1 from unnest(p_action_ids) a(id) where not exists (
       select 1 from public.actions x where x.id = a.id and x.user_id = p_user_id))
     or exists (select 1 from public.work_contexts c where c.id = any(p_context_ids) and c.user_id <> p_user_id) then
    return jsonb_build_object('status', 'not_found');
  end if;
  select * into v_connection from public.agent_connections
   where id = v_conversation.agent_connection_id and user_id = p_user_id;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if v_connection.status <> 'active' then
    return public.mark_agent_message_not_sent(p_user_id, p_message_id, 'not_connected');
  end if;
  if v_conversation.agent_session_id is not null and not exists (
    select 1 from public.agent_sessions s where s.id = v_conversation.agent_session_id
      and s.user_id = p_user_id and s.connection_id = v_connection.id
  ) then return jsonb_build_object('status', 'not_found'); end if;

  -- 서로 다른 세션도 사용자 외부 작업 한도를 함께 센다. 메시지 → 사용자 → 대화 → 세션 순서.
  perform pg_advisory_xact_lock(hashtextextended('agent_turn:' || p_user_id::text, 0));
  select left(btrim(regexp_replace(line, '[[:space:]]+', ' ', 'g')), 80) into v_title
    from regexp_split_to_table(v_message.text, E'\n') with ordinality lines(line,n)
    where line ~ '[^[:space:]]' order by n limit 1;
  v_title := coalesce(v_title, 'Untitled');
  -- 2–4) 지시 대상이 모호하면 세션 생성/바인딩까지 롤백하고 후보만 남긴다.
  begin
    select * into v_conversation from public.conversations
     where id = v_message.conversation_id and user_id = p_user_id for no key update;
    if v_conversation.agent_session_id is null then
      insert into public.agent_sessions (user_id, connection_id, external_session_id, workspace_ref, status, display_name)
        values (p_user_id, v_connection.id, 'pending:' || v_conversation.id, 'pending:' || v_conversation.id, 'bound', v_title)
        on conflict (connection_id, external_session_id) do nothing;
      select * into v_session from public.agent_sessions
       where connection_id = v_connection.id and external_session_id = 'pending:' || v_conversation.id and user_id = p_user_id;
      update public.conversations set agent_session_id = v_session.id
       where id = v_conversation.id and agent_session_id is null;
    else
      select * into v_session from public.agent_sessions where id = v_conversation.agent_session_id;
    end if;
    -- 3) 세션당 턴 하나. 대화가 둘이어도 같은 잠금 뒤에서 직전 턴/진행 중 턴을 읽는다.
    select * into v_session from public.agent_sessions
     where id = v_session.id and user_id = p_user_id and connection_id = v_connection.id for update;
    if not found then raise exception 'start_agent_turn: session mismatch' using errcode = 'P0002'; end if;

    -- 보류에는 메시지 상태/칩과 필요한 pending 세션만 남긴다.
    update public.conversation_messages set refs = refs || jsonb_build_object('agent_turn', jsonb_build_object(
      'action_ids', p_action_ids, 'context_ids', p_context_ids)) where id = p_message_id;
    if v_session.status = 'closed' then
      update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'session_closed' where id = p_message_id;
      return jsonb_build_object('status', 'not_sent', 'reason', 'session_closed');
    elsif v_session.status = 'external' then v_reason := 'session_external';
    elsif v_session.status = 'unreachable' or exists (
      select 1 from public.agent_tasks where agent_session_id = v_session.id
        and state in ('dispatched', 'accepted', 'running', 'awaiting_answer', 'unreachable')
    ) then v_reason := 'session_busy';
    elsif (select count(*) from public.agent_tasks where user_id = p_user_id
             and state in ('dispatched', 'accepted', 'running', 'unreachable')) >= p_live_limit then
      v_reason := 'live_limit';
    elsif exists (
      with pending as (
        select m.id,m.conversation_id,m.seq,m.created_at from public.conversation_messages m
        join public.conversations c on c.id = m.conversation_id and c.user_id = m.user_id
        where c.agent_session_id = v_session.id and c.user_id = p_user_id and c.target_kind = 'agent'
          and m.role = 'user' and m.delivery_state in ('queued', 'not_sent') and m.delivery_expires_at > public.db_now()
          and not (m.refs ? 'referent_candidates' and m.refs->>'referent_action_id' is null)
          and coalesce(m.delivery_reason, '') not in ('invalid_referent', 'session_closed', 'not_found', 'already_dispatched')
      ), heads as (
        select distinct on (conversation_id) * from pending order by conversation_id,seq
      )
      select 1 from heads m
       where (m.conversation_id = v_message.conversation_id and m.seq < v_message.seq)
          or (m.conversation_id <> v_message.conversation_id
              and (m.created_at, m.seq, m.id) < (v_message.created_at, v_message.seq, v_message.id))
    ) then v_reason := 'queue_order';
    end if;
    if v_reason is not null then
      update public.conversation_messages set delivery_state = 'queued', delivery_reason = v_reason where id = p_message_id;
      return jsonb_build_object('status', 'queued', 'reason', v_reason);
    end if;

    -- unknown/접수됨/아직 준비 중인 전달은 새 Action이나 회차를 만들지 않는다.
    select s.* into v_previous from public.agent_tasks t join public.execution_steps s on s.id = t.step_id
     where t.message_id = p_message_id and t.user_id = p_user_id order by t.turn_seq desc limit 1;
    if found then
      if v_previous.state <> 'failed' then return jsonb_build_object('status', 'already_dispatched'); end if;
      select count(*)::integer into v_retry from public.agent_tasks t join public.execution_steps s on s.id = t.step_id
       where t.message_id = p_message_id and t.user_id = p_user_id and s.state = 'failed';
    end if;

    -- 4) 확정 referent → added Action → 직전 턴 Action → 첫 턴 직접 추가.
    if v_message.refs->>'referent_action_id' is not null then
      v_action := (v_message.refs->>'referent_action_id')::uuid;
      if not coalesce(v_message.refs->'referent_candidates' @> jsonb_build_array(v_action), false) then
        raise exception 'start_agent_turn: invalid referent' using errcode = 'TF404';
      end if;
    elsif cardinality(p_action_ids) > 1 then
      v_candidates := to_jsonb(p_action_ids[1:3]);
      raise exception 'needs_referent' using errcode = 'TF004';
    elsif cardinality(p_action_ids) = 1 then
      v_action := p_action_ids[1];
    else
      select r.action_id into v_action from public.agent_tasks t
      join public.execution_runs r on r.id = t.run_id and r.user_id = t.user_id
       where t.agent_session_id = v_session.id and t.user_id = p_user_id and t.turn_seq is not null
       order by t.turn_seq desc limit 1;
      if v_action is not null then
        perform 1 from public.actions where id = v_action and user_id = p_user_id and status = 'open' for share;
        if not found then v_action := null; end if;
      end if;
    end if;
    if v_action is not null then
      perform 1 from public.actions where id = v_action and user_id = p_user_id and status = 'open' for share;
      if not found then raise exception 'open action not found' using errcode = 'TF404'; end if;
    else
      v_action := substr(encode(sha256(convert_to('tf:assistant_agent:action:' || p_message_id, 'UTF8')), 'hex'), 1, 32)::uuid;
      v_note := substr(encode(sha256(convert_to('tf:assistant_agent:note:' || p_message_id, 'UTF8')), 'hex'), 1, 32)::uuid;
      if exists (select 1 from public.actions where id = v_action) then
        perform 1 from public.actions where id = v_action and user_id = p_user_id and status = 'open' for share;
        if not found then raise exception 'open action not found' using errcode = 'TF404'; end if;
      else
        insert into public.sources (id, user_id, kind, title, raw_text, occurred_at, external_url, processing_status, processed_at)
          values (v_note, p_user_id, 'note', 'Taskforce 대화', v_message.text, public.db_now(),
                  'taskforce://conversations/' || v_conversation.id || '#' || p_message_id, 'done', public.db_now());
        -- userCreatedAction/adoptPlan의 세 user Claim과 같은 투영(기한 없음). 원문은 note/Evidence에 보존한다.
        select jsonb_agg(jsonb_build_object(
          'id', gen_random_uuid(), 'source_id', v_note, 'field', x.field, 'value', x.value, 'quote', v_message.text,
          'occurred_at', public.db_now(), 'speaker_role', 'me', 'certainty', 'firm', 'directness', 'first_hand',
          'audience', 'shared', 'origin', 'user', 'channel', 'note', 'state', 'active'))
        into v_claims from (values ('scope', v_title), ('owner', 'me'), ('status', 'open')) x(field, value);
        select jsonb_object_agg(x.field, jsonb_build_object('value', x.value,
          'reason', case when x.field = 'due' then '근거 없음' else '사용자가 직접 정함' end,
          'rules', '[]'::jsonb, 'pending', '[]'::jsonb, 'risks', '[]'::jsonb, 'needsConfirmation', false))
        into v_resolution from (values ('scope', v_title), ('owner', 'me'), ('status', 'open'), ('due', null)) x(field, value);
        perform public.write_action(p_user_id, v_action, null,
          jsonb_build_object('title', v_title, 'owner', 'me', 'status', 'open', 'needs_confirmation', false,
                             'confirm_reasons', '[]'::jsonb, 'resolution', v_resolution),
          v_claims, jsonb_build_array(jsonb_build_object('source_id', v_note, 'quote', v_message.text, 'role', 'created')),
          jsonb_build_array(jsonb_build_object('type', 'user_created', 'actor', 'user', 'rule', 'assistant_agent', 'source_id', null,
            'before', null, 'after', jsonb_build_object('title', v_title, 'owner', 'me', 'status', 'open', 'due', null, 'needs_confirmation', false, 'source_id', null))));
        v_created := true;
        if cardinality(p_context_ids) = 1 then
          select context_version into v_context_version from public.work_contexts
           where id = p_context_ids[1] and user_id = p_user_id and status = 'active' for no key update;
          if found then
            select * into v_membership from public.change_context_membership_by_user(
              p_user_id, v_action, p_context_ids[1], v_context_version, null, null);
            if v_membership.status <> 'ok' then raise exception 'start_agent_turn: membership conflict' using errcode = '40001'; end if;
          end if;
        end if;
      end if;
    end if;
  exception
    when sqlstate 'TF004' then
      update public.conversation_messages set refs = refs || jsonb_build_object('referent_candidates', v_candidates) where id = p_message_id;
      return jsonb_build_object('status', 'needs_referent', 'candidates', v_candidates);
    when sqlstate 'TF404' then
      update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'invalid_referent' where id = p_message_id;
      return jsonb_build_object('status', 'not_sent', 'reason', 'invalid_referent');
  end;

  -- 6) 대화 run → turn_seq → 작업 → agent_message + intent_key prepared. calling/intent marker는 bridge WP 몫이다.
  v_run := public.open_agent_conversation_run(p_user_id, v_session.id, v_action, v_conversation.id);
  update public.agent_sessions set last_turn_seq = last_turn_seq + 1, bound_action_id = coalesce(bound_action_id, v_action)
   where id = v_session.id returning last_turn_seq into v_seq;
  insert into public.agent_tasks (user_id, run_id, agent_session_id, message_id, turn_seq, state)
    values (p_user_id, v_run, v_session.id, p_message_id, v_seq, 'dispatched') returning id into v_task;
  v_step := public.append_step(v_run, (select coalesce(max(seq), 0) + 1 from public.execution_steps where run_id = v_run),
    jsonb_build_object('kind', 'agent_message', 'provider', v_connection.adapter, 'tool', 'message',
      'purpose', 'message:' || p_message_id || case when v_retry > 0 then ':' || v_retry else '' end,
      'body', '', 'args', jsonb_build_object('message_id', p_message_id)));
  if v_step is null or not public.prepare_step(v_step, 0) then
    raise exception 'start_agent_turn: step not prepared' using errcode = '40001';
  end if;
  update public.agent_tasks set step_id = v_step where id = v_task;
  update public.conversation_messages set delivery_state = 'dispatched', delivery_reason = null where id = p_message_id;
  insert into public.metric_events (user_id, type, props)
    values (p_user_id, 'agent_message_sent', jsonb_build_object('adapter', v_connection.adapter, 'access', p_access));
  return jsonb_build_object('status', 'started', 'action_id', v_action, 'run_id', v_run,
    'agent_task_id', v_task, 'turn_seq', v_seq, 'step_id', v_step, 'created_action', v_created);
end;
$$;

create function public.set_agent_message_referent(p_user_id uuid, p_message_id uuid, p_action_id uuid) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages;
begin
  select m.* into v_message from public.conversation_messages m
   join public.conversations c on c.id = m.conversation_id and c.user_id = m.user_id
   where m.id = p_message_id and m.user_id = p_user_id and m.role = 'user' and c.target_kind = 'agent' for update of m;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if v_message.delivery_state not in ('queued', 'not_sent') then return jsonb_build_object('status', 'already_dispatched'); end if;
  if v_message.delivery_expires_at is null or v_message.delivery_expires_at <= public.db_now() then return jsonb_build_object('status', 'expired'); end if;
  if p_action_id is null or not coalesce(v_message.refs->'referent_candidates' @> jsonb_build_array(p_action_id), false)
     or not exists (select 1 from public.actions where id = p_action_id and user_id = p_user_id and status = 'open') then
    return jsonb_build_object('status', 'not_found');
  end if;
  update public.conversation_messages set refs = refs || jsonb_build_object('referent_action_id', p_action_id) where id = p_message_id;
  return jsonb_build_object('status', 'selected', 'action_id', p_action_id);
end;
$$;

create function public.mark_agent_message_not_sent(p_user_id uuid, p_message_id uuid, p_reason text) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages;
  v_target text;
begin
  if p_reason is null or p_reason not in ('write_gate_closed', 'not_connected', 'sign_in_needed', 'unsupported', 'not_found', 'already_dispatched') then
    raise exception 'mark_agent_message_not_sent: invalid reason' using errcode = '22023';
  end if;
  select * into v_message from public.conversation_messages
   where id = p_message_id and user_id = p_user_id and role = 'user' for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  select target_kind into v_target from public.conversations where id = v_message.conversation_id and user_id = p_user_id;
  if v_target is distinct from 'agent' then return jsonb_build_object('status', 'wrong_target'); end if;
  if v_message.delivery_state not in ('queued', 'not_sent') then return jsonb_build_object('status', 'already_dispatched'); end if;
  if v_message.delivery_expires_at is null or v_message.delivery_expires_at <= public.db_now() then return jsonb_build_object('status', 'expired'); end if;
  update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = p_reason where id = p_message_id;
  return jsonb_build_object('status', 'not_sent', 'reason', p_reason);
end;
$$;

-- 선택만 한다. 호출자는 세션/작업 잠금 없이 TS registry로 등급을 다시 계산한다.
create function public.next_queued_agent_message(p_user_id uuid, p_session_id uuid) returns uuid
language sql
set search_path = ''
as $$
  -- created_at은 트랜잭션 시작 시각이다. 먼저 대화별 seq 머리를 고른다.
  with pending as (
    select m.id,m.conversation_id,m.seq,m.created_at from public.conversation_messages m
     join public.conversations c on c.id = m.conversation_id and c.user_id = m.user_id
     where c.agent_session_id = p_session_id and c.user_id = p_user_id and c.target_kind = 'agent'
       and m.role = 'user' and m.delivery_state in ('queued', 'not_sent') and m.delivery_expires_at > public.db_now()
       and not (m.refs ? 'referent_candidates' and m.refs->>'referent_action_id' is null)
       and coalesce(m.delivery_reason, '') not in ('invalid_referent', 'session_closed', 'not_found', 'already_dispatched')
  ), heads as (
    select distinct on (conversation_id) * from pending order by conversation_id,seq
  )
  select id from heads order by created_at,seq,id limit 1;
$$;

-- 기존 함수와 같은 security invoker. 앱은 새 입구를 실행하거나 열에 쓸 수 없다.
do $$
declare f text;
begin
  foreach f in array array['append_step', 'prepare_step', 'finish_run', 'settle_step', 'open_agent_conversation_run',
    'start_agent_turn', 'set_agent_message_referent', 'mark_agent_message_not_sent', 'next_queued_agent_message'] loop
    execute format('revoke all on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
commit;
