-- 직접 추가(POST /api/v1/actions)의 사용자별 횟수 제한: take_rate_limit에 종류 action_create를 더한다.
-- 시도 기록은 물어보기 · 연결 시작과 같은 표(rate_limit_events)에 남긴다. 제목 · 구절은 남기지 않는다.

alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check (kind in ('ask', 'connection_start', 'action_create'));

-- 20261005000000_atomic_rate_limits와 같고, rate_limit_events로 세는 종류에 action_create만 더했다.
create or replace function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int)
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
  perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || p_kind));
  v_since := clock_timestamp() - v_window;

  if p_kind = 'missing_report' then
    select r.created_at into v_nth from public.missing_reports r
    where r.user_id = p_user_id and r.created_at > v_since
    order by r.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.missing_reports (user_id, created_at) values (p_user_id, clock_timestamp());
  elsif p_kind in ('ask', 'connection_start', 'action_create') then
    select e.created_at into v_nth from public.rate_limit_events e
    where e.user_id = p_user_id and e.kind = p_kind and e.created_at > v_since
    order by e.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.rate_limit_events (user_id, kind, created_at) values (p_user_id, p_kind, clock_timestamp());
  else
    raise exception 'take_rate_limit: 모르는 종류 %', p_kind;
  end if;
  return null;
end;
$$;

revoke execute on function public.take_rate_limit from public, anon, authenticated;
grant execute on function public.take_rate_limit to service_role;
