-- U2 Mac PR1: 중단 시각(execution_runs.stopped_at)과 열린 Action에서만 다음 단계 (docs/EXECUTION.md 3 · 5 · 6장, 2026-10-04 사용자 결정 ① · ②).
--
-- ① 중단 시각: run이 멈춘(stopped) 때를 DB 시각으로 적는다. 앱이 어느 기기에서 멈췄든 "Stop requested <시각>"을 보인다(M17 · P9).
--    - stop_run이 열린 run을 멈출 때 적는다. 끝 상태는 다시 열리지 않으므로 처음 멈춘 때 한 번만 적히고, 다시 멈춰도(이미 stopped) 그대로다.
--      지우는 함수는 없다. 앱은 자기 run 행을 RLS(owner_select)로 읽고, POST /runs · stop의 run 요약(runSummarySchema)에도 담는다.
--    - 이 마이그레이션 전에 멈춘 run은 비어 있다(null). 운영에는 그런 run이 없다(실행을 켠 적 없음). 앱은 null이면 시각 없이 보인다.
-- ② 열린 Action에서만 다음 단계: begin_call이 run의 Action을 읽어 열려 있지 않으면(status done · dropped, /now가 보이는 할 일은 open뿐)
--    단계를 부르지 않고 run을 멈춘다(stopped, gate action_closed, ①의 시각도 적는다). 모든 입구(route의 after() · 자기 호출 · sweep)가
--    begin_call을 지나므로 세 입구 모두 막힌다. 남은 예약은 run을 멈추는 기존 트리거(release_run_credits)가 해제한다.
--    이미 calling인 단계는 그대로 끝까지 결과를 받는다(stop과 같다, EXECUTION 5장). 다시 보내기 · 결과 불명 규칙은 바뀌지 않는다.
--    Action 행은 for share로 잠근다(스위치와 같다): 할 일을 끝내는 쓰기(write_action의 update)는 진행 중인 begin_call이 commit될 때까지
--    기다리고, 끝낸 뒤에 commit되는 전이(prepared → calling)는 없다. 잠금 순서: step → run → Action → 정책 → 실행 주체 → 스위치 → 도구
--    → 수신자 → 크레딧 계정.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 적용 → 병합 순서
-- (병합 = 배포라 코드가 먼저 나가면 run 요약 읽기가 없는 열(stopped_at)을 찾아 POST /runs · stop이 500이 된다. 운영은 EXECUTION_ENABLED가
-- 꺼져 있어 두 route 모두 그 전에 404로 끝난다).

-- 기존 표(execution_runs)에 열을 더하며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다.
-- 잠금을 잡는 변경을 맨 앞에 두어, 시간이 다 되면 다른 객체를 바꾸기 전에 실패한다 (그때는 그대로 다시 적용한다).
-- 그 뒤에서 실패하면 파일 전체가 한 트랜잭션으로 돌았는지에 따라 바뀐 함수가 있을 수 있으니, 다시 적용하기 전에 확인한다
-- (함수는 create or replace라 그대로 다시 적용해도 된다. 열은 이미 있으면 add column이 실패하니 그 줄만 빼고 적용한다).
set lock_timeout = '5s';

alter table public.execution_runs add column stopped_at timestamptz;

-- ─────────────────────────────────────────────
-- 1) begin_call: 20261022000000_execution_credits_artifacts와 같고, 앞 단계 확인 뒤에 Action 확인(②)만 더했다
-- ─────────────────────────────────────────────
-- prepared → calling. RPC 하나 = READ COMMITTED 트랜잭션 하나, 외부 호출 전에 commit된다 (외부 호출은 이 안에 없다).
-- 순서: stale(단계 · run · 앞 단계) → stopped → Action 열림(아니면 run을 멈춘다) → 중복(intent) → 실행 주체 → 스위치 → 도구
--       → (외부만) 보내는 연결 → 수신자 허용 목록 → 승인/Auto → 크레딧 → intent + 예약 + lease.
-- 잠금 순서: step → run → Action(for share) → 정책 → 실행 주체 → 스위치 → 도구 → 수신자(for share, 여러 행은 키 순서로) → 크레딧 계정(for update).
-- 끄는 쪽의 update(스위치 · 할 일 끝내기)는 이 트랜잭션이 끝날 때까지 기다린다. 같은 사용자의 두 예약은 계정 행에서 줄을 선다.
-- 검증한 그대로의 내용을 돌려준다. 실행기는 이 내용만 보낸다.
create or replace function public.begin_call(p_step uuid, p_owner text, p_version integer) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_step public.execution_steps;
  v_run public.execution_runs;
  v_policy public.execution_policies;
  v_action_status text;
  v_held uuid;
  v_marker uuid;
  v_locked integer;
  v_blocked boolean;
  v_addresses jsonb;
  v_allowed integer;
  v_account public.credit_accounts;
  v_rate text;
  v_run_used integer;
  v_reserve integer := 0;
begin
  if p_owner is null then
    raise exception 'begin_call: lease 소유자가 필요하다';
  end if;
  select * into v_step from public.execution_steps where id = p_step for update;
  if not found or v_step.state <> 'prepared' or v_step.version <> p_version then
    return '{"gate": "stale"}';
  end if;
  select * into v_run from public.execution_runs where id = v_step.run_id for no key update;
  if v_run.state = 'stopped' then
    return '{"gate": "stopped"}';
  end if;
  if v_run.state not in ('running', 'waiting_approval') then
    return '{"gate": "stale"}';
  end if;
  -- 앞 단계가 끝나지 않았으면(부르는 중 · 결과 불명 · 실패 · 준비 전) 다음 단계로 가지 않는다 (EXECUTION 3장)
  perform 1 from public.execution_steps e
    where e.run_id = v_step.run_id and e.seq < v_step.seq and e.state not in ('called', 'skipped');
  if found then
    return '{"gate": "stale"}';
  end if;

  -- 열린 Action에서만 다음 단계 (2026-10-04 사용자 결정 ②): 끝냈거나(done) 지운(dropped) 할 일의 run은 부르지 않고 멈춘다.
  -- 열림의 기준은 /now와 같다(status open). 멈추면 트리거가 남은 예약을 해제하고(release_run_credits), 시각을 stop_run과 같이 적는다.
  -- for share: 할 일을 끝내는 update는 이 전이가 commit될 때까지 기다리고, 끝낸 뒤 commit되는 전이는 없다. 스위치 · 지급과 달리 되돌려
  -- 이어 가지 않는다: 할 일을 다시 열어도 멈춘 run은 그대로고, 새 run으로 다시 시작한다
  select a.status into v_action_status from public.actions a where a.id = v_run.action_id and a.user_id = v_run.user_id for share;
  if v_action_status is distinct from 'open' then
    perform set_config('execution.gate', 'action_closed', true);
    update public.execution_runs set state = 'stopped', stopped_at = coalesce(stopped_at, public.db_now())
      where id = v_run.id and state in ('running', 'waiting_approval');
    return '{"gate": "action_closed"}';
  end if;

  select * into v_policy from public.execution_policies where id = v_run.policy_id for share;

  -- 같은 목적을 다른 단계가 이미 가졌으면 승인을 묻지 않고 건너뛴다.
  -- 외부 효과 단계가 이미 자기 표식을 가졌으면(한 번 불렀다, 계약 밖에서 prepared로 되돌아옴) 다시 부르지도, 앞 결과를 덮지도 않는다.
  -- 같은 표식을 다시 쓰는 것은 내부 효과의 재시도뿐이다
  select i.step_id into v_held from public.execution_intents i where i.intent_key = v_step.intent_key;
  if v_held is not null and v_held <> v_step.id then
    return public.execution_skip(v_step.id, v_run.id, v_held);
  end if;
  if v_held = v_step.id and v_step.effect_class <> 'internal' then
    return '{"gate": "stale"}';
  end if;

  -- 실행 주체: 운영자 허용 목록 (EXECUTION 7장 1)
  perform 1 from public.execution_actors a where a.user_id = v_run.user_id for share;
  if not found then
    return public.execution_hold(v_run.id, 'actor', 'actor');
  end if;

  -- 차단 스위치: 세 행(전체 · 그 공급자 · 그 모드)을 잠그고 읽는다. 행이 없으면 막힘
  select count(*), coalesce(bool_or(c.blocked), false) into v_locked, v_blocked from (
    select e.blocked from public.execution_controls e
    where (e.scope, e.key) in (('global', '*'), ('provider', v_step.provider), ('mode', v_policy.mode))
    order by e.scope, e.key
    for share
  ) c;
  if v_locked < 3 or v_blocked then
    return public.execution_hold(v_run.id, 'blocked', 'blocked');
  end if;

  -- 도구 목록: 목록 밖 도구, 목록과 효과 종류가 다른 단계(외부 도구를 내부로 적어 승인을 건너뛰려는 것)는 막힌다
  perform 1 from public.execution_tools t
    where t.provider = v_step.provider and t.tool = v_step.tool and t.effect_class = v_step.effect_class
    for share;
  if not found then
    return public.execution_hold(v_run.id, 'blocked', 'tool');
  end if;

  v_addresses := public.norm_addresses(v_step.recipients);
  -- 보내는 연결 · 수신자 허용 목록 · 승인은 외부 효과에만 (EXECUTION 5 · 7장). 내부 효과(초안)에 적힌 받을 사람은 막지 않는다
  if v_step.effect_class = 'external' then
    if v_step.connection_id is null then
      return public.execution_hold(v_run.id, 'needs_connection', 'needs_connection');
    end if;
    -- 수신자 · 대상은 하나 이상, 모두 허용 목록 안. 대상을 인자에만 적은 단계는 판단할 수 없으므로 막는다
    -- (Notion · GitHub 쓰기 대상은 U6b에서 수신자 항목으로 둔다)
    select count(*) into v_allowed from (
      select 1 from public.execution_recipient_allowlist l
      where l.address in (select jsonb_array_elements_text(v_addresses))
      order by l.address
      for share of l
    ) x;
    if jsonb_array_length(v_addresses) = 0 or v_allowed < jsonb_array_length(v_addresses) then
      return public.execution_hold(v_run.id, 'blocked', 'recipient');
    end if;
    -- 유효한 승인이 없으면 Auto/Full 규칙을 지금 다시 확인한다 (준비 단계의 needs_approval을 믿지 않는다. NULL이면 막는다)
    if public.auto_allowed(v_step.id) is not true and not exists (
      select 1 from public.execution_approvals a
      where a.step_id = v_step.id and a.revoked_at is null and a.expires_at > public.db_now()
        and a.hash = public.approval_hash(v_step.id, a.expires_at)
    ) then
      perform set_config('execution.gate', 'not_approved', true);
      update public.execution_runs set state = 'waiting_approval', hold_reason = null
        where id = v_run.id and (state <> 'waiting_approval' or hold_reason is not null);
      return '{"gate": "not_approved"}';
    end if;
  end if;

  -- 크레딧 (U2 PR4): 단계의 추정치를 가용 잔액과 run의 남은 예산 안에서 예약할 수 있어야 부른다. 모자라면 부르지 않고 run에 이유(credit)를
  -- 남긴다. 단계는 prepared에 남아 지급 뒤 sweep이 이어 간다. 지급으로 풀리지 않는 서버 쪽 문제(요율 · 추정치 없음, 닫힌 예약)는 blocked. 추정치 0인 단계(계획)는 예약하지 않지만, 청구 대상인 초안 단계는 추정치가 있어야 한다.
  -- 예약은 단계마다 한 번이다: 같은 단계의 재시도(내부 효과 다시 준비)는 열린 처음 예약을 그대로 쓴다. 이미 정산 · 해제된 예약으로는 부르지 않는다.
  -- 원장 · 계정은 intent를 얻은 뒤에 쓴다: 그 사이에 다른 단계가 먼저 commit해 건너뛰면 예약이 남지 않게
  if v_step.kind = 'draft' and v_step.estimate_credits <= 0 then
    return public.execution_hold(v_run.id, 'blocked', 'no_estimate');
  end if;
  if v_step.estimate_credits > 0 then
    if exists (select 1 from public.credit_ledger l where l.receipt_key = 'reserve:' || v_step.id::text) then
      if exists (select 1 from public.credit_ledger l
                 where l.receipt_key in ('settle:' || v_step.id::text, 'release:' || v_step.id::text)) then
        return public.execution_hold(v_run.id, 'blocked', 'reservation_closed');
      end if;
    else
      select * into v_account from public.credit_accounts where user_id = v_run.user_id for update;
      select r.version into v_rate from public.credit_rates r where r.active;
      if v_rate is null then
        return public.execution_hold(v_run.id, 'blocked', 'no_rate'); -- 요율을 모르면 새 유료 단계를 보류한다 (A41)
      end if;
      if v_run.budget_credits is not null then
        -- run이 쓴 예산 = 예약 - 해제 (정산은 예약에서 옮겨 가므로 그대로 센다)
        select coalesce(sum(case l.kind when 'reserve' then l.credits when 'release' then -l.credits else 0 end), 0)::integer
          into v_run_used from public.credit_ledger l where l.run_id = v_run.id;
      end if;
      if v_step.estimate_credits > coalesce(v_account.granted - v_account.reserved - v_account.settled, 0)
         or (v_run.budget_credits is not null and v_step.estimate_credits > v_run.budget_credits - v_run_used) then
        return public.execution_hold(v_run.id, 'credit', 'insufficient_credit');
      end if;
      v_reserve := v_step.estimate_credits;
    end if;
  end if;

  perform set_config('execution.gate', 'ok', true);
  update public.execution_runs set state = 'running', hold_reason = null
    where id = v_run.id and (state <> 'running' or hold_reason is not null);

  insert into public.execution_intents (intent_key, user_id, step_id) values (v_step.intent_key, v_step.user_id, v_step.id)
    on conflict (intent_key) do nothing
    returning marker into v_marker;
  if v_marker is null then
    select i.step_id, i.marker into v_held, v_marker from public.execution_intents i where i.intent_key = v_step.intent_key;
    if v_held is null or (v_held = v_step.id and v_step.effect_class <> 'internal') then
      return '{"gate": "stale"}';
    end if;
    if v_held <> v_step.id then
      -- 위 확인과 이 insert 사이에 다른 단계가 먼저 commit했다
      return public.execution_skip(v_step.id, v_run.id, v_held);
    end if;
    -- 같은 내부 효과 단계의 재시도: 표식을 다시 쓴다
  end if;

  if v_reserve > 0 then
    insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key, rate_version)
      values (v_run.user_id, 'reserve', v_reserve, v_run.id, v_step.id, 'reserve:' || v_step.id::text, v_rate);
    update public.credit_accounts set reserved = reserved + v_reserve where user_id = v_run.user_id;
  end if;

  -- lease = 실행 route의 maxDuration(300초) + 여유 30초. 살아 있는 함수의 lease는 만료되지 않는다 (U2 PR6 limits.ts의 LEASE_SECONDS와 같은 값)
  update public.execution_steps set state = 'calling', version = version + 1, lease_owner = p_owner,
    lease_expires_at = public.db_now() + make_interval(secs => 330)
    where id = v_step.id;
  return jsonb_build_object(
    'gate', 'ok', 'marker', v_marker, 'provider', v_step.provider, 'tool', v_step.tool, 'connection', v_step.connection_id,
    'recipients', v_addresses, 'body', v_step.body, 'args', v_step.args
  );
end;
$$;

-- ─────────────────────────────────────────────
-- 2) stop_run: 20261021000000_execution_core와 같고, 멈춘 시각(①)만 적는다
-- ─────────────────────────────────────────────
-- POST /runs/[id]/stop: 다음 단계만 막는다 (calling 중인 호출은 결과를 받는다). 멈춘 뒤의 run 상태, 그 사용자의 run이 없으면 null.
-- 시각은 열린 run을 멈출 때 한 번만 적는다: 이미 끝난(멈춘) run은 바꾸지 않으므로 다시 눌러도 처음 시각 그대로다
create or replace function public.stop_run(p_user_id uuid, p_run_id uuid) returns text
language plpgsql
set search_path = ''
as $$
declare
  v_state text;
begin
  perform set_config('execution.gate', 'stop', true);
  update public.execution_runs set state = 'stopped', stopped_at = coalesce(stopped_at, public.db_now())
    where id = p_run_id and user_id = p_user_id and state in ('queued', 'running', 'waiting_approval');
  select state into v_state from public.execution_runs where id = p_run_id and user_id = p_user_id;
  return v_state;
end;
$$;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). 바꿔 만들어도 권한이 그대로지만 함께 다시 적는다
do $$
declare
  f text;
begin
  foreach f in array array['begin_call', 'stop_run'] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
