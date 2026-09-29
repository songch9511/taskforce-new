-- Slack 이벤트 받기 보강 (보안 검토 2026-09-29, docs/go-live/slack-integration.md 2-4).

-- 1) 지운 메시지 표시: Slack에서 지운 메시지는 행을 지우지 않고 글을 비운 채 표시만 남긴다.
--    Slack은 늦게 · 순서 없이 다시 보내므로(재시도, Delayed Events 24시간) 행을 지우면 늦게 온 원래 메시지가 다시 들어온다.
--    남은 행은 (connection_id, channel_id, ts) unique 때문에 다시 넣기를 막는다. 동기화는 표시된 행을 원문에 넣지 않는다.
alter table public.slack_messages add column deleted_at timestamptz;

-- 2) 앱 해제(app_uninstalled · tokens_revoked)를 한 트랜잭션에서: 토큰 · 대기 메시지 · 추적 스레드 · 이름 캐시를 지우고 연결을 revoked로.
--    - 워크스페이스는 external_account_id("팀 id:사용자 id")의 팀 부분이 정확히 같은 것만 (LIKE 와일드카드를 쓰지 않는다)
--    - p_slack_user_ids가 null이면 그 워크스페이스 전체(app_uninstalled), 아니면 그 이용자만(tokens_revoked)
--    - 이벤트 시각(p_before) 뒤에 다시 연결한 것은 건드리지 않는다. revoked가 아닌 모든 상태(active · error · reauth)를 끊는다
--    지운 연결 수를 돌려준다. 서버(service role)만 부른다.
create function public.revoke_slack_connections(p_team_id text, p_slack_user_ids text[], p_before timestamptz)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into ids
  from (
    select c.id
    from public.connections c
    where c.provider = 'slack'
      and split_part(c.external_account_id, ':', 1) = p_team_id
      and c.status <> 'revoked'
      and c.connected_at <= p_before
      and (p_slack_user_ids is null or split_part(c.external_account_id, ':', 2) = any (p_slack_user_ids))
    for update
  ) locked;

  if cardinality(ids) = 0 then
    return 0;
  end if;

  delete from public.connection_secrets where connection_id = any (ids);
  delete from public.slack_messages where connection_id = any (ids);
  delete from public.slack_threads where connection_id = any (ids);
  delete from public.slack_people where connection_id = any (ids);
  update public.connections
     set status = 'revoked', last_error = 'Slack에서 앱을 지웠거나 권한을 거뒀습니다.'
   where id = any (ids);
  return cardinality(ids);
end;
$$;

revoke execute on function public.revoke_slack_connections from public, anon, authenticated;
grant execute on function public.revoke_slack_connections to service_role;
