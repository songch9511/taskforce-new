-- 작업 상태 (POST /api/v1/actions/:id/progress): 할 일 · 진행 중 · 완료.
-- 할 일 = 열림 + 착수 전(started_at null), 진행 중 = 열림 + 착수, 완료 = done.

-- 1) ActionEvent 종류: 착수를 되돌림 (진행 중 → 할 일, actor user, before · after: { started_at }).
--    처음 착수 시각은 이벤트(user_started)와 지표(action_started)에 남아 있으므로 지표 2는 바뀌지 않는다.
--    AI 판단을 고친 것이 아니므로 지표 1(AI 오판율)에 넣지 않는다.
alter table public.action_events drop constraint action_events_type_check;
alter table public.action_events add constraint action_events_type_check check (type in (
  'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
  'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created',
  'user_unstarted'
));

-- 2) 작업 상태 바꾸기를 한 트랜잭션으로: 행 잠금 + 버전 확인 → 상태 쓰기(write_action, 사용자 Claim · user_edited)
--    → 착수 시각 바꾸기. 완료였던 것을 다시 열고 착수하는 도중에 멈춰 "다시 열렸지만 착수 전" 같은 반쪽 상태가 남지 않는다.
--    p_action이 null이면 상태는 그대로 두고 착수 시각만 바꾼다. 상태 값은 서버가 Claim에서 판정해 넘긴다 (write_action과 같은 모양).
--    p_started: true 착수(start_action과 같다: user_started · action_started), false 착수 되돌리기(user_unstarted), null 그대로.
--    착수 · 되돌리기는 잠근 행의 started_at을 보고 바뀔 때만 한다 (이미 그 상태면 이벤트도 남기지 않는다).
--    버전이 다르면(동시에 누가 썼으면) 아무것도 쓰지 않고 false. 착수 시각만 바꿀 때는 버전을 올리지 않는다 (start_action과 같다).
create function public.set_action_progress(
  p_user_id uuid,
  p_action_id uuid,
  p_expected_version integer,
  p_action jsonb,
  p_claims jsonb default '[]',
  p_evidence jsonb default '[]',
  p_events jsonb default '[]',
  p_started boolean default null
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  current_version integer;
  previous_started timestamptz;
begin
  select version, started_at into current_version, previous_started from public.actions
    where id = p_action_id and user_id = p_user_id for update;
  if current_version is null then
    raise exception 'action not found' using errcode = 'P0002';
  end if;
  if current_version <> p_expected_version then
    return false;
  end if;

  if p_action is not null then
    if not public.write_action(p_user_id, p_action_id, p_expected_version, p_action, p_claims, p_evidence, p_events) then
      return false;
    end if;
  end if;

  if p_started is true and previous_started is null then
    -- 열린 Action만 (아니면 P0002)
    perform public.start_action(p_user_id, p_action_id);
  elsif p_started is false and previous_started is not null then
    update public.actions set started_at = null, last_activity_at = now()
      where id = p_action_id and user_id = p_user_id;
    insert into public.action_events (user_id, action_id, type, before, after, actor, rule)
      values (p_user_id, p_action_id, 'user_unstarted', jsonb_build_object('started_at', previous_started),
              jsonb_build_object('started_at', null), 'user', null);
  end if;
  return true;
end;
$$;

revoke execute on function public.set_action_progress from public, anon, authenticated;
grant execute on function public.set_action_progress to service_role;
