-- 0.2.0 맥락층 (구현 계획 B1): 20261103000000_context_core의 표 위에 규칙 · 전파를 더한다. 새 표는 people_handles와 내부 큐 context_version_bumps, 새 열은 둘이다.
-- 결정 기록: docs/context-layer.md. 코드: src/lib/context/. gate(MEMORY_ENABLED · SOURCE_CHUNKS_ENABLED)가 꺼져 있으면 서버 코드는 아무것도 쓰지 않는다.
--
-- 1) 기억 정정은 같은 범위 · 같은 사실 안에서만 (사용자 결정 2026-10-10):
--    - memory_items.subject: "같은 사실"의 열쇠 (정규화한 짧은 문자열). 주제가 없는 행은 아무것도 덮지 않고 덮이지도 않는다.
--    - superseded_by는 같은 사용자 · 같은 범위(scope_kind + 대상) · 같은 kind · 같은 subject의 행만 가리킨다 (memory_items_keep_history를 바꿔 만든다).
--      범위 사이의 우선(좁은 범위가 이긴다)은 읽을 때 그 범위 안에서만 정한다 (src/lib/context/retrieve.ts). 프로젝트의 예외가 다른 프로젝트 · 전체 기본값을 지우지 않는다.
--    - 쓰기는 remember_memory_item 한 함수로: 같은 범위 · 같은 사실의 지금 행과 비교해 진 행을 정정된 이력으로 남긴다.
-- 2) 삭제 전파 (아키텍처 6.5): 원문 글이 지워지면(보관 기간 · Slack 끊기 · 원문 삭제) 같은 트랜잭션에서 조각을 지우고 기억 글을 비운다 (sources 트리거).
--    지운 원문에 조각 · 기억 글을 새로 넣지 못한다 (가드 트리거: 원문 행을 for share로 잠가 지우기와 한 줄로 선다).
--    Slack 끊기 · 앱 제거(purge_slack_data)는 그 연결의 신원 링크 · 사람 계정(이름 · 이메일 출처)도 지운다.
--    접근 상실은 sources.access_lost_at: 행 · 이력은 남기고 검색 · 묶음에서 뺀다.
-- 3) 사람 계정(1차 키)의 유일성 + 출처: people_handles (user, provider, account_ref) unique. people.handles · 출처 사람의 이름 · 이메일은 이 표에서 계산한다.
-- 4) 신원 링크: oauth · inferred 링크는 연결에 묶이고(연결을 끊으면 함께 지워진다), profile · user_confirmed는 연결에 묶이지 않는다.
-- 5) 조각 교체(replace_source_chunks)와 범위 version(work_contexts.context_version): 멤버 추가 · 제거, 범위 기억 변경, 멤버 원문의 새 revision · 글 지움 · 접근 상실에
--    오른다(commit 직전 한 번에, 범위 id 순). 모델 후보(inferred)는 올리지 않는다. 내부 큐 표 context_version_bumps(앱 권한 없음)
--
-- 기억 · 범위는 실행 권한에 닿지 않는다(I04 · I14): 이 파일의 함수 · 트리거는 execution_* 표를 읽거나 쓰지 않는다 (tests/db/context-layer.test.ts가 확인).
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 20261103000000_context_core 뒤에 적용한다.

begin;
-- sources · connections에 트리거를 걸고 열을 더하며 그 표에 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (그때는 그대로 다시 적용)
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 같은 사실의 열쇠: memory_items.subject
--    앱 · 서버가 정규화해서 쓴다(src/lib/context/memory.ts normalizeMemorySubject: NFKC · 소문자 · 공백 하나). DB는 모양만 막는다.
-- ─────────────────────────────────────────────
alter table public.memory_items
  add column subject text constraint memory_items_subject_shape check (
    subject is null or (char_length(subject) between 1 and 200 and subject = btrim(subject) and subject !~ '[[:cntrl:]]')
  );

-- 같은 사실의 지금 행 찾기 (정정 · 읽기 해석)
create index memory_items_fact_idx on public.memory_items (user_id, kind, subject) where subject is not null;
-- 원문 글이 지워질 때 그 원문에서 온 기억 찾기 (uuid 대소문자를 가리지 않는다)
create index memory_items_source_idx on public.memory_items ((lower(source_ref ->> 'source_id'))) where source_ref ? 'source_id';

-- 기억 이력 보호 (20261103000000의 함수를 바꿔 만든다: 같은 트리거가 부르는 함수 하나에 규칙을 모은다).
-- 그대로 두는 것: superseded_by를 쓰면 superseded_at을 남기고, 한 번 남긴 superseded_at · revoked_at은 지우거나 바꾸지 못한다.
-- 더하는 것:
--   - 행의 정체(kind · 범위 · 대상 · subject)는 바꾸지 않는다: 바꾸려면 새 행. subject는 주제 없던 항목의 정정('memory:<id>')과
--     원문 글이 지워진 observed 항목의 비움에만 바뀐다
--   - superseded_by는 같은 사용자 · 같은 범위 · 같은 대상 · 같은 kind · 같은 (비어 있지 않은) subject의 행만 가리킨다.
--     다른 사용자의 행이거나 없는 행이면 여기서 막지 않는다: 복합 외래키 (superseded_by, user_id)가 막는다
create or replace function public.memory_items_keep_history() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_target public.memory_items%rowtype;
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
    -- subject는 두 경우만 바뀐다: 주제 없던 항목을 정정할 때 'memory:<그 id>'로 (remember_memory_item),
    -- 원문 글이 지워진 observed 항목의 주제를 비울 때 (purge_source_context: 주제도 원문에서 온 글자다)
    if (new.kind, new.scope_kind, new.context_id, new.action_id, new.person_id, new.agent_adapter)
         is distinct from (old.kind, old.scope_kind, old.context_id, old.action_id, old.person_id, old.agent_adapter)
       or (old.subject is not null and new.subject is distinct from old.subject
           and not (new.subject is null and new.source_purged and new.origin = 'observed'))
       or (old.subject is null and new.subject is not null and new.subject <> 'memory:' || new.id::text) then
      raise exception 'memory_items_keep_history: kind, scope and subject are fixed (write a new row)' using errcode = 'check_violation';
    end if;
  end if;
  if new.superseded_by is not null and (tg_op = 'INSERT' or new.superseded_by is distinct from old.superseded_by) then
    select * into v_target from public.memory_items m where m.id = new.superseded_by and m.user_id = new.user_id;
    -- 추정(inferred) 후보는 사용자가 말한 것 · 자료에서 읽은 것을 정정하지 못한다 (확인되면 explicit 새 행이 정정한다)
    if found and v_target.origin = 'inferred' and new.origin <> 'inferred' then
      raise exception 'memory_items_keep_history: an inferred item cannot supersede an explicit or observed item' using errcode = 'check_violation';
    end if;
    if found and (
      new.subject is null
      or v_target.subject is distinct from new.subject
      or v_target.kind <> new.kind
      or (v_target.scope_kind, v_target.context_id, v_target.action_id, v_target.person_id, v_target.agent_adapter)
           is distinct from (new.scope_kind, new.context_id, new.action_id, new.person_id, new.agent_adapter)
    ) then
      raise exception 'memory_items_keep_history: superseded_by must be the same fact (kind, subject) in the same scope'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────
-- 2) 접근 상실 (아키텍처 6.5: 403 · 삭제 감지). 행 · 기억 · 조각은 남기고 검색 · 묶음에서만 뺀다. 다시 읽히면 null로 되돌린다
-- ─────────────────────────────────────────────
alter table public.sources add column access_lost_at timestamptz;

-- 같은 문서(revision들): 같은 사용자 · 같은 외부 id이고, 같은 연결이거나 한쪽 연결이 끊겨 비었다 (연결을 끊어도 원문 · 조각은 보관 정책대로 남고,
-- 다시 연결하면 새 연결이 된다: 수집의 "이미 넣은 원문"과 같은 기준, src/lib/connectors/store.ts ingestedIds). 외부 id가 없는 원문은 자기 하나.
-- 서로 다른 두 살아 있는 연결의 같은 외부 id는 다른 문서로 둔다 (연결이 다른 같은 자료의 수렴은 D0 ARCH-V04)
create index sources_user_external_idx on public.sources (user_id, external_id) where external_id is not null;

create function public.source_document_ids(p_user_id uuid, p_source_id uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(s.id), '{}')
    from public.sources me
    join public.sources s on s.user_id = me.user_id
     and (s.id = me.id
          or (me.external_id is not null and s.external_id = me.external_id
              and (s.connection_id = me.connection_id or s.connection_id is null or me.connection_id is null)))
   where me.id = p_source_id and me.user_id = p_user_id;
$$;

-- 서버가 정하는 원문 열(글 지운 시각 · 이유 · 접근 상실)은 앱 역할이 바꾸지 못한다: 바꾸면 지운 원문 가드 · 검색 제외가 풀린다.
-- 앱은 원문 행에 owner_all 정책이 있어(20260925000000) update 자체는 된다. 서버(service role) · 소유자 권한 함수는 그대로 쓴다
create function public.sources_server_columns_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.raw_text_purged_at, new.raw_text_purge_reason, new.access_lost_at)
         is distinct from (old.raw_text_purged_at, old.raw_text_purge_reason, old.access_lost_at) then
    raise exception 'sources_server_columns: raw_text_purged_at, raw_text_purge_reason and access_lost_at are set by the server only'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger sources_server_columns_guard
  before update of raw_text_purged_at, raw_text_purge_reason, access_lost_at on public.sources
  for each row execute function public.sources_server_columns_guard();

-- 기억 · 묶음이 원문을 거를 때 보는 상태 (src/lib/context/store.ts loadSourceStates). 접근 상실은 문서 단위다: 같은 문서의 revision 하나라도
-- 잃었으면 잃은 것으로 본다(범위 검색 match_context_chunks와 같은 기준). 늦게 들어온 새 revision은 되찾음이 아니다: 서버가 set_sources_access(…, false)로 표시해야 한다
create function public.context_source_states(p_user_id uuid, p_source_ids uuid[])
returns table (id uuid, provider text, purged boolean, purge_reason text, access_lost boolean, external_url text)
language sql
stable
set search_path = ''
as $$
  select s.id, k.provider, s.raw_text_purged_at is not null, s.raw_text_purge_reason,
         exists (select 1 from public.sources d where d.id = any (public.source_document_ids(p_user_id, s.id)) and d.access_lost_at is not null),
         s.external_url
    from public.sources s
    left join public.connections k on k.id = s.connection_id and k.user_id = s.user_id
   where s.user_id = p_user_id and s.id = any (p_source_ids);
$$;

-- 접근 상실 표시 · 되찾음 (서버). 같은 문서의 모든 revision을 함께 바꾼다: 접근은 문서의 성질이다. 바꾼 행 수
create function public.set_sources_access(p_user_id uuid, p_source_ids uuid[], p_lost boolean)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.sources s
     set access_lost_at = case when p_lost then now() end
   where s.user_id = p_user_id
     and s.id in (select unnest(public.source_document_ids(p_user_id, x)) from unnest(p_source_ids) as x)
     and (s.access_lost_at is null) = p_lost;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ─────────────────────────────────────────────
-- 3) 지운 원문 가드: 원문 글이 지워진 뒤에는 그 원문의 조각 · 기억 글을 새로 쓰지 못한다.
--    원문 행을 for share로 잠근다: 글 지우기(update, for no key update)와 충돌하므로 둘은 한 줄로 선다.
--    - 가드가 먼저 잠그면 지우기는 그 트랜잭션의 commit을 기다렸다가, commit된 조각 · 기억까지 지운다 (전파 트리거가 새 스냅샷으로 읽는다)
--    - 지우기가 먼저면 가드는 commit을 기다렸다가 지운 값을 읽고 거절한다
-- ─────────────────────────────────────────────
create function public.source_chunks_purged_source_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_purged timestamptz;
begin
  select s.raw_text_purged_at into v_purged
    from public.sources s
   where s.id = new.source_id and s.user_id = new.user_id
   for share;
  -- 없는 원문 · 다른 사용자의 원문은 복합 외래키가 막는다
  if found and v_purged is not null then
    raise exception 'source_chunks_purged_source: source text was purged' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger source_chunks_purged_source_guard
  before insert or update of source_id, text on public.source_chunks
  for each row execute function public.source_chunks_purged_source_guard();

-- 기억: observed는 비운 모양(글 · 인용 · 값 · 주제 없음)만, inferred는 넣지 못한다. Slack 끊기로 지운 원문이면 explicit도 인용(Slack 글자)을 담지 못한다.
-- 사용자가 저장한 explicit 글 · 값은 막지 않는다 (원칙: 사용자가 저장한 기억은 원문이 지워져도 남는다)
create function public.memory_items_purged_source_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_purged timestamptz;
  v_reason text;
begin
  -- uuid 모양이 아닌 출처는 여기서 보지 않는다: CHECK memory_items_source_ref_check가 막는다 (트리거가 CHECK보다 먼저 돈다)
  if new.source_ref is null or coalesce(new.source_ref ->> 'source_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return new;
  end if;
  select s.raw_text_purged_at, s.raw_text_purge_reason into v_purged, v_reason
    from public.sources s
   where s.id = (new.source_ref ->> 'source_id')::uuid and s.user_id = new.user_id
   for share;
  if not found then
    -- 새로 가리키는 출처는 이 사용자의 원문이어야 한다. 이미 가리키던 원문이 지워진 행은 그대로 고칠 수 있다 (원문 삭제 전파 · 잊기)
    if tg_op = 'INSERT' or lower(new.source_ref ->> 'source_id') is distinct from lower(old.source_ref ->> 'source_id') then
      raise exception 'memory_items_purged_source: source not found for this user' using errcode = 'foreign_key_violation';
    end if;
    return new;
  end if;
  if v_purged is null then
    return new;
  end if;
  if new.origin = 'inferred'
     or (new.origin = 'observed' and (new.statement <> '' or new.source_ref ? 'quote' or new.value <> '{}'::jsonb or new.subject is not null))
     or (v_reason = 'disconnected' and new.source_ref ? 'quote') then
    raise exception 'memory_items_purged_source: source text was purged' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger memory_items_purged_source_guard
  before insert or update of source_ref, statement, value, origin on public.memory_items
  for each row execute function public.memory_items_purged_source_guard();

-- ─────────────────────────────────────────────
-- 4) 삭제 전파: 원문 글이 지워지면 그 원문의 조각 · 기억 글을 같은 트랜잭션에서 지운다 (아키텍처 6.1 · 6.5)
--    - source_chunks: 지운다 (글 + 임베딩)
--    - observed 기억: statement를 비우고 source_purged, 인용(source_ref.quote) · 원문에서 읽은 값(value) · 주제(subject)도 비운다. 행 · 이력은 남는다.
--      비운 행은 주제가 없어 같은 사실의 비교(remember_memory_item)에 끼지 않는다
--    - inferred 기억(확인 전 모델 후보): 지운다 (근거 글이 없는 추정은 남길 이유가 없다, 아키텍처 5.3)
--    - explicit 기억(사용자가 저장): 글 · 값은 남긴다. p_strip_quotes(Slack 끊기 · 원문 삭제)면 인용만 뺀다. 보관 기간(90일)은 근거 인용처럼 인용도 남긴다
--    여러 번 불러도 같다 (이미 비운 행은 고치지 않는다). 그 원문의 사용자 행만 본다
-- ─────────────────────────────────────────────
create function public.purge_source_context(p_user_id uuid, p_source_ids uuid[], p_strip_quotes boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_ids text[] := array(select lower(id::text) from unnest(p_source_ids) as id);
begin
  delete from public.source_chunks c where c.user_id = p_user_id and c.source_id = any (p_source_ids);

  delete from public.memory_items m
   where m.user_id = p_user_id and m.origin = 'inferred' and m.source_ref ? 'source_id' and lower(m.source_ref ->> 'source_id') = any (v_ids);

  update public.memory_items m
     set statement = '', source_purged = true, source_ref = m.source_ref - 'quote', value = '{}'::jsonb, subject = null, version = m.version + 1
   where m.user_id = p_user_id and m.origin = 'observed' and m.source_ref ? 'source_id' and lower(m.source_ref ->> 'source_id') = any (v_ids)
     and (m.statement <> '' or m.source_ref ? 'quote' or m.value <> '{}'::jsonb or m.subject is not null);

  if p_strip_quotes then
    update public.memory_items m
       set source_ref = m.source_ref - 'quote', version = m.version + 1
     where m.user_id = p_user_id and m.origin = 'explicit' and m.source_ref ? 'source_id' and lower(m.source_ref ->> 'source_id') = any (v_ids)
       and m.source_ref ? 'quote';
  end if;
end;
$$;

-- 원문 글 지움(보관 기간 purge_expired_source_text · Slack D3 purge_slack_sources)과 원문 행 삭제에 건다.
-- 앱(authenticated)이 원문을 쓰는 경로도 전파되도록 소유자 권한(security definer)으로 돈다: new · old 행의 사용자 · 원문 id로만 좁힌다
create function public.sources_purge_context() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.purge_source_context(old.user_id, array[old.id], true);
  else
    perform public.purge_source_context(new.user_id, array[new.id], new.raw_text_purge_reason = 'disconnected');
  end if;
  return null;
end;
$$;

-- 지운 시각이 처음 생기거나 지운 이유가 바뀔 때만 (Slack D3를 다시 불러도 이유가 같으면 다시 돌지 않는다. 그 사이 새로 쓰는 것은 가드가 막는다)
create trigger sources_purge_context
  after update of raw_text_purged_at, raw_text_purge_reason on public.sources
  for each row
  when (new.raw_text_purged_at is not null
        and (old.raw_text_purged_at is null or new.raw_text_purge_reason is distinct from old.raw_text_purge_reason))
  execute function public.sources_purge_context();

create trigger sources_purge_context_on_delete
  after delete on public.sources
  for each row execute function public.sources_purge_context();

-- ─────────────────────────────────────────────
-- 5) 사람 계정 (아키텍처 5.5: (provider, account_ref)가 1차 키). 한 계정은 사용자마다 한 사람에게만 붙는다 (unique).
--    출처를 남긴다: origin source(연결 · 원문이 보여 준 계정, connection_id = 본 연결) · user(사용자가 적음, 연결 없음).
--    연결을 끊으면(행 삭제) connection_id만 비고 계정은 남는다(원문이 보관 정책대로 남으므로). Slack 끊기 · 앱 제거는 purge_slack_data가 지운다.
--    people.handles는 이 표에서 계산한다(provider → 가장 최근 계정). origin이 user가 아닌 사람의 display_name · emails도 이 표에서 계산한다:
--    출처가 사라진 이름 · 이메일은 남지 않고, 다른 계정이 같은 이름을 보여 주면 남는다. 사용자가 만든 사람(origin user)의 이름 · 이메일은 건드리지 않는다
-- ─────────────────────────────────────────────
create table public.people_handles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  person_id uuid not null,
  provider text not null check (provider ~ '^[a-z][a-z0-9_-]{0,63}$'),
  account_ref text not null check (char_length(account_ref) between 1 and 320),  -- 서비스 계정 id (Slack "T:U", Gmail · Google은 소문자 주소)
  display_name text check (char_length(display_name) between 1 and 200),         -- 그 계정이 보여 준 이름
  email text check (char_length(email) between 3 and 320),                       -- 그 계정이 보여 준 주소 (소문자)
  origin text not null check (origin in ('source', 'user')),
  connection_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, provider, account_ref),
  constraint people_handles_user_unbound check (origin = 'source' or connection_id is null),
  foreign key (person_id, user_id) references public.people (id, user_id) on delete cascade,
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete set null (connection_id)
);

create index people_handles_person_idx on public.people_handles (person_id);
create index people_handles_connection_idx on public.people_handles (connection_id) where connection_id is not null;

create trigger people_handles_set_updated_at
  before update on public.people_handles
  for each row execute function public.set_updated_at();

create function public.people_refresh_from_handles(p_person_id uuid)
returns void
language sql
set search_path = ''
as $$
  update public.people p set
    handles = coalesce((
      select jsonb_object_agg(x.provider, x.account_ref)
        from (select distinct on (h.provider) h.provider, h.account_ref
                from public.people_handles h
               where h.person_id = p.id
               order by h.provider, h.updated_at desc, h.id desc) x
    ), '{}'::jsonb),
    display_name = case when p.origin = 'user' then p.display_name else (
      select h.display_name from public.people_handles h
       where h.person_id = p.id and h.display_name is not null
       order by (h.display_name = p.display_name) desc, h.updated_at desc, h.id desc
       limit 1
    ) end,
    emails = case when p.origin = 'user' then p.emails else coalesce((
      select (array_agg(distinct h.email order by h.email))[1:50] from public.people_handles h where h.person_id = p.id and h.email is not null
    ), '{}'::text[]) end
  where p.id = p_person_id;
$$;

-- 소유자 권한: 사람을 지우거나 계정을 지울 때(Supabase Auth의 supabase_auth_admin 포함) cascade로 불려도 people을 고칠 수 있게. old · new의 사람만 고친다
create function public.people_handles_refresh() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.people_refresh_from_handles(old.person_id);
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.person_id <> old.person_id) then
    perform public.people_refresh_from_handles(new.person_id);
  end if;
  return null;
end;
$$;

-- 연결을 끊어 connection_id만 비는 경우(외래키 set null)는 계산 값이 같으므로 부르지 않는다
create trigger people_handles_refresh
  after insert or delete or update of person_id, provider, account_ref, display_name, email on public.people_handles
  for each row execute function public.people_handles_refresh();

-- 자료에서 본 계정 하나를 사람에 붙인다. 1차 키(계정) → 2차 키(이메일이 정확히 한 사람과 같을 때) → 새 사람. 이름만 같으면 합치지 않는다.
-- 사용자가 적은 계정(origin user)은 고치지 않는다. 같은 계정을 동시에 보면 한 줄로 선다(사람이 둘 생기지 않게). 사람 id를 돌려준다
create function public.observe_person_handle(
  p_user_id uuid,
  p_provider text,
  p_account_ref text,
  p_display_name text,
  p_email text,
  p_connection_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_person uuid;
  v_origin text;
  v_name text := left(nullif(btrim(p_display_name), ''), 200);
  v_email text := nullif(lower(btrim(p_email)), '');
  v_matches uuid[];
begin
  -- 주소 모양이 아니면 이메일로 보지 않는다 (2차 키로 잘못 합치지 않게)
  if v_email is not null and (char_length(v_email) > 320 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    v_email := null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('people_handles:' || p_user_id::text || ':' || p_provider || ':' || p_account_ref, 0));
  -- 같은 주소의 다른 계정(예: gmail · google)을 동시에 보면 둘 다 "없음"을 읽고 사람을 둘 만들 수 있다: 주소도 잠근다 (계정 → 주소 순서)
  if v_email is not null then
    perform pg_advisory_xact_lock(hashtextextended('people_email:' || p_user_id::text || ':' || v_email, 0));
  end if;

  select h.person_id, h.origin into v_person, v_origin
    from public.people_handles h
   where h.user_id = p_user_id and h.provider = p_provider and h.account_ref = p_account_ref;
  if found then
    if v_origin = 'source' then
      update public.people_handles h
         set display_name = coalesce(v_name, h.display_name), email = coalesce(v_email, h.email), connection_id = coalesce(p_connection_id, h.connection_id)
       where h.user_id = p_user_id and h.provider = p_provider and h.account_ref = p_account_ref;
    end if;
    return v_person;
  end if;

  if v_email is not null then
    select array_agg(p.id) into v_matches
      from public.people p
     where p.user_id = p_user_id and p.merged_into is null
       and exists (select 1 from unnest(p.emails) e where lower(e) = v_email);
    if cardinality(v_matches) = 1 then
      v_person := v_matches[1];
    end if;
  end if;
  if v_person is null then
    insert into public.people (user_id, display_name, emails, origin)
    values (p_user_id, v_name, case when v_email is null then '{}'::text[] else array[v_email] end, 'source')
    returning id into v_person;
  end if;
  insert into public.people_handles (user_id, person_id, provider, account_ref, display_name, email, origin, connection_id)
  values (p_user_id, v_person, p_provider, p_account_ref, v_name, v_email, 'source', p_connection_id);
  return v_person;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) 신원 링크 (아키텍처 5.5): oauth(연결 결과) · inferred(연결 자료에서 본 후보)는 연결에 묶이고, profile · user_confirmed는 묶이지 않는다.
--    그래서 연결을 끊으면(행 삭제, 외래키 cascade) 그 연결의 oauth · inferred 링크만 지워지고 사용자가 적거나 확인한 링크는 남는다.
--    로그인 계정(Sign in with Apple · Google)은 연결이 아니다: 따로 링크를 쓰지 않고 loadIdentity가 로그인 주소를 그대로 "나"로 본다.
--    로그인 계정을 링크로 적어야 하면 profile로 쓴다(연결 없음)
-- ─────────────────────────────────────────────
alter table public.identity_links
  add constraint identity_links_connection_bound check ((verified_via in ('oauth', 'inferred')) = (connection_id is not null));

-- ─────────────────────────────────────────────
-- 7) Slack 끊기 · 앱 제거 (D3): 20261013000000의 purge_slack_data를 바꿔 만든다(본문은 그대로 + 맨 끝 한 줄).
--    D3의 연결 단위 입구가 이 함수 하나라(disconnect_connection · revoke_slack_connections가 부른다) 여기에 더한다.
--    원문 글 · 조각 · 기억 글은 purge_slack_sources가 sources를 고칠 때 sources_purge_context가 지운다
-- ─────────────────────────────────────────────
create function public.purge_slack_identity(p_connection_ids uuid[])
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_slack uuid[] := array(select c.id from public.connections c where c.id = any (p_connection_ids) and c.provider = 'slack');
begin
  -- 그 연결의 "나" 링크(oauth · inferred). 사용자가 적거나 확인한 링크(profile · user_confirmed)는 연결에 묶이지 않아 남는다
  delete from public.identity_links l where l.connection_id = any (v_slack);
  -- 그 연결이 본 Slack 계정 (트리거가 사람의 handles · 출처 이름 · 이메일을 다시 계산한다: 다른 출처가 보여 준 값은 남는다)
  delete from public.people_handles h where h.connection_id = any (v_slack);
  -- 연결 행이 다른 길로 먼저 지워져 연결을 잃은 Slack 계정도 (같은 사용자)
  delete from public.people_handles h
   where h.provider = 'slack' and h.origin = 'source' and h.connection_id is null
     and h.user_id in (select c.user_id from public.connections c where c.id = any (v_slack));
end;
$$;

create or replace function public.purge_slack_data(p_connection_ids uuid[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_sources uuid[];
begin
  select coalesce(array_agg(s.id), '{}') into v_sources
    from public.sources s
    join public.connections c on c.id = s.connection_id and c.user_id = s.user_id
   where c.id = any (p_connection_ids) and c.provider = 'slack';

  perform public.purge_slack_sources(v_sources);
  delete from public.slack_messages where connection_id = any (p_connection_ids);
  delete from public.slack_threads where connection_id = any (p_connection_ids);
  delete from public.slack_people where connection_id = any (p_connection_ids);
  perform public.purge_slack_identity(p_connection_ids);
  return cardinality(v_sources);
end;
$$;

-- ─────────────────────────────────────────────
-- 8) 범위 version (아키텍처 5.4 · 6.3): 멤버 추가 · 제거 · 후보 확인, 범위 기억 추가 · 정정 · 잊기 · 삭제 · 비움,
--    멤버 원문의 새 revision · 글 지움 · 접근 상실에 오른다. 모델 후보(inferred 멤버 · inferred 기억)는 묶음에 들지 않으므로 올리지 않는다
--    (stale 신호를 거짓으로 만들지 않게, CTX12). 후보가 확인되면(origin이 inferred에서 바뀜) 오른다.
--    행 트리거 · 조각 교체는 바뀐 범위 id를 큐 표(context_version_bumps, 이 트랜잭션의 txid로)에 모으기만 하고, 큐에 들어간 행마다 걸린
--    deferred constraint trigger가 commit 직전 그 트랜잭션의 것을 꺼내 한 번에 id 순으로 올린다(큐에 넣는 길이 어디든 commit 때 비워진다). 범위 행 잠금을 트랜잭션의 마지막에, 언제나 같은 순서로만 잡으므로
--    기억 · 원문 쓰기(remember_memory_item · 원문 글 지움)와 서로 기다리다 교착하지 않는다. 한 트랜잭션은 범위마다 1 올린다.
--    큐는 소유자 권한 함수만 쓰는 표다(앱 · 익명 권한 없음): 다른 역할이 남의 범위를 큐에 넣어 올리게 할 수 없다.
--    트리거 함수는 소유자 권한이다: 계정 삭제(Supabase Auth의 supabase_auth_admin) · 앱의 원문 쓰기에서 cascade · 트리거로 불려도 돌게. new · old 행의 범위만 본다.
--    묶음을 만드는 쪽(B2 · C2)은 context_version을 기억 · 멤버와 같은 스냅샷에서(또는 먼저) 읽는다 (docs/context-layer.md 4장)
-- ─────────────────────────────────────────────
create table public.context_version_bumps (
  txid bigint not null,
  context_id uuid not null,
  primary key (txid, context_id)
);

alter table public.context_version_bumps enable row level security;
revoke all on public.context_version_bumps from anon, authenticated;

create function public.bump_context_versions(p_context_ids uuid[])
returns void
language sql
set search_path = ''
as $$
  -- 여러 범위를 함께 올릴 때 잠금 순서를 id 순으로 고정한다
  update public.work_contexts w
     set context_version = w.context_version + 1, last_activity_at = now()
    from (select id from public.work_contexts where id = any (p_context_ids) order by id for no key update) x
   where w.id = x.id;
$$;

create function public.queue_context_bumps(p_context_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.context_version_bumps (txid, context_id)
  select txid_current(), c from unnest(p_context_ids) as c where c is not null
  on conflict do nothing;
$$;

-- commit 직전: 이 트랜잭션이 모은 범위를 꺼내 한 번에 올린다 (같은 트랜잭션의 다음 호출은 꺼낼 것이 없어 아무것도 하지 않는다)
create function public.flush_context_bumps() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  with taken as (
    delete from public.context_version_bumps b where b.txid = txid_current() returning b.context_id
  )
  select array_agg(context_id) into v_ids from taken;
  if v_ids is not null then
    perform public.bump_context_versions(v_ids);
  end if;
  return null;
end;
$$;

create constraint trigger context_version_bumps_flush
  after insert on public.context_version_bumps
  deferrable initially deferred
  for each row execute function public.flush_context_bumps();

create function public.context_members_bump_version() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.origin <> 'inferred' then
      perform public.queue_context_bumps(array[new.context_id]);
    end if;
  elsif tg_op = 'DELETE' then
    if old.origin <> 'inferred' then
      perform public.queue_context_bumps(array[old.context_id]);
    end if;
  elsif old.origin <> 'inferred' or new.origin <> 'inferred' then
    perform public.queue_context_bumps(array[old.context_id, new.context_id]);
  end if;
  return null;
end;
$$;

create trigger context_members_bump_version
  after insert or delete on public.context_members
  for each row execute function public.context_members_bump_version();
-- 사용자가 빼거나 다시 넣음(removed_at) · 후보 확인(origin)
create trigger context_members_bump_version_on_update
  after update on public.context_members
  for each row
  when ((old.context_id, old.removed_at, old.origin) is distinct from (new.context_id, new.removed_at, new.origin))
  execute function public.context_members_bump_version();

create function public.memory_items_bump_context_version() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.scope_kind = 'context' and new.origin <> 'inferred' then
      perform public.queue_context_bumps(array[new.context_id]);
    end if;
  elsif old.scope_kind = 'context' and (old.origin <> 'inferred' or (tg_op = 'UPDATE' and new.origin <> 'inferred')) then
    perform public.queue_context_bumps(array[old.context_id]);
  end if;
  return null;
end;
$$;

create trigger memory_items_bump_context_version
  after insert or delete on public.memory_items
  for each row execute function public.memory_items_bump_context_version();
-- 내용이 바뀔 때만 (정정 표시 포인터가 비는 것 · updated_at만 바뀌는 것은 아니다)
create trigger memory_items_bump_context_version_on_update
  after update on public.memory_items
  for each row
  when (old.scope_kind = 'context'
        and (old.statement, old.value, old.origin, old.superseded_at, old.revoked_at, old.valid_from, old.valid_until, old.source_purged)
            is distinct from (new.statement, new.value, new.origin, new.superseded_at, new.revoked_at, new.valid_from, new.valid_until, new.source_purged))
  execute function public.memory_items_bump_context_version();

-- 멤버 원문의 변화: 같은 문서(source_document_ids)의 새 revision이 들어오거나, 글이 지워지거나, 접근을 잃거나 되찾을 때.
-- 그 문서를 멤버로 둔 범위와, 그 문서의 revision을 인용한 지금 쓰는 범위 observed 기억이 있는 범위(멤버가 아니어도 묶음의 기억이 바뀐다)
create function public.sources_bump_member_contexts() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_document uuid[] := public.source_document_ids(new.user_id, new.id);
  v_document_text text[] := array(select lower(d::text) from unnest(v_document) as d);
begin
  perform public.queue_context_bumps(array(
    select cm.context_id
      from public.context_members cm
     where cm.user_id = new.user_id and cm.removed_at is null and cm.origin <> 'inferred'
       and cm.source_id = any (v_document)
    union
    select m.context_id
      from public.memory_items m
     where m.user_id = new.user_id and m.scope_kind = 'context' and m.origin = 'observed'
       and m.superseded_at is null and m.revoked_at is null and not m.source_purged
       and m.source_ref ? 'source_id' and lower(m.source_ref ->> 'source_id') = any (v_document_text)
  ));
  return null;
end;
$$;

create trigger sources_bump_member_contexts
  after insert on public.sources
  for each row
  when (new.external_id is not null)
  execute function public.sources_bump_member_contexts();
create trigger sources_bump_member_contexts_on_update
  after update of external_version, raw_text_purged_at, raw_text_purge_reason, access_lost_at on public.sources
  for each row
  when ((old.external_version, old.raw_text_purged_at, old.raw_text_purge_reason, old.access_lost_at)
        is distinct from (new.external_version, new.raw_text_purged_at, new.raw_text_purge_reason, new.access_lost_at))
  execute function public.sources_bump_member_contexts();

-- ─────────────────────────────────────────────
-- 9) 원문 조각 교체 (아키텍처 6.2): 한 원문의 조각을 한 트랜잭션에서 바꾼다. 같은 문서(source_document_ids)의 옛 revision 조각도 함께 지운다.
--    - 원문 행을 for share로 잠근다 (글 지우기와 한 줄로. 지운 원문이면 넣지 않고 purged)
--    - 같은 문서의 교체는 advisory 잠금으로 한 번에 하나씩. 이 revision보다 나중에 들어온(created_at, id) revision이 있으면 넣지 않는다(stale):
--      늦게 끝난 옛 처리가 새 조각을 덮지 않게. 순서는 수집 순서다 (occurred_at은 Notion에서 날짜 속성 · 만든 시각이라 고친 순서가 아니다)
--    - p_embeddings는 '[…]' 문자열(1536차원) 또는 null. 순번(seq)은 0부터
--    - 문서의 지금 조각과 똑같으면(같은 revision · 순번 · 글 · 임베딩, 개수까지) 바꾸지 않는다(unchanged). 바꿨으면 그 문서를 멤버로 둔
--      범위의 version을 올린다(묶음의 자료가 바뀌었다: commit 직전 큐로, 후보 멤버 제외)
--    돌려주는 값: status(replaced · unchanged · purged · stale)와 조각 수
-- ─────────────────────────────────────────────
create function public.replace_source_chunks(p_user_id uuid, p_source_id uuid, p_texts text[], p_embeddings text[])
returns table (status text, chunks integer)
language plpgsql
set search_path = ''
as $$
declare
  v_external text;
  v_revision text;
  v_purged timestamptz;
  v_created timestamptz;
  v_document uuid[];
begin
  if coalesce(cardinality(p_texts), 0) <> coalesce(cardinality(p_embeddings), 0) then
    raise exception 'replace_source_chunks: texts and embeddings differ in length' using errcode = '22023';
  end if;
  select s.external_id, s.external_version, s.raw_text_purged_at, s.created_at
    into v_external, v_revision, v_purged, v_created
    from public.sources s
   where s.id = p_source_id and s.user_id = p_user_id
   for share;
  if not found then
    raise exception 'replace_source_chunks: source not found' using errcode = 'P0002';
  end if;
  if v_purged is not null then
    return query select 'purged'::text, 0;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('source_chunks:' || p_user_id::text || ':' || coalesce(v_external, p_source_id::text), 0));
  v_document := public.source_document_ids(p_user_id, p_source_id);
  if exists (
    select 1 from public.sources n
     where n.id = any (v_document) and n.id <> p_source_id and (n.created_at, n.id) > (v_created, p_source_id)
  ) then
    return query select 'stale'::text, 0;
    return;
  end if;

  if (select count(*) from public.source_chunks c where c.user_id = p_user_id and c.source_id = any (v_document)) = coalesce(cardinality(p_texts), 0)
     and not exists (
       select 1 from unnest(p_texts, p_embeddings) with ordinality as t (body, emb, ord)
        where not exists (
          select 1 from public.source_chunks c
           where c.user_id = p_user_id and c.source_id = p_source_id and c.source_revision is not distinct from v_revision
             and c.seq = t.ord - 1 and c.text = t.body
             and ((c.embedding is null and t.emb is null) or c.embedding operator(extensions.=) (t.emb)::extensions.vector)
        )
     ) then
    return query select 'unchanged'::text, coalesce(cardinality(p_texts), 0);
    return;
  end if;

  delete from public.source_chunks c where c.user_id = p_user_id and c.source_id = any (v_document);
  insert into public.source_chunks (user_id, source_id, source_revision, seq, text, embedding)
  select p_user_id, p_source_id, v_revision, (t.ord - 1)::int, t.body, (p_embeddings[t.ord::int])::extensions.vector
    from unnest(p_texts) with ordinality as t (body, ord);
  perform public.queue_context_bumps(array(
    select distinct cm.context_id from public.context_members cm
     where cm.user_id = p_user_id and cm.removed_at is null and cm.origin <> 'inferred' and cm.source_id = any (v_document)
  ));
  return query select 'replaced'::text, coalesce(cardinality(p_texts), 0);
end;
$$;

-- 범위 안 조각 검색 (아키텍처 6.1: 관계형 조건이 먼저, 벡터는 범위 안 보완). 지금 멤버(빠지지 않음 · 후보 아님)인 원문의 문서
-- (source_document_ids: 조각은 최신 revision에 붙고, 연결을 끊은 뒤에도 같은 문서로 묶인다)에서 글이 남은(보관 기간 · Slack 끊기 전) revision의 조각만.
-- 문서의 revision 하나라도 접근을 잃었으면 그 문서는 뺀다 (접근은 문서의 성질). Slack 원문은 조각을 만들지 않지만 여기서도 뺀다
create function public.match_context_chunks(p_user_id uuid, p_context_id uuid, p_embedding extensions.vector(1536), p_count int default 8)
returns table (id uuid, source_id uuid, source_revision text, seq integer, text text, similarity double precision)
language sql
stable
set search_path = ''
as $$
  with documents as (
    select public.source_document_ids(p_user_id, m.source_id) as ids
      from public.context_members m
     where m.user_id = p_user_id and m.context_id = p_context_id and m.member_kind = 'source'
       and m.removed_at is null and m.origin <> 'inferred'
  ),
  usable as (
    select distinct r.id
      from documents d
      cross join lateral unnest(d.ids) as r (id)
     where not exists (select 1 from public.sources lost where lost.id = any (d.ids) and lost.access_lost_at is not null)
  ),
  candidates as materialized (
    select c.id, c.source_id, c.source_revision, c.seq, c.text, c.embedding
      from usable u
      join public.sources s on s.id = u.id and s.user_id = p_user_id
      join public.source_chunks c on c.source_id = s.id and c.user_id = p_user_id
     where s.raw_text_purged_at is null
       and not exists (select 1 from public.connections k where k.id = s.connection_id and k.provider = 'slack')
       and c.embedding is not null
  )
  select x.id, x.source_id, x.source_revision, x.seq, x.text, 1 - (x.embedding operator(extensions.<=>) p_embedding) as similarity
    from candidates x
   order by x.embedding operator(extensions.<=>) p_embedding
   limit greatest(1, least(coalesce(p_count, 8), 50));
$$;

-- ─────────────────────────────────────────────
-- 10) 기억 쓰기 (아키텍처 5.3 · 6.4 + 사용자 결정 2026-10-10): 새 행 하나를 넣고, 같은 범위 · 같은 사실(kind + subject)의 지금 행과 견준다.
--     - p_corrects: 사용자가 가리킨 항목의 정정. 새 행이 그 항목의 범위 · kind · subject를 물려받고 그 항목을 정정된 이력으로 남긴다.
--       주제 없는 항목이면 'memory:<그 id>'를 주제로 정한다(그 항목 자체가 사실의 열쇠). expected_version이 다르거나 이미 정정 · 잊은 항목이면 conflict
--     - p_corrects 없이 subject가 있으면 같은 범위의 지금 행과 견준다:
--       explicit 새 행은 이긴다(같은 사실을 다시 말함 = 정정) → 지금 행 모두(후보 포함)를 정정된 이력으로.
--       observed 새 행: 지금 explicit이 있으면 진다(새 행이 처음부터 정정된 이력으로 들어간다). 아니면 observed_at이 늦은 쪽이 이긴다.
--       inferred 새 행: 후보로만 넣는다 (아무것도 덮지 않고 덮이지도 않는다)
--     - 다른 범위의 행은 보지 않는다: 프로젝트의 예외는 전체 기본값을 정정하지 않는다 (우선은 읽을 때, src/lib/context/retrieve.ts)
--     돌려주는 값: status(written · conflict), 새 행 id, 새 행이 정정한 행들, 새 행을 정정한 행(진 경우)
-- ─────────────────────────────────────────────
create function public.remember_memory_item(p_user_id uuid, p_item jsonb, p_corrects uuid default null, p_expected_version integer default null)
returns table (status text, id uuid, superseded uuid[], superseded_by uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_old public.memory_items%rowtype;
  v_kind text := p_item ->> 'kind';
  v_scope text := p_item ->> 'scope_kind';
  v_context uuid := (p_item ->> 'context_id')::uuid;
  v_action uuid := (p_item ->> 'action_id')::uuid;
  v_person uuid := (p_item ->> 'person_id')::uuid;
  v_agent text := p_item ->> 'agent_adapter';
  v_subject text := p_item ->> 'subject';
  v_origin text := p_item ->> 'origin';
  v_observed timestamptz := coalesce((p_item ->> 'observed_at')::timestamptz, now());
  v_winner uuid;
  v_losers uuid[] := '{}';
  v_current record;
  v_id uuid;
begin
  if p_corrects is not null then
    -- 정정은 사용자가 말한 것(explicit)이다: 자료 관찰 · 추정은 가리킨 항목을 정정하지 않는다
    if v_origin is distinct from 'explicit' then
      raise exception 'remember_memory_item: a correction must be explicit' using errcode = '22023';
    end if;
    -- 사실의 열쇠(범위 · kind · subject)는 바뀌지 않으므로(비어 있던 subject는 'memory:<id>'가 된다) 먼저 읽어 같은 사실의 잠금을 잡고,
    -- 그다음 행을 잠근다. 다시 말함(아래 반복문)과 같은 순서(advisory → 행)라 서로 기다리다 교착하지 않는다
    select * into v_old from public.memory_items m where m.id = p_corrects and m.user_id = p_user_id;
    if not found then
      raise exception 'remember_memory_item: memory not found' using errcode = 'P0002';
    end if;
    v_kind := v_old.kind;
    v_scope := v_old.scope_kind;
    v_context := v_old.context_id;
    v_action := v_old.action_id;
    v_person := v_old.person_id;
    v_agent := v_old.agent_adapter;
    v_subject := coalesce(v_old.subject, 'memory:' || v_old.id::text);
  end if;

  -- 'memory:<id>' 주제는 정정이 만든다 (주제 없던 항목을 가리켜 고칠 때). 새 기억이 이 모양을 쓰면 남의 사실 열쇠에 끼어든다
  if p_corrects is null and v_subject like 'memory:%' then
    raise exception 'remember_memory_item: subjects starting with memory: are reserved' using errcode = '22023';
  end if;

  if v_subject is not null then
    -- 같은 범위 · 같은 사실의 쓰기는 한 번에 하나씩
    perform pg_advisory_xact_lock(hashtextextended(concat_ws(':', 'memory_fact', p_user_id, v_kind, v_subject, v_scope,
      v_context, v_action, v_person, v_agent), 0));
  end if;

  -- 잠그는 순서를 원문 글 지우기와 맞춘다: 원문 → 기억 행 → (commit 직전) 범위. 새 행이 가리키는 원문을 기억 행보다 먼저 for share로 잠근다
  -- (가드도 같은 원문을 잠그지만 넣을 때라 늦다: 지우기가 원문을 잡고 기억 행을 기다리는 동안 이쪽이 기억 행을 잡고 원문을 기다리면 교착)
  if coalesce(p_item -> 'source_ref' ->> 'source_id', '') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    perform 1 from public.sources s
     where s.id = (p_item -> 'source_ref' ->> 'source_id')::uuid and s.user_id = p_user_id
     for share;
    if not found then
      raise exception 'remember_memory_item: source not found for this user' using errcode = 'foreign_key_violation';
    end if;
  end if;

  if p_corrects is not null then
    select * into v_old from public.memory_items m where m.id = p_corrects and m.user_id = p_user_id for update;
    if not found then
      raise exception 'remember_memory_item: memory not found' using errcode = 'P0002';
    end if;
    -- 잠그기 전에 읽은 주제와 다르면(그 사이 원문 글이 지워져 주제가 비었다) 다른 사실의 잠금을 잡은 것이다: 다시 보내게 conflict
    if (p_expected_version is not null and v_old.version <> p_expected_version) or v_old.superseded_at is not null or v_old.revoked_at is not null
       or coalesce(v_old.subject, 'memory:' || v_old.id::text) <> v_subject then
      return query select 'conflict'::text, null::uuid, '{}'::uuid[], null::uuid;
      return;
    end if;
    if v_old.subject is null then
      update public.memory_items m set subject = v_subject where m.id = v_old.id;
    end if;
  end if;

  -- 같은 사실의 지금 행을 넣기 전에 잠근다 (id 순): 원문 글 지우기(기억 행을 먼저 잠근다)와 잠그는 순서를 맞춘다
  if v_subject is not null and v_origin <> 'inferred' then
    perform 1
       from public.memory_items m
      where m.user_id = p_user_id and m.kind = v_kind and m.subject = v_subject and m.scope_kind = v_scope
        and m.context_id is not distinct from v_context and m.action_id is not distinct from v_action
        and m.person_id is not distinct from v_person and m.agent_adapter is not distinct from v_agent
        and m.superseded_at is null and m.revoked_at is null
      order by m.id
      for update;
  end if;

  insert into public.memory_items (user_id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, value,
                                   origin, source_ref, observed_at, valid_from, valid_until, confidence)
  values (
    p_user_id, v_kind, v_scope, v_context, v_action, v_person, v_agent, v_subject, p_item ->> 'statement',
    coalesce(p_item -> 'value', '{}'::jsonb), v_origin, nullif(p_item -> 'source_ref', 'null'::jsonb), v_observed,
    (p_item ->> 'valid_from')::timestamptz, (p_item ->> 'valid_until')::timestamptz, (p_item ->> 'confidence')::numeric
  )
  returning memory_items.id into v_id;

  if v_subject is not null and v_origin <> 'inferred' then
    v_winner := v_id;
    for v_current in
      select m.id, m.origin, m.observed_at
        from public.memory_items m
       where m.user_id = p_user_id and m.kind = v_kind and m.subject = v_subject and m.scope_kind = v_scope
         and m.context_id is not distinct from v_context and m.action_id is not distinct from v_action
         and m.person_id is not distinct from v_person and m.agent_adapter is not distinct from v_agent
         and m.superseded_at is null and m.revoked_at is null and (not m.source_purged or m.id = p_corrects) and m.id <> v_id
       order by m.observed_at, m.id
    loop
      if v_current.id = p_corrects or v_origin = 'explicit' then
        v_losers := v_losers || v_current.id;                          -- 정정 · 다시 말함: 새 행이 이긴다
      elsif v_current.origin = 'inferred' then
        null;                                                          -- observed는 후보를 덮지 않는다
      elsif v_current.origin = 'explicit' or v_current.observed_at > v_observed then
        v_winner := v_current.id;                                      -- explicit이 이기고, observed끼리는 늦게 읽은 쪽이 이긴다
      else
        v_losers := v_losers || v_current.id;
      end if;
    end loop;

    if v_winner <> v_id then
      update public.memory_items m set superseded_by = v_winner where m.id = v_id;
      v_losers := '{}';
    elsif cardinality(v_losers) > 0 then
      update public.memory_items m set superseded_by = v_id, version = m.version + 1 where m.id = any (v_losers);
    end if;
  end if;

  return query select 'written'::text, v_id, v_losers, case when v_winner is distinct from v_id then v_winner end;
end;
$$;

-- ─────────────────────────────────────────────
-- 11) 권한: 새 표는 A2와 같은 모양(owner_all + select만, 쓰기는 서버만). 새 함수는 서버(service role)만 부른다.
--     트리거 함수는 앱 · 익명이 직접 부를 수 없게 거둔다 (트리거로는 돈다)
-- ─────────────────────────────────────────────
alter table public.people_handles enable row level security;
create policy "owner_all" on public.people_handles for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.people_handles from anon, authenticated;
grant select on public.people_handles to authenticated;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.source_chunks_purged_source_guard()',
    'public.memory_items_purged_source_guard()',
    'public.purge_source_context(uuid, uuid[], boolean)',
    'public.sources_purge_context()',
    'public.people_refresh_from_handles(uuid)',
    'public.people_handles_refresh()',
    'public.observe_person_handle(uuid, text, text, text, text, uuid)',
    'public.purge_slack_identity(uuid[])',
    'public.bump_context_versions(uuid[])',
    'public.queue_context_bumps(uuid[])',
    'public.flush_context_bumps()',
    'public.source_document_ids(uuid, uuid)',
    'public.sources_server_columns_guard()',
    'public.set_sources_access(uuid, uuid[], boolean)',
    'public.context_source_states(uuid, uuid[])',
    'public.context_members_bump_version()',
    'public.memory_items_bump_context_version()',
    'public.sources_bump_member_contexts()',
    'public.replace_source_chunks(uuid, uuid, text[], text[])',
    'public.match_context_chunks(uuid, uuid, extensions.vector, integer)',
    'public.remember_memory_item(uuid, jsonb, uuid, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end;
$$;

grant execute on function public.observe_person_handle(uuid, text, text, text, text, uuid) to service_role;
-- 서버 경로(service role)가 부르는 내부 함수 (Supabase 기본 권한에 기대지 않는다): Slack D3(purge_slack_data → purge_slack_identity),
-- 트리거 · RPC 안에서 부르는 전파 · version · 사람 계산
grant execute on function public.purge_slack_identity(uuid[]) to service_role;
grant execute on function public.set_sources_access(uuid, uuid[], boolean) to service_role;
grant execute on function public.context_source_states(uuid, uuid[]) to service_role;
grant execute on function public.source_document_ids(uuid, uuid) to service_role;
grant execute on function public.purge_source_context(uuid, uuid[], boolean) to service_role;
grant execute on function public.queue_context_bumps(uuid[]) to service_role;
grant execute on function public.bump_context_versions(uuid[]) to service_role;
grant execute on function public.people_refresh_from_handles(uuid) to service_role;
grant execute on function public.replace_source_chunks(uuid, uuid, text[], text[]) to service_role;
grant execute on function public.match_context_chunks(uuid, uuid, extensions.vector, integer) to service_role;
grant execute on function public.remember_memory_item(uuid, jsonb, uuid, integer) to service_role;

commit;
