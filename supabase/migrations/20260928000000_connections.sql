-- 외부 서비스 연동 (Notion · Gmail · Slack · GitHub)
-- 연결 정보는 사용자가 볼 수 있지만, 토큰은 connection_secrets에 암호화해 두고 서버(service role)만 읽는다.

create table public.connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  provider text not null check (provider in ('notion', 'gmail', 'slack', 'github')),
  external_account_id text not null,          -- 워크스페이스 · 계정 id
  display_name text,                          -- 워크스페이스 이름 등
  status text not null default 'active' check (status in ('active', 'error', 'revoked')),
  settings jsonb not null default '{}',       -- 수집 범위 (예: Notion 데이터 소스 id 목록)
  sync_cursor jsonb,                          -- 어디까지 가져왔는지
  last_synced_at timestamptz,
  sync_started_at timestamptz,                -- 동기화 중이면 시작 시각 (같은 연결을 동시에 돌리지 않는 잠금)
  last_error text,                            -- 원문을 담지 않는 짧은 오류
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider, external_account_id),
  unique (id, user_id)
);

create trigger connections_set_updated_at
  before update on public.connections
  for each row execute function public.set_updated_at();

-- 사용자는 자기 연결을 보고 끊을 수 있다. 만들기 · 고치기는 서버가 한다 (토큰 교환 · 동기화).
alter table public.connections enable row level security;
create policy "owner_select" on public.connections for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owner_delete" on public.connections for delete to authenticated
  using (user_id = (select auth.uid()));

create table public.connection_secrets (
  connection_id uuid primary key references public.connections (id) on delete cascade,
  sealed_token text not null,                 -- AES-256-GCM 암호문 (src/lib/connectors/crypto.ts)
  updated_at timestamptz not null default now()
);

-- 정책이 없으므로 클라이언트(anon · authenticated)는 읽을 수도 쓸 수도 없다. service role만 RLS를 우회한다.
alter table public.connection_secrets enable row level security;
revoke all on public.connection_secrets from anon, authenticated;

-- 연동으로 들어온 원문은 어느 연결의 어떤 항목인지 남겨 같은 항목을 두 번 넣지 않는다.
alter table public.sources
  add column connection_id uuid,
  add column external_id text,                -- 예: Notion 페이지 id
  add column external_version text,           -- 예: 페이지의 last_edited_time
  add foreign key (connection_id, user_id) references public.connections (id, user_id)
    on delete set null (connection_id);

create unique index sources_external_idx on public.sources (connection_id, external_id, external_version)
  where connection_id is not null;
