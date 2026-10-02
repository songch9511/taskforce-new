-- U2 실행 코어 (docs/EXECUTION.md): run · step · 승인 · intent · 차단 스위치 · 허용 목록 · 실행 이벤트와 상태 전이 함수.
-- A29 fixture의 SQL을 운영으로 옮겼다. A29(tests/execution/a29.test.ts)는 이제 이 마이그레이션을 그대로 시험한다.
--
-- - 판단(정규화 · 정책 · 승인 hash · 스위치 · 허용 목록 · 중복)은 이 함수들에만 있다. 실행기(U2 PR6)는 RPC로 부른다.
-- - 쓰기는 서버(service role)만 한다. 앱은 자기 정책 · run · step · 승인을 RLS로 읽기만 한다. 운영 표는 클라이언트가 읽지도 못한다.
-- - 시각은 DB 시각(db_now() = now()). 호출자가 넘긴 시각을 쓰지 않는다.
-- - 닫힌 쪽으로 시작한다: global 스위치가 막힌 채이고, 행이 없는 공급자 · 모드 · 도구도 막힌다. 켜기는 승인된 db query로 한다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 코드는 아직 이 표를 쓰지 않는다(PR6, 플래그 꺼짐).

-- rate_limit_events 제약을 바꾸며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (다시 적용하면 된다)
set lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 0) 시각 · 주소 정규화
-- ─────────────────────────────────────────────
-- 운영은 now()뿐이다. 테스트는 적용 뒤 테스트 안에서만 app.now 판으로 바꾼다 (세션 설정은 풀링된 연결에 남을 수 있다).
create function public.db_now() returns timestamptz
language sql stable
set search_path = ''
as $$ select now() $$;

-- 정규화 규칙은 하나: 승인 hash · intent key · Auto 규칙 · 수신자 허용 목록이 모두 이것을 쓴다 (앞뒤 공백 제거 · 소문자 · 중복 제거 · 정렬)
create function public.norm_address(p text) returns text
language sql immutable
set search_path = ''
as $$ select lower(trim(p)) $$;

create function public.norm_addresses(p jsonb) returns jsonb
language sql immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(distinct public.norm_address(x->>'address') order by public.norm_address(x->>'address')), '[]')
  from jsonb_array_elements(p) x
$$;

-- 단계의 수신자 목록: [{address, origin}]. 출처(origin)는 서버가 주소가 어디서 왔는지 보고 정한다 (user · source · tool_output · model).
-- 모델 출력이 정하지 않는다: 모델이 제안한 주소는 늘 model이고, 사용자가 정한 주소만 user다 (EXECUTION 7장)
create function public.execution_recipients_valid(p jsonb) returns boolean
language sql immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'array' and not exists (
    select 1 from jsonb_array_elements(p) x
    where jsonb_typeof(x) <> 'object'
       or coalesce(trim(x->>'address'), '') = ''
       or coalesce(x->>'origin', '') not in ('user', 'source', 'tool_output', 'model')
  )
$$;

-- ─────────────────────────────────────────────
-- 1) 정책: 사용자마다 하나. 기본 Manual
-- ─────────────────────────────────────────────
create table public.execution_policies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mode text not null default 'manual' check (mode in ('manual', 'auto', 'full')),
  auto_recipients jsonb not null default '[]' check (jsonb_typeof(auto_recipients) = 'array'), -- Auto/Full 규칙: 승인 없이 보내도 되는 주소
  version integer not null default 1,           -- 규칙을 바꾸면 올린다. 승인 hash · Auto 판단이 이 값에 묶인다
  created_at timestamptz not null default now(),
  unique (user_id),
  unique (id, user_id)
);

-- ─────────────────────────────────────────────
-- 2) run: Action 하나에 대한 실행 한 번. 상태는 Action 상태와 따로 둔다 (EXECUTION 3장)
-- ─────────────────────────────────────────────
create table public.execution_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  action_id uuid not null,
  policy_id uuid not null,
  goal text not null check (goal in ('draft')),
  request text not null,                        -- 사용자가 청한 내용
  budget_credits integer check (budget_credits > 0),
  state text not null default 'queued'
    check (state in ('queued', 'running', 'waiting_approval', 'done', 'failed', 'stopped')),
  -- begin_call이 막은 이유: 스위치 · 도구 · 수신자 / 실행 주체 / 보내는 연결 없음 / 크레딧(U2 PR4)
  hold_reason text check (hold_reason in ('blocked', 'actor', 'needs_connection', 'credit')),
  outcome text check (outcome in ('draft_ready', 'needs_connection', 'needs_input')),
  created_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (policy_id, user_id) references public.execution_policies (id, user_id) on delete cascade
);

create index execution_runs_user_created_idx on public.execution_runs (user_id, created_at desc);
create index execution_runs_action_idx on public.execution_runs (action_id);
create index execution_runs_open_idx on public.execution_runs (created_at) where state in ('queued', 'running', 'waiting_approval');

-- ─────────────────────────────────────────────
-- 3) step: 함수 호출 한 번 = 단계 하나. 전이는 CAS (state + version)
-- ─────────────────────────────────────────────
create table public.execution_steps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  run_id uuid not null,
  seq integer not null check (seq > 0),
  kind text not null check (kind in ('plan', 'draft', 'external')),
  provider text not null,
  tool text not null,
  -- internal: 외부 상태를 바꾸지 않는 효과(내장 계획 · 초안의 AI 호출). execution_tools와 같아야 begin_call을 지난다
  effect_class text not null default 'external' check (effect_class in ('internal', 'external')),
  purpose text not null,
  occurrence integer not null default 1,        -- 회차. 사용자의 명시적 다시 보내기에서만 늘어난다
  connection_id uuid,                           -- 보내는 연결(계정). 계획의 일부라 pending을 떠나면 바꿀 수 없다
  recipients jsonb not null default '[]' check (public.execution_recipients_valid(recipients)), -- [{address, origin}], 출처는 서버가 정한다
  body text not null default '',
  args jsonb not null default '{}',
  source_revision integer not null default 1,
  estimate_credits integer not null default 0 check (estimate_credits >= 0),
  state text not null default 'pending'
    check (state in ('pending', 'prepared', 'calling', 'called', 'unknown_outcome', 'failed', 'skipped')),
  version integer not null default 0,
  attempt integer not null default 0 check (attempt >= 0), -- 내부 효과를 lease 만료 · 응답 없음 뒤 다시 준비한 횟수 (최대 2)
  policy_version integer,                       -- 준비할 때의 정책 버전
  needs_approval boolean,                       -- 준비 단계의 정책 평가 (앱이 승인 요청으로 보여 줄 값). begin_call은 이 값을 믿지 않는다
  intent_key text,
  lease_owner text,
  lease_expires_at timestamptz,
  unknown_since timestamptz,
  receipt jsonb,
  created_at timestamptz not null default now(),
  unique (run_id, seq),
  unique (id, user_id),
  constraint prepared_has_policy_version check (state = 'pending' or policy_version is not null),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id) on delete cascade,
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete set null (connection_id)
);

create index execution_steps_calling_idx on public.execution_steps (lease_expires_at) where state = 'calling';
create index execution_steps_unknown_idx on public.execution_steps (unknown_since) where state = 'unknown_outcome';
create index execution_steps_connection_idx on public.execution_steps (connection_id) where connection_id is not null;

-- 계획(공급자 · 도구 · 효과 종류 · 목적 · 회차 · 연결 · 수신자 · 본문 · 인자 · 원문 revision)을 바꾸면 늘 pending으로 되돌리고 version을 올린다.
-- 부르는 중 · 끝난 단계는 못 바꾼다. 예외: 연결을 끊으면(connections 삭제 → set null) 그 단계의 기록은 상태 그대로 남긴다.
create function public.execution_steps_replan() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.connection_id,
      new.recipients, new.body, new.args, new.source_revision)
     is distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.connection_id,
      old.recipients, old.body, old.args, old.source_revision) then
    if old.state not in ('pending', 'prepared') then
      if new.connection_id is null
         and (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.recipients, new.body, new.args, new.source_revision)
             is not distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.recipients, old.body, old.args, old.source_revision) then
        return new;
      end if;
      raise exception 'step % is %: plan is frozen', old.id, old.state;
    end if;
    new.state := 'pending';
    new.version := old.version + 1;
    new.intent_key := null;
    new.policy_version := null;
    new.needs_approval := null;
  end if;
  return new;
end;
$$;

create trigger execution_steps_replan
  before update on public.execution_steps
  for each row execute function public.execution_steps_replan();

-- ─────────────────────────────────────────────
-- 4) 승인 · intent
-- ─────────────────────────────────────────────
create table public.execution_approvals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  step_id uuid not null,
  hash text not null,                           -- 사용자가 본 계획의 approval_hash
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (step_id, user_id) references public.execution_steps (id, user_id) on delete cascade
);

create index execution_approvals_step_idx on public.execution_approvals (step_id);

-- write-ahead intent. 표식(marker)은 외부로 나가는 유일한 값이다: 수신자 · Action id · 본문을 담지 않는 임의 값.
-- intent key는 DB 밖으로 나가지 않는다.
create table public.execution_intents (
  intent_key text primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  step_id uuid not null,
  marker uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now(),
  foreign key (step_id, user_id) references public.execution_steps (id, user_id) on delete cascade
);

create index execution_intents_step_idx on public.execution_intents (step_id);

-- ─────────────────────────────────────────────
-- 5) 운영 표: 차단 스위치 · 도구 목록 · 허용 목록 (EXECUTION 6 · 7장). 클라이언트는 읽지도 못한다
-- ─────────────────────────────────────────────
-- 세 층(전체 · 공급자 · 모드). 행이 없는 공급자 · 모드는 막힌 것으로 본다
create table public.execution_controls (
  scope text not null check (scope in ('global', 'provider', 'mode')),
  key text not null,
  blocked boolean not null default false,
  primary key (scope, key)
);

-- 처음 상태: 전체가 막혀 있다. 풀어도 Manual만 (auto · full 막힘). 공급자는 내장(taskforce)만
insert into public.execution_controls (scope, key, blocked) values
  ('global', '*', true),
  ('provider', 'taskforce', false),
  ('mode', 'manual', false),
  ('mode', 'auto', true),
  ('mode', 'full', true);

-- 실행할 수 있는 도구. 목록 밖 도구 · 효과 종류가 다른 단계는 막힌다 (U6a가 자기 마이그레이션에서 gmail.send를 더한다)
create table public.execution_tools (
  provider text not null,
  tool text not null,
  effect_class text not null check (effect_class in ('internal', 'external')),
  primary key (provider, tool)
);

insert into public.execution_tools (provider, tool, effect_class) values
  ('taskforce', 'plan', 'internal'),
  ('taskforce', 'draft', 'internal');

-- 실행 주체: 건넴 전까지 운영자 계정만 (시드 없음, 승인된 db query로 넣는다)
create table public.execution_actors (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 발송 수신자 · 쓰기 대상: 시험 동안 이 목록 안만 (정규화한 주소)
create table public.execution_recipient_allowlist (
  address text primary key check (address = public.norm_address(address)),
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 6) 실행 이벤트: 상태 · hold가 바뀔 때만 같은 트랜잭션에서 남긴다 (거절마다 남기지 않는다). 글은 담지 않는다
-- ─────────────────────────────────────────────
create table public.execution_events (
  id bigint generated always as identity primary key,
  -- auth.users를 직접 가리키지 않는다: 계정 삭제 중 연결 삭제(set null)가 단계를 다시 계획하며 이벤트를 남길 때
  -- cascade 순서와 상관없이 실패하지 않게. run 복합 FK가 user_id를 확인하고 함께 지운다
  user_id uuid not null,
  run_id uuid not null,
  step_id uuid,
  type text not null check (type in ('run', 'step', 'hold')),
  from_state text,
  to_state text,
  gate text,                                    -- 전이를 일으킨 판단 (begin_call의 gate, lease_expired, stop 등)
  at timestamptz not null default now(),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id) on delete cascade,
  foreign key (step_id, user_id) references public.execution_steps (id, user_id) on delete cascade
);

create index execution_events_run_idx on public.execution_events (run_id, at);
create index execution_events_step_idx on public.execution_events (step_id) where step_id is not null;

-- 함수는 상태를 바꾸기 전에 트랜잭션 안에서만 유효한 execution.gate를 정한다 (set_config(..., true)). 트리거가 그 값을 적는다.
create function public.execution_runs_log() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_gate text := nullif(current_setting('execution.gate', true), '');
begin
  if tg_op = 'INSERT' then
    insert into public.execution_events (user_id, run_id, type, to_state, gate, at)
    values (new.user_id, new.id, 'run', new.state, v_gate, public.db_now());
    return null;
  end if;
  if new.state is distinct from old.state then
    insert into public.execution_events (user_id, run_id, type, from_state, to_state, gate, at)
    values (new.user_id, new.id, 'run', old.state, new.state, v_gate, public.db_now());
  end if;
  if new.hold_reason is distinct from old.hold_reason then
    insert into public.execution_events (user_id, run_id, type, from_state, to_state, gate, at)
    values (new.user_id, new.id, 'hold', old.hold_reason, new.hold_reason, v_gate, public.db_now());
  end if;
  return null;
end;
$$;

create function public.execution_steps_log() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_gate text := nullif(current_setting('execution.gate', true), '');
begin
  if tg_op = 'INSERT' then
    insert into public.execution_events (user_id, run_id, step_id, type, to_state, gate, at)
    values (new.user_id, new.run_id, new.id, 'step', new.state, v_gate, public.db_now());
  elsif new.state is distinct from old.state then
    insert into public.execution_events (user_id, run_id, step_id, type, from_state, to_state, gate, at)
    values (new.user_id, new.run_id, new.id, 'step', old.state, new.state, v_gate, public.db_now());
  end if;
  return null;
end;
$$;

create trigger execution_runs_log
  after insert or update on public.execution_runs
  for each row execute function public.execution_runs_log();

create trigger execution_steps_log
  after insert or update on public.execution_steps
  for each row execute function public.execution_steps_log();

-- ─────────────────────────────────────────────
-- 7) 권한: 앱은 자기 정책 · run · step · 승인을 읽기만 한다. 운영 표 · intent · 이벤트는 서버만
-- ─────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array['execution_policies', 'execution_runs', 'execution_steps', 'execution_approvals'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "owner_select" on public.%I for select to authenticated using (user_id = (select auth.uid()))',
      t
    );
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
  foreach t in array array['execution_intents', 'execution_controls', 'execution_tools', 'execution_actors',
                           'execution_recipient_allowlist', 'execution_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 8) 판단 함수
-- ─────────────────────────────────────────────
-- 승인 없이 나갈 수 있는가: Auto/Full + 수신자가 하나 이상 + 모든 수신자가 사용자에게서 + 규칙 안 + 준비할 때의 정책 버전 그대로.
-- 모르면(NULL) 아니다. 수신자가 없는 단계(대상을 인자에만 적은 것)는 규칙으로 판단할 수 없으므로 아니다
create function public.auto_allowed(p_step uuid) returns boolean
language sql stable
set search_path = ''
as $$
  select p.mode in ('auto', 'full') and s.policy_version = p.version
    and jsonb_array_length(s.recipients) > 0
    and not exists (select 1 from jsonb_array_elements(s.recipients) x where coalesce(x->>'origin', '') <> 'user')
    and public.norm_addresses(s.recipients)
        <@ (select coalesce(jsonb_agg(public.norm_address(a)), '[]') from jsonb_array_elements_text(p.auto_recipients) a)
  from public.execution_steps s
  join public.execution_runs r on r.id = s.run_id
  join public.execution_policies p on p.id = r.policy_id
  where s.id = p_step
$$;

-- 승인 hash: 공급자 · 도구 · 효과 종류 · 연결 · 인자 · 수신자 · 본문 hash · 원문 revision · 정책 버전 · 만료(UTC, 초 단위).
-- 하나라도 바뀌면 값이 바뀐다
create function public.approval_hash(p_step uuid, p_expires timestamptz) returns text
language sql stable
set search_path = ''
as $$
  select encode(sha256(convert_to(jsonb_build_object(
    'provider', s.provider, 'tool', s.tool, 'effect_class', s.effect_class,
    'connection', s.connection_id, 'args', s.args, 'recipients', public.norm_addresses(s.recipients),
    'body_sha256', encode(sha256(convert_to(s.body, 'UTF8')), 'hex'), 'source_revision', s.source_revision, 'policy_version', p.version,
    'expires_at', to_char(date_trunc('second', p_expires) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text, 'UTF8')), 'hex')
  from public.execution_steps s
  join public.execution_runs r on r.id = s.run_id
  join public.execution_policies p on p.id = r.policy_id
  where s.id = p_step
$$;

-- ─────────────────────────────────────────────
-- 9) run · step 만들기 (실행기 · route)
-- ─────────────────────────────────────────────
-- POST /api/v1/runs: 열린 Action에 run을 만들고 첫 단계(계획, 내부 효과)를 둔다. 깨우기를 놓쳐도 sweep이 이 단계부터 이어 간다.
-- 정책이 없으면 기본(Manual)으로 만든다.
create function public.create_run(p_user_id uuid, p_action_id uuid, p_goal text, p_request text, p_budget_credits integer default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_policy uuid;
  v_run uuid;
begin
  perform 1 from public.actions a where a.id = p_action_id and a.user_id = p_user_id and a.status = 'open';
  if not found then
    raise exception 'open action not found' using errcode = 'P0002';
  end if;
  perform set_config('execution.gate', 'create', true);
  insert into public.execution_policies (user_id) values (p_user_id) on conflict (user_id) do nothing;
  select id into v_policy from public.execution_policies where user_id = p_user_id;
  insert into public.execution_runs (user_id, action_id, policy_id, goal, request, budget_credits)
    values (p_user_id, p_action_id, v_policy, p_goal, p_request, p_budget_credits)
    returning id into v_run;
  insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose)
    values (p_user_id, v_run, 1, 'plan', 'taskforce', 'plan', 'internal', 'plan');
  return v_run;
end;
$$;

-- planner가 다음 단계를 붙인다. run을 잠그고, 끝나지 않은 run에 기대한 순번(지금 마지막 + 1)일 때만 넣는다 (CAS).
-- 두 함수가 같은 계획을 붙이려 하면 하나만 들어간다. 효과 종류는 도구 목록이 정한다 (목록 밖이면 external, begin_call이 막는다).
-- 회차는 늘 1이다: 모델 · planner는 회차를 늘리지 못한다 (사용자의 명시적 다시 보내기는 따로 만든다, EXECUTION 4장).
-- 수신자 출처는 서버 코드가 주소가 어디서 왔는지 보고 정한다. 모델 출력의 출처 값을 그대로 넘기지 않는다 (형식은 제약이 확인한다).
-- p_step: {kind, provider, tool, purpose, connection_id?, recipients?, body?, args?, source_revision?, estimate_credits?}
create function public.append_step(p_run_id uuid, p_seq integer, p_step jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_user uuid;
  v_state text;
  v_step uuid;
begin
  select user_id, state into v_user, v_state from public.execution_runs where id = p_run_id for no key update;
  if v_state is null or v_state not in ('queued', 'running') then
    return null;
  end if;
  if p_seq <> (select coalesce(max(seq), 0) + 1 from public.execution_steps where run_id = p_run_id) then
    return null;
  end if;
  perform set_config('execution.gate', 'append', true);
  insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose,
                                      connection_id, recipients, body, args, source_revision, estimate_credits)
  values (
    v_user, p_run_id, p_seq, p_step->>'kind', p_step->>'provider', p_step->>'tool',
    coalesce((select t.effect_class from public.execution_tools t where t.provider = p_step->>'provider' and t.tool = p_step->>'tool'), 'external'),
    p_step->>'purpose', (p_step->>'connection_id')::uuid,
    coalesce(p_step->'recipients', '[]'), coalesce(p_step->>'body', ''), coalesce(p_step->'args', '{}'),
    coalesce((p_step->>'source_revision')::integer, 1), coalesce((p_step->>'estimate_credits')::integer, 0)
  )
  returning id into v_step;
  return v_step;
end;
$$;

-- ─────────────────────────────────────────────
-- 10) 상태 전이 (실행기). 모든 입구(route · 자기 호출 · sweep)가 같은 함수를 지난다
-- ─────────────────────────────────────────────
-- pending → prepared: intent key · 정책 버전 · 승인 필요 표시. 첫 단계를 준비하면 run이 running으로 간다.
-- intent key = (Action, 공급자, 도구, 목적, 정규화한 대상, 회차). 내부 효과는 단계마다 하나다 (외부 상태가 없어 다른 단계와 중복을 따지지 않는다).
create function public.prepare_step(p_step uuid, p_version integer) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('execution.gate', 'prepare', true);
  update public.execution_steps s set
    state = 'prepared',
    version = s.version + 1,
    policy_version = p.version,
    intent_key = case
      when s.effect_class = 'internal' then concat_ws('|', 'internal', s.id)
      else concat_ws('|', r.action_id, s.provider, s.tool, s.purpose, public.norm_addresses(s.recipients)::text, s.occurrence)
    end
  from public.execution_runs r
  join public.execution_policies p on p.id = r.policy_id
  where s.id = p_step and s.state = 'pending' and s.version = p_version and r.id = s.run_id;
  if not found then
    return false;
  end if;
  update public.execution_steps
    set needs_approval = (effect_class = 'external' and public.auto_allowed(id) is not true)
    where id = p_step;
  update public.execution_runs set state = 'running'
    where id = (select run_id from public.execution_steps where id = p_step) and state = 'queued';
  return true;
end;
$$;

-- 앞의 판단에서 막혔다: run에 이유를 남기고(바뀔 때만) gate를 돌려준다
create function public.execution_hold(p_run_id uuid, p_reason text, p_gate text) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('execution.gate', p_gate, true);
  update public.execution_runs set hold_reason = p_reason where id = p_run_id and hold_reason is distinct from p_reason;
  return jsonb_build_object('gate', p_gate);
end;
$$;

-- 같은 목적을 다른 단계가 이미 가졌다: 승인을 묻지 않고 건너뛴다(승인을 기다릴 이유가 없어졌다). 남은 단계가 없으면 run도 끝낸다
create function public.execution_skip(p_step uuid, p_run_id uuid, p_held uuid) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('execution.gate', 'duplicate', true);
  update public.execution_steps
    set state = 'skipped', version = version + 1, receipt = coalesce(receipt, '{}') || jsonb_build_object('duplicate_of', p_held)
    where id = p_step;
  update public.execution_runs set state = 'running', hold_reason = null
    where id = p_run_id and (state <> 'running' or hold_reason is not null);
  perform public.finish_run(p_run_id, null);
  return '{"gate": "duplicate"}';
end;
$$;

-- prepared → calling. RPC 하나 = READ COMMITTED 트랜잭션 하나, 외부 호출 전에 commit된다 (외부 호출은 이 안에 없다).
-- 순서: stale(단계 · run · 앞 단계) → stopped → 중복(intent) → 실행 주체 → 스위치 → 도구 → (외부만) 보내는 연결 → 수신자 허용 목록
--       → 승인/Auto → intent + lease.
-- 잠금 순서: step → run → 정책 → 실행 주체 → 스위치 → 도구 → 수신자(for share, 여러 행은 키 순서로). 끄는 쪽의 update는 이 트랜잭션이 끝날 때까지 기다린다.
-- 검증한 그대로의 내용을 돌려준다. 실행기는 이 내용만 보낸다.
create function public.begin_call(p_step uuid, p_owner text, p_version integer) returns jsonb
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

  -- 같은 목적을 다른 단계가 이미 가졌거나, 외부 효과 단계가 이미 표식을 가졌으면(한 번 불렀다) 다시 부르지 않는다.
  -- 같은 표식을 다시 쓰는 것은 내부 효과의 재시도뿐이다
  select i.step_id into v_held from public.execution_intents i where i.intent_key = v_step.intent_key;
  if v_held is not null and (v_held <> v_step.id or v_step.effect_class <> 'internal') then
    return public.execution_skip(v_step.id, v_run.id, v_held);
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

  perform set_config('execution.gate', 'ok', true);
  update public.execution_runs set state = 'running', hold_reason = null
    where id = v_run.id and (state <> 'running' or hold_reason is not null);

  insert into public.execution_intents (intent_key, user_id, step_id) values (v_step.intent_key, v_step.user_id, v_step.id)
    on conflict (intent_key) do nothing
    returning marker into v_marker;
  if v_marker is null then
    select i.step_id, i.marker into v_held, v_marker from public.execution_intents i where i.intent_key = v_step.intent_key;
    if v_held is null then
      return '{"gate": "stale"}';
    end if;
    if v_held <> v_step.id or v_step.effect_class <> 'internal' then
      -- 위 확인과 이 insert 사이에 다른 단계가 먼저 commit했다
      return public.execution_skip(v_step.id, v_run.id, v_held);
    end if;
    -- 같은 내부 효과 단계의 재시도: 표식을 다시 쓴다
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

-- 남은 단계가 없으면(모두 called · skipped) running → done. 끝낸 결과(outcome)를 함께 적는다
create function public.finish_run(p_run_id uuid, p_outcome text default null) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(current_setting('execution.gate', true), '') = '' then
    perform set_config('execution.gate', 'finish', true);
  end if;
  -- run을 먼저 잠근다: 같은 run에 단계를 붙이는 append_step(run 잠금)이 commit된 뒤의 단계를 센다
  perform 1 from public.execution_runs where id = p_run_id for no key update;
  update public.execution_runs r set state = 'done', outcome = coalesce(p_outcome, r.outcome)
  where r.id = p_run_id and r.state = 'running'
    and not exists (select 1 from public.execution_steps s where s.run_id = p_run_id and s.state not in ('called', 'skipped'));
  return found;
end;
$$;

-- calling → called | failed: lease를 가진 함수만. failed면 run failed.
-- called면 남은 단계가 없을 때 run done. 단 계획 단계는 결과(p_outcome)를 줄 때만 끝낸다: planner는 다음 단계를 붙이고(append_step)
-- 계획 단계를 끝내거나, 끝났다고 정하며(p_outcome) 끝낸다. 결과 없이 끝내고 아무것도 붙이지 않았으면 다음 깨우기의 finish_run이 닫는다.
create function public.settle_step(p_step uuid, p_owner text, p_state text, p_receipt jsonb, p_outcome text default null)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_run uuid;
  v_kind text;
begin
  if p_state not in ('called', 'failed') then
    raise exception 'settle_step: 잘못된 상태 %', p_state;
  end if;
  perform set_config('execution.gate', 'response', true);
  update public.execution_steps set state = p_state, receipt = p_receipt, version = version + 1, lease_owner = null, lease_expires_at = null
    where id = p_step and state = 'calling' and lease_owner = p_owner
    returning run_id, kind into v_run, v_kind;
  if v_run is null then
    return false;
  end if;
  if p_state = 'failed' then
    update public.execution_runs set state = 'failed' where id = v_run and state = 'running';
  elsif p_outcome is not null or v_kind <> 'plan' then
    perform public.finish_run(v_run, p_outcome);
  end if;
  return true;
end;
$$;

-- 내부 효과(AI 호출)는 외부 상태가 없다: 결과 불명 대신 다시 준비한다(attempt + 1, 같은 표식). 다시 준비가 2번을 넘으면 failed · run failed.
-- p_owner가 있으면 그 lease 소유자의 단계만(응답 없음), 없으면 lease가 끝난 단계만(sweep: 겹친 sweep이 새 lease를 받은 단계를 건드리지 않는다)
create function public.execution_retry_internal(p_steps uuid[], p_owner text default null) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  if coalesce(current_setting('execution.gate', true), '') = '' then
    perform set_config('execution.gate', 'retry', true);
  end if;
  with moved as (
    update public.execution_steps s set
      state = case when s.attempt < 2 then 'prepared' else 'failed' end,
      attempt = case when s.attempt < 2 then s.attempt + 1 else s.attempt end,
      receipt = case when s.attempt < 2 then s.receipt else jsonb_build_object('error', 'retries_exhausted') end,
      version = s.version + 1, lease_owner = null, lease_expires_at = null
    where s.id = any (p_steps) and s.state = 'calling' and s.effect_class = 'internal'
      and (case when p_owner is null then s.lease_expires_at < public.db_now() else s.lease_owner = p_owner end)
    returning s.run_id, s.state
  ), failed_runs as (
    update public.execution_runs r set state = 'failed'
    where r.state = 'running' and r.id in (select m.run_id from moved m where m.state = 'failed')
    returning r.id
  )
  select count(*)::integer into v_count from moved;
  return v_count;
end;
$$;

-- lease를 가진 함수가 응답을 못 받았다(시간 초과 · 연결 끊김). 외부 효과는 다시 부르지 않고 결과 불명, 내부 효과는 다시 준비
create function public.mark_unknown(p_step uuid, p_owner text) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_effect text;
begin
  perform set_config('execution.gate', 'no_response', true);
  select effect_class into v_effect from public.execution_steps
    where id = p_step and state = 'calling' and lease_owner = p_owner
    for update;
  if v_effect is null then
    return false;
  end if;
  if v_effect = 'internal' then
    return public.execution_retry_internal(array[p_step], p_owner) = 1;
  end if;
  update public.execution_steps set state = 'unknown_outcome', unknown_since = public.db_now(), version = version + 1, lease_owner = null
    where id = p_step;
  return true;
end;
$$;

-- sweep ①: lease가 끝난 calling. 외부 효과는 다시 부르지 않고 결과 불명, 내부 효과는 다시 준비. 바뀐 단계 수
create function public.sweep_expire() returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_external integer;
begin
  perform set_config('execution.gate', 'lease_expired', true);
  update public.execution_steps set state = 'unknown_outcome', unknown_since = public.db_now(), version = version + 1, lease_owner = null
    where state = 'calling' and lease_expires_at < public.db_now() and effect_class = 'external';
  get diagnostics v_external = row_count;
  return v_external + public.execution_retry_internal(array(
    select id from public.execution_steps where state = 'calling' and lease_expires_at < public.db_now() and effect_class = 'internal'
  ));
end;
$$;

-- sweep ②: readback이 표식을 찾았다. unknown_outcome → called (receipt는 readback에서 온다)
create function public.readback_settle(p_step uuid, p_receipt jsonb) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_run uuid;
begin
  perform set_config('execution.gate', 'readback', true);
  update public.execution_steps set state = 'called', receipt = p_receipt, version = version + 1, lease_owner = null, lease_expires_at = null
    where id = p_step and state = 'unknown_outcome'
    returning run_id into v_run;
  if v_run is null then
    return false;
  end if;
  perform public.finish_run(v_run, null);
  return true;
end;
$$;

-- ─────────────────────────────────────────────
-- 11) 사용자 행동 (route). 다른 사용자의 행은 없는 것처럼 다룬다
-- ─────────────────────────────────────────────
-- 사용자가 볼 계획의 hash. 만료는 초 단위 (앱의 Date는 밀리초라 마이크로초가 사라진다)
create function public.show_plan(p_user_id uuid, p_step uuid) returns table (hash text, expires_at timestamptz)
language sql stable
set search_path = ''
as $$
  select public.approval_hash(s.id, t.e), t.e
  from public.execution_steps s, (select date_trunc('second', public.db_now() + interval '1 hour') as e) t
  where s.id = p_step and s.user_id = p_user_id
$$;

-- POST /approvals/[id]: 사용자가 본 hash를 지금 계획으로 다시 계산해 같을 때만 기록한다. 만료는 지금부터 1시간 안 (show_plan과 같은 창).
-- 아직 부르지 않은 단계(pending · prepared)만 승인한다
create function public.approve_step(p_user_id uuid, p_step uuid, p_shown_hash text, p_expires timestamptz) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_run uuid;
begin
  if p_expires <= public.db_now() or p_expires > public.db_now() + interval '1 hour' then
    return false;
  end if;
  select run_id into v_run from public.execution_steps where id = p_step and user_id = p_user_id and state in ('pending', 'prepared');
  if v_run is null or public.approval_hash(p_step, p_expires) is distinct from p_shown_hash then
    return false;
  end if;
  perform set_config('execution.gate', 'approved', true);
  insert into public.execution_approvals (user_id, step_id, hash, expires_at) values (p_user_id, p_step, p_shown_hash, p_expires);
  update public.execution_runs set state = 'running' where id = v_run and state = 'waiting_approval';
  return true;
end;
$$;

-- 승인 철회. 철회 뒤에는 이어서 실행해도 부르지 않는다.
-- 단계를 먼저 잠가(begin_call과 같은 순서) 진행 중인 begin_call과 줄을 세운다: begin_call이 먼저면 그 commit을 기다린 뒤 철회하고,
-- 철회가 먼저면 begin_call이 철회된 승인을 본다. 철회한 승인 수와 그때의 단계 상태를 돌려준다.
-- 단계가 prepared · pending이 아니면(calling · called 등) 이미 부르기 시작해 철회가 늦었다. 그 사용자의 단계가 없으면 행이 없다
create function public.revoke_approval(p_user_id uuid, p_step uuid) returns table (revoked integer, step_state text)
language plpgsql
set search_path = ''
as $$
declare
  v_state text;
  v_count integer;
begin
  select s.state into v_state from public.execution_steps s where s.id = p_step and s.user_id = p_user_id for update;
  if not found then
    return;
  end if;
  update public.execution_approvals set revoked_at = public.db_now()
    where step_id = p_step and user_id = p_user_id and revoked_at is null;
  get diagnostics v_count = row_count;
  return query select v_count, v_state;
end;
$$;

-- POST /runs/[id]/stop: 다음 단계만 막는다 (calling 중인 호출은 결과를 받는다). 멈춘 뒤의 run 상태, 그 사용자의 run이 없으면 null
create function public.stop_run(p_user_id uuid, p_run_id uuid) returns text
language plpgsql
set search_path = ''
as $$
declare
  v_state text;
begin
  perform set_config('execution.gate', 'stop', true);
  update public.execution_runs set state = 'stopped'
    where id = p_run_id and user_id = p_user_id and state in ('queued', 'running', 'waiting_approval');
  select state into v_state from public.execution_runs where id = p_run_id and user_id = p_user_id;
  return v_state;
end;
$$;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). 트리거 함수도 막는다 (트리거로 불릴 때는 권한을 보지 않는다)
do $$
declare
  f text;
begin
  foreach f in array array[
    'db_now', 'norm_address', 'norm_addresses', 'execution_recipients_valid', 'execution_steps_replan', 'execution_runs_log',
    'execution_steps_log', 'auto_allowed', 'approval_hash', 'create_run', 'append_step', 'prepare_step', 'execution_hold',
    'execution_skip', 'begin_call', 'finish_run', 'settle_step', 'execution_retry_internal', 'mark_unknown', 'sweep_expire',
    'readback_settle', 'show_plan', 'approve_step', 'revoke_approval', 'stop_run'
  ] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 12) run 만들기의 사용자별 횟수 제한 (POST /api/v1/runs, U2 PR6). 시도 기록은 같은 표(rate_limit_events)에, 글은 남기지 않는다
-- ─────────────────────────────────────────────
alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check (kind in ('ask', 'connection_start', 'action_create', 'run_create'));

-- 20261009000000_action_create_rate_limit와 같고, rate_limit_events로 세는 종류에 run_create만 더했다.
create or replace function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
  v_window interval := make_interval(secs => p_window_seconds);
  v_since timestamptz;
  v_nth timestamptz;
begin
  if p_user_id is null or p_max < 1 or p_window_seconds < 1 then
    raise exception 'take_rate_limit: 잘못된 인자';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || p_kind));
  v_since := clock_timestamp() - v_window;

  if p_kind = 'missing_report' then
    select r.created_at into v_nth from public.missing_reports r
    where r.user_id = p_user_id and r.created_at > v_since
    order by r.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.missing_reports (user_id, created_at) values (p_user_id, clock_timestamp());
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create') then
    select e.created_at into v_nth from public.rate_limit_events e
    where e.user_id = p_user_id and e.kind = p_kind and e.created_at > v_since
    order by e.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.rate_limit_events (user_id, kind, created_at) values (p_user_id, p_kind, clock_timestamp());
  else
    raise exception 'take_rate_limit: 모르는 종류 %', p_kind;
  end if;
  return null;
end;
$$;

revoke execute on function public.take_rate_limit from public, anon, authenticated;
grant execute on function public.take_rate_limit to service_role;
