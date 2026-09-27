-- 구조화된 할 일 (Notion 할 일 DB 등, docs/INTEGRATIONS.md "Notion 할 일 DB").
-- 속성 값을 LLM 없이 코드가 Claim으로 옮긴다. 바뀐 버전마다 속성 스냅샷을 원문 한 줄로 남겨 근거로 쓴다.

-- 1) 원문 종류 'task'와 속성 스냅샷 ({ snapshot, editedByUser }: 실패한 버전을 페이지를 다시 읽지 않고 다시 처리할 수 있게)
alter table public.sources drop constraint sources_kind_check;
alter table public.sources add constraint sources_kind_check
  check (kind in ('meeting', 'message', 'email', 'doc', 'note', 'task'));
alter table public.sources add column structured jsonb;   -- kind = 'task'의 속성 스냅샷 (제목 · 담당 · 기한 · 상태)과 고친 사람이 사용자인지

-- 2) Claim: 채널 'task', 출처 'tracker'(사용자가 할 일 도구에서 직접 고친 값. 앱에서 고친 'user'와 같은 권한이지만 AI 오판으로 세지 않는다)
--    tracker도 원문 · 인용이 있어야 한다 (claims_source_origin은 'user'만 예외로 둔다).
alter table public.claims drop constraint claims_channel_check;
alter table public.claims add constraint claims_channel_check
  check (channel in ('meeting', 'message', 'email', 'doc', 'note', 'task'));
alter table public.claims drop constraint claims_origin_check;
alter table public.claims add constraint claims_origin_check check (origin in ('source', 'user', 'tracker'));

-- 3) 외부 할 일 ↔ Action 연결. 첫 등장 때 매칭한 결과를 남기고, 이후 버전은 매칭 없이 이 표로 붙인다.
--    서버만 쓴다 (actions와 같은 규칙): 사용자는 자기 행을 읽기만 한다.
create table public.action_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  connection_id uuid not null,
  external_id text not null,                 -- 예: Notion 페이지 id
  action_id uuid not null,
  created_at timestamptz not null default now(),
  unique (connection_id, external_id),
  foreign key (connection_id, user_id) references public.connections (id, user_id) on delete cascade,
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade
);

create index action_links_action_idx on public.action_links (action_id);

alter table public.action_links enable row level security;
create policy "owner_select" on public.action_links for select to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update, delete on public.action_links from anon, authenticated;

-- 4) 동기화가 외부 할 일마다 "마지막으로 처리를 마친 버전(비교 기준)"과 "처리를 마치지 못한 가장 최근 버전(다시 처리)"을 한 번에 읽는다.
--    항목 id가 많아도(처음 훑기) 주소 길이 · 행 수 한도에 걸리지 않게 함수로 둔다. 서버(service role)만 부른다.
create function public.task_source_states(p_user_id uuid, p_connection_id uuid, p_external_ids text[])
returns table (
  external_id text,
  source_id uuid,
  external_version text,
  structured jsonb,
  processing_status text,
  started_at timestamptz,                   -- 처리를 시작한 시각 (멈춘 처리를 가려낸다)
  linked boolean
)
language sql
stable
set search_path = ''
as $$
  with latest as (
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, s.processing_status,
            coalesce((s.processing_summary->>'started_at')::timestamptz, s.created_at) as started_at
       from public.sources s
      where s.user_id = p_user_id and s.connection_id = p_connection_id and s.kind = 'task'
        and s.external_id = any (p_external_ids) and s.processing_status = 'done'
      order by s.external_id, s.occurred_at desc, s.created_at desc)
    union all
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, s.processing_status,
            coalesce((s.processing_summary->>'started_at')::timestamptz, s.created_at) as started_at
       from public.sources s
      where s.user_id = p_user_id and s.connection_id = p_connection_id and s.kind = 'task'
        and s.external_id = any (p_external_ids) and s.processing_status <> 'done'
      order by s.external_id, s.occurred_at desc, s.created_at desc)
  )
  select l.external_id, l.id, l.external_version, l.structured, l.processing_status, l.started_at,
         exists (select 1 from public.action_links a
                  where a.user_id = p_user_id and a.connection_id = p_connection_id and a.external_id = l.external_id)
    from latest l;
$$;

revoke execute on function public.task_source_states from public, anon, authenticated;
grant execute on function public.task_source_states to service_role;
