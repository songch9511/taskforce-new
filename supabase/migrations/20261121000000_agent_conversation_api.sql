-- OA D1d-s: 대화 API v2 확장의 서버 SQL (구현 계획 D1d, Assistant 계약 v3 3.2 · 3.8 · 5장 · 8장). 새 표 · 열 · 트리거 · 인덱스는 없다.
--
-- 1) 공통 metric 블록 v2 (아래, 글자 그대로): metric_events type에 새 5개를 더한다 — message_resent(Send again) · question_answered(질문 답) ·
--    session_renamed · session_opened_external · session_resumed. 다섯 type은 모두 상태 변경과 같은 트랜잭션에서 아래 함수가 쓴다
--    (검토 반영 7-5: 상태만 바뀌고 지표가 빠지거나 지표만 남는 틈을 없앤다). 질문 답 · 이름 바꾸기는 5) · 6)의 래퍼가, 나머지는 2) 3) 4)가 쓴다.
--    props에는 id · 종류 · 이유 코드만 담는다 (사용자 글 · 답 값 0). 앱(authenticated)이 직접 쓰는 type은 app_opened · assistant_opened 그대로다.
-- 2) requeue_agent_messages(p_user_id, p_conversation_id, p_message_ids): Send again. 대상 상태(not_sent · expired)의 사용자 메시지를 queued로 되돌리고
--    delivery_reason을 비우고 보관 기한을 지금부터 24시간으로 새로 준다 (계약 3.2 "Send again"). cancelled는 끝 상태라 받지 않는다(OD-8): 앱은 같은 글을 새 client_message_id로 보낸다.
--    결과 불명(dispatched + 마지막 단계 unknown_outcome)과 질문의 답이 된 글(refs.answer_for)은 다시 보내지 않는다. 실제 전달은 TS가 이 함수가 끝난 뒤(commit 뒤) 메시지마다 시작한다.
--    잠금: 대상 메시지를 id 순으로 for update 하는 것뿐이다 (대화 대상은 바뀌지 않아 잠그지 않는다). 만료 sweep(conversation_expire_agent_messages, skip locked)과 같은 행이 겹쳐도 잃은 갱신이 없다.
-- 3) open_agent_session_external(p_user_id, p_session_id): Open in Terminal (계약 3.8). bound 세션을 external로 바꾼다. 진행 중 턴(dispatched · accepted · running · awaiting_answer · unreachable)이 있으면 busy,
--    첫 턴의 실제 세션 id를 아직 받지 못한 세션(pending:)은 not_started, bound가 아니면 not_bound(이미 external이면 unchanged). 쓰기는 세션 상태 · 묶인 대화마다 event 한 줄("Opened in Terminal") · 지표 한 줄뿐이다.
--    external 동안 새 메시지는 start_agent_turn이 queued/session_external로 쌓는다(D1c-1). 경로 lease 해제는 D3c-2가 이 함수에 건다.
-- 4) resume_agent_session_here(p_user_id, p_session_id): Resume here. external을 bound로 되돌린다(이미 bound이면 unchanged, external이 아니면 not_external). 같은 방식으로 event 줄("Resumed here") · 지표.
--    대기 메시지를 보낸 순서대로 시작하는 일은 TS가 commit 뒤에 startNextQueuedTurn으로 한다(잠금을 쥔 채 부르지 않는다).
--    사용자가 터미널 세션을 닫았다고 확인했는지는 route가 본다(본문 confirmed_terminal_closed: true) — 이 함수는 상태 전이만 한다.
--    3 · 4번은 세션 잠금을 잡은 직후 묶인 대화를 for update nowait로 한 번 더 확인한다(검토 반영 7-2): 첫 조회와 세션 잠금 사이에 새 대화가 연결되고 다른 요청이 그 대화를
--    쥐면 (세션 → 대화)와 (대화 → 세션)이 서로 기다려 교착하므로, 기다리지 않고 55P03으로 원자 실패한다. TS가 몇 번 다시 시도하고 그래도 안 되면 409 busy_retry.
-- 5) answer_agent_question_recorded(…): 질문 답 + 지표. D1c-2b의 answer_agent_question 본문은 그대로 두고 그 결과가 answered일 때만 question_answered 한 줄을 같은 트랜잭션에서 쓴다 (duplicate · 잘못된 답 · 낡은 질문은 0).
-- 6) rename_agent_session(p_user_id, p_session_id, p_display_name): 이름 바꾸기 + 지표. 실제로 바뀔 때만 session_renamed 한 줄(adapter만). 같은 이름은 unchanged, 없거나 남의 세션은 not_found.
-- 7) start_agent_turn_auto(…): 자동 시작(대기열 머리 · Resume · Stop 뒤)의 시작 입구 (검토 반영 8-1). TS가 고른 메시지 id를 그대로 받아 route_agent_message와 같은 순서로 그 메시지 행을 잠근 뒤
--    상태를 다시 읽는다: queued이거나 not_sent + 이유가 gate 계열(write_gate_closed · not_connected · adapter_disabled)이면 같은 트랜잭션에서 route_agent_message를 부르고, 아니면 아무것도 하지 않고 skipped.
--    검사한 뒤 다른 요청이 상태를 바꿨어도(예: 앞 메시지가 만료돼 not_sent/spawn_failed가 머리가 됨) 낡은 상태로 새 회차를 만들지 않는다. route_agent_message 본문은 바꾸지 않는다.
-- 잠금 순서(D1c와 같다): 메시지 → 사용자 advisory → 대화 → 세션 → run → task → step. 2번은 메시지만, 3 · 4번은 묶인 대화(id 순) → 세션 → 묶인 대화 다시 확인, 7번은 route_agent_message와 같다.
-- 함수는 모두 서버 전용이다: security invoker, search_path 비움, public · anon · authenticated 실행 거절, service_role만 실행.
-- 적용: 운영 DB에는 병합 직전 승인을 받고 저장소 문서(docs/agent-gateway.md)의 방법으로만 한다. 20261120000000_action_numbers 뒤에 적용한다.

begin;
set local lock_timeout = '5s';
-- 진행 중 metric insert와 교착하지 않고 마이그레이션만 재시도한다 (D1c-1과 같다).
lock table public.metric_events in access exclusive mode nowait;

-- OA 공통 블록: metric_events 확장 (Assistant 계약 v3 8장). 코디네이터 Opus 소유, 2026-10-13.
-- 이 블록은 metric_events에 처음 쓰는 OA WP들이 **글자 그대로** 자기 마이그레이션에 넣는다(지금: D1c-1 · D4c-1s).
-- 레인이 달라 어느 쪽이 먼저 적용돼도 결과가 같게 만든다: 열은 if not exists, CHECK · 정책은 계약 8장 전체 목록으로 통째로 교체.
-- 목록을 바꿔야 하면 작업자는 멈추고 코디네이터가 이 파일을 고쳐 두 WP에 같이 반영한다.
-- 기준: main의 마지막 정의 20261020000000_source_failure_visibility.sql:26 (app_opened · action_started · handoff_used ·
-- connection_created · connection_reauth · reconnect_notified · source_failed), 앱 insert 정책 20261001000000_metric_events_client_app_opened.sql.
-- v2 (2026-10-14, 코디네이터): D1d(대화 API) 쓰기 기록 5개 추가 — message_resent · question_answered · session_renamed ·
-- session_opened_external · session_resumed. v1(D1c-1 · D4c-1s, 이미 main)은 그대로 두고, 이후 metric CHECK를 바꾸는 WP는 이 v2 목록 전체를 쓴다.

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
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
    'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed'
  ));

drop policy if exists "owner_insert_app_opened" on public.metric_events;
drop policy if exists "owner_insert_client_app_types" on public.metric_events;
create policy "owner_insert_client_app_types" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type in ('app_opened', 'assistant_opened'));

-- ─────────────────────────────────────────────
-- 2) Send again
-- ─────────────────────────────────────────────
create function public.requeue_agent_messages(p_user_id uuid, p_conversation_id uuid, p_message_ids uuid[]) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_target text;
  v_adapter text;
  v_row record;
  v_id uuid;
  v_out jsonb := '[]'::jsonb;
  v_seen uuid[] := '{}';
  v_unknown boolean;
begin
  if p_message_ids is not null and cardinality(p_message_ids) not between 1 and 50 then
    raise exception 'requeue_agent_messages: message ids must be 1-50' using errcode = '22023';
  end if;
  select c.target_kind, a.adapter into v_target, v_adapter
    from public.conversations c
    left join public.agent_connections a on a.id = c.agent_connection_id and a.user_id = c.user_id
   where c.id = p_conversation_id and c.user_id = p_user_id;
  if not found then return jsonb_build_object('status', 'not_found', 'messages', '[]'::jsonb); end if;
  if v_target is distinct from 'agent' then return jsonb_build_object('status', 'wrong_target', 'messages', '[]'::jsonb); end if;

  -- 이름을 주지 않으면 대상 상태 전부, 주면 그 id (이 대화 · 이 사용자의 사용자 메시지만). 행을 id 순으로 먼저 잠근다.
  perform 1 from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.user_id = p_user_id and m.role = 'user'
     and (case when p_message_ids is null then m.delivery_state in ('not_sent', 'expired') else m.id = any (p_message_ids) end)
   order by m.id for update;

  for v_row in
    select m.id, m.delivery_state, m.delivery_reason, m.refs from public.conversation_messages m
     where m.conversation_id = p_conversation_id and m.user_id = p_user_id and m.role = 'user'
       and (case when p_message_ids is null then m.delivery_state in ('not_sent', 'expired') else m.id = any (p_message_ids) end)
     order by m.seq
  loop
    v_seen := array_append(v_seen, v_row.id);
    if v_row.delivery_state in ('not_sent', 'expired') and not (v_row.refs ? 'answer_for') then
      update public.conversation_messages
         set delivery_state = 'queued', delivery_reason = null, delivery_expires_at = public.db_now() + interval '24 hours'
       where id = v_row.id;
      insert into public.metric_events (user_id, type, props)
        values (p_user_id, 'message_resent', jsonb_strip_nulls(jsonb_build_object(
          'adapter', v_adapter, 'from', v_row.delivery_state, 'reason', v_row.delivery_reason)));
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_row.id, 'result', 'requeued'));
    else
      -- 결과를 알 수 없는 전달은 다시 보내지 않는다 (계약 3.2: unknown_outcome 뒤에는 회차가 오르지 않는다)
      select coalesce((
        select s.state = 'unknown_outcome'
          from public.agent_tasks t join public.execution_steps s on s.id = t.step_id and s.user_id = t.user_id
         where t.message_id = v_row.id and t.user_id = p_user_id
         order by t.turn_seq desc nulls last limit 1), false) into v_unknown;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'message_id', v_row.id, 'result', 'skipped',
        'reason', case when v_row.delivery_state = 'dispatched' and v_unknown then 'unknown_outcome' else 'not_eligible' end));
    end if;
  end loop;

  -- 이름을 준 id 중 이 대화 · 이 사용자의 사용자 메시지가 아닌 것 (없는 id · 남의 id · 다른 대화의 id)
  if p_message_ids is not null then
    foreach v_id in array p_message_ids loop
      if not (v_id = any (v_seen)) then
        v_seen := array_append(v_seen, v_id);
        v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_id, 'result', 'skipped', 'reason', 'not_found'));
      end if;
    end loop;
  end if;
  return jsonb_build_object('status', 'ok', 'messages', v_out);
end;
$$;

-- ─────────────────────────────────────────────
-- 3) Open in Terminal
-- ─────────────────────────────────────────────
create function public.open_agent_session_external(p_user_id uuid, p_session_id uuid) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_session public.agent_sessions;
  v_adapter text;
  v_conversation record;
begin
  if not exists (select 1 from public.agent_sessions where id = p_session_id and user_id = p_user_id) then
    return jsonb_build_object('status', 'not_found');
  end if;
  -- 묶인 대화 → 세션 (start · stop과 같은 순서)
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update;
  select * into v_session from public.agent_sessions where id = p_session_id and user_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  -- 세션을 잡는 동안 새로 연결된 대화가 있을 수 있다: 기다리지 않고 한 번 더 잠근다 (이미 쥔 행은 바로 지나간다)
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update nowait;
  if v_session.status = 'external' then return jsonb_build_object('status', 'unchanged'); end if;
  if exists (select 1 from public.agent_tasks t where t.agent_session_id = p_session_id and t.user_id = p_user_id
               and t.state in ('dispatched', 'accepted', 'running', 'awaiting_answer', 'unreachable')) then
    return jsonb_build_object('status', 'busy');
  end if;
  if v_session.external_session_id like 'pending:%' then return jsonb_build_object('status', 'not_started'); end if;
  if v_session.status <> 'bound' then return jsonb_build_object('status', 'not_bound'); end if;

  update public.agent_sessions set status = 'external' where id = p_session_id;
  for v_conversation in
    select c.id from public.conversations c where c.agent_session_id = p_session_id and c.user_id = p_user_id order by c.id
  loop
    insert into public.conversation_messages (user_id, conversation_id, seq, role, text, content)
      select p_user_id, v_conversation.id, coalesce(max(m.seq), 0) + 1, 'event', 'Opened in Terminal', jsonb_build_object('kind', 'event')
        from public.conversation_messages m where m.conversation_id = v_conversation.id;
    update public.conversations set last_message_at = public.db_now() where id = v_conversation.id;
  end loop;
  select a.adapter into v_adapter from public.agent_connections a where a.id = v_session.connection_id and a.user_id = p_user_id;
  insert into public.metric_events (user_id, type, props)
    values (p_user_id, 'session_opened_external', jsonb_strip_nulls(jsonb_build_object('adapter', v_adapter)));
  return jsonb_build_object('status', 'external');
end;
$$;

-- ─────────────────────────────────────────────
-- 4) Resume here
-- ─────────────────────────────────────────────
create function public.resume_agent_session_here(p_user_id uuid, p_session_id uuid) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_session public.agent_sessions;
  v_adapter text;
  v_conversation record;
begin
  if not exists (select 1 from public.agent_sessions where id = p_session_id and user_id = p_user_id) then
    return jsonb_build_object('status', 'not_found');
  end if;
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update;
  select * into v_session from public.agent_sessions where id = p_session_id and user_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update nowait;
  if v_session.status = 'bound' then return jsonb_build_object('status', 'unchanged'); end if;
  if v_session.status <> 'external' then return jsonb_build_object('status', 'not_external'); end if;

  update public.agent_sessions set status = 'bound' where id = p_session_id;
  for v_conversation in
    select c.id from public.conversations c where c.agent_session_id = p_session_id and c.user_id = p_user_id order by c.id
  loop
    insert into public.conversation_messages (user_id, conversation_id, seq, role, text, content)
      select p_user_id, v_conversation.id, coalesce(max(m.seq), 0) + 1, 'event', 'Resumed here', jsonb_build_object('kind', 'event')
        from public.conversation_messages m where m.conversation_id = v_conversation.id;
    update public.conversations set last_message_at = public.db_now() where id = v_conversation.id;
  end loop;
  select a.adapter into v_adapter from public.agent_connections a where a.id = v_session.connection_id and a.user_id = p_user_id;
  insert into public.metric_events (user_id, type, props)
    values (p_user_id, 'session_resumed', jsonb_strip_nulls(jsonb_build_object('adapter', v_adapter)));
  return jsonb_build_object('status', 'bound');
end;
$$;

-- ─────────────────────────────────────────────
-- 5) 질문 답 + 지표
-- ─────────────────────────────────────────────
create function public.answer_agent_question_recorded(
  p_user_id uuid, p_agent_task_id uuid, p_provider_request_id text, p_answers jsonb, p_answered_locally boolean,
  p_answer_message_id uuid default null
) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_result jsonb;
  v_kind text;
  v_adapter text;
begin
  v_result := public.answer_agent_question(p_user_id, p_agent_task_id, p_provider_request_id, p_answers, p_answered_locally, p_answer_message_id);
  if v_result->>'status' = 'answered' then
    select t.answered_question->>'kind', a.adapter into v_kind, v_adapter
      from public.agent_tasks t
      join public.agent_sessions s on s.id = t.agent_session_id and s.user_id = t.user_id
      left join public.agent_connections a on a.id = s.connection_id and a.user_id = s.user_id
     where t.id = p_agent_task_id and t.user_id = p_user_id;
    insert into public.metric_events (user_id, type, props)
      values (p_user_id, 'question_answered', jsonb_strip_nulls(jsonb_build_object('kind', v_kind, 'adapter', v_adapter)));
  end if;
  return v_result;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) 이름 바꾸기 + 지표
-- ─────────────────────────────────────────────
create function public.rename_agent_session(p_user_id uuid, p_session_id uuid, p_display_name text) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_session public.agent_sessions;
  v_adapter text;
  v_name text := btrim(p_display_name, E' \t\r\n');
begin
  if v_name is null or char_length(v_name) not between 1 and 200 then
    raise exception 'rename_agent_session: display name must be 1-200 characters' using errcode = '22023';
  end if;
  select * into v_session from public.agent_sessions where id = p_session_id and user_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if v_session.display_name is not distinct from v_name then return jsonb_build_object('status', 'unchanged'); end if;
  update public.agent_sessions set display_name = v_name where id = p_session_id;
  select a.adapter into v_adapter from public.agent_connections a where a.id = v_session.connection_id and a.user_id = p_user_id;
  insert into public.metric_events (user_id, type, props)
    values (p_user_id, 'session_renamed', jsonb_strip_nulls(jsonb_build_object('adapter', v_adapter)));
  return jsonb_build_object('status', 'renamed');
end;
$$;

-- ─────────────────────────────────────────────
-- 7) 자동 시작: 고정한 메시지를 잠금 안에서 다시 확인하고 시작
-- ─────────────────────────────────────────────
create function public.start_agent_turn_auto(
  p_user_id uuid, p_message_id uuid, p_access text, p_live_limit integer,
  p_action_ids uuid[] default '{}', p_context_ids uuid[] default '{}'
) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_message public.conversation_messages;
  v_conversation public.conversations;
  v_task public.agent_tasks;
  v_origin uuid;
  v_answer_event text;
begin
  select * into v_message from public.conversation_messages where id = p_message_id and user_id = p_user_id and role = 'user';
  -- 없는 · 남의 메시지는 route_agent_message가 not_found로 답한다 (같은 결과, 쓰기 0)
  if not found then
    return public.route_agent_message(p_user_id, p_message_id, p_access, p_live_limit, p_action_ids, p_context_ids);
  end if;
  select * into v_conversation from public.conversations where id = v_message.conversation_id and user_id = p_user_id;
  select * into v_task from public.agent_tasks where agent_session_id = v_conversation.agent_session_id
    and user_id = p_user_id and state = 'awaiting_answer';
  v_origin := v_task.message_id;
  v_answer_event := 'answer:' || v_task.id || ':' || encode(sha256(convert_to(v_task.pending_question->>'provider_request_id','UTF8')),'hex');
  -- route_agent_message와 같은 행을 같은 순서로 먼저 잠근다 (메시지 → …): 이 뒤의 route_agent_message 잠금은 이미 쥔 행이라 기다리지 않는다
  perform 1 from public.conversation_messages where user_id = p_user_id and (id in (p_message_id, v_origin)
    or (external_event_id = v_answer_event and conversation_id = (select conversation_id from public.conversation_messages where id = v_origin))) order by id for update;
  -- 잠금을 얻은 뒤의 상태로 다시 확인한다 (기다리는 동안 다른 요청이 commit했을 수 있다)
  select * into v_message from public.conversation_messages where id = p_message_id and user_id = p_user_id;
  if not (v_message.delivery_state = 'queued'
    or (v_message.delivery_state = 'not_sent' and v_message.delivery_reason in ('write_gate_closed', 'not_connected', 'adapter_disabled'))) then
    return jsonb_build_object('status', 'skipped');
  end if;
  return public.route_agent_message(p_user_id, p_message_id, p_access, p_live_limit, p_action_ids, p_context_ids);
end;
$$;

-- 서버 전용: 앱은 이 입구를 실행할 수 없다 (기존 함수와 같은 security invoker + 같은 권한 블록).
do $$
declare f text;
begin
  foreach f in array array['requeue_agent_messages', 'open_agent_session_external', 'resume_agent_session_here', 'answer_agent_question_recorded', 'rename_agent_session', 'start_agent_turn_auto'] loop
    execute format('revoke all on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
commit;
