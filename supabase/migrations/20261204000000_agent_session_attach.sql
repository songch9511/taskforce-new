-- 외부 세션 이어받기 서버 (OA 외부 세션 PR2s, 계약 handoffs/oa-external-sessions-contract.md 7장 ES-17 · ES-18 · 10장 · 19장):
-- Taskforce 밖에서 시작한 Claude Code 세션을 이 사용자의 에이전트 세션 + 대화로 묶는다. 서버가 받는 것은 Claude 세션 UUID와 가상 루트(/taskforce/ws_<uuid>)뿐이다.
-- 대화 본문 · 실제 경로 · 제목은 받지 않는다 (display_name은 ''로 둔다, ES-19).
--
-- 이 파일이 하는 일:
--   1) attach_agent_session: 함수 하나. 새 표 0 — 기존 agent_sessions · conversations 모양 그대로 쓴다 (agent_gateway_core, conversation_agent_target).
--      pending 갈래(bridge_commands: external_session_id가 'pending:%'이면 resume false)는 실제 id면 바로 resume true라 고칠 것이 없다:
--      이어받은 세션의 첫 메시지는 기존 start_agent_turn이 새 세션을 만들지 않고 이 세션에 턴을 붙인다 (시험: tests/db/agent-session-attach.scenarios.ts).
--   2) metric_events 종류 검사: 바로 앞 목록(20261203000000) 그대로 + session_attached 하나. 앱 insert 정책(owner_insert_client_app_types)은 그대로다 — 이 지표는 함수가 남긴다.
--
-- 함수 규칙 (security definer, search_path 빈 값, public · anon · authenticated 실행 권한 없음, service role만):
--   - 인자 모양을 한 번 더 강제한다: Claude id는 정규 소문자 UUID, workspace_ref는 /taskforce/ws_<소문자 UUID>, adapter는 registry 문자열 모양. 어긋나면 22023이고 아무것도 쓰지 않는다.
--   - 소유 확인이 먼저다: bridge는 이 사용자 것이고 active이며(for share로 쥔다 — 그 사이 해제(revoke_bridge)가 끼어들지 못한다), 그 bridge에 이 adapter의 active 연결이 있어야 한다.
--     아니면 not_found (없는 · 남의 · 해제된 bridge와 연결 없음을 구별해 알리지 않는다). 소유를 확인한 뒤에야 잠금을 잡는다.
--   - 같은 (사용자, Claude id)는 advisory lock으로 직렬화한다. 동시에 온 두 요청은 하나가 created, 나머지가 existing이다 (세션 · 대화 · 이벤트 각각 1).
--   - session_in_use: 같은 사용자의 다른 연결(다른 Mac)에 닫히지 않은 같은 Claude id 세션이 있거나, 이 연결의 세션이 closed이다. 아무것도 쓰지 않는다.
--   - existing: 같은 연결에 이미 묶인 세션 (Taskforce가 시작한 세션 · 이전에 이어받은 세션 · Open in Terminal로 external이 된 세션 모두). 상태 · workspace_ref는 고치지 않는다.
--   - created: 세션(status bound, display_name '')과/또는 대화(target agent)를 이 호출이 새로 만들었다. 지표 session_attached는 이때만, 같은 트랜잭션에서 한 번 남긴다 (props는 adapter뿐).
--   - Action · run · 작업 · 메시지는 만들지 않는다 (붙이기만 한다). 첫 메시지가 오면 start_agent_turn이 Action과 턴을 만든다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) attach_agent_session
-- ─────────────────────────────────────────────
create function public.attach_agent_session(p_user_id uuid, p_bridge_id uuid, p_adapter text, p_external_session_id text, p_workspace_ref text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_connection public.agent_connections;
  v_session public.agent_sessions;
  v_conversation uuid;
  v_created boolean := false;
begin
  if p_user_id is null or p_bridge_id is null or p_adapter is null or p_external_session_id is null or p_workspace_ref is null
     or p_adapter !~ '^agent:[a-z0-9][a-z0-9_-]*$' or char_length(p_adapter) > 64
     or p_external_session_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_workspace_ref !~ '^/taskforce/ws_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'attach_agent_session: invalid argument' using errcode = '22023';
  end if;

  -- 소유 확인이 먼저다 (잠금은 확인 뒤): 없는 · 남의 · 해제된 bridge id로는 아무 잠금도 잡지 못한다.
  perform 1 from public.bridges where id = p_bridge_id and user_id = p_user_id and status = 'active' for share;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  select * into v_connection from public.agent_connections
   where bridge_id = p_bridge_id and user_id = p_user_id and adapter = p_adapter and status = 'active'
   order by created_at, id limit 1 for share;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- 같은 (사용자, Claude id)의 이어받기는 한 번에 하나씩
  perform pg_advisory_xact_lock(hashtextextended('attach_agent_session:' || p_user_id::text || ':' || p_external_session_id, 0));

  -- 다른 연결(다른 Mac)이 이미 쥐고 있다 (그 연결의 세션이 닫혔으면 막지 않는다: 해제된 bridge의 옛 세션)
  if exists (
    select 1 from public.agent_sessions s
      join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
     where s.user_id = p_user_id and s.external_session_id = p_external_session_id
       and s.connection_id <> v_connection.id and c.adapter = p_adapter and s.status <> 'closed'
  ) then
    return jsonb_build_object('status', 'session_in_use');
  end if;

  insert into public.agent_sessions (user_id, connection_id, external_session_id, workspace_ref, display_name, status)
    values (p_user_id, v_connection.id, p_external_session_id, p_workspace_ref, '', 'bound')
    on conflict (connection_id, external_session_id) do nothing
    returning * into v_session;
  if v_session.id is null then
    -- 이미 이 연결에 묶여 있다: 그 행을 그대로 돌려준다 (workspace_ref · status를 고치지 않는다)
    select * into v_session from public.agent_sessions
     where connection_id = v_connection.id and external_session_id = p_external_session_id and user_id = p_user_id;
    if not found then
      return jsonb_build_object('status', 'not_found');
    end if;
    if v_session.status = 'closed' then
      return jsonb_build_object('status', 'session_in_use');
    end if;
  else
    v_created := true;
  end if;

  -- 이 세션의 대화: 있으면 그대로 (보관한 대화보다 열린 대화를 먼저), 없으면 만든다
  select c.id into v_conversation from public.conversations c
   where c.user_id = p_user_id and c.agent_session_id = v_session.id and c.target_kind = 'agent'
   order by (c.archived_at is not null), c.created_at, c.id limit 1;
  if v_conversation is null then
    insert into public.conversations (user_id, target_kind, agent_connection_id, agent_session_id)
      values (p_user_id, 'agent', v_session.connection_id, v_session.id) returning id into v_conversation;
    v_created := true;
  end if;

  if v_created then
    insert into public.metric_events (user_id, type, props)
      values (p_user_id, 'session_attached', jsonb_build_object('adapter', p_adapter));
  end if;
  return jsonb_build_object('status', case when v_created then 'created' else 'existing' end,
    'session_id', v_session.id, 'conversation_id', v_conversation);
end;
$$;
revoke all on function public.attach_agent_session(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.attach_agent_session(uuid, uuid, text, text, text) to service_role;

-- ─────────────────────────────────────────────
-- 2) metric_events: session_attached
-- ─────────────────────────────────────────────
-- 종류 검사: 20261203000000의 전체 목록 + session_attached 하나. 앱 insert 정책은 바꾸지 않는다 (위 머리 주석).
alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
    'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed',
    'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved',
    'billing_checkout_started', 'billing_trial_started', 'billing_subscription_activated', 'billing_payment_succeeded',
    'billing_payment_failed', 'billing_plan_changed', 'billing_subscription_cancelled', 'billing_subscription_resumed',
    'billing_subscription_ended', 'billing_lifetime_purchased', 'billing_refund_requested', 'billing_refunded',
    'billing_portal_opened', 'billing_duplicate_purchase', 'billing_review_needed', 'billing_legacy_marked', 'billing_notice_scheduled',
    'ai_key_saved', 'ai_key_deleted', 'ai_key_revoked',
    'external_sessions_shown',
    'session_attached'
  ));

commit;
