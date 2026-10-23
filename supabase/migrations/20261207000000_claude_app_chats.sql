-- Claude 데스크톱 세션과 나눈 대화 저장 (OA PR-D3s, 계약 handoffs/oa-external-sessions-contract.md 25 · 26장):
-- Mac이 Claude 데스크톱 앱에 열린 세션으로 보낸 글("Received"로 확인된 것)과 그 뒤 세션이 쓴 답 글을 서버에 저장해 사용자의 다른 기기에서 보이게 한다.
-- **서버가 시작하는 보내기 길은 없다**: 이 표들은 bridge 명령 · 대화 · 에이전트 작업과 이어지지 않고, 쓰기 입구는 아래 서버 함수 둘뿐이다 (읽기는 앱이 RLS로 직접).
--
-- 저장하는 것 (25.1 + 26장 Q-D3a): 보낸 글 · 답 글의 글, 답 글 앞에서 쓴 **도구 단계의 이름만**(순서대로, 한 답 글에 최대 40개), 제목(1–200자), Mac이 만든 불투명 id(HMAC).
-- 저장하지 않는 것: 도구 입력 · 결과 · 경로 · 명령, 폴더 이름, Claude 세션 id, pid, 데스크톱에서 직접 친 말. 도구 이름은 도메인 claude_app_tool_name(영문 · 숫자 · _ · -, 128자 이하:
-- 실제 Claude Code MCP 이름은 mcp__<서버 이름 또는 uuid>__<도구> 모양이라 API의 64자를 넘는다)이라 `Bash(git status)` · 경로 · 공백이 든 값은 DB가 거절한다.
-- 보관 (26장 Q-D3b): **사용자가 지우거나 계정을 지울 때까지** 둔다. 자동 정리 함수 · cron은 없다 (purge_* 없음, /api/cron/retention은 이 표를 건드리지 않는다).
--
-- 이 파일이 하는 일:
--   0) 적용 순서 가드: 맨 앞에서 metric_events_type_check에 claude_app_session_opened가 있는지 본다. 없으면(= 20261206000000이 아직 적용되지 않았으면) 예외로 멈춘다 (보안 검토 P2-2).
--      이 파일은 그 검사를 "20261206의 목록 + 새 종류"로 다시 만들기 때문에, 순서가 바뀌면 D2의 종류가 조용히 빠진다.
--   1) claude_app_chats · claude_app_chat_messages · claude_app_chat_tombstones (user_id + owner_all RLS + 부모와의 (id, user_id) 복합 외래키).
--      앱은 채팅 · 메시지를 select만, 묘비는 읽지도 못한다. 쓰기는 서버 함수(service role)만.
--        - bridge **해제(revoke)는 지우지 않는다** (external_sessions와 다르다: 사용자의 대화 기록이다). bridge 삭제 · 계정 삭제는 cascade.
--        - unique (chat_id, mac_ref)로 같은 묶음을 두 번 올려도 한 행이다. 답 글의 reply_to는 **같은 채팅의 사용자 글**만 가리킨다 (복합 외래키 (reply_to, chat_id)).
--        - 묘비(claude_app_chat_tombstones): 사용자가 대화를 지울 때 그 대화의 **사용자 글 mac_ref**(불투명 hex 64자)만 (bridge, session_ref)별로 남긴다. 응답을 못 받은 Mac이 지운 뒤에
--          같은 묶음을 다시 보내도 대화가 되살아나지 않게 하는 것뿐이다 (글 · 제목 · 도구 이름 없음). 사용자별 10,000개까지만 두고 넘으면 가장 오래된 것부터 지운다.
--   2) save_claude_app_chat: 한 교환의 행들을 올린다 (멱등). 소유 확인 → 사용자별 직렬화 → 묘비 확인 → 채팅 upsert → 행을 보낸 순서대로 넣는다 → 한도 확인.
--        - 사용자 글 없이 답 글만 온 묶음(또는 사용자 글이 모두 묘비에 든 묶음)은 채팅을 만들지 않는다: 사용자가 지운 대화를 되살리지 못하게 한다 (모두 orphan, 지표 없음).
--        - 사용자별 한도 (보안 검토 P2-1 · P3): 저장 합계 50 MiB(모든 행의 본문 바이트 + 행마다 512바이트), 행 20만 개, 채팅 2,000개. 넘기면 아무것도 쓰지 않고 quota_exceeded.
--          이미 저장된 행의 재시도는 한도에 걸리지 않는다. 합계는 생성 열 body_bytes를 덮는 (user_id) include (body_bytes) 인덱스로 index-only scan 한다.
--          (행 몫 512 때문에 50 MiB에 닿는 행 수는 102,400개 안쪽이라 20만 행 상한은 그 위의 안전판이다.)
--        - 새로 들어간 사용자 글마다 같은 트랜잭션에서 claude_app_message_sent를 남긴다 (props {result:'received'}뿐, 글 · id 0).
--        - said_at은 서버 시각 + 1일까지로 자른다. title은 p_keep_title이면 그대로 두고 아니면 p_title로 바꾼다(null이면 지운다); 새 행이 없는 재시도는 제목도 건드리지 않는다.
--   3) delete_claude_app_chat: 사용자가 채팅을 지운다 (행 cascade) + 묘비 + claude_app_chat_deleted (props 없음). 저장과 같은 사용자별 잠금으로 겹침을 직렬화한다.
--   4) metric_events 종류 검사: 바로 앞 목록(20261206000000_claude_app_session_metrics.sql, claude_app_session_opened까지)의 전체 + claude_app_message_sent · claude_app_chat_deleted.
--      앱 insert 정책(owner_insert_client_app_types)은 그대로다: 앱이 이 종류를 직접 남기지 못한다. 이 PR은 PR-D2(20261206)보다 **늦게** 병합한다.
--      (앞으로 이 검사를 다시 만드는 마이그레이션은 이 두 종류를 목록에 이어 가져야 한다 — tests/metrics/agent-event-registry.test.ts가 최신 목록을 등록부와 대조한다.)
--   5) 속도 제한 종류 claude_app_chat (저장 요청, 10분에 120번) · claude_app_sent (보내기 결과 지표 route, 10분에 120번) · claude_app_chat_day (저장 요청, 하루에 1,000번):
--      한도 값은 route가 정한다 (src/lib/api/claude-app-chats.ts CLAUDE_APP_CHAT_LIMIT · CLAUDE_APP_CHAT_DAILY_LIMIT · CLAUDE_APP_SENT_LIMIT). 종류를 나눠 한쪽이 차도 다른 쪽이 굶지 않는다.
--      rate_limit_events 종류 검사는 20261204000000의 목록 그대로 + 이 셋, take_rate_limit은 그 파일의 본문 그대로 + 이 셋 (create or replace).
--
-- 함수 규칙 (invoker + search_path 빈 값, public · anon · authenticated 실행 권한 없음, service role만 — report_external_sessions 같은 형제 서버 전용 함수와 같다):
--   - security definer가 아니다: 호출자는 서버의 service role(admin 클라이언트)뿐이고 쓰는 표는 service role이 이미 쓸 수 있다. 권한을 올려 줄 이유가 없다.
--   - 인자 모양을 한 번 더 강제한다(22023, 아무것도 쓰지 않는다): 알려진 칸만, ref는 소문자 hex 64자, 시각은 ISO-8601, 글 길이, 도구 이름 모양 · 40개. 실제 입구는 route의 zod가 먼저 막는다.
--   - 소유 확인이 먼저다: bridge는 이 사용자 것이고 active이며(for share로 쥔다 — 그 사이 해제가 끼어들지 못한다) 아니면 not_found (없는 · 남의 · 해제된 bridge를 구별해 알리지 않는다). 잠금은 확인 뒤에 잡는다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 0) 적용 순서 가드
-- ─────────────────────────────────────────────
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'metric_events_type_check' and conrelid = 'public.metric_events'::regclass
       and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_session_opened%'
  ) then
    raise exception '20261207_claude_app_chats: apply 20261206000000_claude_app_session_metrics.sql first (metric_events_type_check does not contain claude_app_session_opened)';
  end if;
end;
$$;

-- ─────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────
-- 도구 단계 이름의 모양: 영문 · 숫자 · _ · -, 128자 이하. Anthropic API의 도구 이름은 64자까지지만 Claude Code가 기록에 남기는 MCP 이름(mcp__<서버>__<도구>)은 그보다 길다 (uuid 서버: 80자 안팎).
create domain public.claude_app_tool_name as text check (value ~ '^[A-Za-z0-9_-]{1,128}$');

-- title: Claude Code 기록의 제목에서 Mac이 뽑아 제어 글자를 지운 것(1–200자). 없으면 null. 사용자 글에 가깝다 — 로그 · 지표 · AI 호출에 쓰지 않는다. 마지막 묶음이 말한 값으로 바뀐다.
-- session_ref: Mac이 세션 UUID에서 "Mac에만 있는 열쇠"로 만든 HMAC (external_sessions.session_ref와 같은 값). 서버는 Claude 세션을 찾을 수 없다.
create table public.claude_app_chats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  bridge_id uuid not null,
  session_ref text not null check (session_ref ~ '^[0-9a-f]{64}$'),
  title text check (title is null or char_length(title) between 1 and 200),
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (bridge_id, session_ref),
  constraint claude_app_chats_bridge_fkey foreign key (bridge_id, user_id)
    references public.bridges (id, user_id) on delete cascade
);

create index claude_app_chats_user_idx on public.claude_app_chats (user_id, last_message_at desc);

create trigger claude_app_chats_set_updated_at
  before update on public.claude_app_chats
  for each row execute function public.set_updated_at();

-- role user = Taskforce에서 보낸 글(Mac이 대상 기록에서 "Received"를 확인한 것), assistant = 그 뒤 세션이 쓴 답 글.
-- mac_ref: Mac 열쇠 HMAC (사용자 글 = peer msg_id + 보낸 pid, 답 글 = 기록 줄의 uuid + 블록 번호). 서버는 기록 id를 모른다.
-- body: 사용자 글 1–16,000자, 답 글 1–65,536바이트(UTF-8). truncated: Mac이 상한에서 잘랐는가.
-- tool_names: 이 답 글 앞에서 쓴 도구 단계의 **이름만**, 순서대로 최대 40개 (답 글에만). said_at: 기록 줄의 시각 — 보여 줄 때는 said_at, seq 순서로 정렬한다.
create table public.claude_app_chat_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  chat_id uuid not null,
  seq bigint generated always as identity,
  role text not null check (role in ('user', 'assistant')),
  mac_ref text not null check (mac_ref ~ '^[0-9a-f]{64}$'),
  reply_to uuid,
  body text not null check (octet_length(body) between 1 and 65536),
  -- 본문 바이트: 사용자별 한도 합계를 인덱스만 읽어 싸게 구하려는 생성 열이다 (아래 claude_app_chat_messages_user_idx). 쓸 수 없고 octet_length(body)와 늘 같다
  body_bytes integer generated always as (octet_length(body)) stored,
  truncated boolean not null,
  tool_names public.claude_app_tool_name[] not null default '{}',
  said_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (id, chat_id),
  unique (chat_id, mac_ref),
  constraint claude_app_chat_messages_chat_fkey foreign key (chat_id, user_id)
    references public.claude_app_chats (id, user_id) on delete cascade,
  constraint claude_app_chat_messages_reply_user_fkey foreign key (reply_to, user_id)
    references public.claude_app_chat_messages (id, user_id) on delete cascade,
  constraint claude_app_chat_messages_reply_chat_fkey foreign key (reply_to, chat_id)
    references public.claude_app_chat_messages (id, chat_id) on delete cascade,
  constraint claude_app_chat_messages_reply_role check ((role = 'assistant') = (reply_to is not null)),
  constraint claude_app_chat_messages_user_body check (role <> 'user' or char_length(body) <= 16000),
  constraint claude_app_chat_messages_tool_names check (
    cardinality(tool_names) <= 40
    and array_position(tool_names::text[], null) is null
    and (role = 'assistant' or cardinality(tool_names) = 0)
  )
);

-- 사용자별 한도의 합계 질의(sum(body_bytes + 512), count(*) ... where user_id = ...)를 이 인덱스만으로 읽는다 (index-only scan): 본문(TOAST)을 열지 않고 행당 몇 바이트만 훑는다.
create index claude_app_chat_messages_user_idx on public.claude_app_chat_messages (user_id) include (body_bytes);
create index claude_app_chat_messages_chat_idx on public.claude_app_chat_messages (chat_id, seq);
create index claude_app_chat_messages_reply_idx on public.claude_app_chat_messages (reply_to) where reply_to is not null;

alter table public.claude_app_chats enable row level security;
create policy "owner_all" on public.claude_app_chats for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.claude_app_chats from anon, authenticated;
grant select on public.claude_app_chats to authenticated;

alter table public.claude_app_chat_messages enable row level security;
create policy "owner_all" on public.claude_app_chat_messages for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.claude_app_chat_messages from anon, authenticated;
grant select on public.claude_app_chat_messages to authenticated;
-- 보여 주는 순서(seq)를 앱이 건드리지 못하게 한다 (identity 열은 서버 함수의 insert가 권한 검사 없이 채운다)
revoke all on sequence public.claude_app_chat_messages_seq_seq from anon, authenticated;

-- 묘비 (코드 검토 P2-4): 사용자가 지운 대화의 **사용자 글 mac_ref**만 (bridge, session_ref)별로 남긴다. 응답을 못 받은 Mac이 지운 뒤에 같은 묶음을 다시 보내도(재시도)
-- 그 사용자 글은 orphan으로 거절되고 대화도 지표도 되살아나지 않는다. 새로 보낸 글은 새 mac_ref라 막히지 않는다. 담는 것은 불투명 hex뿐이다 (글 · 제목 · 도구 이름 없음).
-- 채팅 표를 가리키지 않는다(채팅이 지워진 뒤에도 남아야 한다): bridge(복합 외래키)와 계정에만 묶여 함께 지워진다. 앱은 읽지도 못한다 (권한 없음; 서버 함수만).
create table public.claude_app_chat_tombstones (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  bridge_id uuid not null,
  session_ref text not null check (session_ref ~ '^[0-9a-f]{64}$'),
  mac_ref text not null check (mac_ref ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  primary key (bridge_id, session_ref, mac_ref),
  constraint claude_app_chat_tombstones_bridge_fkey foreign key (bridge_id, user_id)
    references public.bridges (id, user_id) on delete cascade
);

create index claude_app_chat_tombstones_user_idx on public.claude_app_chat_tombstones (user_id, created_at desc);

alter table public.claude_app_chat_tombstones enable row level security;
create policy "owner_all" on public.claude_app_chat_tombstones for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.claude_app_chat_tombstones from anon, authenticated;

-- ─────────────────────────────────────────────
-- 2) save_claude_app_chat: 한 교환의 행들을 올린다 (멱등)
-- ─────────────────────────────────────────────
-- p_messages: [{ mac_ref, role, reply_to_ref?, body, truncated, said_at, tool_names? }] 1–20개, mac_ref 중복 없음, 보낸 순서대로 (사용자 글이 그 답 글보다 앞이다).
-- 응답: { status: 'not_found' } · { status: 'quota_exceeded' } (아무것도 쓰지 않았다) 또는 { status: 'ok', chat_id (채팅이 없고 만들지 않았으면 null), saved, existing, orphan }.
--   existing = 이미 저장된 행(재시도), orphan = reply_to_ref가 같은 채팅의 사용자 글로 풀리지 않은 답 글 · 묘비에 든 사용자 글(그 행만 거절하고 나머지는 저장한다).
-- p_keep_title: true면 저장된 제목을 그대로 둔다 (요청에 title 칸이 없었다). false(기본)면 p_title로 바꾼다 (null이면 지운다). 새 행이 없는 재시도는 어느 쪽이든 제목을 건드리지 않는다.
create function public.save_claude_app_chat(p_user_id uuid, p_bridge_id uuid, p_session_ref text, p_title text, p_messages jsonb, p_keep_title boolean default false) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c_max_user_bytes constant bigint := 52428800;  -- 사용자별 저장 합계 50 MiB = 모든 행의 (본문 바이트 + 행 몫)의 합
  c_row_overhead constant integer := 512;        -- 행마다 본문에 더해 세는 몫 (행 · 인덱스 · 도구 이름 · 키): 한 줄짜리 글을 수십만 개 넣어 한도를 우회하지 못하게 한다
  c_max_user_rows constant integer := 200000;    -- 사용자별 행 수 하드 상한
  c_max_user_chats constant integer := 2000;     -- 사용자별 채팅 수
  v_count integer;
  v_chat uuid;
  v_el jsonb;
  v_role text;
  v_id uuid;
  v_reply uuid;
  v_tool_names public.claude_app_tool_name[];
  v_tombstoned text[];
  v_saved integer := 0;
  v_existing integer := 0;
  v_orphan integer := 0;
  v_new_users integer := 0;
  v_used bigint;
  v_rows bigint;
begin
  if p_user_id is null or p_bridge_id is null or p_session_ref is null or p_messages is null or p_keep_title is null
     or p_session_ref !~ '^[0-9a-f]{64}$'
     or (p_title is not null and char_length(p_title) not between 1 and 200)
     or jsonb_typeof(p_messages) <> 'array' then
    raise exception 'save_claude_app_chat: invalid argument' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_messages);
  if v_count not between 1 and 20 then
    raise exception 'save_claude_app_chat: invalid batch size' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_messages) e where jsonb_typeof(e) is distinct from 'object') then
    raise exception 'save_claude_app_chat: invalid element' using errcode = '22023';
  end if;
  -- 알려진 칸만 (경로 · 도구 입력 · 결과 같은 칸이 끼어들면 거절)
  if exists (select 1 from jsonb_array_elements(p_messages) e
              where (e - array['mac_ref', 'role', 'reply_to_ref', 'body', 'truncated', 'said_at', 'tool_names']) <> '{}'::jsonb) then
    raise exception 'save_claude_app_chat: unknown field' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_messages) e
    where jsonb_typeof(e -> 'mac_ref') is distinct from 'string' or (e ->> 'mac_ref') !~ '^[0-9a-f]{64}$'
       or (e ->> 'role') is null or (e ->> 'role') not in ('user', 'assistant')
       or jsonb_typeof(e -> 'body') is distinct from 'string' or octet_length(e ->> 'body') not between 1 and 65536
       or jsonb_typeof(e -> 'truncated') is distinct from 'boolean'
       or jsonb_typeof(e -> 'said_at') is distinct from 'string'
       or (e ->> 'said_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
       or ((e ->> 'role') = 'user' and (char_length(e ->> 'body') > 16000 or (e -> 'reply_to_ref') is not null
                                        or ((e -> 'tool_names') is not null and e -> 'tool_names' <> '[]'::jsonb)))
       or ((e ->> 'role') = 'assistant' and (jsonb_typeof(e -> 'reply_to_ref') is distinct from 'string' or (e ->> 'reply_to_ref') !~ '^[0-9a-f]{64}$'))
       or ((e -> 'tool_names') is not null and jsonb_typeof(e -> 'tool_names') is distinct from 'array')
  ) then
    raise exception 'save_claude_app_chat: invalid message' using errcode = '22023';
  end if;
  -- 도구 단계는 이름만: 최대 40개, 이름 모양 (경로 · 명령 · 객체는 거절)
  if exists (
    select 1 from jsonb_array_elements(p_messages) e,
      lateral (select count(*) as n, coalesce(bool_and(jsonb_typeof(t) = 'string' and (t #>> '{}') ~ '^[A-Za-z0-9_-]{1,128}$'), true) as ok
                 from jsonb_array_elements(case when jsonb_typeof(e -> 'tool_names') = 'array' then e -> 'tool_names' else '[]'::jsonb end) t) x
    where x.n > 40 or not x.ok
  ) then
    raise exception 'save_claude_app_chat: invalid tool names' using errcode = '22023';
  end if;
  if (select count(distinct e ->> 'mac_ref') from jsonb_array_elements(p_messages) e) <> v_count then
    raise exception 'save_claude_app_chat: duplicate mac_ref' using errcode = '22023';
  end if;
  -- 시각 값이 달력에 없는 날이면 (2026-02-30 같은) 캐스트가 실패한다 → 같은 22023
  begin
    perform (e ->> 'said_at')::timestamptz from jsonb_array_elements(p_messages) e;
  exception when invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
    raise exception 'save_claude_app_chat: invalid time' using errcode = '22023';
  end;

  -- 소유 확인이 먼저다: 없는 · 남의 · 해제된 bridge id로는 잠금을 잡지 못한다. 확인한 행은 for share로 쥐고 있어 그 사이 해제(update)가 끼어들지 못한다.
  perform 1 from public.bridges where id = p_bridge_id and user_id = p_user_id and status = 'active' for share;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  -- 같은 사용자의 저장 · 지우기는 한 번에 하나씩: 뒤따르는 답 글이 앞선 사용자 글을 볼 수 있고, 지우기와 겹쳐도 반쯤 지워진 채팅이 없고, 사용자별 한도를 동시에 넘지 못한다.
  -- (한 사용자의 요청이 줄을 서는 것뿐이다: 속도 제한이 이미 사용자별로 요청 수를 막는다)
  perform pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0));

  -- 묘비: 이 묶음의 사용자 글 중 사용자가 이미 지운 대화의 것 (지운 뒤 재시도가 대화를 되살리지 못하게 한다)
  select coalesce(array_agg(t.mac_ref), '{}'::text[]) into v_tombstoned from public.claude_app_chat_tombstones t
   where t.bridge_id = p_bridge_id and t.session_ref = p_session_ref
     and t.mac_ref in (select e ->> 'mac_ref' from jsonb_array_elements(p_messages) e where e ->> 'role' = 'user');

  select c.id into v_chat from public.claude_app_chats c
   where c.bridge_id = p_bridge_id and c.session_ref = p_session_ref and c.user_id = p_user_id;
  if v_chat is null then
    -- 묘비에 들지 않은 사용자 글이 없는 묶음은 채팅을 만들지 않는다 (지운 대화를 늦게 온 답 글 · 재시도가 되살리지 못한다)
    if not exists (select 1 from jsonb_array_elements(p_messages) e where e ->> 'role' = 'user' and not ((e ->> 'mac_ref') = any (v_tombstoned))) then
      return jsonb_build_object('status', 'ok', 'chat_id', null, 'saved', 0, 'existing', 0, 'orphan', v_count);
    end if;
    -- 사용자별 채팅 한도
    if (select count(*) from public.claude_app_chats c where c.user_id = p_user_id) >= c_max_user_chats then
      return jsonb_build_object('status', 'quota_exceeded');
    end if;
  end if;

  -- 아래 한 덩어리(채팅 만들기 + 행 넣기)가 사용자별 본문 한도를 넘기면 통째로 되돌린다 (이 블록 안의 쓰기만 롤백된다)
  begin
  if v_chat is null then
    insert into public.claude_app_chats (user_id, bridge_id, session_ref, title)
      values (p_user_id, p_bridge_id, p_session_ref, case when p_keep_title then null else p_title end)
      on conflict (bridge_id, session_ref) do update set title = excluded.title
      returning id into v_chat;
  end if;
  for v_el in select e from jsonb_array_elements(p_messages) with ordinality as t(e, ord) order by ord loop
    v_id := null;
    v_role := v_el ->> 'role';
    if v_role = 'user' then
      if (v_el ->> 'mac_ref') = any (v_tombstoned) then
        v_orphan := v_orphan + 1;
        continue;
      end if;
      insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, body, truncated, said_at)
        values (p_user_id, v_chat, 'user', v_el ->> 'mac_ref', v_el ->> 'body', (v_el ->> 'truncated')::boolean, least((v_el ->> 'said_at')::timestamptz, now() + interval '1 day'))
        on conflict (chat_id, mac_ref) do nothing
        returning id into v_id;
      if v_id is null then
        v_existing := v_existing + 1;
      else
        v_saved := v_saved + 1;
        v_new_users := v_new_users + 1;
      end if;
    else
      select m.id into v_id from public.claude_app_chat_messages m where m.chat_id = v_chat and m.mac_ref = v_el ->> 'mac_ref';
      if found then
        v_existing := v_existing + 1;
        continue;
      end if;
      -- 답 글은 같은 채팅의 사용자 글로만 풀린다 (다른 채팅 · 답 글 · 없는 ref는 orphan)
      select m.id into v_reply from public.claude_app_chat_messages m
       where m.chat_id = v_chat and m.role = 'user' and m.mac_ref = v_el ->> 'reply_to_ref';
      if not found then
        v_orphan := v_orphan + 1;
        continue;
      end if;
      v_tool_names := array(
        select t.name from jsonb_array_elements_text(v_el -> 'tool_names') with ordinality as t(name, i) order by t.i
      )::public.claude_app_tool_name[];
      insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, reply_to, body, truncated, tool_names, said_at)
        values (p_user_id, v_chat, 'assistant', v_el ->> 'mac_ref', v_reply, v_el ->> 'body', (v_el ->> 'truncated')::boolean, v_tool_names, least((v_el ->> 'said_at')::timestamptz, now() + interval '1 day'))
        on conflict (chat_id, mac_ref) do nothing
        returning id into v_id;
      if v_id is null then
        v_existing := v_existing + 1;
      else
        v_saved := v_saved + 1;
      end if;
    end if;
  end loop;

  -- 사용자별 저장 한도 (50 MiB, 경계 포함, 행마다 본문 + 512바이트로 센다 · 행 수 20만): 새 행이 들어갔고 합계나 행 수가 넘으면 이 블록의 쓰기(채팅 만들기 포함)를 모두 되돌리고 quota_exceeded.
  -- 새 행이 없는 호출(재시도)은 한도를 묻지 않는다. 합계와 행 수는 한 질의로, (user_id) include (body_bytes) 인덱스만 읽어 구한다 (사용자별 잠금 아래).
  if v_saved > 0 then
    select coalesce(sum(m.body_bytes + c_row_overhead), 0), count(*) into v_used, v_rows from public.claude_app_chat_messages m where m.user_id = p_user_id;
    if v_used > c_max_user_bytes or v_rows > c_max_user_rows then
      raise exception 'claude_app_chat_quota' using errcode = 'P0001';
    end if;
  end if;
  exception when sqlstate 'P0001' then
    -- 우리가 던진 한도 예외만 받는다 (다른 P0001은 그대로 올린다)
    if sqlerrm <> 'claude_app_chat_quota' then
      raise;
    end if;
    return jsonb_build_object('status', 'quota_exceeded');
  end;

  -- 제목: p_keep_title이면 그대로, 아니면 p_title로 바꾼다 (null이면 지운다). 새 행이 있을 때만 제목 · 마지막 대화 시각을 고친다 (재시도는 건드리지 않는다)
  if v_saved > 0 then
    update public.claude_app_chats set title = case when p_keep_title then title else p_title end, last_message_at = now() where id = v_chat and user_id = p_user_id;
  end if;
  -- 지표 (원칙 6): 새로 들어간 사용자 글마다 하나. 같은 트랜잭션이라 묶음이 롤백되면 지표도 없다. props는 결과 코드뿐 (글 · 제목 · id 0)
  if v_new_users > 0 then
    insert into public.metric_events (user_id, type, props)
      select p_user_id, 'claude_app_message_sent', jsonb_build_object('result', 'received') from generate_series(1, v_new_users);
  end if;
  return jsonb_build_object('status', 'ok', 'chat_id', v_chat, 'saved', v_saved, 'existing', v_existing, 'orphan', v_orphan);
end;
$$;
revoke all on function public.save_claude_app_chat(uuid, uuid, text, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.save_claude_app_chat(uuid, uuid, text, text, jsonb, boolean) to service_role;

-- ─────────────────────────────────────────────
-- 3) delete_claude_app_chat: 사용자가 저장된 대화를 지운다
-- ─────────────────────────────────────────────
-- 응답: { status: 'deleted' | 'not_found' } (남의 · 없는 id는 구별하지 않는다). bridge가 해제된 뒤에도 지울 수 있다 (사용자의 기록이다).
-- 지울 때 그 대화의 사용자 글 mac_ref를 묘비로 남긴다 (코드 검토 P2-4): 지운 뒤 재시도가 대화를 되살리지 못한다. 묘비는 사용자별 10,000개까지 (넘으면 가장 오래된 것부터 지운다).
create function public.delete_claude_app_chat(p_user_id uuid, p_chat_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c_max_tombstones constant integer := 10000;
  v_id uuid;
begin
  if p_user_id is null or p_chat_id is null then
    raise exception 'delete_claude_app_chat: invalid argument' using errcode = '22023';
  end if;
  -- 저장과 같은 사용자별 잠금: 저장이 끝난 뒤에 지우거나, 지운 뒤에 온 저장은 채팅이 없는 것(과 묘비)을 본다
  perform pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0));
  insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref)
    select c.user_id, c.bridge_id, c.session_ref, m.mac_ref
      from public.claude_app_chats c
      join public.claude_app_chat_messages m on m.chat_id = c.id and m.user_id = c.user_id
     where c.id = p_chat_id and c.user_id = p_user_id and m.role = 'user'
    on conflict do nothing;
  delete from public.claude_app_chats where id = p_chat_id and user_id = p_user_id returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  -- 묘비 개수 상한: 가장 오래된 것부터 (재시도는 몇 분 안의 일이라 새 것이면 충분하다)
  delete from public.claude_app_chat_tombstones t
   where t.user_id = p_user_id
     and (t.bridge_id, t.session_ref, t.mac_ref) in (
       select o.bridge_id, o.session_ref, o.mac_ref from public.claude_app_chat_tombstones o
        where o.user_id = p_user_id order by o.created_at desc, o.mac_ref desc offset c_max_tombstones
     );
  insert into public.metric_events (user_id, type, props) values (p_user_id, 'claude_app_chat_deleted', '{}'::jsonb);
  return jsonb_build_object('status', 'deleted');
end;
$$;
revoke all on function public.delete_claude_app_chat(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_claude_app_chat(uuid, uuid) to service_role;

-- ─────────────────────────────────────────────
-- 4) metric_events: claude_app_message_sent · claude_app_chat_deleted
-- ─────────────────────────────────────────────
-- 종류 검사: 20261206000000의 전체 목록(20261204000000 + claude_app_session_opened) + 이 두 종류. 앱 insert 정책은 바꾸지 않는다 (위 머리 주석).
alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
    'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed',
    'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved',
    'billing_checkout_started', 'billing_trial_started', 'billing_subscription_activated', 'billing_payment_succeeded',
    'billing_payment_failed', 'billing_plan_changed', 'billing_subscription_cancelled', 'billing_subscription_resumed',
    'billing_subscription_ended', 'billing_lifetime_purchased', 'billing_refund_requested', 'billing_refunded',
    'billing_portal_opened', 'billing_duplicate_purchase', 'billing_review_needed', 'billing_legacy_marked', 'billing_notice_scheduled',
    'ai_key_saved', 'ai_key_deleted', 'ai_key_revoked',
    'external_sessions_shown',
    'session_attached',
    'claude_app_session_opened',
    'claude_app_message_sent', 'claude_app_chat_deleted'
  ));

-- ─────────────────────────────────────────────
-- 5) 속도 제한 종류 claude_app_chat · claude_app_sent · claude_app_chat_day
-- ─────────────────────────────────────────────
-- 새 종류 셋만 더한다: claude_app_chat = 저장 요청(PUT)의 10분 한도, claude_app_chat_day = 같은 요청의 하루(86,400초) 한도(사용자별 1,000번), claude_app_sent = 보내기 결과 지표 route.
-- 한도 값은 route가 정하고 저장 함수보다 먼저 센다. 앞 목록 · 본문은 20261204000000_agent_session_attach.sql의 take_rate_limit 그대로다 (종류 목록 두 곳만 다르다).
-- (rate_limit_events의 정리는 하루 지난 행을 지운다 — 하루 창이 정확히 그 경계다.)
alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check(kind in ('ask','connection_start','action_create','run_create','bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key','agent_attach','claude_app_chat','claude_app_sent','claude_app_chat_day'));

create or replace function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int,p_bridge_id uuid default null)
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
  if p_kind in ('bridge_events','bridge_ack','bridge_poll','bridge_decide') and (p_bridge_id is null or not exists(
    select 1 from public.bridges where id=p_bridge_id and user_id=p_user_id)) then
    raise exception 'take_rate_limit: invalid bridge' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || p_kind || ':' || coalesce(p_bridge_id::text,'')));
  v_since := clock_timestamp() - v_window;

  if p_kind = 'missing_report' then
    select r.created_at into v_nth from public.missing_reports r
    where r.user_id = p_user_id and r.created_at > v_since
    order by r.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.missing_reports (user_id, created_at) values (p_user_id, clock_timestamp());
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create', 'bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key','agent_attach','claude_app_chat','claude_app_sent','claude_app_chat_day') then
    if p_bridge_id is not null then
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id = p_bridge_id and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    else
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id is null and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    end if;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.rate_limit_events (user_id, kind, created_at,bridge_id) values (p_user_id, p_kind, clock_timestamp(),p_bridge_id);
  else
    raise exception 'take_rate_limit: 모르는 종류 %', p_kind;
  end if;
  return null;
end;
$$;

revoke execute on function public.take_rate_limit from public, anon, authenticated;
grant execute on function public.take_rate_limit to service_role;

commit;
