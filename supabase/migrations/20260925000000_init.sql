-- Taskforce 초기 스키마
-- 모델 설명: docs/PRD.md 4장, docs/ARCHITECTURE.md 5장
-- 원칙: 모든 행은 user_id를 갖고, RLS로 본인 행만 보인다.
--       자식 테이블은 (부모 id, user_id) 복합 외래키로 다른 사용자의 부모를 가리키지 못한다.

create extension if not exists vector with schema extensions;

-- ─────────────────────────────────────────────
-- 원문
-- ─────────────────────────────────────────────
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('meeting', 'message', 'email', 'doc', 'note')),
  title text,
  raw_text text not null,
  occurred_at timestamptz not null,           -- 발언 시점 (입력 시점 아님)
  external_url text,
  created_at timestamptz not null default now(),
  unique (id, user_id)
);

create index sources_user_occurred_idx on public.sources (user_id, occurred_at desc);

-- ─────────────────────────────────────────────
-- Action: 필드 값은 claims로부터 resolve()가 계산한 결과
-- ─────────────────────────────────────────────
create table public.actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null,
  scope_summary text,
  owner text not null default 'me' check (owner in ('me', 'other', 'unknown')),
  counterpart text,
  due_at timestamptz,
  status text not null default 'open' check (status in ('open', 'done', 'dropped')),
  needs_confirmation boolean not null default false,
  embedding extensions.vector(1536),          -- 임베딩 모델을 정하면 차원을 맞춘다
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create index actions_user_status_due_idx on public.actions (user_id, status, due_at);
create index actions_embedding_idx on public.actions
  using hnsw (embedding extensions.vector_cosine_ops);

-- ─────────────────────────────────────────────
-- Claim: 누가 언제 무엇을 말했나 (docs/TRUTH_RULES.md 2장)
-- ─────────────────────────────────────────────
create table public.claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  action_id uuid not null,
  source_id uuid not null,
  field text not null check (field in ('due', 'scope', 'owner', 'status')),
  value text not null,                        -- 정규화된 값 (예: 기한은 ISO 8601)
  value_text text,                            -- 원문 표현 (예: "금요일까지")
  quote text not null,
  occurred_at timestamptz not null,
  speaker text,
  speaker_role text not null check (speaker_role in ('me', 'counterpart', 'third_party')),
  certainty text not null check (certainty in ('firm', 'tentative')),
  directness text not null check (directness in ('first_hand', 'reported')),
  audience text not null check (audience in ('shared', 'private')),
  state text not null default 'active' check (state in ('active', 'superseded', 'disputed')),
  created_at timestamptz not null default now(),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete cascade
);

create index claims_action_field_idx on public.claims (action_id, field, occurred_at);

-- ─────────────────────────────────────────────
-- Evidence: Action 상세에 보여줄 근거 인용
-- ─────────────────────────────────────────────
create table public.evidence (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  action_id uuid not null,
  source_id uuid not null,
  quote text not null,
  role text not null check (role in ('created', 'updated', 'completed', 'duplicate')),
  created_at timestamptz not null default now(),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete cascade
);

create index evidence_action_idx on public.evidence (action_id);

-- ─────────────────────────────────────────────
-- ActionEvent: 변경 이력 + 지표 1(AI 오판율)의 원천
-- ─────────────────────────────────────────────
create table public.action_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  action_id uuid not null,
  type text not null check (type in (
    'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed',
    'user_edited', 'user_deleted', 'user_confirmed'
  )),
  before jsonb,
  after jsonb,
  source_id uuid,
  actor text not null check (actor in ('ai', 'user')),
  rule text,                                  -- 적용된 판정 규칙 (예: 'rule0+rule4')
  created_at timestamptz not null default now(),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete set null (source_id)
);

create index action_events_action_idx on public.action_events (action_id, created_at);

-- ─────────────────────────────────────────────
-- JudgeLog: Jev 판정 기록. 기각한 후보도 남겨 누락을 분석한다.
-- ─────────────────────────────────────────────
create table public.judge_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  source_id uuid not null,
  candidate jsonb not null,
  jev_answers jsonb not null,                 -- 질문별 확률
  decision text not null check (decision in ('auto', 'confirm', 'reject')),
  model_version text not null,
  created_at timestamptz not null default now(),
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete cascade
);

create index judge_logs_source_idx on public.judge_logs (source_id);

-- ─────────────────────────────────────────────
-- MetricEvent: 지표 2(착수 시간), 3(리텐션)
-- ─────────────────────────────────────────────
create table public.metric_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type text not null check (type in ('app_opened', 'action_started', 'handoff_used')),
  action_id uuid,
  at timestamptz not null default now(),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete set null (action_id)
);

create index metric_events_user_at_idx on public.metric_events (user_id, at);

-- ─────────────────────────────────────────────
-- updated_at 자동 갱신
-- ─────────────────────────────────────────────
create function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger actions_set_updated_at
  before update on public.actions
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────
-- RLS: 본인 행만 읽고 쓴다
-- ─────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'sources', 'actions', 'claims', 'evidence', 'action_events', 'judge_logs', 'metric_events'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "owner_all" on public.%I for all to authenticated
         using (user_id = (select auth.uid()))
         with check (user_id = (select auth.uid()))',
      t
    );
  end loop;
end;
$$;
