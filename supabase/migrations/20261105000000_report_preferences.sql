-- 0.2.0 보고 설정 · 일일 보고 (구현 계획 H1, 디자인 준비도 D06 · 5.5): 표 2개 report_preferences · report_deliveries,
-- 트리거 함수 1개와 서버 전용 함수 4개 (보고 잡기 · 다시 잡기 · 끝난 대기 닫기 · 상태 숫자).
--
-- - 읽고 쓰는 코드는 REPORTS_V2_ENABLED gate 뒤에만 있다 (src/lib/reports, GET · PUT /api/v2/reports/preferences, cron/reports).
--   gate가 꺼져 있으면 표는 비어 있고 기존 알림(cron/reminders · 확인 요청 · 재연결)은 그대로다.
-- - report_preferences: 사용자당 한 행(user_id가 기본 키, profiles · billing_accounts와 같다). 기본값은 D06:
--   Both · 08:30 · 조용한 시간 22:00–08:00 · Respect Focus 켬. 시간대는 기본값이 없다: Mac이 보낸 IANA 이름만 쓴다(추측하지 않는다).
--   행이 없으면 API가 기본값을 돌려주고 일일 보고는 보내지 않는다 (시간대를 모르므로).
--   시각은 "HH:MM" 글자(계약 reportClockSchema와 같은 모양). 조용한 시간 끄기(Off) = quiet_start · quiet_end 모두 null.
--   같은 시작 · 끝은 0시간인지 24시간인지 모호해서 받지 않는다.
-- - report_deliveries: 보낸(또는 보내려던) 일일 보고 원장. 유일 키 (user_id, kind, time_zone, report_date)와 claim 함수의 사용자 잠금이
--   cron이 겹쳐 돌아도 같은 날 보고를 두 번 잡지 못하게 한다. 실패 내용은 짧은 코드(last_error)만 남기고 알림 문구 · 원문은 남기지 않는다.
-- - 권한: 앱은 자기 행을 RLS로 읽기만 한다(owner_all + select). 쓰기는 서버(service role)만 한다 — 20261103000000_context_core와 같은 모양.
-- - 계정 삭제: auth.users → report_preferences → report_deliveries 로 on delete cascade.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.

begin;

-- ─────────────────────────────────────────────
-- 1) report_preferences: 보고 설정 (Mac Reports 탭, H2)
-- ─────────────────────────────────────────────
create table public.report_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  mode text not null default 'both' check (mode in ('both', 'daily', 'meaningful')),
  daily_time text not null default '08:30' check (daily_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  quiet_start text default '22:00' check (quiet_start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  quiet_end text default '08:00' check (quiet_end ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  respect_focus boolean not null default true,
  -- IANA 이름 모양만 DB가 본다. 실제로 있는 시간대인지는 서버(Intl, 일정 계산과 같은 런타임)가 저장 전에 확인한다
  time_zone text not null check (char_length(time_zone) <= 64 and time_zone ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$'),
  -- 일정에 닿는 값(mode · daily_time · quiet_* · time_zone)이 바뀐 시각. 트리거만 쓴다 (오늘 보고를 잃지 않는 규칙, src/lib/reports/schedule.ts)
  schedule_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint report_preferences_quiet_pair check ((quiet_start is null) = (quiet_end is null)),
  constraint report_preferences_quiet_window check (quiet_start <> quiet_end)
);

-- ─────────────────────────────────────────────
-- 2) report_deliveries: 일일 보고 원장 (멱등 · 재시도)
--    report_date = 잡을 때 그 시간대(time_zone)의 현지 날짜. scheduled_at = 그날의 예정 시각(UTC), expires_at = 이 뒤로는 보내지 않는다.
--    pending: 잡혀서 보내는 중이거나 다시 보낼 차례를 기다린다(next_attempt_at). sent · failed · skipped는 끝.
--    attempts는 잡을 때마다 오른다(보내는 쪽의 펜스 토큰). last_error는 코드만 (예: no_devices · empty · stale · network · apns_500)
-- ─────────────────────────────────────────────
create table public.report_deliveries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.report_preferences (user_id) on delete cascade,
  kind text not null check (kind in ('daily')),
  time_zone text not null check (char_length(time_zone) <= 64 and time_zone ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$'),
  report_date date not null,
  scheduled_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0 check (attempts >= 0),
  claimed_at timestamptz not null default now(),
  next_attempt_at timestamptz,
  sent_at timestamptz,
  last_error text check (last_error ~ '^[a-z0-9_]{1,64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, kind, time_zone, report_date),
  constraint report_deliveries_window check (expires_at >= scheduled_at),
  constraint report_deliveries_pending_next check ((status = 'pending') = (next_attempt_at is not null)),
  constraint report_deliveries_sent_at check ((status = 'sent') = (sent_at is not null))
);

create index report_deliveries_user_scheduled_idx on public.report_deliveries (user_id, kind, scheduled_at desc);
create index report_deliveries_pending_idx on public.report_deliveries (next_attempt_at) where status = 'pending';

-- ─────────────────────────────────────────────
-- 3) updated_at · schedule_changed_at
-- ─────────────────────────────────────────────
create trigger report_preferences_set_updated_at
  before update on public.report_preferences
  for each row execute function public.set_updated_at();
create trigger report_deliveries_set_updated_at
  before update on public.report_deliveries
  for each row execute function public.set_updated_at();

-- 일정에 닿는 값이 바뀌었을 때만 schedule_changed_at을 지금으로. 그 밖에는 이전 값을 지킨다 (서버 코드도 직접 바꾸지 못한다)
create function public.report_preferences_schedule_changed() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.mode, new.daily_time, new.quiet_start, new.quiet_end, new.time_zone)
     is distinct from (old.mode, old.daily_time, old.quiet_start, old.quiet_end, old.time_zone) then
    new.schedule_changed_at = now();
  else
    new.schedule_changed_at = old.schedule_changed_at;
  end if;
  return new;
end;
$$;

create trigger report_preferences_schedule_changed
  before update on public.report_preferences
  for each row execute function public.report_preferences_schedule_changed();
revoke all on function public.report_preferences_schedule_changed() from public, anon, authenticated;

-- ─────────────────────────────────────────────
-- 4) 서버 전용 함수 (cron/reports, src/lib/reports/store.ts). 호출자 권한 · search_path = '' · service_role만 실행
-- ─────────────────────────────────────────────

-- 새 일일 보고 잡기. 같은 사용자의 잡기는 설정 행 잠금으로 한 줄로 선다: 동시에 도는 cron 둘이 같은 날을 두 번 잡지 못한다.
-- 지금 시간대의 이 현지 날짜(p_day_start부터) 또는 그 뒤에 예정된 보고가 이미 있으면(어느 시간대로 잡았든, 상태와 상관없이) 잡지 않는다:
-- 하루에 보고는 하나, 늦은 날짜를 보낸 뒤에 앞 날짜를 보내지 않는다. 잡으면 attempts 1 · 임대(p_lease_seconds) 동안 다른 실행이 다시 잡지 못한다.
create function public.claim_report_delivery(
  p_user_id uuid,
  p_kind text,
  p_time_zone text,
  p_report_date date,
  p_day_start timestamptz,
  p_scheduled_at timestamptz,
  p_expires_at timestamptz,
  p_now timestamptz,
  p_lease_seconds integer
) returns setof public.report_deliveries
language plpgsql
set search_path = ''
as $$
begin
  perform 1 from public.report_preferences where user_id = p_user_id for update;
  if not found then
    return;
  end if;
  if exists (
    select 1 from public.report_deliveries d
     where d.user_id = p_user_id and d.kind = p_kind and d.scheduled_at >= p_day_start
  ) then
    return;
  end if;
  return query
    insert into public.report_deliveries (user_id, kind, time_zone, report_date, scheduled_at, expires_at, status, attempts, claimed_at, next_attempt_at)
    values (p_user_id, p_kind, p_time_zone, p_report_date, p_scheduled_at, p_expires_at, 'pending', 1, p_now, p_now + make_interval(secs => p_lease_seconds))
    on conflict (user_id, kind, time_zone, report_date) do nothing
    returning *;
end;
$$;

-- 실패한(또는 보내다 멈춘) 보고 다시 잡기: 대기 중 · 차례가 됨 · 시도 횟수가 남음 · 아직 늦지 않음 · 더 뒤에 예정된 보고가 없음.
-- 잡기와 같은 사용자 잠금을 잡고, 행 잠금으로 다시 확인하므로 겹친 실행 중 하나만 잡는다.
create function public.claim_report_retry(
  p_id uuid,
  p_now timestamptz,
  p_lease_seconds integer,
  p_max_attempts integer
) returns setof public.report_deliveries
language plpgsql
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  select d.user_id into v_user_id from public.report_deliveries d where d.id = p_id;
  if not found then
    return;
  end if;
  perform 1 from public.report_preferences where user_id = v_user_id for update;
  return query
    update public.report_deliveries d
       set attempts = d.attempts + 1,
           next_attempt_at = p_now + make_interval(secs => p_lease_seconds)
     where d.id = p_id
       and d.status = 'pending'
       and d.next_attempt_at <= p_now
       and d.attempts < p_max_attempts
       and p_now <= d.expires_at
       and not exists (
         select 1 from public.report_deliveries o
          where o.user_id = d.user_id and o.kind = d.kind and o.scheduled_at > d.scheduled_at
       )
    returning d.*;
end;
$$;

-- 더 보낼 수 없는 대기 행을 닫는다: 늦었거나(expires_at 지남) 시도를 다 썼고, 지금 보내는 중이 아니다(임대가 끝남).
-- 이미 남긴 실패 코드는 그대로, 없으면 stale (보내다 멈춘 실행). 닫은 행 수를 돌려준다
create function public.finish_stale_report_deliveries(p_now timestamptz, p_max_attempts integer) returns integer
language sql
set search_path = ''
as $$
  with done as (
    update public.report_deliveries
       set status = 'failed', next_attempt_at = null, last_error = coalesce(last_error, 'stale')
     where status = 'pending'
       and next_attempt_at <= p_now
       and (p_now > expires_at or attempts >= p_max_attempts)
    returning 1
  )
  select count(*)::integer from done;
$$;

-- 일일 보고의 상태 숫자: 열린 할 일의 개수만 센다 (제목 · 상대 · 원문 · 메모 열을 읽지 않는다, 알림에는 숫자만 실린다).
-- review = 확인 요청, 나머지는 내 일(owner me, 확인 요청 아님): overdue = 기한이 오늘(사용자 현지 날짜) 전, due_today = 오늘,
-- in_progress = 착수했고 기한이 없거나 오늘 뒤 (앞의 두 숫자와 겹치지 않는다)
create function public.report_status_counts(p_user_id uuid, p_today date)
returns table (review integer, overdue integer, due_today integer, in_progress integer)
language sql
stable
set search_path = ''
as $$
  select
    count(*) filter (where a.needs_confirmation)::integer,
    count(*) filter (where not a.needs_confirmation and a.owner = 'me' and a.due_date < p_today)::integer,
    count(*) filter (where not a.needs_confirmation and a.owner = 'me' and a.due_date = p_today)::integer,
    count(*) filter (where not a.needs_confirmation and a.owner = 'me' and a.started_at is not null
                       and (a.due_date is null or a.due_date > p_today))::integer
  from public.actions a
  where a.user_id = p_user_id and a.status = 'open';
$$;

revoke all on function public.claim_report_delivery(uuid, text, text, date, timestamptz, timestamptz, timestamptz, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.claim_report_retry(uuid, timestamptz, integer, integer) from public, anon, authenticated;
revoke all on function public.finish_stale_report_deliveries(timestamptz, integer) from public, anon, authenticated;
revoke all on function public.report_status_counts(uuid, date) from public, anon, authenticated;
grant execute on function public.claim_report_delivery(uuid, text, text, date, timestamptz, timestamptz, timestamptz, timestamptz, integer) to service_role;
grant execute on function public.claim_report_retry(uuid, timestamptz, integer, integer) to service_role;
grant execute on function public.finish_stale_report_deliveries(timestamptz, integer) to service_role;
grant execute on function public.report_status_counts(uuid, date) to service_role;

-- ─────────────────────────────────────────────
-- 5) RLS · 권한: 본인 행만 읽는다 (owner_all). 쓰기 권한은 없다 — 서버(service role, RLS 우회)만 쓴다
-- ─────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array['report_preferences', 'report_deliveries'] loop
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
