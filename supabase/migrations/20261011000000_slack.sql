-- Slack 연동 (docs/go-live/slack-integration.md 2-6).
-- Slack은 메시지를 Events API로 보내 준다(/api/connectors/slack/events). 남길 메시지만 slack_messages에 모아 두었다가,
-- 대화가 30분 멈추면 묶어서 원문(sources)으로 넣는다(동기화). 나머지 채널 메시지는 받는 즉시 버리고 저장하지 않는다.
--
-- 새 표 세 개는 모두 서버만 쓴다: 정책이 없으므로 클라이언트(anon · authenticated)는 읽을 수도 쓸 수도 없다(service role만 RLS를 우회).
-- CLAUDE.md의 owner_all 규칙에서 벗어나는 이유: 앱이 읽을 일이 없고, 원문 본문(남의 메시지)이 들어 있어
-- oauth_handoffs · connection_secrets와 같게 둔다. 연결 · 계정을 지우면 함께 지워진다(복합 외래키 cascade).

-- 1) 대기 메시지: 원문으로 넣기 전의 메시지. 넣으면 source_id를 적고(재전송 막기용으로 3일 남김) 처리가 끝나면 text를 비운다.
create table public.slack_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  connection_id uuid not null,
  channel_id text not null,
  channel_type text not null check (channel_type in ('im', 'mpim', 'channel', 'group')),
  ts text not null,                           -- Slack 메시지 id (예: 1727678400.123456)
  thread_ts text,                             -- 스레드 답글이면 첫 글의 ts
  sender_id text not null,                    -- 보낸 사람의 Slack 사용자 id
  text text not null default '',              -- Slack 원본 글 (<@U…> 언급 그대로). 원문으로 넣고 처리가 끝나면 비운다
  edited_at timestamptz,
  received_at timestamptz not null default now(),
  source_id uuid,                             -- 이 메시지를 담아 넣은 원문
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade,
  -- 동의 철회 등으로 원문이 지워지면 표시가 풀려 다시 묶인다 (slack-integration.md 2-5)
  foreign key (source_id, user_id) references public.sources (id, user_id) on delete set null (source_id),
  unique (connection_id, channel_id, ts)
);

create index slack_messages_pending_idx on public.slack_messages (connection_id, received_at) where source_id is null;
create index slack_messages_source_idx on public.slack_messages (source_id) where source_id is not null;

alter table public.slack_messages enable row level security;
revoke all on public.slack_messages from anon, authenticated;

-- 2) 추적 스레드: 채널에서 사용자가 쓰거나 언급된 스레드. 이 스레드의 답글은 사용자를 부르지 않아도 남긴다.
create table public.slack_threads (
  connection_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  channel_id text not null,
  thread_ts text not null,
  last_activity_at timestamptz not null default now(),
  primary key (connection_id, channel_id, thread_ts),
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade
);

alter table public.slack_threads enable row level security;
revoke all on public.slack_threads from anon, authenticated;

-- 3) 이름 캐시: Slack 사용자 · 대화 id → 이름 (users.info · conversations.info, 7일)
create table public.slack_people (
  connection_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  slack_id text not null,
  kind text not null check (kind in ('user', 'conversation')),
  name text not null,
  fetched_at timestamptz not null default now(),
  primary key (connection_id, slack_id),
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade
);

alter table public.slack_people enable row level security;
revoke all on public.slack_people from anon, authenticated;

-- 4) 연결 · 다시 연결한 시각. Slack이 늦게 보낸 tokens_revoked · app_uninstalled가 그 뒤에 다시 한 연결을 끊지 않게 한다.
--    created_at은 다시 연결해도 그대로이고(saveConnection이 행을 고친다), updated_at은 동기화마다 바뀌어 쓸 수 없다.
alter table public.connections add column connected_at timestamptz not null default now();
update public.connections set connected_at = created_at;

-- 5) 원문 본문을 지운 이유. retention: 저장 90일(purge_expired_source_text), disconnected: Slack 연결을 끊거나 앱을 지움(slack-integration.md D3).
--    null이면서 raw_text_purged_at이 있으면 이 열이 생기기 전의 90일 정리다.
alter table public.sources
  add column raw_text_purge_reason text check (raw_text_purge_reason in ('retention', 'disconnected'));
