-- 0.2.0 실행 additive 확장 (구현 계획 C1, 런타임 계약 4장): 값 · 열 · 연결별 정책 표를 더한다. 실행하는 코드는 이 묶음에 없다.
--
-- 이 파일이 하는 일은 저장 계약뿐이다. 새 값을 DB가 받는다고 실행이 생기지 않는다:
--   - run 만들기(create_run)는 지금처럼 goal draft만, 계획 붙이기(append_step)는 plan · draft · external만 받는다(아래 3).
--     예전에는 CHECK가 막았고, CHECK가 넓어졌으므로 같은 자리(함수)에서 막는다.
--   - 실행기(src/lib/execution/executor.ts)는 goal이 draft가 아니거나 단계 종류가 plan · draft가 아니면 모델도 외부도 부르지 않는다.
--   - begin_call · 승인 hash · auto_allowed · 사용자 정책(execution_policies)은 한 글자도 바꾸지 않았다(이 파일은 그 함수를 다시 만들지 않는다).
--     연결별 정책 행이 있어도 실행 허용 · begin_call 결과 · 승인 hash가 달라지지 않는다. 런타임 소비와 승인 hash 결합은 뒤 단계(C2 · D1 · E1)다.
--   - conversation_id · context_id · bundle_context_version · directive_version은 "어느 대화 · 범위에서 어떤 지시 버전으로 시작했나"의 기록이다.
--     어떤 gate · 전이 · 판정에도 입력이 아니다(I04 · I14, ARCH06 · ARCH07). work_contexts의 멤버십 · 보관 · 병합 · context_version이 바뀌어도 실행은 변하지 않는다.
--
-- 현재 값은 20261021000000_execution_core.sql 한 곳에만 정의돼 있다(이후 파일이 이 CHECK를 바꾸지 않았다. V02):
--   goal ('draft') · hold_reason ('blocked','actor','needs_connection','credit') · outcome ('draft_ready','needs_connection','needs_input')
--   · execution_steps.kind ('plan','draft','external'). 아래는 기존 값을 모두 두고 런타임 계약 4장의 값만 더한다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
-- 기존 표(execution_runs · execution_steps · conversations · work_contexts · connections)에 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다
-- (그때는 그대로 다시 적용한다. 한 트랜잭션이라 남는 객체가 없다).
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) execution_runs 열: 대화 · 범위 · 지시 버전. 모두 서버(service role)만 쓴다(앱은 select만)
-- ─────────────────────────────────────────────
-- 부모(대화 · 범위)가 지워져도 실행 기록은 남고 참조만 비운다(on delete set null (열)). 부모와 (id, user_id) 복합 외래키라 남의 대화 · 범위를 가리키지 못한다.
-- directive_version은 사용자 지시가 바뀐 횟수(기본 1), bundle_context_version은 맥락 묶음을 만들 때의 work_contexts.context_version이다.
-- 둘은 별개이며 서로 파생하지 않는다. 범위를 지워도 bundle_context_version은 그때 묶은 버전의 기록으로 남는다(context_id만 비운다).
-- agent_session_id · message_id · target_at · acceptance는 이 묶음에 없다(D1 이후).
alter table public.execution_runs add column conversation_id uuid;
alter table public.execution_runs add column context_id uuid;
alter table public.execution_runs add column directive_version integer not null default 1;
alter table public.execution_runs add column bundle_context_version integer;

alter table public.execution_runs
  add constraint execution_runs_directive_version_check check (directive_version >= 1),
  add constraint execution_runs_bundle_context_version_check check (bundle_context_version >= 1),
  add constraint execution_runs_conversation_fkey foreign key (conversation_id, user_id)
    references public.conversations (id, user_id) on delete set null (conversation_id),
  add constraint execution_runs_context_fkey foreign key (context_id, user_id)
    references public.work_contexts (id, user_id) on delete set null (context_id);

-- 부모를 지울 때 참조를 비우는 갱신이 표 전체를 훑지 않게
create index execution_runs_conversation_idx on public.execution_runs (conversation_id) where conversation_id is not null;
create index execution_runs_context_idx on public.execution_runs (context_id) where context_id is not null;

-- ─────────────────────────────────────────────
-- 2) CHECK 교체: 기존 값을 모두 두고 런타임 계약 4장의 값만 더한다
-- ─────────────────────────────────────────────
-- 기존 CHECK는 이름 없는 열 제약이라 이름을 카탈로그에서 찾는다. 열마다 정확히 하나여야 한다(아니면 아무것도 바꾸지 않고 실패한다).
do $$
declare
  spec record;
  v_count integer;
  v_name text;
begin
  for spec in
    select * from (values
      ('public.execution_runs'::regclass, 'goal'),
      ('public.execution_runs'::regclass, 'hold_reason'),
      ('public.execution_runs'::regclass, 'outcome'),
      ('public.execution_steps'::regclass, 'kind')
    ) as t (tbl, col)
  loop
    select count(*), min(c.conname) into v_count, v_name
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.conrelid = spec.tbl and c.contype = 'c' and array_length(c.conkey, 1) = 1 and a.attname = spec.col;
    if v_count <> 1 then
      raise exception 'C1: %.% CHECK 제약이 %개다 (정확히 1개여야 한다)', spec.tbl, spec.col, v_count;
    end if;
    execute format('alter table %s drop constraint %I', spec.tbl, v_name);
  end loop;
end;
$$;

-- goal: 사용자 에이전트 위임(agent) · 발송(send, D5) · 후속 연락(followup, D6). 검토는 goal이 아니라 단계다
alter table public.execution_runs
  add constraint execution_runs_goal_check check (goal in ('draft', 'agent', 'send', 'followup')),
  -- 막힌 이유: 공유 자원 잠금(resource) · 에이전트에 닿지 않음(agent_unreachable)
  add constraint execution_runs_hold_reason_check
    check (hold_reason in ('blocked', 'actor', 'needs_connection', 'credit', 'resource', 'agent_unreachable')),
  -- 결과: 미지원 동작(needs_capability) · 검토 한도 소진(review_failed) · 에이전트 결과 검증 통과(agent_done)
  add constraint execution_runs_outcome_check
    check (outcome in ('draft_ready', 'needs_connection', 'needs_input', 'needs_capability', 'review_failed', 'agent_done'));

-- 단계 종류: 외부 효과(agent_dispatch · agent_message · agent_cancel · send)와 내부 효과(review · check · observe). 효과 종류는 execution_tools가 정한다
alter table public.execution_steps
  add constraint execution_steps_kind_check
    check (kind in ('plan', 'draft', 'external', 'agent_dispatch', 'agent_message', 'agent_cancel', 'review', 'check', 'send', 'observe'));

-- ─────────────────────────────────────────────
-- 3) 새 값이 실행 입구로 새지 않게: create_run · append_step이 지금 실행하는 값만 받는다
-- ─────────────────────────────────────────────
-- 20261021000000_execution_core.sql과 같고(서명 · 본문 · 권한 그대로), goal 확인만 맨 앞에 더했다. 새 goal을 실행하는 단계(C2 · D1 · E1)가 이 확인을 넓힌다.
create or replace function public.create_run(p_user_id uuid, p_action_id uuid, p_goal text, p_request text, p_budget_credits integer default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_policy uuid;
  v_run uuid;
begin
  if p_goal is distinct from 'draft' then
    raise exception 'create_run: goal % 는 아직 실행하지 않는다 (draft만)', p_goal using errcode = '22023';
  end if;
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

-- 20261021000000_execution_core.sql과 같고, 단계 종류 확인만 붙이기 직전에 더했다 (run이 없거나 끝났거나 순번이 어긋난 호출은 예전처럼 null).
-- 붙일 수 있는 종류는 지금 실행기가 아는 plan · draft · external뿐이다. external은 실행기가 준비도 부르기도 하지 않는다(발송은 U6a)
create or replace function public.append_step(p_run_id uuid, p_seq integer, p_step jsonb)
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
  if p_step->>'kind' is null or p_step->>'kind' not in ('plan', 'draft', 'external') then
    raise exception 'append_step: 단계 종류 % 는 아직 붙이지 않는다 (plan · draft · external만)', p_step->>'kind' using errcode = '22023';
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
-- 4) 연결별 정책 최소형 (DR07): 저장 계약뿐이다
-- ─────────────────────────────────────────────
-- 연결 하나에 정책 하나. 기존 사용자 정책(execution_policies, 사용자당 1행)은 그대로 기본값이다.
-- 이 표를 읽는 실행 코드는 없다: begin_call · auto_allowed · approval_hash는 이 표를 보지 않는다(행이 있어도 실행 허용 · 승인 hash가 달라지지 않는다).
-- 연결별 정책을 begin_call이 소비하고 승인 hash의 정책 버전에 이 version을 넣는 것은 뒤 단계(C2 · D1 · E1)다. 그때까지 "있다"는 것은 "쓴다"가 아니다.
--
-- - mode: execution_policies.mode와 같은 값. 기본 manual(가장 좁은 쪽). 이 값이 auto · full이어도 차단 스위치(execution_controls)가 막는다.
-- - allowed_tools: 이 연결로 실행할 수 있는 도구 이름. 비어 있으면(기본) 아무것도 허용하지 않는다. NULL · 빈 문자열 원소는 거절한다.
-- - allowed_targets: 이 연결로 닿을 수 있는 대상 목록(배열). 원소의 모양은 쓰는 단계(D5 · adapter)가 정한다: 여기서는 배열인지만 본다.
-- - standing_budget_credits: Auto/Full의 standing 예산(A47). 0(기본)이면 없음. 음수 금지.
-- - version: 내용이 바뀔 때마다 정확히 1씩 올린다(아래 트리거). 승인이 묶일 값이라 몰래 바꾸거나 되돌리거나 건너뛰지 못한다.
-- 연결을 지우면 정책도 함께 지워진다(on delete cascade): 같은 계정을 다시 연결해도 옛 정책을 물려받지 않는다. 다른 사용자의 연결은 복합 외래키가 막는다.
create table public.execution_connection_policies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  connection_id uuid not null,
  mode text not null default 'manual' check (mode in ('manual', 'auto', 'full')),
  allowed_tools text[] not null default '{}',
  allowed_targets jsonb not null default '[]' check (jsonb_typeof(allowed_targets) = 'array'),
  standing_budget_credits integer not null default 0 check (standing_budget_credits >= 0),
  version integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, connection_id),
  unique (id, user_id),
  constraint execution_connection_policies_tools_valid
    check (array_position(allowed_tools, null) is null and array_position(allowed_tools, '') is null),
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade
);

-- 몰래 바꾸기 막기: 소유자 · 연결 · 만든 시각은 못 바꾼다(정책을 다른 연결로 옮겨 권한이 번지지 않게).
-- 내용(mode · allowed_tools · allowed_targets · standing_budget_credits)이 바뀌면 version은 정확히 old + 1이어야 한다.
-- 내용이 그대로면 version도 그대로이거나 old + 1(승인을 무효로 만들려는 올림)이다. 내려가거나 건너뛰는 갱신은 거절한다.
-- 동시 갱신은 `update ... set version = version + 1 where version = <읽은 값>`로 한 쪽만 이긴다(나중 쪽은 행 잠금을 기다린 뒤 조건이 어긋나 0행).
create function public.execution_connection_policies_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.user_id, new.connection_id, new.created_at) is distinct from (old.id, old.user_id, old.connection_id, old.created_at) then
    raise exception 'execution_connection_policies: id · user_id · connection_id · created_at은 바꿀 수 없다' using errcode = '23514';
  end if;
  if new.version <> old.version + 1
     and (new.version <> old.version
          or (new.mode, new.allowed_tools, new.allowed_targets, new.standing_budget_credits)
             is distinct from (old.mode, old.allowed_tools, old.allowed_targets, old.standing_budget_credits)) then
    raise exception 'execution_connection_policies: version은 내용이 바뀔 때 정확히 + 1이어야 한다 (% -> %)', old.version, new.version using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger execution_connection_policies_guard
  before update on public.execution_connection_policies
  for each row execute function public.execution_connection_policies_guard();
create trigger execution_connection_policies_set_updated_at
  before update on public.execution_connection_policies
  for each row execute function public.set_updated_at();

-- 권한: 앱은 자기 행을 RLS로 읽기만 한다(owner_all 정책 + select 권한, 기존 execution_policies와 같은 모양). 쓰기는 서버(service role)만.
alter table public.execution_connection_policies enable row level security;
create policy "owner_all" on public.execution_connection_policies for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.execution_connection_policies from anon, authenticated;
grant select on public.execution_connection_policies to authenticated;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). 바꿔 만든 함수도 권한이 그대로지만 함께 다시 적는다. 트리거 함수도 막는다
do $$
declare
  f text;
begin
  foreach f in array array['create_run', 'append_step', 'execution_connection_policies_guard'] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;

commit;
