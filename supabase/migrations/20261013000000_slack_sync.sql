-- Slack 연동: 원문 넣기 · 연결 끊기 · 대기 데이터 정리 (docs/go-live/slack-integration.md 2-5 · 2-6 · 2-7).
-- 함수는 모두 서버(service role)만 부른다. 앱의 연결 직접 삭제 정책은 20261014000000에서 지운다(이 코드를 배포한 뒤에 적용).

-- 1) 원문 저장 + 대기 행 표시를 한 트랜잭션에서.
--    묶음(IngestItem)을 원문으로 넣고, 이번 동기화가 읽은 (channel_id, ts) 행만 그 원문으로 표시한다(묶음 열쇠로 고르면 동기화 도중 새로 온 메시지까지 잡힌다).
--    - 연결 행을 잠가 같은 연결의 넣기 · 끊기 · 앱 해제를 한 줄로 세운다. 끊겼거나(revoked) 지운 연결에는 넣지 않는다(D3 뒤에 글이 다시 생기지 않게)
--    - 읽은 뒤 Slack에서 지운 메시지가 있으면 넣지 않는다(원문에 지운 글이 들어가지 않게). 표시하지 않은 행은 다음 동기화가 다시 묶는다
--    - 같은 묶음(external_id)을 이미 넣었으면(동시 동기화) 넣지도 표시하지도 않는다. 그 원문의 행은 넣은 쪽이 이미 표시했고,
--      남은 행(늦게 온 메시지)은 첫 ts가 달라져 다음 동기화에 새 묶음이 된다
--    돌려주는 값: 원문 id(넣지 않았으면 null)와 새로 넣었는지.
create function public.slack_ingest_source(
  p_user_id uuid,
  p_connection_id uuid,
  p_source jsonb,
  p_channel_ids text[],
  p_ts text[]
)
returns table (source_id uuid, created boolean)
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform 1 from public.connections c
   where c.id = p_connection_id and c.user_id = p_user_id and c.provider = 'slack' and c.status <> 'revoked'
   for update;
  if not found then
    raise exception 'slack connection not found or revoked';
  end if;

  created := false;
  source_id := null;

  -- 고른 행을 잠그고(그 사이 지움 표시가 끼어들지 않게) 지운 것이 있는지 본다
  perform 1
    from public.slack_messages m
    join unnest(p_channel_ids, p_ts) as picked (channel_id, ts) on m.channel_id = picked.channel_id and m.ts = picked.ts
   where m.connection_id = p_connection_id and m.user_id = p_user_id
   for update of m;
  if exists (
    select 1
      from public.slack_messages m
      join unnest(p_channel_ids, p_ts) as picked (channel_id, ts) on m.channel_id = picked.channel_id and m.ts = picked.ts
     where m.connection_id = p_connection_id and m.user_id = p_user_id and m.deleted_at is not null
  ) then
    return next;
    return;
  end if;

  if exists (
    select 1 from public.sources s
     where s.connection_id = p_connection_id and s.user_id = p_user_id and s.external_id = p_source->>'external_id'
  ) then
    return next;
    return;
  end if;

  insert into public.sources (user_id, connection_id, external_id, external_version, kind, title, raw_text, occurred_at, external_url, participants)
  values (
    p_user_id, p_connection_id, p_source->>'external_id', p_source->>'external_version', p_source->>'kind', p_source->>'title',
    p_source->>'raw_text', (p_source->>'occurred_at')::timestamptz, p_source->>'external_url', nullif(p_source->'participants', 'null'::jsonb)
  )
  returning id into v_id;

  update public.slack_messages m
     set source_id = v_id
    from unnest(p_channel_ids, p_ts) as picked (channel_id, ts)
   where m.connection_id = p_connection_id and m.user_id = p_user_id
     and m.channel_id = picked.channel_id and m.ts = picked.ts
     and m.source_id is null and m.deleted_at is null;

  source_id := v_id;
  created := true;
  return next;
end;
$$;

revoke execute on function public.slack_ingest_source from public, anon, authenticated;
grant execute on function public.slack_ingest_source to service_role;

-- 2) Slack에서 온 글자 지우기 (D3: 연결을 끊거나 Slack에서 앱을 지웠을 때). 할 일 · 상태 · 기한은 남긴다.
--    Slack 개발자 정책: 앱을 지우면 관련 데이터를 14 영업일 안에 모두 지워야 한다. 그래서 CLAUDE.md 원칙 2(근거) · 5(Claim을 지우지 않는다)의 예외다.
--    - 원문(sources): 본문 · 관련자를 비우고 제목은 'Slack', raw_text_purge_reason = 'disconnected'. 행 · 링크 · 처리 결과는 남긴다
--    - 근거 인용(evidence.quote): 'Slack 연결을 끊어 지웠어요'로 바꾼다
--    - Claim(claims): 행과 판정 값(value · speaker_role …)은 남겨 할 일 값이 바뀌지 않게 하고, 글자(quote · value_text · speaker)만 비운다
--    - 판정 기록(judge_logs): 후보 구절이 들어 있으므로 행째 지운다
--    몇 번 불러도 같다: 지운 뒤에 끝난 처리가 새로 쓴 인용 · 판정 기록도 다시 부르면 지워진다(3 · 6).
create function public.purge_slack_sources(p_source_ids uuid[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.sources
     set raw_text = '', title = 'Slack', participants = null, structured = null,
         raw_text_purged_at = coalesce(raw_text_purged_at, now()), raw_text_purge_reason = 'disconnected'
   where id = any (p_source_ids);
  update public.evidence set quote = 'Slack 연결을 끊어 지웠어요'
   where source_id = any (p_source_ids) and quote <> 'Slack 연결을 끊어 지웠어요';
  update public.claims set quote = '', value_text = null, speaker = null
   where source_id = any (p_source_ids) and (quote <> '' or value_text is not null or speaker is not null);
  delete from public.judge_logs where source_id = any (p_source_ids);
end;
$$;

revoke execute on function public.purge_slack_sources from public, anon, authenticated;
grant execute on function public.purge_slack_sources to service_role;

--    연결 단위: 그 연결의 Slack 원문 모두 + 대기 메시지 · 추적 스레드 · 이름 캐시.
--    연결 행을 지우기 전에 불러야 한다(지우면 sources.connection_id가 null이 되어 어느 원문이 Slack에서 왔는지 모른다). 지운 원문 수를 돌려준다.
create function public.purge_slack_data(p_connection_ids uuid[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_sources uuid[];
begin
  select coalesce(array_agg(s.id), '{}') into v_sources
    from public.sources s
    join public.connections c on c.id = s.connection_id and c.user_id = s.user_id
   where c.id = any (p_connection_ids) and c.provider = 'slack';

  perform public.purge_slack_sources(v_sources);
  delete from public.slack_messages where connection_id = any (p_connection_ids);
  delete from public.slack_threads where connection_id = any (p_connection_ids);
  delete from public.slack_people where connection_id = any (p_connection_ids);
  return cardinality(v_sources);
end;
$$;

revoke execute on function public.purge_slack_data from public, anon, authenticated;
grant execute on function public.purge_slack_data to service_role;

-- 3) 원문 처리가 끝난 뒤(동기화): 처리 도중에 연결을 끊었거나 앱이 지워졌으면(원문이 이미 D3로 지워짐),
--    처리가 그 뒤에 쓴 인용 · Claim 글자 · 판정 기록도 지운다. 지웠으면 true.
create function public.slack_repurge_if_disconnected(p_user_id uuid, p_source_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.sources s
     where s.id = p_source_id and s.user_id = p_user_id and s.raw_text_purge_reason = 'disconnected'
  ) then
    return false;
  end if;
  perform public.purge_slack_sources(array[p_source_id]);
  return true;
end;
$$;

revoke execute on function public.slack_repurge_if_disconnected from public, anon, authenticated;
grant execute on function public.slack_repurge_if_disconnected to service_role;

-- 4) 연결 끊기 (DELETE /api/v1/connections/:id): Slack이면 D3 → 연결 행 삭제를 한 트랜잭션에서.
--    서비스 쪽 토큰 폐기는 이 함수를 부르기 전에 서버가 한다. 그 사용자의 연결이 없으면 false.
create function public.disconnect_connection(p_user_id uuid, p_connection_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_provider text;
begin
  select c.provider into v_provider
    from public.connections c
   where c.id = p_connection_id and c.user_id = p_user_id
   for update;
  if not found then
    return false;
  end if;
  if v_provider = 'slack' then
    perform public.purge_slack_data(array[p_connection_id]);
  end if;
  delete from public.connections where id = p_connection_id and user_id = p_user_id;
  return true;
end;
$$;

revoke execute on function public.disconnect_connection from public, anon, authenticated;
grant execute on function public.disconnect_connection to service_role;

-- 5) 앱 해제(app_uninstalled · tokens_revoked · 동기화 중 token_revoked)도 D3까지. 20261012000000의 함수에 purge_slack_data만 더했다.
create or replace function public.revoke_slack_connections(p_team_id text, p_slack_user_ids text[], p_before timestamptz)
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
  perform public.purge_slack_data(ids);
  update public.connections
     set status = 'revoked', last_error = 'Slack에서 앱을 지웠거나 권한을 거뒀습니다.'
   where id = any (ids);
  return cardinality(ids);
end;
$$;

-- 6) 대기 데이터 정리 (/api/cron/retention, 매일): 받은 지 p_messages_before보다 오래된 대기 메시지(넣은 행의 재전송 막기 표시 · 넣지 못한 행 모두)와
--    마지막 활동이 p_threads_before보다 오래된 추적 스레드. 한 번에 p_limit개씩(남은 것은 다음 호출).
--    안전망: D3로 지운 원문에 글자가 남아 있으면(지운 뒤에 끝난 처리가 쓴 인용 등) 다시 지운다.
create function public.purge_slack_buffers(p_messages_before timestamptz, p_threads_before timestamptz, p_limit int default 5000)
returns table (messages_deleted int, threads_deleted int, sources_repurged int)
language plpgsql
set search_path = ''
as $$
declare
  v_messages int;
  v_threads int;
  v_leftover uuid[];
begin
  delete from public.slack_messages m
   where m.id in (select id from public.slack_messages where received_at < p_messages_before order by received_at limit p_limit);
  get diagnostics v_messages = row_count;

  delete from public.slack_threads t
   where (t.connection_id, t.channel_id, t.thread_ts) in (
     select connection_id, channel_id, thread_ts from public.slack_threads
      where last_activity_at < p_threads_before order by last_activity_at limit p_limit
   );
  get diagnostics v_threads = row_count;

  select coalesce(array_agg(id), '{}') into v_leftover
    from (
      select s.id from public.sources s
       where s.raw_text_purge_reason = 'disconnected'
         and (exists (select 1 from public.evidence e where e.source_id = s.id and e.quote <> 'Slack 연결을 끊어 지웠어요')
           or exists (select 1 from public.claims c where c.source_id = s.id and (c.quote <> '' or c.value_text is not null or c.speaker is not null))
           or exists (select 1 from public.judge_logs j where j.source_id = s.id))
       limit p_limit
    ) leftover;
  perform public.purge_slack_sources(v_leftover);

  return query select v_messages, v_threads, cardinality(v_leftover);
end;
$$;

revoke execute on function public.purge_slack_buffers from public, anon, authenticated;
grant execute on function public.purge_slack_buffers to service_role;

create index slack_messages_received_idx on public.slack_messages (received_at);
create index slack_threads_activity_idx on public.slack_threads (last_activity_at);
-- D3가 원문으로 근거 · Claim을 찾는다 (이벤트 받기 안에서도 부르므로 전체를 훑지 않게)
create index evidence_source_idx on public.evidence (source_id);
create index claims_source_idx on public.claims (source_id);
create index sources_purge_reason_idx on public.sources (raw_text_purge_reason) where raw_text_purge_reason is not null;
