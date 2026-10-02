-- U2 PR4: 실행 산출물 · 크레딧 원장 · AI 원가 기록 (docs/EXECUTION.md 12장, K4 = C3 운영자 지급 원장, A45 · A46 · A51).
--
-- - 크레딧은 운영자가 지급한다(grant_credits, 승인된 db query). 구매 · 구독 · 클라이언트 지급 경로는 없다.
-- - begin_call이 단계를 부르기 전에 그 단계의 추정치를 예약한다. 계정 행을 잠가(for update) 같은 사용자의 run끼리 줄을 세우므로
--   잔액을 넘는 예약은 생기지 않는다. 모자라면 부르지 않고 run에 이유(hold_reason 'credit')를 남긴다. 단계는 prepared에 남는다.
-- - 정산은 끝낸 단계의 확정된 청구 대상 원가 × 요율(credit_rates)이고 예약을 넘지 않는다. 남은 예약은 해제한다.
--   청구 대상 원가가 하나라도 미확정이면 정산하지 않고 예약을 그대로 둔다(0원 처리 · 해제 없음, A46).
-- - 부르지 못했거나 실패한 단계의 예약은 run이 끝날 때(또는 끝난 run에서 단계가 나올 때) 트리거가 해제한다.
-- - OpenRouter 원가(execution_usage)는 사용자 크레딧과 따로 남긴다. 시도마다 한 행이라 합계는 다시 물은 시도까지 모두 더한다(A51).
-- - 원장 키(receipt_key)와 generation id는 unique다: 같은 영수증 · 재시도 · 중복 호출이 두 번 차감하거나 두 번 지급하지 않는다.
-- - 쓰기는 서버(service role)만 한다. 앱은 자기 산출물만 RLS로 읽고, 원장 · 계정 · 요율 · 원가는 읽지도 못한다(잔액은 PR6의 GET 합계).
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 코드는 아직 이 표를 쓰지 않는다(PR6, 플래그 꺼짐).

-- 새 표가 기존 표(auth.users · actions · execution_runs · execution_steps)를 외래키로 가리키며 그 표의 잠금을 잡는다:
-- 운영에서 오래 기다리지 않고 실패하게 한다. 잠금을 잡는 첫 문장(첫 create table)에서 시간이 다 되면 그대로 다시 적용한다.
-- 그 뒤에서 실패하면 파일 전체가 한 트랜잭션으로 돌았는지에 따라 남은 객체가 있을 수 있으니, 다시 적용하기 전에 확인한다.
set lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 산출물: 내장 초안 (단계 하나에 하나). 앱이 RLS로 읽는다
-- ─────────────────────────────────────────────
-- 본문은 보관 기간(retain_until)이 지나면 purge_expired_artifacts가 비운다(본문만, 제목 · 기록은 남긴다).
-- 보관 기간은 D9a-1(처리방침)이 정한다. 그때까지 제안값 90일을 열 기본값 한 곳에 둔다 (바꾸면 alter column ... set default).
create table public.execution_artifacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  run_id uuid not null,
  step_id uuid not null unique,
  action_id uuid not null,
  kind text not null check (kind in ('draft')),
  title text not null,
  body text not null,
  marker uuid not null unique,                  -- 그 단계 intent의 표식 (execution_intents.marker)
  model text not null,                          -- 초안을 만든 모델 id
  prompt_version text not null,                 -- DRAFT_PROMPT_VERSION
  retain_until timestamptz not null default now() + interval '90 days',
  body_purged_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  constraint execution_artifacts_purged check (body_purged_at is null or body = ''),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id) on delete cascade,
  foreign key (step_id, user_id) references public.execution_steps (id, user_id) on delete cascade,
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade
);

create index execution_artifacts_action_idx on public.execution_artifacts (user_id, action_id, created_at desc);
create index execution_artifacts_retain_idx on public.execution_artifacts (retain_until) where body_purged_at is null;

-- ─────────────────────────────────────────────
-- 2) 요율: 원가(USD) → 크레딧. 버전을 두고 원장 행이 그 버전을 가리킨다. 지금 쓰는 요율은 active 하나
-- ─────────────────────────────────────────────
-- 원가를 크레딧에 1:1로 옮기지 않는다(A51). c3-v1: 1 크레딧 = $0.001. 요율을 바꾸려면 새 버전을 넣고 active를 옮긴다(승인된 db query)
create table public.credit_rates (
  version text primary key,
  usd_per_credit numeric not null check (usd_per_credit > 0),
  active boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index credit_rates_one_active_idx on public.credit_rates ((true)) where active;

insert into public.credit_rates (version, usd_per_credit, active) values ('c3-v1', 0.001, true);

-- ─────────────────────────────────────────────
-- 3) 계정 · 원장
-- ─────────────────────────────────────────────
-- 계정: 사용자마다 한 행. 원장 합계를 그대로 들고 있어 잠금 대상이 된다 (예약 · 정산 · 해제 · 지급이 이 행을 for update로 잠근다).
-- 가용 = granted - reserved - settled. 제약이 마지막 방어선이다: 어떤 경로로도 가용이 음수가 되지 않는다
create table public.credit_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  granted integer not null default 0,           -- 지급(grant) - 회수(adjust)
  reserved integer not null default 0,          -- 아직 정산 · 해제하지 않은 예약
  settled integer not null default 0,           -- 정산(사용)한 크레딧
  constraint credit_accounts_balance check (granted >= 0 and reserved >= 0 and settled >= 0 and reserved + settled <= granted)
);

-- 원장: 더하기만 한다. 키(receipt_key)가 unique라 같은 일을 두 번 적지 않는다.
--   grant:<지급 id>   운영자 지급(+) · 회수(adjust, -). 지급 id는 운영자가 지급마다 새로 만든 uuid
--   reserve:<step>    begin_call의 예약 (단계마다 한 번, 재시도는 처음 예약을 그대로 쓴다)
--   settle:<step>     확정 원가로 정산 (예약 상한 안)
--   release:<step>    정산하고 남은 예약 · 부르지 못한 단계의 예약 해제
-- run · step 외래키는 지울 때 막는다(no action): 원장은 지우지 않는다. 계정 삭제는 auth.users cascade로 같은 문장 안에서 함께 지워진다
create table public.credit_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('grant', 'adjust', 'reserve', 'settle', 'release')),
  credits integer not null,
  run_id uuid,
  step_id uuid,
  receipt_key text not null unique,
  rate_version text references public.credit_rates (version), -- 예약 · 정산의 요율 (정산은 예약 때 요율로 한다)
  cost_usd numeric,                             -- 정산: 확정된 청구 대상 원가 합계 (USD)
  created_at timestamptz not null default now(),
  constraint credit_ledger_credits check (case kind when 'adjust' then credits < 0 when 'settle' then credits >= 0 else credits > 0 end),
  constraint credit_ledger_key check (case
    when kind in ('reserve', 'settle', 'release') then step_id is not null and run_id is not null and receipt_key = kind || ':' || step_id::text
    else step_id is null and run_id is null and receipt_key like 'grant:%' end),
  constraint credit_ledger_rate check ((kind in ('reserve', 'settle')) = (rate_version is not null)),
  constraint credit_ledger_cost check ((kind = 'settle') = (cost_usd is not null and cost_usd >= 0)),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id),
  foreign key (step_id, user_id) references public.execution_steps (id, user_id)
);

create index credit_ledger_user_idx on public.credit_ledger (user_id, id);
create index credit_ledger_run_idx on public.credit_ledger (run_id) where run_id is not null;
create index credit_ledger_step_idx on public.credit_ledger (step_id) where step_id is not null;

-- ─────────────────────────────────────────────
-- 4) AI 원가 (OpenRouter): 시도마다 한 행. 사용자 청구(원장)와 따로 둔다. 글은 담지 않는다
-- ─────────────────────────────────────────────
-- confirmed: 응답의 usage.cost 또는 generation 조회(reconcile_usage)로 확정한 비용. unconfirmed: 모른다(cost_usd null, 0으로 두지 않는다).
-- generation id가 없는 시도(시간 초과 등)는 조회로 확정할 수 없어 운영자가 정할 때까지 unconfirmed다.
-- billable: 사용자 청구 대상. 초안 단계를 끝낸 호출(complete_internal_step)에서 응답을 받은(generation id가 있는) 시도만 true.
-- 계획 단계 · 실패 · 응답 없이 다시 부른 시도(record_usage) · 응답을 받지 못한 시도는 플랫폼 원가다(청구 근거가 없다).
-- 서버가 단계 종류와 시도 기록으로 정한다(호출자가 넘기지 않는다)
create table public.execution_usage (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  run_id uuid not null,
  step_id uuid not null,
  generation_id text unique,
  model text not null,
  prompt_tokens integer check (prompt_tokens >= 0),
  completion_tokens integer check (completion_tokens >= 0),
  cost_usd numeric check (cost_usd >= 0),
  cost_status text not null check (cost_status in ('confirmed', 'unconfirmed')),
  billable boolean not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint execution_usage_cost check ((cost_status = 'confirmed') = (cost_usd is not null) and (cost_status = 'confirmed') = (confirmed_at is not null)),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id),
  foreign key (step_id, user_id) references public.execution_steps (id, user_id)
);

create index execution_usage_step_idx on public.execution_usage (step_id);
create index execution_usage_run_idx on public.execution_usage (run_id);
create index execution_usage_unconfirmed_idx on public.execution_usage (created_at) where cost_status = 'unconfirmed';

-- ─────────────────────────────────────────────
-- 5) 권한: 앱은 자기 산출물을 읽기만 한다. 원장 · 계정 · 요율 · 원가는 서버만
-- ─────────────────────────────────────────────
alter table public.execution_artifacts enable row level security;
create policy "owner_select" on public.execution_artifacts for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.execution_artifacts from anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['credit_rates', 'credit_accounts', 'credit_ledger', 'execution_usage'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) 지급 (운영자, 승인된 db query · 장부 #16)
-- ─────────────────────────────────────────────
-- 양수는 지급(grant), 음수는 회수(adjust). 지급 id마다 한 번: 같은 id로 다시 부르면 아무것도 하지 않고 false.
-- 같은 id로 다른 사용자 · 다른 양을 주면 실수이므로 오류. 예약 · 정산된 크레딧은 회수할 수 없다(계정 제약)
create function public.grant_credits(p_user_id uuid, p_credits integer, p_grant_id uuid) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_key text := 'grant:' || p_grant_id::text;
  v_count integer;
begin
  if p_user_id is null or p_grant_id is null or coalesce(p_credits, 0) = 0 then
    raise exception 'grant_credits: 잘못된 인자';
  end if;
  insert into public.credit_accounts (user_id) values (p_user_id) on conflict (user_id) do nothing;
  perform 1 from public.credit_accounts where user_id = p_user_id for update;
  insert into public.credit_ledger (user_id, kind, credits, receipt_key)
    values (p_user_id, case when p_credits > 0 then 'grant' else 'adjust' end, p_credits, v_key)
    on conflict (receipt_key) do nothing;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    perform 1 from public.credit_ledger l where l.receipt_key = v_key and l.user_id = p_user_id and l.credits = p_credits;
    if not found then
      raise exception 'grant_credits: 이미 다른 지급에 쓴 id다';
    end if;
    return false;
  end if;
  update public.credit_accounts set granted = granted + p_credits where user_id = p_user_id;
  return true;
end;
$$;

-- ─────────────────────────────────────────────
-- 7) begin_call: 20261021000000_execution_core와 같고, intent + lease 앞에 크레딧 예약만 더했다
-- ─────────────────────────────────────────────
-- prepared → calling. RPC 하나 = READ COMMITTED 트랜잭션 하나, 외부 호출 전에 commit된다 (외부 호출은 이 안에 없다).
-- 순서: stale(단계 · run · 앞 단계) → stopped → 중복(intent) → 실행 주체 → 스위치 → 도구 → (외부만) 보내는 연결 → 수신자 허용 목록
--       → 승인/Auto → 크레딧 → intent + 예약 + lease.
-- 잠금 순서: step → run → 정책 → 실행 주체 → 스위치 → 도구 → 수신자(for share, 여러 행은 키 순서로) → 크레딧 계정(for update).
-- 끄는 쪽의 update는 이 트랜잭션이 끝날 때까지 기다린다. 같은 사용자의 두 예약은 계정 행에서 줄을 선다.
-- 검증한 그대로의 내용을 돌려준다. 실행기는 이 내용만 보낸다.
create or replace function public.begin_call(p_step uuid, p_owner text, p_version integer) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_step public.execution_steps;
  v_run public.execution_runs;
  v_policy public.execution_policies;
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
-- 8) 원가 기록 · 정산 · 해제
-- ─────────────────────────────────────────────
-- 시도 기록(src/lib/ai/llm.ts LlmAttempt 배열 그대로: [{generationId, model, usage?: {prompt_tokens, completion_tokens, cost?}}])을
-- 단계의 원가 행으로 남긴다. 비용이 있으면 확정, 없으면 미확정(0으로 두지 않는다). 같은 generation id는 한 번만 남긴다.
-- 청구 대상(p_billable)이어도 응답을 받지 못한 시도(generation id도 비용도 없음)는 플랫폼 원가로 남긴다: 확인할 수 없는 사용량으로 청구하지 않는다
create function public.credit_insert_usage(p_step uuid, p_attempts jsonb, p_billable boolean) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  if jsonb_typeof(p_attempts) is distinct from 'array' then
    raise exception 'usage: 시도 기록은 배열이어야 한다';
  end if;
  insert into public.execution_usage (user_id, run_id, step_id, generation_id, model, prompt_tokens, completion_tokens,
                                      cost_usd, cost_status, billable, confirmed_at)
  select s.user_id, s.run_id, s.id, a.value->>'generationId', a.value->>'model',
         (a.value->'usage'->>'prompt_tokens')::integer, (a.value->'usage'->>'completion_tokens')::integer,
         (a.value->'usage'->>'cost')::numeric,
         case when a.value->'usage'->>'cost' is null then 'unconfirmed' else 'confirmed' end,
         p_billable and (a.value->>'generationId' is not null or a.value->'usage'->>'cost' is not null),
         case when a.value->'usage'->>'cost' is null then null else public.db_now() end
  from public.execution_steps s, jsonb_array_elements(p_attempts) with ordinality a (value, n)
  where s.id = p_step
  order by a.n
  on conflict (generation_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 끝낸(called) 단계 하나의 예약을 정산한다: 확정된 청구 대상 원가 합계(모든 시도) × 예약 때 요율, 예약을 넘지 않게 올림. 남은 예약은 해제.
-- 예약이 없거나 이미 정산 · 해제했으면 그대로. 아직 끝내지 않은 단계(부르는 중 · 다시 준비 · 결과 불명)는 정산하지 않는다(재시도가 그 예약을 쓴다).
-- 청구 대상 원가가 하나라도 미확정이면, 또는 초안 단계인데 청구 대상 원가 행이 없으면(원가를 모른다) 예약을 둔 채 돌아간다 (A46).
-- 계정 행을 먼저 잠그고 확인한다: 같은 단계의 원가를 두 함수가 동시에 확정해도 뒤의 쪽이 앞의 commit을 보고 한 번만 정산한다.
-- 결과: none · done · pending · unconfirmed · settled
create function public.credit_settle_step(p_step uuid) returns text
language plpgsql
set search_path = ''
as $$
declare
  v_reserve public.credit_ledger;
  v_step public.execution_steps;
  v_cost numeric;
  v_credits integer;
begin
  select * into v_reserve from public.credit_ledger where receipt_key = 'reserve:' || p_step::text;
  if not found then
    return 'none';
  end if;
  -- 정산 · 해제 행은 commit되면 바뀌지 않는다: 이미 닫힌 예약은 계정을 잠그지 않고 돌아간다 (잠근 뒤 다시 확인한다)
  if exists (select 1 from public.credit_ledger
             where receipt_key in ('settle:' || p_step::text, 'release:' || p_step::text)) then
    return 'done';
  end if;
  perform 1 from public.credit_accounts where user_id = v_reserve.user_id for update;
  if exists (select 1 from public.credit_ledger
             where receipt_key in ('settle:' || p_step::text, 'release:' || p_step::text)) then
    return 'done';
  end if;
  select * into v_step from public.execution_steps where id = p_step;
  if v_step.state is distinct from 'called' then
    return 'pending';
  end if;
  if exists (select 1 from public.execution_usage u where u.step_id = p_step and u.billable and u.cost_status = 'unconfirmed')
     or (v_step.kind = 'draft' and not exists (select 1 from public.execution_usage u where u.step_id = p_step and u.billable)) then
    return 'unconfirmed';
  end if;
  select coalesce(sum(u.cost_usd), 0) into v_cost from public.execution_usage u where u.step_id = p_step and u.billable;
  select least(v_reserve.credits, ceil(v_cost / r.usd_per_credit))::integer into v_credits
    from public.credit_rates r where r.version = v_reserve.rate_version;
  insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key, rate_version, cost_usd)
    values (v_reserve.user_id, 'settle', v_credits, v_reserve.run_id, p_step, 'settle:' || p_step::text, v_reserve.rate_version, v_cost);
  if v_reserve.credits > v_credits then
    insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key)
      values (v_reserve.user_id, 'release', v_reserve.credits - v_credits, v_reserve.run_id, p_step, 'release:' || p_step::text);
  end if;
  update public.credit_accounts set reserved = reserved - v_reserve.credits, settled = settled + v_credits
    where user_id = v_reserve.user_id;
  return 'settled';
end;
$$;

-- 끝난 run(done · failed · stopped)에서 부르지 못했거나 실패한 단계(pending · prepared · failed · skipped)의 예약을 해제하고,
-- 끝낸 단계(called)는 정산한다(원가가 미확정이면 예약을 둔다, A46). 부르는 중(calling) · 결과 불명(외부)은 둔다. 해제한 단계 수.
-- run 행을 먼저 잠그고(step → run → 계정 순서) 새로 읽는다: run을 끝내는 함수(stop_run)와 단계를 내보내는 함수(mark_unknown · settle_step)가
-- 동시에 돌아도 뒤에 commit하는 쪽이 앞의 결과를 보고 해제한다. 아래 트리거가 부른다. 다시 불러도 같은 단계를 두 번 해제하지 않는다.
-- 한 트랜잭션에서 여러 run을 부르지 않는다(run → 계정 잠금을 쥔 채 다른 run을 기다리면 교착한다). sweep은 credit_open_ended_runs로 고른 run마다 RPC 한 번
create function public.release_run_credits(p_run_id uuid) returns integer
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_state text;
  v_count integer := 0;
begin
  select state into v_state from public.execution_runs where id = p_run_id for no key update;
  if v_state is null or v_state not in ('done', 'failed', 'stopped') then
    return 0;
  end if;
  for r in
    select l.user_id, l.step_id, l.credits, s.state as step_state
    from public.credit_ledger l
    join public.execution_steps s on s.id = l.step_id
    where l.run_id = p_run_id and l.kind = 'reserve'
    order by l.id
  loop
    if r.step_state = 'called' then
      perform public.credit_settle_step(r.step_id);
      continue;
    end if;
    if r.step_state not in ('pending', 'prepared', 'failed', 'skipped') then
      continue;
    end if;
    perform 1 from public.credit_accounts where user_id = r.user_id for update;
    continue when exists (select 1 from public.credit_ledger
                          where receipt_key in ('settle:' || r.step_id::text, 'release:' || r.step_id::text));
    insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key)
      values (r.user_id, 'release', r.credits, p_run_id, r.step_id, 'release:' || r.step_id::text);
    update public.credit_accounts set reserved = reserved - r.credits where user_id = r.user_id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- 열린 예약(정산 · 해제 전)이 남은 끝난 run (U2 PR6 sweep의 보조 안전망: 이 run마다 release_run_credits를 RPC 한 번씩). 잠그지 않고 읽기만 한다.
-- 끝낸 단계의 원가가 미확정이라 예약을 둔 run도 들어 있다 (release_run_credits가 그대로 둔다)
create function public.credit_open_ended_runs(p_limit integer default 100) returns table (run_id uuid)
language sql stable
set search_path = ''
as $$
  select l.run_id from public.credit_ledger l join public.execution_runs r on r.id = l.run_id
  where l.kind = 'reserve' and r.state in ('done', 'failed', 'stopped')
    and not exists (select 1 from public.credit_ledger x
                    where x.receipt_key in ('settle:' || l.step_id::text, 'release:' || l.step_id::text))
  group by l.run_id
  order by min(l.id)
  limit p_limit
$$;

-- 남은 예약을 그 자리에서 해제 · 정산하는 두 순간 (어느 함수가 바꿨든):
--   ① run이 끝 상태로 간다 (stop_run · settle_step 실패 · 다시 준비 한도 · finish_run)
--   ② 부르던 단계 · 결과 불명 단계가 나온다 (calling · unknown_outcome → called · prepared · failed 등). 이미 끝난(멈춘) run이면
--      나온 단계를 정산 · 해제하고, run이 끝나지 않았으면 아무것도 안 한다
-- run · 단계 상태를 바꾸는 것은 서버 함수뿐이라 호출자 권한으로 돈다. 연결 끊기의 set null(서버가 아닌 역할일 수 있다)은
-- state를 update 대상으로 적지 않아(update of state) 이 트리거를 부르지 않는다
create function public.credit_release_trigger() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'execution_runs' then
    perform public.release_run_credits(new.id);
  else
    perform public.release_run_credits(new.run_id);
  end if;
  return null;
end;
$$;

create trigger execution_runs_release_credits
  after update of state on public.execution_runs
  for each row
  when (new.state is distinct from old.state and new.state in ('done', 'failed', 'stopped'))
  execute function public.credit_release_trigger();

create trigger execution_steps_release_credits
  after update of state on public.execution_steps
  for each row
  when (old.state in ('calling', 'unknown_outcome') and new.state is distinct from old.state)
  execute function public.credit_release_trigger();

-- ─────────────────────────────────────────────
-- 9) 실행기가 부르는 함수 (U2 PR6)
-- ─────────────────────────────────────────────
-- 내부 효과 단계를 끝낸다: calling → called + 산출물(초안 단계) + 원가 행 + 정산을 한 트랜잭션에서. lease 소유자만, 아니면 false.
-- 계획 단계는 산출물 없이, 초안 단계는 산출물과 함께 부른다(어긋나면 오류). 결과(p_outcome)와 run 끝내기는 settle_step과 같다.
-- 원가: p_attempts는 이 호출의 모든 시도(다시 물은 시도 포함). 초안 단계의 시도는 청구 대상, 계획 단계는 플랫폼 원가.
-- p_artifact: {title, body, model, prompt_version}. 같은 함수를 두 번 불러도(응답 뒤 쓰기 재시도) 두 번째는 false, 이중 차감 0
create function public.complete_internal_step(
  p_step uuid, p_owner text, p_receipt jsonb, p_attempts jsonb, p_artifact jsonb default null, p_outcome text default null
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_step public.execution_steps;
begin
  select * into v_step from public.execution_steps where id = p_step and state = 'calling' and lease_owner = p_owner for update;
  if not found then
    return false;
  end if;
  if v_step.effect_class <> 'internal' then
    raise exception 'complete_internal_step: 내부 효과 단계가 아니다';
  end if;
  if (v_step.kind = 'draft') <> (p_artifact is not null) then
    raise exception 'complete_internal_step: 초안 단계는 산출물과 함께, 다른 단계는 산출물 없이 끝낸다';
  end if;
  if jsonb_typeof(p_attempts) is distinct from 'array' then
    raise exception 'complete_internal_step: 시도 기록은 배열이어야 한다';
  end if;
  -- 초안을 받았으면 모델을 한 번 이상 불렀다: 시도 기록이 비면 원가를 모르는 것이지 0원이 아니다 (A46)
  if v_step.kind = 'draft' and jsonb_array_length(p_attempts) = 0 then
    raise exception 'complete_internal_step: 초안 단계의 시도 기록이 없다';
  end if;
  -- 산출물 · 원가 행을 단계를 끝내기 전에 쓴다: 끝내며 run이 끝나면(finish_run) 트리거가 바로 정산하므로 그때 원가 행이 있어야 한다
  if p_artifact is not null then
    insert into public.execution_artifacts (user_id, run_id, step_id, action_id, kind, title, body, marker, model, prompt_version)
    values (
      v_step.user_id, v_step.run_id, v_step.id, (select r.action_id from public.execution_runs r where r.id = v_step.run_id), 'draft',
      p_artifact->>'title', p_artifact->>'body',
      (select i.marker from public.execution_intents i where i.intent_key = v_step.intent_key and i.step_id = v_step.id),
      p_artifact->>'model', p_artifact->>'prompt_version'
    );
  end if;
  perform public.credit_insert_usage(p_step, p_attempts, v_step.kind = 'draft');
  if not public.settle_step(p_step, p_owner, 'called', p_receipt, p_outcome) then
    raise exception 'complete_internal_step: 잠근 단계를 끝내지 못했다'; -- 위에서 잠그고 확인했으므로 일어나지 않는다
  end if;
  perform public.credit_settle_step(p_step);
  return true;
end;
$$;

-- 끝내지 못한 호출의 시도를 원가로 남긴다: 형식 오류 · 시간 초과로 실패(settle_step 'failed')하거나 응답 없이 다시 준비(mark_unknown)하기 전,
-- 또는 lease를 잃은 함수가 뒤늦게 응답을 받았을 때. 모두 플랫폼 원가(billable false)라 청구 · 단계 상태를 바꾸지 않는다. 남긴 행 수.
-- 실행기는 단계를 내보내기(settle_step · mark_unknown) 전에 먼저 부른다: 그 사이에 죽어도 원가 행은 남고, 단계는 lease 만료로 다시 준비된다
create function public.record_usage(p_step uuid, p_attempts jsonb) returns integer
language plpgsql
set search_path = ''
as $$
begin
  return public.credit_insert_usage(p_step, p_attempts, false);
end;
$$;

-- 미확정 원가를 확정한다: sweep이 generation 조회(src/lib/ai/generation.ts)의 total_cost로, generation id가 없는 행은 운영자가 정한 값으로.
-- 미확정 행만 바꾼다(같은 확정을 두 번 받아도 한 번). 그 단계를 끝냈고(called) 청구 대상 원가가 모두 확정되면 정산한다.
-- 원가 행 → 계정 순서로 잠근다: 한 트랜잭션에서 여러 행을 확정하지 말고 RPC 한 번에 한 행씩 부른다(겹친 sweep끼리 교착하지 않게)
create function public.reconcile_usage(p_usage_id bigint, p_cost_usd numeric) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_step uuid;
begin
  if p_cost_usd is null or p_cost_usd < 0 then
    raise exception 'reconcile_usage: 잘못된 비용';
  end if;
  update public.execution_usage set cost_usd = p_cost_usd, cost_status = 'confirmed', confirmed_at = public.db_now()
    where id = p_usage_id and cost_status = 'unconfirmed'
    returning step_id into v_step;
  if v_step is null then
    return false;
  end if;
  perform public.credit_settle_step(v_step);
  return true;
end;
$$;

-- 보관 기간이 지난 산출물의 본문을 비운다(제목 · 기록 · 원가는 남긴다). 비운 수. retention cron 연결은 D9a-1 뒤(U2 PR8)
create function public.purge_expired_artifacts() returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.execution_artifacts set body = '', body_purged_at = public.db_now()
    where body_purged_at is null and retain_until < public.db_now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). begin_call은 바꿔 만들어도 권한이 그대로지만 함께 다시 적는다
do $$
declare
  f text;
begin
  foreach f in array array[
    'grant_credits', 'begin_call', 'credit_insert_usage', 'credit_settle_step', 'release_run_credits', 'credit_open_ended_runs', 'credit_release_trigger',
    'complete_internal_step', 'record_usage', 'reconcile_usage', 'purge_expired_artifacts'
  ] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
