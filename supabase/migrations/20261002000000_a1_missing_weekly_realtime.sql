-- Phase A1: 누락 신고(지표 4) · 주간 질문(지표 5) · 누락 신고 횟수 제한 · 앱의 Action 실시간 반영.

-- 1) ActionEvent 종류: 사용자가 원문 구절로 빠진 할 일을 신고해 생긴 Action (after: { stage, source_id })
--    같은 트랜잭션에서 created(actor ai)와 함께 남는다. 지표 1(AI 오판율)의 분모에서 빼고 지표 4의 분자로 센다.
alter table public.action_events drop constraint action_events_type_check;
alter table public.action_events add constraint action_events_type_check check (type in (
  'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
  'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing'
));

-- 2) 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?" 응답 (지표 5: 그림자 목록 비율).
--    한 사용자 · 한 주(한국 시간 월요일)에 하나. 쓰기는 서버(POST /api/v1/weekly-check, service role)만 한다 — actions와 같은 규칙.
--    다시 답하면 덮어쓰고 answered_at도 새로 적는다. 지표 5와 "이번 주에 답했나"는 answered_at으로 본다 (created_at은 첫 답).
create table public.weekly_checks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  week_start date not null check (extract(isodow from week_start) = 1),  -- 그 주 월요일
  answer text not null check (answer in ('yes', 'no', 'skipped')),
  answered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, week_start)
);

alter table public.weekly_checks enable row level security;
create policy "owner_select" on public.weekly_checks for select to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update, delete on public.weekly_checks from anon, authenticated;

-- 3) 누락 신고 시도: 신고 한 번이 LLM · Jev · 임베딩을 부르므로 사용자별 횟수를 제한한다 (POST /api/v1/sources/:id/missing).
--    추출을 시작하기 전에 서버(service role)가 한 줄씩 남기고, 최근 시도 수로 429를 가른다. 원문 · 구절은 남기지 않는다.
create table public.missing_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index missing_reports_user_created_idx on public.missing_reports (user_id, created_at);

alter table public.missing_reports enable row level security;
create policy "owner_select" on public.missing_reports for select to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update, delete on public.missing_reports from anon, authenticated;

-- 4) Realtime: 앱이 actions 변경을 구독해 지금 할 일을 다시 불러온다 (읽기 권한은 RLS owner_select 그대로).
--    Supabase가 아닌 Postgres(PGlite 테스트)에는 publication이 없으므로 있을 때만 추가한다.
do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'actions'
     ) then
    alter publication supabase_realtime add table public.actions;
  end if;
end;
$$;
