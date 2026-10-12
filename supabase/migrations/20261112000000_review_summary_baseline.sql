-- 0.2.0 C3 후속 (A–D 승인, C) — 복귀 요약의 첫 정상 표시 기준점.
-- 표 1개(return_summary_baseline)와 서비스 롤 전용 함수 1개(return_summary_baseline_init) + 20261111000000의 return_summary_scan을 create or replace로 갱신한다.
-- 기존 03–11 SQL 파일은 한 글자도 바꾸지 않는다. 기존 표 · 다른 함수 · 제약 · 트리거는 바꾸지 않는다(additive).
--
-- 왜: 20261111000000에서는 run 결과 · 읽은 시각이 없는 대화 메시지가 "처음 Clear한 뒤"에야 변화로 올라온다(읽음 기준이 없으면 이력을 변화로 올리지 않는다).
-- 사용자가 요약을 처음 정상으로 보고도 Clear를 누르지 않으면 새 run 결과 · 메시지가 계속 안 보였다. 첫 Clear에 기대지 않고, 최초 정상 표시의 순간을 기준점으로 삼는다.
--
-- 계약 (docs/review-summary.md "첫 정상 표시 기준점"):
--   - GET(return_summary_scan)은 계속 읽기만 한다. 기준점은 서버가 발급한 토큰(사용자 · 지평 · 기준점 범위의 관찰 집합 digest)의 별도 확정 쓰기로만 생긴다:
--     client now · 시간 길이 추정 · "시각 이하 전부 읽음" · inbox 완전성 가정은 쓰지 않는다.
--   - 기준점 범위 = 지평까지 보이는 run 결과 전부 + 읽은 시각(conversations.last_read_at)이 없는 대화 메시지의 (사건, 작업) 쌍. 미열람 Action 변화(action_events)와 미결정은 범위 밖이다.
--   - 확정(return_summary_baseline_init)은 digest 확인과 읽음 표시를 **한 문장**(같은 스냅샷)으로 한다: 조회 뒤 확정 전에 commit된 범위 안 사건은 digest가 달라 stale(표시 0),
--     확정 때 아직 commit되지 않은 사건 · 지평 뒤 사건은 범위 밖이라 읽음이 되지 않고 기준점 뒤 새 변화로 보인다.
--   - 이미 기준점이 있거나 Clear한 적이 있으면(두 기기 · 응답 유실 재시도 · 늦은 확정 · 업그레이드 이전 Clear 사용자) 아무것도 쓰지 않고 already_initialized다. 다시 초기화하지 않는다.
--   - 기준점 전 Clear(return_summary_clear의 p_baseline 경로)는 그대로 기준점 이력도 읽음으로 삼는다. 기준점 뒤 Clear는 기준점 이력을 다시 다루지 않는다
--     (조회가 cursor의 baseline 표시를 "읽음 기준이 없다"일 때만 켠다).
--   - 같은 사용자의 확정 · Clear는 같은 advisory lock으로 직렬이다. 정확성은 잠금이 아니라 관찰 집합 규칙이 만든다.
--
-- 새 영구 원문 · 요약 저장소 없음: 기준점 행은 시각 하나(토큰의 지평). 글 없음.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.
-- 되돌리기(rollback): 순서대로 (시험이 이 문장들과 20261111000000의 return_summary_scan 정의를 그대로 실행해 적용 전 객체 지문 · 권한 복원을 확인한다):
--   drop function public.return_summary_baseline_init(uuid, text[], timestamptz, text, timestamptz);
--   drop function public.return_summary_scan(uuid, text[], timestamptz, integer);
--   (20261111000000_review_summary.sql의 `create function public.return_summary_scan(...)` 문장을 다시 실행해 이전 정의를 되살린다)
--   revoke all on function public.return_summary_scan(uuid, text[], timestamptz, integer) from public, anon, authenticated, service_role;
--   grant execute on function public.return_summary_scan(uuid, text[], timestamptz, integer) to service_role;
--   drop table public.return_summary_baseline;
--   drop function public.return_summary_baseline_guard();
--   (되돌려도 이미 읽음으로 표시된 쌍(return_summary_reads)은 남는다: 읽은 것이 다시 안 읽음이 되지 않는다.)

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) return_summary_baseline: 기준점이 확정됐다는 표시. 사용자당 한 행, 바뀌지 않는다
-- ─────────────────────────────────────────────
create table public.return_summary_baseline (
  user_id uuid primary key references auth.users (id) on delete cascade,
  -- 토큰의 지평: 이 시각까지 보이던 기준점 범위의 사건이 기준점이었다 (표시용 · 감사용. 읽음의 근거는 return_summary_reads의 쌍이다)
  horizon timestamptz not null,
  created_at timestamptz not null default now()
);

create function public.return_summary_baseline_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'return_summary_baseline: 기준점은 한 번 정해지면 바뀌지 않는다 (%)', old.user_id using errcode = 'check_violation';
end;
$$;

create trigger return_summary_baseline_guard
  before update on public.return_summary_baseline
  for each row execute function public.return_summary_baseline_guard();

alter table public.return_summary_baseline enable row level security;
create policy "owner_all" on public.return_summary_baseline for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.return_summary_baseline from anon, authenticated;
grant select on public.return_summary_baseline to authenticated;

-- ─────────────────────────────────────────────
-- 2) 조회: 기준점이 있으면 Clear 없이도 run 결과 · 메시지가 변화로 오른다. baseline_state · init_digest를 더한다 (읽기만, 아무것도 쓰지 않는다)
--    init_digest: 기준점 범위 = p_action_ids '{}'(어떤 작업도 아님) + p_baseline true인 return_summary_scope
--    (20261111000000의 return_summary_scan을 create or replace: 서명 · 반환 형식 · 권한 그대로, 본문만 바뀐다)
-- ─────────────────────────────────────────────
create or replace function public.return_summary_scan(p_user_id uuid, p_change_types text[], p_now timestamptz default null, p_limit integer default 300)
returns jsonb
language sql
set search_path = ''
as $$
  with
  p as (
    select coalesce(p_now, clock_timestamp()) as h,
           (select st.cleared_through from public.return_summary_state st where st.user_id = p_user_id) as w,
           -- 첫 정상 표시 기준점이 확정됐다 (return_summary_baseline). Clear한 적이 있거나 기준점이 있으면 읽음 기준이 있다
           exists (select 1 from public.return_summary_baseline bl where bl.user_id = p_user_id) as b
  ),
  -- 작업별로 사용자가 마지막으로 손댄 시각 (사용자 이벤트 전부: user_seen · 직접 쓰기). 한 번만 센다
  seen as (
    select ue.action_id, max(ue.created_at) as last_at, max(date_trunc('milliseconds', ue.created_at)) as last_ms
      from public.actions a
      join public.action_events ue on ue.action_id = a.id and ue.user_id = a.user_id and ue.actor = 'user'
     where a.user_id = p_user_id
     group by ue.action_id
  ),
  shown as (
    select cd.*
      from p, public.return_summary_candidates(p_user_id, p_change_types, p.h) cd
      left join seen on seen.action_id = cd.action_id
     where not exists (
             select 1 from public.return_summary_reads r
              where r.user_id = p_user_id and r.source = cd.source and r.event_ref = cd.event_ref and r.action_id = cd.action_id)
       and case cd.source
             when 'action_event' then seen.last_ms is null or date_trunc('milliseconds', cd.at) > seen.last_ms
             when 'run_event' then (p.w is not null or p.b) and cd.is_current
             else (p.w is not null or p.b or cd.last_read_at is not null) and cd.at > coalesce(cd.last_read_at, '-infinity'::timestamptz)
           end
  ),
  works as (
    select act.id as action_id, act.title, act.status, (act.started_at is not null) as started,
           (select to_char(sn.last_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from seen sn where sn.action_id = act.id) as last_user_at,
           max(ch.at) as latest,
           jsonb_agg(
             jsonb_build_object(
               'source', case ch.source when 'run_event' then 'run' when 'message' then 'message' else 'action_event' end,
               'kind', ch.kind,
               'at', to_char(ch.at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               'detail', ch.detail, 'source_state', ch.source_state)
             order by ch.at, ch.source, ch.kind) as changes,
           row_number() over (order by max(ch.at) desc, act.id) as rn
      from shown ch
      join public.actions act on act.id = ch.action_id and act.user_id = p_user_id
     group by act.id, act.title, act.status, act.started_at
  ),
  page as (
    select case when (select count(*) from works) > p_limit then (select array_agg(w.action_id order by w.rn) from works w where w.rn <= p_limit) end as ids
  )
  select jsonb_build_object(
    'since', (select to_char(p.w at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from p where p.w is not null),
    'horizon', (select to_char(p.h at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from p),
    'digest', (select public.return_summary_digest(p_user_id, p_change_types, p.h, (select ids from page), p.w is null and not p.b) from p),
    'truncated', (select count(*) from works) > p_limit,
    'page', (select to_jsonb(ids) from page),
    -- baseline: 읽음 기준이 없다 (Clear도 기준점도 없다) — 잘린 조회의 Clear가 run · 대화 이력도 기준으로 삼아야 하는가
    'baseline', (select p.w is null and not p.b from p),
    -- baseline_state: 복귀 요약 응답의 baseline 값. init_digest: 아직 기준점이 없을 때만, 기준점 범위(run 결과 전부 + 읽은 시각이 없는 대화 메시지, 지평까지)의 (사건, 작업) 쌍 digest
    'baseline_state', (select case when p.w is not null then 'cleared' when p.b then 'initialized' else 'never_cleared' end from p),
    'init_digest', (select case when p.w is null and not p.b then public.return_summary_digest(p_user_id, p_change_types, p.h, '{}'::uuid[], true) end from p),
    'works', coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'action_id', w.action_id, 'title', w.title, 'status', w.status, 'started', w.started,
                  'last_user_at', w.last_user_at, 'changes', w.changes)
                order by w.rn)
         from works w where w.rn <= p_limit),
      '[]'::jsonb)
  )
$$;

-- ─────────────────────────────────────────────
-- 3) 확정: 토큰의 기준점 범위를 읽음으로 표시하고 기준점 행을 쓴다
--    initialized          : 범위 digest가 토큰과 같다 → 그 (사건, 작업) 쌍만 읽음 + 기준점 행. 지평 뒤 · 확정 때 미커밋 사건은 범위 밖이라 기준점 뒤 새 변화로 보인다.
--    already_initialized  : 이미 기준점이 있거나 Clear한 적이 있다 → 아무것도 쓰지 않는다 (재초기화 없음, 기존 읽음 그대로).
--    stale                : 조회 뒤 확정 전에 범위가 달라졌다(늦게 commit됨 · 지워짐) → 아무것도 쓰지 않는다. 다음 정상 표시의 새 토큰으로 다시.
--    invalid              : 지평이 서버 시각보다 미래다 → 아무것도 쓰지 않는다.
--    digest 확인과 표시는 한 문장이다 (같은 스냅샷). 같은 사용자의 확정 · Clear는 advisory lock으로 직렬이다.
-- ─────────────────────────────────────────────
create function public.return_summary_baseline_init(
  p_user_id uuid, p_change_types text[], p_horizon timestamptz, p_digest text, p_now timestamptz default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_digest text;
  v_inserted bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('return_summary:' || p_user_id::text, 0));

  if p_horizon > v_now then
    return jsonb_build_object('status', 'invalid');
  end if;
  if exists (select 1 from public.return_summary_state st where st.user_id = p_user_id)
     or exists (select 1 from public.return_summary_baseline bl where bl.user_id = p_user_id) then
    return jsonb_build_object('status', 'already_initialized');
  end if;

  with ins as (
    insert into public.return_summary_reads (user_id, source, event_ref, action_id)
    select p_user_id, sc.source, sc.event_ref, sc.action_id
      from public.return_summary_scope(p_user_id, p_change_types, p_horizon, '{}'::uuid[], true) sc
     where (select public.return_summary_digest(p_user_id, p_change_types, p_horizon, '{}'::uuid[], true)) = p_digest
    on conflict do nothing
    returning 1
  )
  select (select public.return_summary_digest(p_user_id, p_change_types, p_horizon, '{}'::uuid[], true)), (select count(*) from ins)
    into v_digest, v_inserted;
  if v_digest is distinct from p_digest then
    return jsonb_build_object('status', 'stale');
  end if;

  insert into public.return_summary_baseline (user_id, horizon) values (p_user_id, p_horizon);
  return jsonb_build_object('status', 'initialized');
end;
$$;

-- ─────────────────────────────────────────────
-- 4) 함수 권한: 서버(service role)만 부른다. 앱 · 익명은 부르지 못한다. 트리거 함수는 아무도 못 부른다
--    (create or replace한 return_summary_scan의 권한은 그대로이지만 다시 적어 둔다)
-- ─────────────────────────────────────────────
revoke all on function public.return_summary_baseline_init(uuid, text[], timestamptz, text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.return_summary_baseline_init(uuid, text[], timestamptz, text, timestamptz) to service_role;
revoke all on function public.return_summary_scan(uuid, text[], timestamptz, integer) from public, anon, authenticated, service_role;
grant execute on function public.return_summary_scan(uuid, text[], timestamptz, integer) to service_role;
revoke all on function public.return_summary_baseline_guard() from public, anon, authenticated, service_role;

commit;
