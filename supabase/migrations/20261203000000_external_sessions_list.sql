-- 외부 세션 목록 (OA 외부 세션 PR1 "보이기", 계약 handoffs/oa-external-sessions-contract.md 16장 확정):
-- Taskforce 밖에서 시작한 Claude Code 세션을 Mac이 찾아 서버에 알린다. 서버에 가는 것은 제목 · 상태 · 마지막 활동 시각 · 불투명 id뿐이다.
-- 대화 본문 · 실제 경로 · 폴더 이름 · Claude 세션 id는 이 표에 없다. session_ref는 Mac이 세션 UUID에서 "Mac에만 있는 열쇠"로 만든 HMAC이라
-- 서버는 이 값에서 Claude 세션을 찾을 수 없다 (대응표는 Mac에만 있다).
--
-- 이 파일이 하는 일:
--   1) external_sessions 표 (user_id + owner_all RLS + bridges와 (id, user_id) 복합 외래키). 앱은 읽기만, 쓰기는 서버 함수(service role)만.
--   2) report_external_sessions: 한 Mac의 목록을 "스냅샷 교체"로 쓴다. 보관 규칙:
--        - 보고마다 이번 목록에 없는 그 Mac의 행(제목)을 지운다 (7일 창 밖으로 나간 세션 · 사라진 세션).
--        - bridge가 해제(revoked)되면 트리거가 그 Mac의 행을 즉시 지운다. bridge 삭제 · 계정 삭제는 cascade.
--        - Mac이 보고를 멈추면 reported_at이 오래된 행을 purge_external_sessions가 지운다 (매일 도는 /api/cron/retention).
--   3) metric_events: external_sessions_shown (앱이 POST /api/v1/metric-events로 알리고 route가 남김, 하루 한 번 — UTC 날짜별 부분 unique 인덱스). 종류 검사는 20261129000000의 전체 목록 + 이 type 하나.
--      앱 insert 정책(owner_insert_client_app_types)과 앱의 열 권한(type · action_id)은 그대로다: props를 쓰려고 앱에 열 권한을 넓히지 않고, route가 구간 enum을 검증한 뒤 서버 권한으로 넣는다.
--      (session_attached · session_attach_refused는 이어받기 PR2의 몫이다.)
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) external_sessions
-- ─────────────────────────────────────────────
-- title: Claude Code 기록의 custom-title / agent-name에서 Mac이 뽑아 제어 글자를 지운 것(1–200자). 없으면 null. 사용자 글에 가깝다 — 로그 · 지표 · AI 호출에 쓰지 않는다.
-- state: 보이는 이유(폴더 거절 · 버전 · worktree · 읽지 못함)는 서버에 unavailable 하나로 접어 보낸다.
-- last_activity_at: 기록 파일의 수정 시각. reported_at: 서버 시각 — 보관 기준.
create table public.external_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  bridge_id uuid not null,
  session_ref text not null check (session_ref ~ '^[0-9a-f]{64}$'),
  title text check (title is null or char_length(title) between 1 and 200),
  state text not null check (state in ('available', 'running_claude_app', 'running_terminal', 'running_elsewhere', 'unknown', 'unavailable')),
  last_activity_at timestamptz not null,
  reported_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (bridge_id, session_ref),
  constraint external_sessions_bridge_fkey foreign key (bridge_id, user_id)
    references public.bridges (id, user_id) on delete cascade
);

create index external_sessions_user_idx on public.external_sessions (user_id);
create index external_sessions_reported_idx on public.external_sessions (reported_at);

create trigger external_sessions_set_updated_at
  before update on public.external_sessions
  for each row execute function public.set_updated_at();

alter table public.external_sessions enable row level security;
create policy "owner_all" on public.external_sessions for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.external_sessions from anon, authenticated;
grant select on public.external_sessions to authenticated;

-- ─────────────────────────────────────────────
-- 2) report_external_sessions: 한 Mac의 목록 스냅샷 교체
-- ─────────────────────────────────────────────
-- p_sessions: [{ id, title, state, last_activity_at }] 최대 50개, id(= session_ref) 중복 없음. 모양이 틀리면 예외(22023 또는 열 제약)이고 아무것도 쓰지 않는다.
-- bridge가 이 사용자 것이고 active가 아니면 not_found (route가 404). 같은 bridge의 보고는 직렬화한다.
create function public.report_external_sessions(p_user_id uuid, p_bridge_id uuid, p_sessions jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_count integer;
  v_removed integer;
begin
  if p_user_id is null or p_bridge_id is null or p_sessions is null or jsonb_typeof(p_sessions) <> 'array' then
    raise exception 'report_external_sessions: invalid argument' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_sessions);
  if v_count > 50 then
    raise exception 'report_external_sessions: too many sessions' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_sessions) e where jsonb_typeof(e) <> 'object') then
    raise exception 'report_external_sessions: invalid element' using errcode = '22023';
  end if;
  if (select count(distinct e ->> 'id') from jsonb_array_elements(p_sessions) e) <> v_count then
    raise exception 'report_external_sessions: duplicate or missing id' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('external_sessions:' || p_bridge_id::text));
  perform 1 from public.bridges where id = p_bridge_id and user_id = p_user_id and status = 'active' for share;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  insert into public.external_sessions (user_id, bridge_id, session_ref, title, state, last_activity_at, reported_at)
  select p_user_id, p_bridge_id, e ->> 'id', e ->> 'title', e ->> 'state', (e ->> 'last_activity_at')::timestamptz, now()
  from jsonb_array_elements(p_sessions) e
  on conflict (bridge_id, session_ref) do update
    set title = excluded.title, state = excluded.state, last_activity_at = excluded.last_activity_at, reported_at = excluded.reported_at;

  delete from public.external_sessions
  where bridge_id = p_bridge_id and user_id = p_user_id
    and session_ref <> all (coalesce((select array_agg(e ->> 'id') from jsonb_array_elements(p_sessions) e), '{}'::text[]));
  get diagnostics v_removed = row_count;

  return jsonb_build_object('status', 'ok', 'kept', v_count, 'removed', v_removed);
end;
$$;
revoke all on function public.report_external_sessions(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.report_external_sessions(uuid, uuid, jsonb) to service_role;

-- bridge가 해제되면 그 Mac이 보고한 제목을 바로 지운다
create function public.external_sessions_on_bridge_revoked() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.external_sessions where bridge_id = new.id;
  return new;
end;
$$;
revoke all on function public.external_sessions_on_bridge_revoked() from public, anon, authenticated;
create trigger external_sessions_on_bridge_revoked
  after update of status on public.bridges
  for each row when (new.status = 'revoked' and old.status is distinct from 'revoked')
  execute function public.external_sessions_on_bridge_revoked();

-- Mac이 보고를 멈춘 행의 보관 정리 (/api/cron/retention이 부른다. 한 번에 최대 5,000개)
create function public.purge_external_sessions(p_before timestamptz, p_limit integer) returns integer
language plpgsql set search_path = '' as $$
declare v_count integer;
begin
  with picked as (
    select id from public.external_sessions where reported_at < p_before
    order by reported_at, id limit greatest(0, least(p_limit, 5000)) for update skip locked
  )
  delete from public.external_sessions where id in (select id from picked);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.purge_external_sessions(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.purge_external_sessions(timestamptz, integer) to service_role;

-- ─────────────────────────────────────────────
-- 3) metric_events: external_sessions_shown
-- ─────────────────────────────────────────────
-- 종류 검사: 20261129000000의 전체 목록 + external_sessions_shown. 앱 insert 정책은 바꾸지 않는다(위 머리 주석).
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
    'external_sessions_shown'
  ));

-- 하루 한 번 (UTC 날짜): 앱이 켜질 때마다 보내도 두 번째부터는 unique 위반(23505)으로 route가 조용히 넘긴다
create unique index metric_events_external_shown_day_idx
  on public.metric_events (user_id, (("at" at time zone 'UTC')::date))
  where type = 'external_sessions_shown';

commit;
