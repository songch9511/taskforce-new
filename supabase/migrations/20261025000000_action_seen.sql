-- U1 PR2: 바뀜 점 — 사용자가 할 일을 본 시점 (POST /api/v1/actions/:id/seen, GET /api/v1/now의 항목별 changed).
--
-- - 본 것은 이벤트로만 남긴다: action_events에 user_seen(actor user, before · after · source_id 없음)을 더한다.
-- - actions 행은 고치지 않는다 → last_activity_at · 랭킹 · Realtime(actions) 영향 없음. 읽기는 기존 인덱스 action_events_action_idx를 탄다.
-- - 서버(service role)만 쓴다: action_events의 클라이언트 쓰기 차단(20260929000000, insert · update · delete 권한 회수)은 그대로다.
-- - 어떤 이벤트를 바뀜으로 치는지는 코드가 정한다 (src/lib/actions/changed.ts). 여기서는 값만 넓힌다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 적용 → 병합 순서
-- (병합 = 배포라 코드가 먼저 나가면 user_seen이 제약에 막혀 /seen이 500이 된다. /now는 user_seen이 없어도 그대로 돈다).

-- 기존 표(action_events)의 제약을 바꾸며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (그때는 그대로 다시 적용한다).
set lock_timeout = '5s';

-- 기존 값은 모두 그대로 받고 user_seen만 더한다. 문장 하나: 제약을 지우고 다시 만드는 사이에 제약 없는 표가 남지 않는다.
alter table public.action_events
  drop constraint action_events_type_check,
  add constraint action_events_type_check check (type in (
    'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
    'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created',
    'user_unstarted', 'artifact_created', 'user_seen'
  ));
