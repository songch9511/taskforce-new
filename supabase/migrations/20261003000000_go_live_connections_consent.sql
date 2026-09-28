-- go live 1장: 앱에서 연결하기 · 외부 AI 처리 동의 · 2단계 연동 "원해요" (docs/GO_LIVE.md 1장 · 8장)

-- 1) 연결: Google(Calendar · Meet 전사)과 Gmail(별도 프로젝트)을 따로 연결한다.
--    reauth: 토큰이 만료돼 다시 연결해야 함 (Google 테스트 상태 7일 만료 등). 동기화하지 않고 앱이 재연결을 안내한다.
alter table public.connections drop constraint connections_provider_check;
alter table public.connections add constraint connections_provider_check
  check (provider in ('notion', 'google', 'gmail', 'slack', 'github'));
alter table public.connections drop constraint connections_status_check;
alter table public.connections add constraint connections_status_check
  check (status in ('active', 'error', 'revoked', 'reauth'));

-- 2) 앱의 OAuth 시작(POST /api/v1/connections/{provider}/start)이 만든 서명된 state의 nonce. callback에서 한 번만 쓴다.
--    앱이 띄운 브라우저에는 로그인 세션이 없어서, 사용자는 서명된 state로 정하고 같은 state를 두 번 쓰지 못하게 여기서 지운다.
--    정책이 없으므로 클라이언트는 읽을 수도 쓸 수도 없다 (service role만).
create table public.oauth_nonces (
  nonce text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('notion', 'google', 'gmail', 'slack')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index oauth_nonces_user_expires_idx on public.oauth_nonces (user_id, expires_at);
create index oauth_nonces_expires_idx on public.oauth_nonces (expires_at);

alter table public.oauth_nonces enable row level security;
revoke all on public.oauth_nonces from anon, authenticated;

-- 2-1) 앱 OAuth의 완료 대기 (handoff). callback은 code를 바로 토큰으로 바꾸지 않고 여기에 암호화해 두고
--      taskforce://connections/{provider}?handoff=<id>로 돌려보낸다. 연결은 시작한 사용자가 로그인한 앱에서
--      POST /api/v1/connections/{provider}/complete {handoff}로만 마친다 (user_id가 같아야 하고, 2분 안에, 한 번만).
--      그래서 남이 만든 권한 주소를 눌러도 연결이 그 사람 계정에 붙지 않는다. 정책이 없으므로 service role만 읽고 쓴다.
create table public.oauth_handoffs (
  id text primary key check (char_length(id) >= 32),
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('notion', 'google', 'gmail', 'slack')),
  sealed_code text not null,                  -- AES-256-GCM 암호문 (CONNECTOR_TOKEN_KEY, src/lib/connectors/crypto.ts)
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index oauth_handoffs_expires_idx on public.oauth_handoffs (expires_at);

alter table public.oauth_handoffs enable row level security;
revoke all on public.oauth_handoffs from anon, authenticated;

-- 3) 2단계 연동 "원해요" (POST /api/v1/connection-requests). 사용자 · 서비스마다 하나 (다시 눌러도 그대로).
--    수요가 많은 순서로 붙인다 (원칙 6). 쓰기는 서버만 한다. 앱은 자기 요청을 읽어 "요청함"을 보여줄 수 있다.
create table public.connection_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  provider text not null check (provider in ('microsoft', 'zoom', 'github', 'linear', 'jira')),
  created_at timestamptz not null default now(),
  unique (user_id, provider)
);

alter table public.connection_requests enable row level security;
create policy "owner_select" on public.connection_requests for select to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update, delete on public.connection_requests from anon, authenticated;

-- 4) 지표 이벤트: 연결 완료 (설치 → 연결 → 첫 Action 흐름). 서버(OAuth callback)만 남긴다.
--    클라이언트 insert 정책은 app_opened 그대로다 (20261001000000).
alter table public.metric_events drop constraint metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in ('app_opened', 'action_started', 'handoff_used', 'connection_created'));

-- 5) 외부 AI 처리 동의 (App Store 5.1.2(i)). null이면 서버는 원문을 LLM · Jev · 임베딩에 보내지 않는다.
--    동의 · 철회는 서버(POST · DELETE /api/v1/consent)만 쓴다: 클라이언트는 프로필의 다른 열만 쓸 수 있다.
--    기존 사용자를 동의한 것으로 바꾸지 않는다 (앱에서 한 번 동의해야 한다).
alter table public.profiles add column ai_consent_at timestamptz;

revoke insert, update on public.profiles from anon, authenticated;
grant insert (user_id, display_name, aliases, emails) on public.profiles to authenticated;
grant update (user_id, display_name, aliases, emails) on public.profiles to authenticated;

-- 6) 동기화할 연결 (cron · 수동 동기화 · 연결 직후): 동의한 사용자의 active · error 연결만, 오래 안 한 순서로 (서버 전용).
--    동의하지 않은 사용자의 연결은 쿼리 단계에서 빠진다. 동기화 도중 철회는 원문 처리 직전의 확인이 막는다 (src/lib/consent).
create function public.syncable_connections(p_providers text[], p_user_id uuid default null)
returns table (id uuid, user_id uuid, provider text, settings jsonb, sync_cursor jsonb, last_synced_at timestamptz)
language sql stable
set search_path = ''
as $$
  select c.id, c.user_id, c.provider, c.settings, c.sync_cursor, c.last_synced_at
  from public.connections c
  join public.profiles p on p.user_id = c.user_id and p.ai_consent_at is not null
  where c.provider = any (p_providers)
    and c.status in ('active', 'error')
    and (p_user_id is null or c.user_id = p_user_id)
  order by c.last_synced_at asc nulls first, c.id;
$$;

revoke execute on function public.syncable_connections from public, anon, authenticated;
grant execute on function public.syncable_connections to service_role;
