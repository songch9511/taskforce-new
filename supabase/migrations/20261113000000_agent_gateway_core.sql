-- 0.2.0 에이전트 게이트웨이 저장 계약 (구현 계획 D1a, Assistant 계약 v3 3.4 · 3.6 · 3.8 · 4.2, 런타임 계약 5장): 표 넷 · 열 · 제약 · 인덱스 · RLS · 권한뿐이다.
-- 에이전트를 실행하는 코드는 이 묶음에 없다.
--
-- 이 파일이 하는 일은 저장 계약뿐이다 (20261109000000_execution_additive_contract와 같은 원칙). 새 표 · 열 · 값을 DB가 받는다고 에이전트 단계가 실행되지 않는다:
--   - 실행 입구 함수(create_run · append_step · begin_call · approve_* · 실행기)는 한 글자도 바꾸지 않았다. 이 파일은 함수를 만들지도 바꾸지도 않는다.
--     그래서 이 파일 뒤에도 create_run은 goal 'draft'만, append_step은 plan · draft · external만 받고, goal 'agent' run은 만들어지지 않는다.
--     (kind 'conversation'도 goal 'agent'뿐이다. 입구는 D1c가 연다 — 그 전에는 이 표 · 열에 쓰는 서버 코드가 없다.)
--   - execution_tools · execution_controls에 행을 더하지 않았다 (agent:* 도구 · 공급자 스위치는 입구를 실제로 쓰는 D1c-1에서 연다).
--   - 앱(authenticated)은 새 표 넷을 읽기만 한다. 쓰기는 모두 서버(service role)다. 사용자 정책 · 승인 hash · begin_call은 이 표들을 보지 않는다.
--   - bridge_commands(D2a) · agent_path_leases(D3c) · conversations 열 · conversation_messages 열(D1b) · context_members의 agent_session 종류 · execution_artifacts 열은 이 묶음에 없다.
--
-- 새 표 (모두 user_id + RLS + 부모와 (id, user_id) 복합 외래키. 남의 행을 가리키지 못한다):
--   bridges           Mac bridge의 최소 identity (아키텍처 9.1). 기기 식별의 해시와 상태뿐 — 이름 · 이메일 · 토큰 열이 없다.
--   agent_connections 에이전트 연결 (계약 v3 4.2). v1 `connections` 표는 건드리지 않는다(AC-20: provider CHECK를 넓히면 배포된 앱의 연결 목록이 깨진다).
--                     로그인 계정 · 이메일 · 토큰 열이 없다(I16).
--   agent_sessions    에이전트 세션 binding (런타임 계약 5장 · 계약 v3 3.4 · 3.8).
--   agent_tasks       원격 작업 (런타임 계약 5장 · 계약 v3 3.4 · 3.6). 세션당 진행 중 턴 하나는 DB 백스톱 인덱스가 마지막 방어선이다.
-- 기존 표 확장:
--   execution_runs    kind('task' | 'conversation') · agent_session_id · reviewed_turn_seq (계약 v3 3.4). 기존 행은 kind 'task'.
--   execution_events  type에 'agent' + 사건 봉투 열 (런타임 계약 5장 "사건 봉투"). 기존 트리거(execution_runs_log 등)는 바꾸지 않았다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
-- 기존 표(execution_runs · execution_events)에 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다
-- (그때는 그대로 다시 적용한다. 한 트랜잭션이라 남는 객체가 없다).
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) bridges: Mac bridge 최소 identity (아키텍처 9.1)
-- ─────────────────────────────────────────────
-- device_ref는 bridge가 보고하는 기기 식별의 해시다(기기 이름 · 이메일 · 로그인 계정 금지). 한 사용자의 같은 기기는 bridge 하나(unique).
-- capabilities는 bridge가 보고한 값 = "설치돼 있고 이 버전"뿐이다(계약 v3 4.3). 실제로 되는지(예: 쓰기 gate)는 이 값이 증명하지 않는다.
-- status 'revoked' ↔ revoked_at: 해제한 시각이 있어야 해제 상태이고, 해제 상태면 시각이 있어야 한다.
create table public.bridges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  device_ref text not null check (char_length(device_ref) between 1 and 200),
  status text not null default 'active' check (status in ('active', 'revoked')),
  capabilities jsonb not null default '{}' check (jsonb_typeof(capabilities) = 'object'),
  last_heartbeat_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, device_ref),
  constraint bridges_revoked_consistent check ((status = 'revoked') = (revoked_at is not null))
);

-- ─────────────────────────────────────────────
-- 2) agent_connections: 에이전트 연결 (계약 v3 4.2)
-- ─────────────────────────────────────────────
-- adapter는 서버 registry 문자열이다. 모양은 src/lib/api/contract.ts의 agentAdapterIdSchema와 같다(`agent:` + 소문자 · 숫자 · _ · -, 64자 이하).
-- bridge가 지워지면(해제 뒤 정리) 연결은 남고 bridge_id만 비운다. 같은 사용자의 bridge만 가리킬 수 있다.
create table public.agent_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  adapter text not null,
  bridge_id uuid,
  device_ref text check (char_length(device_ref) <= 200),
  status text not null default 'active' check (status in ('active', 'error', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  constraint agent_connections_adapter_check check (adapter ~ '^agent:[a-z0-9][a-z0-9_-]*$' and char_length(adapter) <= 64),
  constraint agent_connections_bridge_fkey foreign key (bridge_id, user_id)
    references public.bridges (id, user_id) on delete set null (bridge_id)
);

-- ─────────────────────────────────────────────
-- 3) agent_sessions: 에이전트 세션 (런타임 계약 5장 · 계약 v3 3.4 · 3.8)
-- ─────────────────────────────────────────────
-- external_session_id는 에이전트 쪽 세션 id, workspace_ref는 bridge가 정한 작업 폴더 식별이다(경로 원문이 아니다).
-- status: bound(Taskforce가 쓰는 중) · external(사용자가 터미널에서 이어 씀, 3.8) · unreachable · closed.
-- bound_action_id는 "처음 맡긴 이슈"의 기록뿐이다(3.4): 세션의 현재 이슈는 거기서 정하지 않는다. Action이 지워지면 비운다.
-- last_turn_seq는 마지막으로 시작한 턴 번호(새 턴을 시작하는 서버가 세션 행을 잠그고 올린다 — D1c-1), last_event_seq는 마지막으로 적용한 bridge 사건 순서다.
-- 연결이 지워지면 세션도 지워진다(on delete cascade). 한 연결 안에서 같은 외부 세션은 하나다.
create table public.agent_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  connection_id uuid not null,
  external_session_id text not null check (char_length(external_session_id) between 1 and 200),
  workspace_ref text not null check (char_length(workspace_ref) between 1 and 500),
  display_name text not null default '' check (char_length(display_name) <= 200),
  status text not null default 'bound' check (status in ('bound', 'external', 'unreachable', 'closed')),
  bound_action_id uuid,
  last_turn_seq integer not null default 0 check (last_turn_seq >= 0),
  last_event_seq bigint not null default 0 check (last_event_seq >= 0),
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (connection_id, external_session_id),
  constraint agent_sessions_connection_fkey foreign key (connection_id, user_id)
    references public.agent_connections (id, user_id) on delete cascade,
  constraint agent_sessions_bound_action_fkey foreign key (bound_action_id, user_id)
    references public.actions (id, user_id) on delete set null (bound_action_id)
);

-- ─────────────────────────────────────────────
-- 4) execution_runs 열 (계약 v3 3.4)
-- ─────────────────────────────────────────────
-- kind: 'task'(Taskforce가 맡긴 작업) · 'conversation'(에이전트 직접 대화 = 세션 × 이슈마다 열린 run 하나). 기존 행은 모두 'task'.
-- conversation은 goal 'agent'뿐이다. 이 CHECK가 있어도 goal 'agent' run을 만드는 입구(create_run)는 열려 있지 않다(위 머리 주석).
-- agent_session_id: 세션이 지워져도 run(기록)은 남고 참조만 비운다(on delete set null (열)). 같은 사용자의 세션만 가리킨다.
-- reviewed_turn_seq: 마지막 검토가 본 턴(result_ready 계산의 원천). 0이면 아직 검토한 턴이 없다.
alter table public.execution_runs add column kind text not null default 'task';
alter table public.execution_runs add column agent_session_id uuid;
alter table public.execution_runs add column reviewed_turn_seq integer not null default 0;

alter table public.execution_runs
  add constraint execution_runs_kind_check check (kind in ('task', 'conversation')),
  add constraint execution_runs_reviewed_turn_seq_check check (reviewed_turn_seq >= 0),
  add constraint execution_runs_conversation_goal check (kind = 'task' or goal = 'agent'),
  add constraint execution_runs_agent_session_fkey foreign key (agent_session_id, user_id)
    references public.agent_sessions (id, user_id) on delete set null (agent_session_id);

-- 세션 × 이슈마다 열린 대화 run은 하나다: 동시 요청 둘이 와도 둘째는 unique 위반(서버가 첫째 run을 다시 읽어 쓴다). 끝난 run(done · failed · stopped)은 세지 않는다
create unique index execution_runs_open_conversation_idx on public.execution_runs (agent_session_id, action_id)
  where kind = 'conversation' and state not in ('done', 'failed', 'stopped');
-- 세션을 지울 때 참조를 비우는 갱신이 표 전체를 훑지 않게
create index execution_runs_agent_session_idx on public.execution_runs (agent_session_id) where agent_session_id is not null;

-- ─────────────────────────────────────────────
-- 5) agent_tasks: 원격 작업 (런타임 계약 5장 · 계약 v3 3.4 · 3.6)
-- ─────────────────────────────────────────────
-- 작업 하나 = 세션의 턴 하나(직접 대화) 또는 맡긴 작업 하나. 상태 전이는 서버 코드가 한다 — 이 표는 값의 모양만 막는다.
-- state: dispatched → accepted → running → (awaiting_answer) → idle(턴의 끝, 다음 사용자 메시지를 기다림) | completed | failed | cancelled | unreachable.
--   idle은 completed가 아니다(3.4). unreachable은 실패가 아니다: 직전 상태를 last_live_state에 적고 reconcile을 기다린다(그래서 last_live_state는 unreachable이 아니다).
-- pending_question: 모양({question_id, kind, text, ...})은 서버 zod가 검증한다(계약 v3 3.6). DB는 JSON 객체인지와 awaiting_answer일 때 있는지만 본다.
--   질문 글은 여기에만 둔다(사건 payload에 담지 않는다).
-- result_revision은 검증된 현재 결과 회차(사건 도착만으로 올리지 않는다), expected_result_revision은 다음 요청에 실어 보낸 결과 회차다.
-- message_id는 이 턴을 시작한 사용자 메시지다. 메시지가 지워져도 작업(기록)은 남고 참조만 비운다.
-- run이 지워지면 작업도 지워진다(on delete cascade). 단계(step_id)는 비운다.
create table public.agent_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  run_id uuid not null,
  step_id uuid,
  agent_session_id uuid not null,
  message_id uuid,
  external_task_id text check (char_length(external_task_id) <= 200),
  turn_seq integer check (turn_seq >= 1),
  state text not null default 'dispatched'
    check (state in ('dispatched', 'accepted', 'running', 'awaiting_answer', 'idle', 'completed', 'failed', 'cancelled', 'unreachable')),
  last_live_state text
    check (last_live_state in ('dispatched', 'accepted', 'running', 'awaiting_answer', 'idle', 'completed', 'failed', 'cancelled')),
  directive_version integer not null default 1 check (directive_version >= 1),
  result_revision integer not null default 0 check (result_revision >= 0),
  expected_result_revision integer not null default 1 check (expected_result_revision >= 1),
  pending_question jsonb check (pending_question is null or jsonb_typeof(pending_question) = 'object'),
  cancel_requested_at timestamptz,
  last_event_seq bigint not null default 0 check (last_event_seq >= 0),
  last_seen_at timestamptz,
  result_refs jsonb not null default '[]' check (jsonb_typeof(result_refs) = 'array'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  constraint agent_tasks_awaiting_question check (state <> 'awaiting_answer' or pending_question is not null),
  constraint agent_tasks_run_fkey foreign key (run_id, user_id)
    references public.execution_runs (id, user_id) on delete cascade,
  constraint agent_tasks_step_fkey foreign key (step_id, user_id)
    references public.execution_steps (id, user_id) on delete set null (step_id),
  constraint agent_tasks_session_fkey foreign key (agent_session_id, user_id)
    references public.agent_sessions (id, user_id) on delete cascade,
  constraint agent_tasks_message_fkey foreign key (message_id, user_id)
    references public.conversation_messages (id, user_id) on delete set null (message_id)
);

-- DB 백스톱 두 개 (계약 v3 3.4). 실제 직렬화는 서버가 새 턴을 시작할 때 세션 행을 `for update`로 잡고 한다(D1c-1) — 이 인덱스는 마지막 방어선이다.
-- ① 세션당 진행 중 턴은 하나(dispatched · accepted · running · awaiting_answer). idle · completed · failed · cancelled는 여럿 있어도 된다.
create unique index agent_tasks_in_progress_idx on public.agent_tasks (agent_session_id)
  where state in ('dispatched', 'accepted', 'running', 'awaiting_answer');
-- ② 같은 세션의 턴 번호는 한 번만 쓴다 (turn_seq가 아직 없는 작업은 제외).
create unique index agent_tasks_session_turn_idx on public.agent_tasks (agent_session_id, turn_seq) where turn_seq is not null;

-- ─────────────────────────────────────────────
-- 6) execution_events: type 'agent' + 사건 봉투 열 (런타임 계약 5장)
-- ─────────────────────────────────────────────
-- 기존 type CHECK는 이름 없는 열 제약이라 이름을 카탈로그에서 찾는다. 정확히 하나여야 한다(아니면 아무것도 바꾸지 않고 실패한다).
do $$
declare
  v_count integer;
  v_name text;
begin
  select count(*), min(c.conname) into v_count, v_name
  from pg_catalog.pg_constraint c
  join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
  where c.conrelid = 'public.execution_events'::regclass and c.contype = 'c' and array_length(c.conkey, 1) = 1 and a.attname = 'type';
  if v_count <> 1 then
    raise exception 'D1a: public.execution_events.type CHECK 제약이 %개다 (정확히 1개여야 한다)', v_count;
  end if;
  execute format('alter table public.execution_events drop constraint %I', v_name);
end;
$$;

-- 기존 값(run · step · hold)을 모두 두고 agent만 더한다. 에이전트 사건은 서버가 bridge 사건을 받아 쓴다(D1c-2).
-- payload에는 글을 담지 않는다: 질문 글은 agent_tasks.pending_question, 결과 글은 산출물에만 있다. 이 규칙의 검증은 서버 코드가 한다(D1c-2) — DB는 JSON 객체인지만 본다.
-- external_event_id는 bridge가 붙인 사건 id(중복 사건을 한 번만 적용하는 열쇠), external_seq는 그 순서, directive_version · turn_seq는 사건이 속한 지시 버전 · 턴이다.
-- bridge가 지워져도 사건 기록은 남고 bridge_id만 비운다.
alter table public.execution_events
  add column external_event_id text,
  add column external_seq bigint,
  add column directive_version integer,
  add column turn_seq integer,
  add column bridge_id uuid,
  add column payload jsonb;

alter table public.execution_events
  add constraint execution_events_type_check check (type in ('run', 'step', 'hold', 'agent')),
  add constraint execution_events_external_event_id_check check (char_length(external_event_id) <= 200),
  add constraint execution_events_external_seq_check check (external_seq >= 0),
  add constraint execution_events_directive_version_check check (directive_version >= 1),
  add constraint execution_events_turn_seq_check check (turn_seq >= 1),
  add constraint execution_events_payload_check check (payload is null or jsonb_typeof(payload) = 'object'),
  -- type 'agent' ↔ external_event_id: 에이전트 사건은 사건 id가 있어야 하고, 다른 type은 이 열을 쓰지 않는다
  add constraint execution_events_agent_event_id check ((type = 'agent') = (external_event_id is not null)),
  add constraint execution_events_bridge_fkey foreign key (bridge_id, user_id)
    references public.bridges (id, user_id) on delete set null (bridge_id);

-- 같은 사건은 한 번만 적용한다 (run마다). 다른 run이면 같은 사건 id도 된다. type이 agent가 아닌 행은 이 제약 밖이다
create unique index execution_events_agent_dedup_idx on public.execution_events (run_id, external_event_id) where type = 'agent';

-- ─────────────────────────────────────────────
-- 7) 부모를 지울 때 참조를 비우는 갱신 · 계정 삭제 cascade가 표 전체를 훑지 않게 (동작은 바뀌지 않는다)
-- ─────────────────────────────────────────────
create index agent_connections_user_idx on public.agent_connections (user_id);
create index agent_connections_bridge_idx on public.agent_connections (bridge_id) where bridge_id is not null;
create index agent_sessions_user_idx on public.agent_sessions (user_id);
create index agent_sessions_bound_action_idx on public.agent_sessions (bound_action_id) where bound_action_id is not null;
create index agent_tasks_user_idx on public.agent_tasks (user_id);
create index agent_tasks_run_idx on public.agent_tasks (run_id);
create index agent_tasks_session_idx on public.agent_tasks (agent_session_id);
create index agent_tasks_step_idx on public.agent_tasks (step_id) where step_id is not null;
create index agent_tasks_message_idx on public.agent_tasks (message_id) where message_id is not null;
create index execution_events_bridge_idx on public.execution_events (bridge_id) where bridge_id is not null;

-- ─────────────────────────────────────────────
-- 8) updated_at 자동 갱신 (기존 public.set_updated_at)
-- ─────────────────────────────────────────────
create trigger bridges_set_updated_at
  before update on public.bridges
  for each row execute function public.set_updated_at();
create trigger agent_connections_set_updated_at
  before update on public.agent_connections
  for each row execute function public.set_updated_at();
create trigger agent_sessions_set_updated_at
  before update on public.agent_sessions
  for each row execute function public.set_updated_at();
create trigger agent_tasks_set_updated_at
  before update on public.agent_tasks
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────
-- 9) 권한: 앱은 자기 행을 RLS로 읽기만 한다 (owner_all 정책 + select 권한, execution_connection_policies와 같은 모양). 쓰기는 서버(service role)만
-- ─────────────────────────────────────────────
-- 이 파일은 함수를 만들지 않아 함수 권한(execute)을 따로 정하지 않는다.
do $$
declare
  t text;
begin
  foreach t in array array['bridges', 'agent_connections', 'agent_sessions', 'agent_tasks'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "owner_all" on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))',
      t
    );
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

commit;
