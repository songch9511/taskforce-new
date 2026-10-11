-- 0.2.0 코디네이터 1 (구현 계획 C2, 런타임 계약 3 · 5 · 6장, 아키텍처 7.1 · 7.2 · 10장): 사건 큐 저장 계약.
-- 20261103000000_context_core의 inbox_events를 additive로 넓히고, 서버(service role)만 부르는 RPC와 실제 성공 경로에 붙은 생산자 트리거를 더한다.
-- 새 표는 없다. `pending_decisions` 표도 없다(계산값: coordinator_pending_inputs는 읽기 함수일 뿐이다). 사용자 API · UI는 이 묶음에 없다.
--
-- 이 파일이 하는 일 / 하지 않는 일
--   1) inbox_events 열: claim/lease(claim_token · claimed_by · claimed_at · claim_expires_at) · 시도(attempts · last_error_kind · dead_at) ·
--      모델 호출 예산(model_calls ≤ 1 · jev_calls) · 처리 결과(result_kind · result_evidence · result_ids: 종류와 id뿐) · 쌓인 순서(seq).
--      기존 열 · A2 제약은 그대로다(type은 이름 모양만 보고, 종류 목록은 RPC가 본다 — A2 테스트가 type 'timer'를 직접 쌓는다).
--      refs · result_ids는 id · 종류 토큰 · 작은 숫자만 받는다(원문 · 발화 글이 사건에 들어올 길을 DB가 막는다).
--   2) RPC(모두 service_role 전용, search_path = ''): coordinator_enqueue(멱등 적재) · coordinator_claim(사용자별 직렬화 집기) ·
--      coordinator_finish(lease가 살아 있는 소비자만 처리 완료) · coordinator_fail(실패 기록 + 재시도 지연) ·
--      coordinator_reserve_model_call / coordinator_reserve_jev_calls(모델 호출 전에 DB에 먼저 잡는 예산) ·
--      coordinator_enqueue_due_timers(기한 창 timer) · coordinator_recover_missing(삼킨 적재 회수) · coordinator_pending_inputs(결정 대기 계산의 읽기 원천).
--   3) 생산자 트리거(실제 성공 경로의 같은 트랜잭션에서 적재): 원문 처리 done → source_processed / source_revised · 사용자 메시지 → user_message ·
--      사용자 Action 결정 / 승인 / 승인 철회 / 멈춤 → decision_made · 범위 context_version 상승 → memory_changed.
--      회신 · 에이전트 · 의존 · 제안 · bridge · 연결 변화에는 생산자가 없다(원천 표가 아직 없다). 봉투 종류만 coordinator_event_types()에 있다.
--   4) 하지 않는 것: 기존 함수 · 트리거 · CHECK를 다시 만들지 않는다(begin_call · approval_hash · create_run · append_step · write_action 등 그대로).
--      execution_* 표는 트리거가 읽을 뿐 쓰지 않는다(트리거가 inbox_events에만 쓴다). 사건이 Action 값 · Claim · run · 단계 · 정책을 바꾸지 않는다(I01 · I04 · I14).
--
-- 적재의 정직성(생산자 트리거)
--   - 적재는 성공 쓰기와 같은 트랜잭션이다: 원문은 processing_status가 done으로 바뀌는 UPDATE의 트리거(failed · pending · processing은 사건이 아니다),
--     INSERT로 바로 done인 행(실행 receipt · 대화 채택 note)은 원문 처리 성공이 아니라 사건이 아니다. 같은 dedup_key는 한 번만(on conflict do nothing):
--     재시도 · 응답 유실 · 재처리가 사건을 늘리지 않는다. 쓰기 성공과 적재 사이에 "틈"이 없어 누락 · 거짓 성공 · 중복이 생기지 않는다.
--   - 적재가 실패해도 성공 쓰기를 깨지 않는다: 각 트리거는 예외를 삼키고 경고(SQLSTATE만, 데이터 없음)만 남긴다. 삼킨 경우의 누락은
--     coordinator_recover_missing이 멱등으로 메운다(원문 done · 사용자 메시지 · 사용자 Action 결정만. 승인 · 멈춤 · 범위 version 사건은 코디네이터가 DB를 다시 읽어 판단하므로 회수하지 않는다).
--   - 사건은 사실이라 만든 뒤 바꿀 수 없고(트리거), processed_at은 결과(result_kind)와 함께 처리 RPC로만 쓰며 되돌릴 수 없다.
--
-- 순서 · 직렬화(집기)
--   - 사용자마다 "머리" 사건(처리 전 · 죽지 않은 사건 중 created_at, seq 순으로 가장 이른 것)만 집는다. 같은 시각이면 쌓인 순서(seq)로 가른다.
--     뒤 사건은 앞 사건이 처리되거나 죽어야 집힌다(사용자별 순서 보존). 다른 사용자는 서로 막지 않는다. 오래 기다린 머리부터 limit개까지.
--   - 같은 사용자를 동시에 집는 호출 둘은 사용자 advisory xact lock(pg_try_advisory_xact_lock)으로 하나만 통과하고, 머리 행은 for update skip locked로 잠근다
--     (끝내기 · 예산 예약이 쥐고 있는 사건을 가로채지 않는다). 처리 중에는 lease(claim_expires_at)가 직렬화를 잇는다: 살아 있는 lease가 있는 머리의 사용자는 건너뛴다.
--   - lease가 끝난 머리는 다시 집힌다(attempts +1, 새 claim_token). 시도를 다 쓴 머리는 dead_at을 쓰고(처리된 것이 아니다) 그 사용자의 다음 사건으로 넘어간다.
--   - 같은 created_at의 큰 seq가 commit 순서를 뒤집을 수 있다(동시에 열린 두 트랜잭션): 사건은 사실(id)만 담고 처리가 DB를 다시 읽으므로 순서가 진실을 정하지 않는다.
--
-- 모델 예산: 관리(생성) 모델은 사건당 최대 1회(model_calls ∈ {0, 1}), 호출 전에 reserve가 먼저 commit된다. 예약만 남고 응답이 없으면 다시 부르지 않는다
-- (소비자가 "판정 못함"으로 처리). Jev는 jev_calls로 따로 세고 상한을 넘기는 예약은 전부 거절한다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.
-- 되돌리기(rollback): 새 트리거 · 함수 · 제약 · 열을 지우면 된다(inbox_events의 A2 열은 그대로). 이 파일은 기존 데이터를 바꾸지 않는다.

begin;
-- 기존 표(inbox_events · sources · conversation_messages · action_events · execution_approvals · execution_runs · work_contexts)에 잠금을 잡는다:
-- 운영에서 오래 기다리지 않고 실패하게 한다(그때는 그대로 다시 적용한다. 한 트랜잭션이라 남는 객체가 없다).
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 사건 종류 · refs 모양
-- ─────────────────────────────────────────────
-- 아키텍처 7.1 입구. 생산자가 붙는 것과 아직 없는 것은 docs/coordinator.md 표. 종류를 더하려면 이 함수와 src/lib/coordinator/types.ts를 함께 바꾼다
create function public.coordinator_event_types() returns text[]
language sql immutable
set search_path = ''
as $$
  select array[
    'user_message', 'source_processed', 'source_revised', 'reply_observed', 'agent_event', 'dependency_changed',
    'memory_changed', 'timer_due', 'decision_made', 'connection_changed', 'bridge_unreachable'
  ]::text[]
$$;

-- refs · result_ids 모양: 키는 소문자 이름, 값은 uuid 문자열 · 소문자 종류 토큰 · 9자리 이하 정수 · uuid 문자열 배열(100개 이하). 키는 20개 이하.
-- 문장(공백 · 한글 · 대문자 · 구두점)과 중첩 객체는 받지 않는다: 원문 · 발화 글이 사건에 들어오지 못한다
create function public.inbox_refs_valid(p_refs jsonb) returns boolean
language sql immutable
set search_path = ''
as $$
  select jsonb_typeof(p_refs) = 'object'
     and (select count(*) from jsonb_object_keys(p_refs)) <= 20
     and not exists (
       select 1 from jsonb_each(p_refs) e
        where e.key !~ '^[a-z][a-z0-9_]{0,40}$'
           or not (
                (jsonb_typeof(e.value) = 'string' and (e.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
             or (jsonb_typeof(e.value) = 'string' and (e.value #>> '{}') ~ '^[a-z][a-z0-9_]{0,63}$')
             or (jsonb_typeof(e.value) = 'number' and (e.value #>> '{}') ~ '^[0-9]{1,9}$')
             or (jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) <= 100
                 and not exists (
                   select 1 from jsonb_array_elements(e.value) x
                    where jsonb_typeof(x) <> 'string' or (x #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
           )
     )
$$;

-- ─────────────────────────────────────────────
-- 2) inbox_events 열 · 제약 (additive)
-- ─────────────────────────────────────────────
alter table public.inbox_events
  -- 쌓인 순서: created_at이 같을 때의 tie-break
  add column seq bigint generated always as identity,
  -- claim/lease: 집은 소비자만 끝낼 수 있다(claim_token). 한 사건에 살아 있는 lease는 하나다
  add column claim_token uuid,
  add column claimed_by text check (char_length(claimed_by) between 1 and 100),
  add column claimed_at timestamptz,
  add column claim_expires_at timestamptz,
  -- 시도: 집을 때마다 +1. 상한을 넘으면 dead_at(처리된 것이 아니다)
  add column attempts integer not null default 0 check (attempts >= 0),
  add column last_error_kind text check (last_error_kind ~ '^[a-z][a-z0-9_]{0,63}$'),
  add column dead_at timestamptz,
  -- 모델 호출 예산: 관리(생성) 모델은 사건당 최대 1회. 예약은 호출 전에 commit된다
  add column model_calls integer not null default 0 check (model_calls between 0 and 1),
  add column model_call_reserved_at timestamptz,
  add column jev_calls integer not null default 0 check (jev_calls >= 0),
  -- 처리 결과: 종류 + 근거 종류 + id뿐(글 없음). processed_at은 결과와 함께, 처리 RPC로만
  add column result_kind text check (result_kind in ('no_impact', 'impact_recorded', 'stale', 'rejected', 'not_judged', 'not_handled')),
  add column result_evidence text check (result_evidence ~ '^[a-z][a-z0-9_]{0,63}$'),
  add column result_ids jsonb not null default '{}',
  -- refs · 처리 결과 일관성은 NOT VALID로 건다: 새 행 · 고치는 행에는 지금부터 적용되고, 이 파일을 적용하기 전에 쌓인 행(지금까지 이 표에 쓰는 코드는 없었지만
  -- 운영 DB를 조회해 확인하지 않았다)은 검사하지 않아 적용이 실패하지 않는다. 옛 행을 검사하려면 나중에 validate constraint 하면 된다
  add constraint inbox_events_refs_ids_only check (public.inbox_refs_valid(refs)) not valid,
  add constraint inbox_events_result_ids_ids_only check (public.inbox_refs_valid(result_ids)),
  add constraint inbox_events_result_consistency check ((processed_at is null) = (result_kind is null)) not valid,
  add constraint inbox_events_dead_not_processed check (dead_at is null or processed_at is null),
  add constraint inbox_events_claim_shape check ((claim_token is null) = (claimed_by is null) and (claim_token is null) = (claim_expires_at is null)),
  add constraint inbox_events_model_call_shape check ((model_calls = 1) = (model_call_reserved_at is not null));

-- 머리 사건 찾기(사용자별 가장 이른 처리 전 사건): 같은 시각은 seq로 가른다
create index inbox_events_claim_idx on public.inbox_events (user_id, created_at, seq) where processed_at is null and dead_at is null;

-- 사건의 사실(누가 · 무슨 종류 · 어떤 키 · 어떤 id · 언제)은 바뀌지 않고, 처리 표시는 되돌릴 수 없다. 이 표를 고치는 정식 경로는 위 RPC뿐이다
create function public.inbox_events_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.user_id, new.type, new.dedup_key, new.refs, new.created_at, new.seq)
     is distinct from (old.user_id, old.type, old.dedup_key, old.refs, old.created_at, old.seq) then
    raise exception 'inbox_events: 사건의 사실(user_id · type · dedup_key · refs · created_at)은 immutable이다 (%)', old.id using errcode = 'check_violation';
  end if;
  if old.processed_at is not null
     and (new.processed_at, new.result_kind, new.result_evidence, new.result_ids, new.claim_token)
         is distinct from (old.processed_at, old.result_kind, old.result_evidence, old.result_ids, old.claim_token) then
    raise exception 'inbox_events: 이미 processed 된 사건의 처리 결과는 바꿀 수 없다 (%)', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger inbox_events_guard
  before update on public.inbox_events
  for each row execute function public.inbox_events_guard();

-- ─────────────────────────────────────────────
-- 3) 적재 (서버). 같은 dedup_key는 한 번만, created_at은 DB 시각이다
-- ─────────────────────────────────────────────
create function public.coordinator_enqueue(p_user_id uuid, p_type text, p_dedup_key text, p_refs jsonb default '{}')
returns table (event_id uuid, created boolean)
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_type is null or not (p_type = any (public.coordinator_event_types())) then
    raise exception 'coordinator_enqueue: 알 수 없는 사건 종류 %', p_type using errcode = '22023';
  end if;
  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  values (p_user_id, p_type, p_dedup_key, coalesce(p_refs, '{}'::jsonb), public.db_now())
  on conflict (user_id, dedup_key) do nothing
  returning id into v_id;
  if v_id is not null then
    return query select v_id, true;
    return;
  end if;
  select e.id into v_id from public.inbox_events e where e.user_id = p_user_id and e.dedup_key = p_dedup_key;
  return query select v_id, false;
end;
$$;

-- 트리거 안에서 쓰는 적재: 예외를 삼키지 않는다(삼키는 곳은 각 트리거 함수). 같은 키면 아무것도 하지 않는다
create function public.coordinator_enqueue_internal(p_user_id uuid, p_type text, p_dedup_key text, p_refs jsonb) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  values (p_user_id, p_type, p_dedup_key, p_refs, public.db_now())
  on conflict (user_id, dedup_key) do nothing;
$$;

-- ─────────────────────────────────────────────
-- 4) 집기 (서버). 사용자별 직렬화
-- ─────────────────────────────────────────────
-- 사용자마다 머리 사건 하나. 살아 있는 lease가 있으면 그 사용자는 건너뛴다. limit개까지, 오래 기다린 머리부터.
-- 시도를 다 쓴 머리는 죽은 사건으로 접고 같은 사용자의 다음 사건을 본다. 결과 행의 claim_token을 가진 소비자만 끝낼 수 있다
create function public.coordinator_claim(p_consumer text, p_lease_seconds integer, p_limit integer, p_max_attempts integer)
returns table (
  event_id uuid, user_id uuid, type text, dedup_key text, refs jsonb, created_at timestamptz, seq bigint,
  claim_token uuid, attempts integer, model_calls integer, jev_calls integer
)
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
  v_cand record;
  v_head public.inbox_events%rowtype;
  v_token uuid;
  v_count integer := 0;
begin
  if p_consumer is null or char_length(p_consumer) not between 1 and 100
     or p_lease_seconds is null or p_lease_seconds not between 1 and 600
     or p_limit is null or p_limit not between 1 and 100
     or p_max_attempts is null or p_max_attempts not between 1 and 20 then
    raise exception 'coordinator_claim: 인자가 범위 밖이다 (consumer 1–100자 · lease 1–600초 · limit 1–100 · 시도 1–20)' using errcode = '22023';
  end if;

  for v_cand in
    with recursive u(uid) as (
      (select e.user_id from public.inbox_events e where e.processed_at is null and e.dead_at is null order by e.user_id limit 1)
      union all
      select (select e.user_id from public.inbox_events e where e.user_id > u.uid and e.processed_at is null and e.dead_at is null order by e.user_id limit 1)
        from u where u.uid is not null
    )
    select u.uid as uid, h.created_at as head_at, h.seq as head_seq
      from u
      cross join lateral (
        select e.created_at, e.seq from public.inbox_events e
         where e.user_id = u.uid and e.processed_at is null and e.dead_at is null
         order by e.created_at, e.seq limit 1
      ) h
     where u.uid is not null
     order by h.created_at, h.seq
  loop
    exit when v_count >= p_limit;
    -- 같은 사용자를 동시에 집는 호출은 하나만 통과한다
    continue when not pg_try_advisory_xact_lock(hashtextextended('tf.coordinator:' || v_cand.uid::text, 0));
    <<per_user>>
    loop
      -- 머리: 처리 전 · 죽지 않은 사건 중 가장 이른 것 (잠그지 않고 읽는다. for update skip locked를 여기에 붙이면 잠긴 머리를 건너뛰고 뒤 사건을 집는다)
      select * into v_head from public.inbox_events e
       where e.user_id = v_cand.uid and e.processed_at is null and e.dead_at is null
       order by e.created_at, e.seq limit 1;
      exit per_user when not found;
      -- 그 머리 행을 잠근다. 끝내기 · 예산 예약이 쥐고 있으면 이 사용자는 건너뛴다
      perform 1 from public.inbox_events e where e.id = v_head.id and e.processed_at is null and e.dead_at is null for update skip locked;
      exit per_user when not found;
      -- 살아 있는 lease: 다른 소비자가 처리 중이다
      exit per_user when v_head.claim_expires_at is not null and v_head.claim_expires_at > v_now;
      if v_head.attempts >= p_max_attempts then
        update public.inbox_events e set dead_at = v_now where e.id = v_head.id;
        continue per_user;
      end if;
      v_token := gen_random_uuid();
      update public.inbox_events e
         set claim_token = v_token, claimed_by = p_consumer, claimed_at = v_now,
             claim_expires_at = v_now + make_interval(secs => p_lease_seconds), attempts = e.attempts + 1
       where e.id = v_head.id
       returning e.* into v_head;
      v_count := v_count + 1;
      return query select v_head.id, v_head.user_id, v_head.type, v_head.dedup_key, v_head.refs, v_head.created_at, v_head.seq,
                          v_head.claim_token, v_head.attempts, v_head.model_calls, v_head.jev_calls;
      exit per_user;
    end loop;
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 5) 끝내기 · 실패 · 예산 예약 (서버). lease가 살아 있고 집은 토큰이 같은 소비자만
-- ─────────────────────────────────────────────
-- 결과: finished(이번에 처리 완료) · already_finished(같은 토큰으로 이미 처리 완료 — 응답 유실 뒤 같은 commit의 재시도) ·
-- lost_claim(토큰이 다르거나 lease가 끝났거나 사건이 없다 — 늦은 소비자의 commit은 거절된다. 처리는 아직 안 된 것이다)
create function public.coordinator_finish(p_event_id uuid, p_claim_token uuid, p_result_kind text, p_result_ids jsonb, p_evidence text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
begin
  update public.inbox_events e
     set processed_at = v_now, result_kind = p_result_kind, result_ids = coalesce(p_result_ids, '{}'::jsonb), result_evidence = p_evidence
   where e.id = p_event_id and e.claim_token = p_claim_token and e.processed_at is null and e.dead_at is null and e.claim_expires_at > v_now;
  if found then
    return 'finished';
  end if;
  if exists (select 1 from public.inbox_events e where e.id = p_event_id and e.claim_token = p_claim_token and e.processed_at is not null) then
    return 'already_finished';
  end if;
  return 'lost_claim';
end;
$$;

-- 소비자가 처리하지 못했다: 까닭 종류만 남기고(글 없음) lease를 재시도 지연 뒤로 당긴다. 끝난 것으로 보지 않는다(attempts는 이미 집을 때 올랐다)
create function public.coordinator_fail(p_event_id uuid, p_claim_token uuid, p_error_kind text, p_retry_after_seconds integer) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
begin
  if p_retry_after_seconds is null or p_retry_after_seconds not between 0 and 600 then
    raise exception 'coordinator_fail: 재시도 지연이 범위 밖이다 (0–600초)' using errcode = '22023';
  end if;
  update public.inbox_events e
     set last_error_kind = p_error_kind, claim_expires_at = least(e.claim_expires_at, v_now + make_interval(secs => p_retry_after_seconds))
   where e.id = p_event_id and e.claim_token = p_claim_token and e.processed_at is null and e.dead_at is null and e.claim_expires_at > v_now;
  return found;
end;
$$;

-- 관리(생성) 모델 호출 예약: 사건당 한 번. true를 받은 소비자만 부른다. 예약만 남고 응답이 없으면(소비자가 죽음 · 응답 유실) 다시 true가 되지 않는다
create function public.coordinator_reserve_model_call(p_event_id uuid, p_claim_token uuid) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
begin
  update public.inbox_events e set model_calls = 1, model_call_reserved_at = v_now
   where e.id = p_event_id and e.claim_token = p_claim_token and e.processed_at is null and e.dead_at is null
     and e.claim_expires_at > v_now and e.model_calls = 0;
  return found;
end;
$$;

-- Jev 호출 예약: p_count만큼 더하되 합이 p_cap을 넘으면 하나도 더하지 않는다(전부 또는 0)
create function public.coordinator_reserve_jev_calls(p_event_id uuid, p_claim_token uuid, p_count integer, p_cap integer) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
begin
  if p_count is null or p_count not between 1 and 100 or p_cap is null or p_cap not between 1 and 100 then
    raise exception 'coordinator_reserve_jev_calls: 인자가 범위 밖이다 (count · cap 1–100)' using errcode = '22023';
  end if;
  update public.inbox_events e set jev_calls = e.jev_calls + p_count
   where e.id = p_event_id and e.claim_token = p_claim_token and e.processed_at is null and e.dead_at is null
     and e.claim_expires_at > v_now and e.jev_calls + p_count <= p_cap;
  return found;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) timer: 기한 창 (런타임 계약 12장 긴급 창)
-- ─────────────────────────────────────────────
-- 열린 Action 중 기한(due_at)이 지금보다 뒤이고 창(p_window_seconds) 안인 것을 기한 값마다 한 번 timer_due로 쌓는다.
-- 이미 쌓인 것을 빼고 p_limit개까지만 새로 쌓는다(오래된 사건이 자리를 막지 않는다). 지난 기한은 "다가오는" 변화가 아니라 쌓지 않는다.
-- 기한이 Claim으로 바뀌면 키가 달라져 새 사건이다. 코디네이터가 켜져 있을 때 sweep만 부른다(꺼져 있으면 부르지 않는다)
create function public.coordinator_enqueue_due_timers(p_window_seconds integer, p_limit integer) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
  v_count integer;
begin
  if p_window_seconds is null or p_window_seconds not between 1 and 604800 or p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'coordinator_enqueue_due_timers: 인자가 범위 밖이다 (창 1초–7일 · limit 1–1000)' using errcode = '22023';
  end if;
  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select d.user_id, 'timer_due', d.dedup_key, jsonb_build_object('action_id', d.action_id, 'kind', 'due_window'), v_now
    from (
      select k.user_id, k.action_id, k.dedup_key
        from (
          select a.user_id, a.id as action_id, a.due_at,
                 'timer:due_window:' || a.id::text || ':' || floor(extract(epoch from a.due_at))::bigint::text as dedup_key
            from public.actions a
           where a.status = 'open' and a.due_at is not null and a.due_at > v_now and a.due_at <= v_now + make_interval(secs => p_window_seconds)
        ) k
       where not exists (select 1 from public.inbox_events e where e.user_id = k.user_id and e.dedup_key = k.dedup_key)
       order by k.due_at, k.action_id
       limit p_limit
    ) d
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ─────────────────────────────────────────────
-- 7) 회수: 삼킨 적재를 멱등으로 메운다 (생산자 트리거는 적재 실패로 성공 쓰기를 깨지 않는다)
-- ─────────────────────────────────────────────
-- 최근 p_lookback_seconds 안의 원문 처리 완료 · 사용자 메시지 · 사용자 Action 결정 중 사건이 없는 것을 같은 dedup_key로 쌓는다(종류마다 p_limit개까지).
-- 원문은 처리 요약(processing_summary)이 있는 done만 센다: 처리 없이 바로 done으로 쓴 행(실행 receipt · 대화 채택 note)은 처리 성공이 아니다.
-- 이미 사건이 있으면 아무것도 하지 않아 겹쳐 돌려도 같다. 쌓은 수를 돌려준다
create function public.coordinator_recover_missing(p_lookback_seconds integer, p_limit integer) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
  v_since timestamptz;
  v_count integer;
  v_total integer := 0;
begin
  if p_lookback_seconds is null or p_lookback_seconds not between 60 and 604800 or p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'coordinator_recover_missing: 인자가 범위 밖이다 (기간 60초–7일 · limit 1–1000)' using errcode = '22023';
  end if;
  v_since := v_now - make_interval(secs => p_lookback_seconds);

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select s.user_id,
         case when cardinality(public.source_document_ids(s.user_id, s.id)) > 1 then 'source_revised' else 'source_processed' end,
         'source:' || s.id::text, jsonb_build_object('source_id', s.id, 'kind', s.kind), v_now
    from (
      select x.* from public.sources x
       where x.processing_status = 'done' and x.kind <> 'execution' and x.processing_summary is not null and x.processed_at >= v_since
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'source:' || x.id::text)
       order by x.processed_at, x.id limit p_limit
    ) s
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select m.user_id, 'user_message', 'message:' || m.id::text, jsonb_build_object('conversation_id', m.conversation_id, 'message_id', m.id), v_now
    from (
      select x.* from public.conversation_messages x
       where x.role = 'user' and x.created_at >= v_since
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'message:' || x.id::text)
       order by x.created_at, x.id limit p_limit
    ) m
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select a.user_id, 'decision_made', 'action_event:' || a.id::text, jsonb_build_object('action_id', a.action_id, 'action_event_id', a.id, 'kind', a.type), v_now
    from (
      select x.* from public.action_events x
       where x.actor = 'user' and x.type in ('user_confirmed', 'user_deleted', 'user_edited', 'completed', 'dropped', 'reopened') and x.created_at >= v_since
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'action_event:' || x.id::text)
       order by x.created_at, x.id limit p_limit
    ) a
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  return v_total;
end;
$$;

-- ─────────────────────────────────────────────
-- 8) 생산자 트리거: 실제 성공 경로의 같은 트랜잭션에서 적재. 예외는 삼킨다(경고에 SQLSTATE만)
-- ─────────────────────────────────────────────
-- 트리거 함수는 소유자 권한이다: 쓰는 역할(앱 · 서버 · Supabase Auth의 계정 삭제)이 inbox_events 권한이 없어도 돌고, 그 역할이 사건을 직접 쓰지는 못한다.

-- 원문 처리 완료: processing_status가 done으로 바뀔 때만(실패 · 대기 · 처리 중은 사건이 아니다). 같은 문서의 두 번째 revision부터 source_revised
create function public.coordinator_on_source_done() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id,
      case when cardinality(public.source_document_ids(new.user_id, new.id)) > 1 then 'source_revised' else 'source_processed' end,
      'source:' || new.id::text,
      jsonb_build_object('source_id', new.id, 'kind', new.kind));
  exception when others then
    raise warning 'coordinator_on_source_done: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_source_done
  after update of processing_status on public.sources
  for each row
  when (new.processing_status = 'done' and old.processing_status is distinct from 'done' and new.kind <> 'execution')
  execute function public.coordinator_on_source_done();

-- 대화 v2 사용자 메시지(conversation_post_message가 쓴다). 답(assistant) · 이벤트 행은 사건이 아니다
create function public.coordinator_on_user_message() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id, 'user_message', 'message:' || new.id::text,
      jsonb_build_object('conversation_id', new.conversation_id, 'message_id', new.id));
  exception when others then
    raise warning 'coordinator_on_user_message: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_user_message
  after insert on public.conversation_messages
  for each row
  when (new.role = 'user')
  execute function public.coordinator_on_user_message();

-- 사용자가 한 Action 결정: 확인 · 삭제 · 수정 · 완료 · 취소 · 다시 열기(action_events의 actor user). 읽음(user_seen) · 착수 · 메모 · 직접 추가는 결정이 아니다
create function public.coordinator_on_action_decision() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id, 'decision_made', 'action_event:' || new.id::text,
      jsonb_build_object('action_id', new.action_id, 'action_event_id', new.id, 'kind', new.type));
  exception when others then
    raise warning 'coordinator_on_action_decision: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_action_decision
  after insert on public.action_events
  for each row
  when (new.actor = 'user' and new.type in ('user_confirmed', 'user_deleted', 'user_edited', 'completed', 'dropped', 'reopened'))
  execute function public.coordinator_on_action_decision();

-- 실행 승인 · 승인 철회 · 멈춤(사용자가 한 것). execution_* 표는 읽기만 한다
create function public.coordinator_on_approval() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id, 'decision_made', 'approval:' || new.id::text,
      jsonb_build_object('step_id', new.step_id, 'run_id', (select s.run_id from public.execution_steps s where s.id = new.step_id and s.user_id = new.user_id), 'kind', 'approval'));
  exception when others then
    raise warning 'coordinator_on_approval: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_approval
  after insert on public.execution_approvals
  for each row execute function public.coordinator_on_approval();

create function public.coordinator_on_approval_revoked() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id, 'decision_made', 'approval_revoked:' || new.id::text,
      jsonb_build_object('step_id', new.step_id, 'run_id', (select s.run_id from public.execution_steps s where s.id = new.step_id and s.user_id = new.user_id), 'kind', 'approval_revoked'));
  exception when others then
    raise warning 'coordinator_on_approval_revoked: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_approval_revoked
  after update of revoked_at on public.execution_approvals
  for each row
  when (old.revoked_at is null and new.revoked_at is not null)
  execute function public.coordinator_on_approval_revoked();

-- 사용자 멈춤: stop_run이 execution.gate를 stop으로 정한 전이만 (Action을 닫아서 멈춘 것 등 다른 까닭은 사용자의 run 결정이 아니다)
create function public.coordinator_on_run_stop() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    if current_setting('execution.gate', true) = 'stop' then
      perform public.coordinator_enqueue_internal(
        new.user_id, 'decision_made', 'run_stop:' || new.id::text,
        jsonb_build_object('run_id', new.id, 'action_id', new.action_id, 'kind', 'stop'));
    end if;
  exception when others then
    raise warning 'coordinator_on_run_stop: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_run_stop
  after update of state on public.execution_runs
  for each row
  when (new.state = 'stopped' and old.state is distinct from 'stopped')
  execute function public.coordinator_on_run_stop();

-- 범위 version 상승(B1: 범위 기억 · 멤버십 · 멤버 원문 revision). 올릴 때마다 version당 한 번
create function public.coordinator_on_context_version() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.coordinator_enqueue_internal(
      new.user_id, 'memory_changed', 'memory_changed:' || new.id::text || ':' || new.context_version::text,
      jsonb_build_object('context_id', new.id, 'context_version', new.context_version));
  exception when others then
    raise warning 'coordinator_on_context_version: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

create trigger coordinator_on_context_version
  after update of context_version on public.work_contexts
  for each row
  when (new.context_version > old.context_version)
  execute function public.coordinator_on_context_version();

-- ─────────────────────────────────────────────
-- 9) 결정 대기 계산의 읽기 원천 (런타임 계약 6장 pending_decisions). 계산값이라 표가 없다. 읽기만 한다(쓰지 않는다)
-- ─────────────────────────────────────────────
-- 행: kind · action_id · run_id · step_id · version(처리되면 바뀌어 목록에서 빠지는 식별) · created_at · due_at.
--   approval: 준비됐고 승인이 필요한데 유효한 승인이 없는 단계(begin_call과 같은 기준: 철회 · 만료 · hash 불일치는 유효하지 않다), version = step:<id>:<단계 version>:<정책 version>
--   run_input / review_failed: 그 Action의 가장 최근 run이 needs_input / review_failed로 끝났고 멈추지 않았다, version = run:<id>:<outcome>
--   confirm: 열린 Action의 확인 요청(needs_confirmation), version = action:<id>:<Action version>
-- 아직 원천이 없는 것(에이전트 질문 · 열린 제안 · 긴급 창의 막힘 의존)은 이 함수에 없다. 소유권은 user_id로 모든 조인에서 확인한다.
create function public.coordinator_pending_inputs(p_user_id uuid)
returns table (kind text, action_id uuid, run_id uuid, step_id uuid, version text, created_at timestamptz, due_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select 'approval'::text, r.action_id, r.id, s.id,
         'step:' || s.id::text || ':' || s.version::text || ':' || s.policy_version::text,
         s.created_at, a.due_at
    from public.execution_steps s
    join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
    join public.actions a on a.id = r.action_id and a.user_id = r.user_id
   where s.user_id = p_user_id and s.state = 'prepared' and s.needs_approval is true and s.policy_version is not null
     and r.state in ('queued', 'running', 'waiting_approval') and a.status = 'open'
     and not exists (
       select 1 from public.execution_approvals ap
        where ap.step_id = s.id and ap.user_id = s.user_id and ap.revoked_at is null and ap.expires_at > public.db_now()
          and ap.hash = public.approval_hash(s.id, ap.expires_at))
  union all
  select case r.outcome when 'needs_input' then 'run_input' else 'review_failed' end, r.action_id, r.id, null::uuid,
         'run:' || r.id::text || ':' || r.outcome, r.created_at, a.due_at
    from public.execution_runs r
    join public.actions a on a.id = r.action_id and a.user_id = r.user_id
   where r.user_id = p_user_id and r.outcome in ('needs_input', 'review_failed') and r.state <> 'stopped' and a.status = 'open'
     and not exists (
       select 1 from public.execution_runs n
        where n.user_id = r.user_id and n.action_id = r.action_id and (n.created_at, n.id) > (r.created_at, r.id))
  union all
  select 'confirm'::text, a.id, null::uuid, null::uuid, 'action:' || a.id::text || ':' || a.version::text, a.last_activity_at, a.due_at
    from public.actions a
   where a.user_id = p_user_id and a.status = 'open' and a.needs_confirmation
$$;

-- ─────────────────────────────────────────────
-- 10) 권한: 서버(service role)만 부른다. 앱 · 익명은 부르지 못한다. 트리거 함수 · 내부 함수는 아무도 부르지 못한다
-- ─────────────────────────────────────────────
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.coordinator_event_types()',
    'public.inbox_refs_valid(jsonb)',
    'public.coordinator_enqueue(uuid, text, text, jsonb)',
    'public.coordinator_claim(text, integer, integer, integer)',
    'public.coordinator_finish(uuid, uuid, text, jsonb, text)',
    'public.coordinator_fail(uuid, uuid, text, integer)',
    'public.coordinator_reserve_model_call(uuid, uuid)',
    'public.coordinator_reserve_jev_calls(uuid, uuid, integer, integer)',
    'public.coordinator_enqueue_due_timers(integer, integer)',
    'public.coordinator_recover_missing(integer, integer)',
    'public.coordinator_pending_inputs(uuid)',
    'public.coordinator_enqueue_internal(uuid, text, text, jsonb)',
    'public.inbox_events_guard()',
    'public.coordinator_on_source_done()',
    'public.coordinator_on_user_message()',
    'public.coordinator_on_action_decision()',
    'public.coordinator_on_approval()',
    'public.coordinator_on_approval_revoked()',
    'public.coordinator_on_run_stop()',
    'public.coordinator_on_context_version()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
  end loop;
end;
$$;

grant execute on function public.coordinator_event_types() to service_role;
-- inbox_events의 CHECK(refs · result_ids)가 서버(service role)의 쓰기에서 이 함수를 부른다
grant execute on function public.inbox_refs_valid(jsonb) to service_role;
grant execute on function public.coordinator_enqueue(uuid, text, text, jsonb) to service_role;
grant execute on function public.coordinator_claim(text, integer, integer, integer) to service_role;
grant execute on function public.coordinator_finish(uuid, uuid, text, jsonb, text) to service_role;
grant execute on function public.coordinator_fail(uuid, uuid, text, integer) to service_role;
grant execute on function public.coordinator_reserve_model_call(uuid, uuid) to service_role;
grant execute on function public.coordinator_reserve_jev_calls(uuid, uuid, integer, integer) to service_role;
grant execute on function public.coordinator_enqueue_due_timers(integer, integer) to service_role;
grant execute on function public.coordinator_recover_missing(integer, integer) to service_role;
grant execute on function public.coordinator_pending_inputs(uuid) to service_role;

commit;
