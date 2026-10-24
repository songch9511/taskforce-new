-- 하위 에이전트 트리 지표 네 종류 (T3s, 계획 docs/design/taskforce-0.2.0-agent-tree-implementation-plan-2026-10-23.md T3s 절, 계약 handoffs/oa-agent-tree-t3s-contract.md):
-- 앱이 POST /api/v2/agent-tree/*로 알리면 route(src/lib/api/agent-tree-metrics.ts)가 서버 권한으로 metric_events에 남긴다. 모양은 claude_app_session_opened(20261206000000)와 같다.
-- **글 · 이름 · 경로 · 개수는 없다**: 열기 둘은 props가 비어 있고, T2 둘은 props가 턴 id(agent_task_id) 하나뿐이다.
--
--   종류                           세는 단위                    props                          route
--   project_sessions_opened        사용자 · UTC 날짜 하루 한 번  {}                             POST /api/v2/agent-tree/project-sessions-opened
--   subagent_row_opened            사용자 · UTC 날짜 하루 한 번  {}                             POST /api/v2/agent-tree/subagent-opened
--   subagent_turn_used             턴(agent_task_id) 한 번       {"agent_task_id": "<uuid>"}    POST /api/v2/agent-tree/turn-used
--   subagent_question_redirected   턴(agent_task_id) 한 번       {"agent_task_id": "<uuid>"}    POST /api/v2/agent-tree/question-redirected
--
-- 이 파일이 하는 일 (새 표 · 함수 · 정책 · 열 0):
--   0) 적용 순서 가드: 맨 앞에서 metric_events_type_check에 20261206의 claude_app_session_opened, 20261207의 claude_app_message_sent · claude_app_chat_deleted,
--      20261208의 claude_app_chats_deleted_all이 모두 있는지 본다. 없으면(= 20261207000000 또는 20261208000000이 아직 적용되지 않았으면) 예외로 멈춘다.
--      이 파일은 그 검사를 "20261208의 목록 + 새 넷"으로 다시 만들기 때문에, 순서가 바뀌면 20261207 · 20261208이 나중에 검사를 다시 만들면서 이 넷이 조용히 빠지고 route가 23514로 실패한다.
--      20261208의 자기 가드는 20261207만 보므로 이 파일이 20261208보다 먼저 적용되는 일은 이 가드가 막는다. 순서는 20261207 → 20261208 → 20261209다.
--   1) metric_events 종류 검사: 바로 앞 목록(20261208000000_claude_app_chats_delete_all.sql = 20261207의 목록 + claude_app_chats_deleted_all)의 전체 + 위 넷.
--      앱 insert 정책(owner_insert_client_app_types)과 앱의 열 권한(type · action_id)은 그대로다: 앱이 이 종류를 직접 남기지 못한다.
--      이 파일이 다시 만드는 것은 이 지표 종류 검사 하나뿐이다: rate_limit_events_kind_check · take_rate_limit은 건드리지 않는다 (20261208의 것 그대로).
--      **앞으로 이 검사를 다시 만드는 마이그레이션은 이 네 종류(project_sessions_opened · subagent_row_opened · subagent_turn_used · subagent_question_redirected)를 목록에 이어 가져와야 한다**
--      — 시험 tests/metrics/agent-event-registry.test.ts가 최신 목록을 등록부와 대조하고 tests/db/agent-tree-metrics.test.ts가 이 파일 뒤의 파일이 이 넷을 담는지 본다.
--   2) 하루 한 번 (열기 둘, UTC 날짜별 부분 unique 인덱스): 앱이 열 때마다 보내도 두 번째부터는 unique 위반(23505)으로 route가 조용히 넘긴다. 같은 날 다른 종류는 막지 않는다.
--   3) 턴마다 한 번 (T2 둘, (user_id, props->>'agent_task_id') 부분 unique 인덱스): Mac이 턴이 끝날 때마다 알려도 같은 턴의 두 번째부터는 23505. 두 종류는 서로 막지 않는다.
--   4) T2 둘 전용 props 검사 metric_events_subagent_turn_props: 이 두 종류의 props는 키 agent_task_id 하나뿐이고 값은 소문자 uuid 글자여야 한다.
--      소문자만 받는 까닭: 3)의 인덱스는 글자 그대로 비교하므로 대문자 uuid를 받으면 같은 턴을 두 번 셀 수 있다 (route도 소문자로 바꿔 남긴다).
--      기존 props 검사 metric_events_props_shape(객체인지만)는 건드리지 않는다.
--      NULL 함정: CHECK는 NULL이면 통과한다. 키가 없을 때 jsonb_typeof(NULL)이 NULL이 되어 통과하지 않도록 coalesce로 거짓으로 만든다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 CLI의 linked query 파일 실행으로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 0) 적용 순서 가드
-- ─────────────────────────────────────────────
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'metric_events_type_check' and conrelid = 'public.metric_events'::regclass
       and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_session_opened%'
       and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_message_sent%'
       and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_chat_deleted%'
       and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_chats_deleted_all%'
  ) then
    raise exception '20261209_agent_tree_metrics: apply 20261207000000_claude_app_chats.sql and 20261208000000_claude_app_chats_delete_all.sql first (metric_events_type_check does not contain claude_app_session_opened, claude_app_message_sent, claude_app_chat_deleted and claude_app_chats_deleted_all)';
  end if;
end;
$$;

-- ─────────────────────────────────────────────
-- 1) 종류 검사: 20261208의 전체 목록(20261207의 목록 + claude_app_chats_deleted_all) + 새 넷
-- ─────────────────────────────────────────────
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
    'session_attached',
    'claude_app_session_opened',
    'claude_app_message_sent', 'claude_app_chat_deleted',
    'claude_app_chats_deleted_all',
    'project_sessions_opened', 'subagent_row_opened', 'subagent_turn_used', 'subagent_question_redirected'
  ));

-- ─────────────────────────────────────────────
-- 2) 하루 한 번 (열기 둘)
-- ─────────────────────────────────────────────
create unique index metric_events_project_sessions_opened_day_idx
  on public.metric_events (user_id, (("at" at time zone 'UTC')::date))
  where type = 'project_sessions_opened';

create unique index metric_events_subagent_row_opened_day_idx
  on public.metric_events (user_id, (("at" at time zone 'UTC')::date))
  where type = 'subagent_row_opened';

-- ─────────────────────────────────────────────
-- 3) 턴마다 한 번 (T2 둘)
-- ─────────────────────────────────────────────
create unique index metric_events_subagent_turn_used_task_idx
  on public.metric_events (user_id, (props ->> 'agent_task_id'))
  where type = 'subagent_turn_used';

create unique index metric_events_subagent_question_redirected_task_idx
  on public.metric_events (user_id, (props ->> 'agent_task_id'))
  where type = 'subagent_question_redirected';

-- ─────────────────────────────────────────────
-- 4) T2 둘 전용 props 검사
-- ─────────────────────────────────────────────
alter table public.metric_events add constraint metric_events_subagent_turn_props
  check (
    type not in ('subagent_turn_used', 'subagent_question_redirected')
    or (
      coalesce(jsonb_typeof(props -> 'agent_task_id'), '') = 'string'
      and (props - 'agent_task_id') = '{}'::jsonb
      and props ->> 'agent_task_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    )
  );

commit;
