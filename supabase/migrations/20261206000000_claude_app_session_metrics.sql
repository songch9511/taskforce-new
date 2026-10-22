-- 데스크톱 세션 레일 · Sessions 패널 지표 (OA PR-D2, 계약 handoffs/oa-external-sessions-contract.md 21.6 · 23장):
-- 사용자가 Claude 데스크톱 앱의 세션 보기(레일 링 · Sessions의 줄)를 연 날을 센다. **종류만이다**: props도 칸도 없다 (세션 id · 제목 · 폴더는 서버에 오지 않는다).
--
-- 이 파일이 하는 일 (새 표 · 함수 · 정책 0):
--   1) metric_events 종류 검사: 바로 앞 목록(20261204000000_agent_session_attach.sql, session_attached까지)의 전체 + claude_app_session_opened 하나.
--      앱 insert 정책(owner_insert_client_app_types)과 앱의 열 권한(type · action_id)은 그대로다: 앱이 이 종류를 직접 남기지 못한다.
--      앱이 POST /api/v2/external-sessions/claude-app-opened로 알리고 route(src/lib/api/external-sessions.ts)가 서버 권한으로 남긴다 (external_sessions_shown과 같은 모양).
--      (앞으로 이 검사를 다시 만드는 마이그레이션은 claude_app_session_opened를 목록에 이어 가져야 한다 — 시험 tests/metrics/agent-event-registry.test.ts가 최신 목록을 등록부와 대조한다.)
--   2) 하루 한 번 (UTC 날짜별 부분 unique 인덱스): 앱이 열 때마다 보내도 두 번째부터는 unique 위반(23505)으로 route가 조용히 넘긴다. 같은 날 다른 종류는 막지 않는다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 CLI의 linked query 파일 실행으로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

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
    'claude_app_session_opened'
  ));

create unique index metric_events_claude_app_opened_day_idx
  on public.metric_events (user_id, (("at" at time zone 'UTC')::date))
  where type = 'claude_app_session_opened';

commit;
