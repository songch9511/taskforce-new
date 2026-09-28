-- Phase 3: Action · Claim · Evidence · ActionEvent는 서버만 쓴다 (docs/PLATFORMS.md 2장).
-- 앱 · 웹은 읽기만 하고, 모든 쓰기는 /api/v1을 거쳐 이벤트를 남긴다. 그래야 지표 1(AI 오판율)이 빠짐없이 계산된다.

-- 1) 클라이언트 쓰기 막기: 본인 행 읽기만 허용
do $$
declare
  t text;
begin
  foreach t in array array['actions', 'claims', 'evidence', 'action_events'] loop
    execute format('drop policy "owner_all" on public.%I', t);
    execute format(
      'create policy "owner_select" on public.%I for select to authenticated using (user_id = (select auth.uid()))',
      t
    );
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- 2) Action: 판정 결과와 확인 요청 이유, 착수 · 활동 시각
alter table public.actions
  add column due_date date,                               -- 기한 날짜 (due_at은 그날 23:59 KST)
  add column confirm_reasons text[] not null default '{}', -- 확인 요청 이유 (담당 확인 · 병합 확인 · 판정 확인 · 규칙 3/6)
  add column resolution jsonb,                             -- 필드별 판정 이유 · 위험 신호 (resolveAction 결과 요약)
  add column started_at timestamptz,
  add column last_activity_at timestamptz not null default now(),
  add column version integer not null default 0;           -- 동시 쓰기 확인용 (write_action)

create index actions_user_open_idx on public.actions (user_id, status, needs_confirmation, due_date);

-- 3) Claim: 사용자가 앱에서 직접 고친 값도 Claim으로 남긴다 (원문 없음). 채널은 규칙 5에 쓴다.
alter table public.claims
  add column origin text not null default 'source' check (origin in ('source', 'user')),
  add column channel text check (channel in ('meeting', 'message', 'email', 'doc', 'note')),
  alter column source_id drop not null,
  alter column quote drop not null,
  alter column value drop not null,
  add constraint claims_source_origin check (origin = 'user' or (source_id is not null and quote is not null));

-- 4) ActionEvent 종류: 취소 · 다시 열림 · 착수
alter table public.action_events drop constraint action_events_type_check;
alter table public.action_events add constraint action_events_type_check check (type in (
  'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
  'user_edited', 'user_deleted', 'user_confirmed', 'user_started'
));

-- 5) 알림용 기기 토큰 (APNs). 앱이 POST /api/v1/devices로 등록하고, 사용자는 자기 기기만 본다.
--    토큰은 앱 설치 하나에 하나라 전역에서 유일하다: 같은 기기에서 다른 계정으로 로그인하면 마지막 계정으로 옮겨 간다.
create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  token text not null,
  platform text not null check (platform in ('ios', 'macos')),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  app_version text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (token)
);

create index devices_user_idx on public.devices (user_id, last_seen_at);

alter table public.devices enable row level security;
create policy "owner_select" on public.devices for select to authenticated using (user_id = (select auth.uid()));
create policy "owner_delete" on public.devices for delete to authenticated using (user_id = (select auth.uid()));
revoke insert, update on public.devices from anon, authenticated;

-- 6) 매칭: 한 사용자의 열린 Action 중 임베딩이 가까운 것 (서버 전용)
create function public.match_open_actions(p_user_id uuid, p_embedding extensions.vector(1536), p_count int default 5)
returns table (id uuid, similarity double precision)
language sql stable
set search_path = ''
as $$
  -- 사용자의 열린 Action을 먼저 좁힌 뒤 정확히 잰다. 전역 HNSW 인덱스를 타면 다른 사용자 행에 밀려
  -- 가까운 후보를 놓칠 수 있다 (필터가 인덱스 탐색 뒤에 걸리므로). 한 사용자의 열린 Action은 수백 개 수준이라 충분히 빠르다.
  with mine as materialized (
    select a.id, a.embedding from public.actions a
    where a.user_id = p_user_id and a.status = 'open' and a.embedding is not null
  )
  select m.id, 1 - (m.embedding operator(extensions.<=>) p_embedding) as similarity
  from mine m
  order by m.embedding operator(extensions.<=>) p_embedding
  limit p_count;
$$;

revoke execute on function public.match_open_actions from public, anon, authenticated;
grant execute on function public.match_open_actions to service_role;

-- 7) 지표 이벤트: 클라이언트는 app_opened · handoff_used만 남길 수 있고 고치거나 지울 수 없다.
--    action_started는 서버(POST /actions/:id/start)만 남긴다.
drop policy "owner_all" on public.metric_events;
create policy "owner_select" on public.metric_events for select to authenticated using (user_id = (select auth.uid()));
create policy "owner_insert_client_types" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type in ('app_opened', 'handoff_used'));
revoke update, delete on public.metric_events from anon, authenticated;
-- id · at · user_id는 서버가 정한다 (클라이언트가 시각을 꾸며 지표를 흔들 수 없게).
revoke insert on public.metric_events from anon, authenticated;
grant insert (type, action_id) on public.metric_events to authenticated;

-- 8) Action 쓰기를 한 트랜잭션으로: 행 잠금 + 버전 확인 → Claim · 근거 · 이벤트 삽입 → 행 갱신.
--    p_expected_version이 null이면 새 Action을 만든다. 버전이 다르면(동시에 누가 썼으면) 아무것도 쓰지 않고 false.
create function public.write_action(
  p_user_id uuid,
  p_action_id uuid,
  p_expected_version integer,
  p_action jsonb,
  p_claims jsonb default '[]',
  p_evidence jsonb default '[]',
  p_events jsonb default '[]'
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  current_version integer;
begin
  if p_expected_version is null then
    insert into public.actions (id, user_id, title, counterpart, owner, due_date, due_at, status, needs_confirmation,
                                confirm_reasons, resolution, embedding)
    values (
      p_action_id, p_user_id, p_action->>'title', p_action->>'counterpart', p_action->>'owner',
      (p_action->>'due_date')::date, (p_action->>'due_at')::timestamptz, p_action->>'status',
      (p_action->>'needs_confirmation')::boolean,
      array(select jsonb_array_elements_text(coalesce(p_action->'confirm_reasons', '[]'))),
      p_action->'resolution', (p_action->>'embedding')::extensions.vector
    );
  else
    select version into current_version from public.actions
      where id = p_action_id and user_id = p_user_id for update;
    if current_version is null then
      raise exception 'action not found' using errcode = 'P0002';
    end if;
    if current_version <> p_expected_version then
      return false;
    end if;
    update public.actions set
      title = p_action->>'title',
      owner = p_action->>'owner',
      due_date = (p_action->>'due_date')::date,
      due_at = (p_action->>'due_at')::timestamptz,
      status = p_action->>'status',
      needs_confirmation = (p_action->>'needs_confirmation')::boolean,
      confirm_reasons = array(select jsonb_array_elements_text(coalesce(p_action->'confirm_reasons', '[]'))),
      resolution = p_action->'resolution',
      last_activity_at = now(),
      version = version + 1
    where id = p_action_id and user_id = p_user_id;
  end if;

  insert into public.claims (id, user_id, action_id, source_id, field, value, quote, occurred_at,
                             speaker_role, certainty, directness, audience, origin, channel)
  select (c->>'id')::uuid, p_user_id, p_action_id, (c->>'source_id')::uuid, c->>'field', c->>'value', c->>'quote',
         (c->>'occurred_at')::timestamptz, c->>'speaker_role', c->>'certainty', c->>'directness', c->>'audience',
         coalesce(c->>'origin', 'source'), c->>'channel'
  from jsonb_array_elements(p_claims) c;

  insert into public.evidence (user_id, action_id, source_id, quote, role)
  select p_user_id, p_action_id, (e->>'source_id')::uuid, e->>'quote', e->>'role'
  from jsonb_array_elements(p_evidence) e;

  insert into public.action_events (user_id, action_id, type, before, after, source_id, actor, rule)
  select p_user_id, p_action_id, v->>'type', v->'before', v->'after', (v->>'source_id')::uuid, v->>'actor', v->>'rule'
  from jsonb_array_elements(p_events) v;

  return true;
end;
$$;

revoke execute on function public.write_action from public, anon, authenticated;
grant execute on function public.write_action to service_role;

-- 9) 착수: 착수 시각 · 이벤트 · 지표를 한 트랜잭션으로. 열린 Action만. 처음 착수한 시각을 돌려준다.
create function public.start_action(p_user_id uuid, p_action_id uuid) returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
  first_started timestamptz;
begin
  update public.actions
    set started_at = coalesce(started_at, now()), last_activity_at = now()
    where id = p_action_id and user_id = p_user_id and status = 'open'
    returning started_at into first_started;
  if first_started is null then
    raise exception 'open action not found' using errcode = 'P0002';
  end if;
  insert into public.action_events (user_id, action_id, type, before, after, actor, rule)
    values (p_user_id, p_action_id, 'user_started', null, jsonb_build_object('started_at', first_started), 'user', null);
  -- 지표 2(착수 시간): app_opened → 첫 action_started
  insert into public.metric_events (user_id, type, action_id) values (p_user_id, 'action_started', p_action_id);
  return first_started;
end;
$$;

revoke execute on function public.start_action from public, anon, authenticated;
grant execute on function public.start_action to service_role;

