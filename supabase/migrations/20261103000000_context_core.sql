-- 0.2.0 맥락층 · 대화 뼈대 (구현 계획 A2): 표 9개 work_contexts · context_members · memory_items · identity_links · people ·
-- source_chunks · inbox_events · conversations · conversation_messages. 필드 계약은 0.2.0 아키텍처 5장 · 런타임 계약 2장.
--
-- - 표만 만든다. 코드는 아직 이 표를 읽거나 쓰지 않는다 (src/lib/flags.ts의 gate가 모두 꺼짐, route 없음).
--   updated_at은 기존 public.set_updated_at()을 트리거로 쓴다. 새 함수는 기억 이력 보호 트리거 public.memory_items_keep_history() 하나다.
-- - 모든 행은 user_id를 갖고, 자식은 부모와 (id, user_id) 복합 외래키로 묶여 다른 사용자의 부모를 가리키지 못한다.
--   기존 표(actions · sources · connections)에는 이미 unique (id, user_id)가 있어 바꾸지 않는다.
-- - 권한: 앱은 자기 행을 RLS로 읽기만 한다(owner_all 정책 + select 권한). 쓰기는 서버(service role)만 한다
--   (CLAUDE.md "읽기는 Supabase에서 직접(RLS), 쓰기는 서버 API로만"). 권한 모양은 billing_accounts(20261101000000)와 같다:
--   기본 권한(all)을 모두 거두고 select만 다시 준다 (insert · update · delete · truncate 없음).
-- - 기억 · 범위는 실행 권한에 닿지 않는다(불변식 I04 · I14): 이 표들은 execution_* 표를 가리키지 않는다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
-- 기존 표(actions · sources · connections)를 가리키는 외래키를 만들며 그 표에 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다
-- (그때는 그대로 다시 적용한다. 한 트랜잭션이라 남는 객체가 없다).
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) people: 상대 (아키텍처 5.5). (provider, account_ref)가 1차 키(handles), 이메일이 2차, 이름은 보조 단서.
--    이름만 같은 두 사람은 두 행이다. 병합은 사용자 또는 코드 규칙으로만(merged_into)
-- ─────────────────────────────────────────────
create table public.people (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 200),
  emails text[] not null default '{}' check (cardinality(emails) <= 50),
  handles jsonb not null default '{}' check (jsonb_typeof(handles) = 'object'),  -- provider → 계정 id (예: {"slack": "T1:U2"})
  origin text not null check (origin in ('source', 'user', 'inferred')),
  merged_into uuid,                                                               -- 합쳐진 대상. 대상 행을 지우면 null
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  constraint people_not_merged_into_self check (merged_into <> id),
  foreign key (merged_into, user_id) references public.people (id, user_id) on delete set null (merged_into)
);

create index people_user_idx on public.people (user_id);
create index people_merged_into_idx on public.people (merged_into) where merged_into is not null;

-- ─────────────────────────────────────────────
-- 2) work_contexts: 사용자가 이루려는 결과의 범위 (아키텍처 5.4). 상태 머신이 없고 어떤 gate · 전이 · 판정에도 입력이 아니다(I14).
--    동명 범위 둘은 둘로 둔다(자동 병합 없음). 멤버 · 범위 기억 · 멤버 Source revision이 바뀌면 context_version을 올린다
-- ─────────────────────────────────────────────
create table public.work_contexts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  kind text not null check (kind in ('project', 'client', 'goal', 'personal')),
  status text not null default 'active' check (status in ('active', 'archived')),
  context_version integer not null default 1 check (context_version >= 1),
  last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create index work_contexts_user_status_idx on public.work_contexts (user_id, status, last_activity_at desc);

-- ─────────────────────────────────────────────
-- 3) context_members: 범위의 멤버. 멤버 종류마다 외래키 열 하나(id만 담는 다형 열을 두지 않는다). 정확히 하나만 채우고 member_kind와 맞아야 한다.
--    agent session 멤버는 agent_sessions가 생기는 PR(D1)에서 열 · 종류를 더한다.
--    origin: user(사용자가 정함, 자동 규칙이 덮지 않는다) · auto(코드 규칙) · inferred(모델 후보, confidence 필수)
--    사용자가 뺀 멤버는 행을 지우지 않고 removed_at을 남긴다(origin user): 같은 멤버를 자동 규칙이 다시 넣지 못한다(unique). 지금 멤버 = removed_at이 없는 행
-- ─────────────────────────────────────────────
create table public.context_members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  context_id uuid not null,
  member_kind text not null check (member_kind in ('action', 'source', 'person')),
  action_id uuid,
  source_id uuid,
  person_id uuid,
  origin text not null check (origin in ('user', 'auto', 'inferred')),
  confidence numeric check (confidence >= 0 and confidence <= 1),
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint context_members_removed_by_user check (removed_at is null or origin = 'user'),
  constraint context_members_one_member check (
    (member_kind = 'action') = (action_id is not null)
    and (member_kind = 'source') = (source_id is not null)
    and (member_kind = 'person') = (person_id is not null)
  ),
  constraint context_members_confidence_inferred check ((origin = 'inferred') = (confidence is not null)),
  unique (context_id, action_id),
  unique (context_id, source_id),
  unique (context_id, person_id),
  foreign key (context_id, user_id) references public.work_contexts (id, user_id) on delete cascade,
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete cascade,
  foreign key (person_id, user_id) references public.people (id, user_id) on delete cascade
);

create index context_members_action_idx on public.context_members (action_id) where action_id is not null;
create index context_members_source_idx on public.context_members (source_id) where source_id is not null;
create index context_members_person_idx on public.context_members (person_id) where person_id is not null;
create index context_members_user_idx on public.context_members (user_id);

-- ─────────────────────────────────────────────
-- 4) memory_items: 사용자 또는 자료가 말한 한 가지 (아키텍처 5.3). Action 필드를 바꾸지 않는다(I01), 실행 권한에 닿지 않는다(I04).
--    origin: explicit(사용자가 직접 말함) > observed(자료 · 검증된 결과에서 읽음, source_ref 필수) > inferred(모델 추정, confidence 필수).
--    정정은 새 행 + 옛 행 superseded_by (옛 행은 지우지 않는다). 잊기는 revoked_at.
--    현재 항목 = superseded_at · revoked_at이 모두 없는 행. superseded_at은 정정된 사실 자체를 남기는 한 방향 표시라서,
--    정정한 새 행이 지워져도(직접 삭제 · 범위 cascade) 포인터 superseded_by만 비고 옛 행은 현재로 돌아오지 않는다 (트리거 memory_items_keep_history)
--    범위: global(대상 없음) · context · action · counterpart(person) · agent(adapter 이름, 예: agent:claude-code). 대상 열은 범위와 맞아야 한다.
--    observed 항목의 출처 원문 글이 지워지면 statement를 비우고 source_purged = true (빈 statement ⇔ source_purged)
-- ─────────────────────────────────────────────
create table public.memory_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in (
    'identity_link', 'goal', 'condition', 'outcome_criteria', 'relationship', 'fact', 'working_rule', 'plan'
  )),
  scope_kind text not null check (scope_kind in ('global', 'context', 'action', 'counterpart', 'agent')),
  context_id uuid,
  action_id uuid,
  person_id uuid,
  agent_adapter text check (agent_adapter ~ '^agent:[a-z0-9][a-z0-9_-]*$' and char_length(agent_adapter) <= 64), -- contract agentAdapterIdSchema
  statement text not null check (char_length(statement) <= 1000),               -- 한 줄, 사용자 언어
  value jsonb not null default '{}' check (jsonb_typeof(value) = 'object'),      -- 구조화 값 (예: {"start_after": {"kind": "design_approved"}})
  origin text not null check (origin in ('explicit', 'observed', 'inferred')),
  -- 출처: message_id | source_id + quote | artifact_id | event_id 중 하나 이상 (id만, 원문 글은 quote뿐).
  -- 있는 키는 모양이 맞아야 한다: message_id · source_id · artifact_id는 uuid 문자열, event_id는 1–100자 문자열, quote는 문자열
  -- (앱의 memorySourceRefSchema와 같은 모양. uuid 변형 비트 같은 세부까지 같지는 않다)
  source_ref jsonb check (source_ref is null or (
    jsonb_typeof(source_ref) = 'object'
    and source_ref ?| array['message_id', 'source_id', 'artifact_id', 'event_id']
    and (source_ref -> 'message_id' is null or (jsonb_typeof(source_ref -> 'message_id') = 'string'
      and source_ref ->> 'message_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
    and (source_ref -> 'source_id' is null or (jsonb_typeof(source_ref -> 'source_id') = 'string'
      and source_ref ->> 'source_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
    and (source_ref -> 'artifact_id' is null or (jsonb_typeof(source_ref -> 'artifact_id') = 'string'
      and source_ref ->> 'artifact_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
    and (source_ref -> 'event_id' is null or (jsonb_typeof(source_ref -> 'event_id') = 'string'
      and char_length(source_ref ->> 'event_id') between 1 and 100))
    and (source_ref -> 'quote' is null or jsonb_typeof(source_ref -> 'quote') = 'string')
  )),
  observed_at timestamptz not null default now(),                               -- 말한 · 읽은 시각
  valid_from timestamptz,                                                       -- 사실의 유효 구간 (알 때만)
  valid_until timestamptz,
  superseded_by uuid,
  superseded_at timestamptz,                                                    -- 정정된 시각. 한 번 남기면 지우거나 바꾸지 않는다
  revoked_at timestamptz,                                                       -- 잊은 시각. 한 번 남기면 지우거나 바꾸지 않는다
  confidence numeric check (confidence >= 0 and confidence <= 1),
  source_purged boolean not null default false,
  version integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  constraint memory_items_scope_target check (
    (scope_kind = 'context') = (context_id is not null)
    and (scope_kind = 'action') = (action_id is not null)
    and (scope_kind = 'counterpart') = (person_id is not null)
    and (scope_kind = 'agent') = (agent_adapter is not null)
  ),
  constraint memory_items_observed_source check (origin <> 'observed' or source_ref is not null),
  constraint memory_items_confidence_inferred check ((origin = 'inferred') = (confidence is not null)),
  constraint memory_items_statement_purged check ((statement = '') = source_purged),
  constraint memory_items_purged_observed check (not source_purged or origin = 'observed'),
  constraint memory_items_valid_range check (valid_from is null or valid_until is null or valid_from <= valid_until),
  constraint memory_items_not_superseded_by_self check (superseded_by <> id),
  constraint memory_items_superseded_marked check (superseded_by is null or superseded_at is not null),
  foreign key (context_id, user_id) references public.work_contexts (id, user_id) on delete cascade,
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (person_id, user_id) references public.people (id, user_id) on delete cascade,
  -- 정정한 새 행을 지우면(범위 삭제 cascade 포함) 포인터만 비운다. superseded_at이 남아 옛 행은 현재 항목이 되지 않는다
  foreign key (superseded_by, user_id) references public.memory_items (id, user_id) on delete set null (superseded_by)
);

create index memory_items_user_idx on public.memory_items (user_id);
create index memory_items_user_current_idx on public.memory_items (user_id, scope_kind)
  where superseded_at is null and revoked_at is null;
create index memory_items_context_idx on public.memory_items (context_id) where context_id is not null;
create index memory_items_action_idx on public.memory_items (action_id) where action_id is not null;
create index memory_items_person_idx on public.memory_items (person_id) where person_id is not null;
create index memory_items_superseded_by_idx on public.memory_items (superseded_by) where superseded_by is not null;

-- ─────────────────────────────────────────────
-- 5) identity_links: 서비스별 "나" (아키텍처 5.5). oauth(연결 결과) · profile(프로필 별칭 · 이메일) · user_confirmed · inferred(확인 전, isUser에 넣지 않음).
--    shared_account(팀 공용 메일함 등)는 "나"의 발언으로 치지 않는다. OAuth에서 온 링크는 그 연결을 끊으면(connections 행 삭제) 함께 지운다
-- ─────────────────────────────────────────────
create table public.identity_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  provider text not null check (char_length(provider) between 1 and 64),
  account_ref text not null check (char_length(account_ref) between 1 and 320), -- 서비스 user id
  email text check (char_length(email) between 3 and 320),
  connection_id uuid,
  verified_via text not null check (verified_via in ('oauth', 'profile', 'user_confirmed', 'inferred')),
  shared_account boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider, account_ref),
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade
);

create index identity_links_connection_idx on public.identity_links (connection_id) where connection_id is not null;

-- ─────────────────────────────────────────────
-- 6) source_chunks: 원문 조각 임베딩 (아키텍처 6.2, 1–2k자, 1536차원 = actions.embedding과 같은 모델).
--    보관 기간은 원문과 같고 원문 글이 지워지면 조각을 지운다(6.5). source_revision = sources.external_version (없는 원문은 null)
-- ─────────────────────────────────────────────
create table public.source_chunks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  source_id uuid not null,
  source_revision text,
  seq integer not null check (seq >= 0),
  text text not null check (char_length(text) between 1 and 4000),
  embedding extensions.vector(1536),
  created_at timestamptz not null default now(),
  constraint source_chunks_position unique nulls not distinct (source_id, source_revision, seq),
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete cascade
);

create index source_chunks_user_idx on public.source_chunks (user_id);

-- ─────────────────────────────────────────────
-- 7) inbox_events: 코디네이터가 처리할 사건 (아키텍처 5.7 · 7.1). 같은 사건은 dedup_key로 한 번만 쌓인다.
--    종류 목록은 생산자를 붙이는 PR(C2)이 정한다: 여기서는 이름 모양만 막는다. refs에는 id만 담는다 (글 없음)
-- ─────────────────────────────────────────────
create table public.inbox_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type text not null check (type ~ '^[a-z][a-z0-9_]{0,63}$'),
  dedup_key text not null check (char_length(dedup_key) between 1 and 300),
  refs jsonb not null default '{}' check (jsonb_typeof(refs) = 'object'),   -- action_ids · context_ids · run_ids · source_id · task_id
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (user_id, dedup_key)
);

create index inbox_events_pending_idx on public.inbox_events (user_id, created_at) where processed_at is null;

-- ─────────────────────────────────────────────
-- 8) conversations: 런처 대화 (런타임 계약 2장). context_id는 대화의 기본 범위(null = All work), 범위를 지우면 null.
--    글 보관 기한 뒤 메시지 text만 비우고(text_purged_at) 행 · refs는 남긴다
-- ─────────────────────────────────────────────
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text check (char_length(title) <= 200),
  context_id uuid,
  created_at timestamptz not null default now(),
  last_message_at timestamptz,
  last_read_at timestamptz,
  archived_at timestamptz,
  text_purged_at timestamptz,
  unique (id, user_id),
  foreign key (context_id, user_id) references public.work_contexts (id, user_id) on delete set null (context_id)
);

create index conversations_user_recent_idx on public.conversations (user_id, last_message_at desc nulls last);
create index conversations_context_idx on public.conversations (context_id) where context_id is not null;

-- ─────────────────────────────────────────────
-- 9) conversation_messages: 같은 제출을 두 번 저장 · 실행하지 않는다 (unique (conversation_id, client_message_id), A03 · D1).
--    사용자 메시지는 client_message_id가 있고 4,000자 이하. refs · intent는 서버가 쓴다 (모델 출력의 id를 그대로 믿지 않는다)
-- ─────────────────────────────────────────────
create table public.conversation_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  conversation_id uuid not null,
  seq integer not null check (seq > 0),
  role text not null check (role in ('user', 'assistant', 'event')),
  client_message_id uuid,
  text text not null default '' check (char_length(text) <= 20000),
  refs jsonb not null default '{}' check (jsonb_typeof(refs) = 'object'),
  intent jsonb check (jsonb_typeof(intent) = 'object'),                      -- {kind, confidence, judge_version}
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (conversation_id, seq),
  unique (conversation_id, client_message_id),
  constraint conversation_messages_user_message check (
    role <> 'user' or (client_message_id is not null and char_length(text) <= 4000)
  ),
  foreign key (conversation_id, user_id) references public.conversations (id, user_id) on delete cascade
);

create index conversation_messages_user_idx on public.conversation_messages (user_id);

-- ─────────────────────────────────────────────
-- 10) updated_at 자동 갱신 (기존 public.set_updated_at)
-- ─────────────────────────────────────────────
create trigger people_set_updated_at
  before update on public.people
  for each row execute function public.set_updated_at();
create trigger work_contexts_set_updated_at
  before update on public.work_contexts
  for each row execute function public.set_updated_at();
create trigger context_members_set_updated_at
  before update on public.context_members
  for each row execute function public.set_updated_at();
create trigger memory_items_set_updated_at
  before update on public.memory_items
  for each row execute function public.set_updated_at();

-- 기억의 정정 · 잊기는 한 방향이다 (아키텍처 5.3: 옛 행은 이력으로 남고, 사용자의 정정 · 잊기를 되돌리지 않는다).
-- superseded_by를 쓰면 superseded_at을 남기고, 한 번 남긴 superseded_at · revoked_at은 서버(service role)도 지우거나 바꾸지 못한다.
-- 서버의 잊기 · 정정은 `where revoked_at is null` · `where superseded_at is null`로 써서 다시 보낸 요청이 오류가 아니라 0행이 되게 한다.
create function public.memory_items_keep_history() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.superseded_by is not null and new.superseded_at is null then
    new.superseded_at = now();
  end if;
  if tg_op = 'UPDATE' then
    if old.superseded_at is not null and new.superseded_at is distinct from old.superseded_at then
      raise exception 'memory_items_keep_history: superseded_at is permanent' using errcode = 'check_violation';
    end if;
    if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
      raise exception 'memory_items_keep_history: revoked_at is permanent' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

create trigger memory_items_keep_history
  before insert or update on public.memory_items
  for each row execute function public.memory_items_keep_history();
revoke all on function public.memory_items_keep_history() from public, anon, authenticated;
create trigger identity_links_set_updated_at
  before update on public.identity_links
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────
-- 11) RLS · 권한: 본인 행만 읽는다 (owner_all). 쓰기 권한은 없다 — 서버(service role, RLS 우회)만 쓴다
-- ─────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'people', 'work_contexts', 'context_members', 'memory_items', 'identity_links',
    'source_chunks', 'inbox_events', 'conversations', 'conversation_messages'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "owner_all" on public.%I for all to authenticated
         using (user_id = (select auth.uid()))
         with check (user_id = (select auth.uid()))',
      t
    );
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

commit;
