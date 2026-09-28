-- 사용자별 요청 횟수 제한을 한 트랜잭션에서 센다 (물어보기 · 누락 신고 · 연결 시작).
-- 전에는 서버가 시도 수를 읽고(select) 따로 남겨서(insert), 동시에 들어온 요청이 모두 한도 아래로 보고 통과할 수 있었다.
-- take_rate_limit은 사용자 · 종류마다 advisory lock을 잡은 채로 세고 남기므로 동시 요청도 한도를 넘지 못한다.

-- 1) 시도 기록 (물어보기 · 연결 시작). 누락 신고는 원래 표(missing_reports, 20261002000000)를 그대로 쓴다.
--    질문 · 답 · 주소는 남기지 않는다. 쓰기는 서버(take_rate_limit)만 한다.
create table public.rate_limit_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('ask', 'connection_start')),
  created_at timestamptz not null default now()
);

create index rate_limit_events_user_kind_created_idx on public.rate_limit_events (user_id, kind, created_at);

alter table public.rate_limit_events enable row level security;
create policy "owner_select" on public.rate_limit_events for select to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update, delete on public.rate_limit_events from anon, authenticated;

-- 2) 한도 확인 + 시도 기록 (서버 전용).
--    최근 p_window_seconds 안의 시도가 p_max개 미만이면 한 번을 남기고 null, 아니면 남기지 않고 다시 할 수 있는 시각
--    (가장 최근 p_max번째 시도가 창 밖으로 나가는 시각)을 돌려준다.
--    같은 사용자 · 종류의 호출은 advisory lock으로 한 줄로 세운다: 앞선 호출이 커밋해야 다음 호출이 세기 시작한다
--    (plpgsql의 문장마다 새 스냅샷을 보므로 앞선 호출의 기록이 보인다).
create function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int)
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
  elsif p_kind in ('ask', 'connection_start') then
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
