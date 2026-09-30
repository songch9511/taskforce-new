-- 연결 설정(connections.settings)을 DB 안에서 한 번에 고친다 (docs/FEATURE_MAP.md 3-3, docs/go-live/google-integration.md 9장).
-- 전에는 서버가 설정 전체를 읽고(select) 고쳐 통째로 다시 썼다(update). 같은 연결의 설정을 동시에 쓰는 둘이 있으면 늦게 쓴 쪽이
-- 먼저 쓴 쪽의 변경을 되돌렸다: 다시 연결한 범위(scopes) · 계정(googleUserId)이 동기화 통계 기록에 옛 값으로 돌아가거나, 통계 한 번분이 사라짐.
-- 이제 서버는 바꿀 것만 넘기고 DB가 지금 값에 합친다. 같은 연결 행을 고치는 호출은 행 잠금으로 한 줄로 선다.
-- 함수는 모두 서버(service role)만 부른다 (lib/connectors/store.ts mergeConnectionSettings · addConnectionStats).

-- 1) 위 수준 키 바꾸기 · 빼기 + Notion DB 설정(settings.dataSources)은 DB마다 바꾸기.
--    settings = (settings || p_set) - p_remove, 그 위에 dataSources = dataSources || p_data_sources (p_data_sources에 없는 DB의 설정은 그대로).
--    설정 · dataSources가 객체가 아니면 빈 객체에서 시작한다. p_data_sources를 주면서 p_set · p_remove로 dataSources를 함께 건드리지 않는다.
--    한 UPDATE 문이라, 동시에 고친 쪽이 먼저 커밋하면 그 값 위에 다시 계산한다. id와 user_id가 모두 맞는 행만 고친다. 돌려주는 값: 고친 행이 있는가.
create function public.merge_connection_settings(
  p_user_id uuid,
  p_connection_id uuid,
  p_set jsonb default '{}'::jsonb,
  p_remove text[] default '{}'::text[],
  p_data_sources jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_set jsonb := coalesce(p_set, '{}'::jsonb);
  v_remove text[] := coalesce(p_remove, '{}'::text[]);
  v_data_sources jsonb := coalesce(p_data_sources, '{}'::jsonb);
begin
  if jsonb_typeof(v_set) <> 'object' or jsonb_typeof(v_data_sources) <> 'object' then
    raise exception 'merge_connection_settings: 잘못된 인자';
  end if;
  if exists (select 1 from jsonb_each(v_data_sources) e where jsonb_typeof(e.value) <> 'object') then
    raise exception 'merge_connection_settings: DB 설정은 객체여야 함';
  end if;
  if v_data_sources <> '{}'::jsonb and ((v_set -> 'dataSources') is not null or 'dataSources' = any (v_remove)) then
    raise exception 'merge_connection_settings: dataSources를 p_set · p_remove와 p_data_sources로 함께 바꿀 수 없음';
  end if;

  update public.connections c
     set settings = ((case when jsonb_typeof(c.settings) = 'object' then c.settings else '{}'::jsonb end || v_set) - v_remove)
                    || case
                         when v_data_sources = '{}'::jsonb then '{}'::jsonb
                         else jsonb_build_object(
                           'dataSources',
                           (case when jsonb_typeof(c.settings -> 'dataSources') = 'object' then c.settings -> 'dataSources' else '{}'::jsonb end) || v_data_sources
                         )
                       end
   where c.id = p_connection_id and c.user_id = p_user_id;
  return found;
end;
$$;

revoke execute on function public.merge_connection_settings from public, anon, authenticated;
grant execute on function public.merge_connection_settings to service_role;

-- 2) 동기화 통계(settings.stats = { since, counts }) 더하기: p_counts(이름 → 양수)를 counts에 더한다 (google-integration.md 8장).
--    since는 저장된 값을 그대로 두고, 처음이면 p_now(ISO 8601, 밀리초 · Z). 저장된 통계 모양이 다르면(객체가 아님 · since가 문자열이 아님 ·
--    counts가 객체가 아님 · counts에 숫자가 아닌 값이 있음) 새로 센다 (전의 google/settings.ts withStats와 같다). 숫자인지 먼저 보고 더하므로 형 변환 오류가 나지 않는다.
--    p_counts에서 숫자가 아니거나 양수가 아닌 값은 더하지 않는다. 더할 것이 없거나 연결이 없으면 쓰지 않고 false.
--    연결 행을 잠근 채(for no key update: 키를 바꾸지 않으므로 외래키 확인과 부딪치지 않는다) 읽고 쓰므로, 같은 연결에 동시에 더한 개수가 모두 남는다.
create function public.add_connection_stats(p_user_id uuid, p_connection_id uuid, p_counts jsonb, p_now timestamptz)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_settings jsonb;
  v_stats jsonb;
  v_since jsonb;
  v_counts jsonb;
  v_key text;
  v_value jsonb;
  v_added boolean := false;
begin
  if jsonb_typeof(p_counts) is distinct from 'object' or p_now is null then
    raise exception 'add_connection_stats: 잘못된 인자';
  end if;

  select c.settings into v_settings
    from public.connections c
   where c.id = p_connection_id and c.user_id = p_user_id
   for no key update;
  if not found then
    return false;
  end if;
  if jsonb_typeof(v_settings) is distinct from 'object' then
    v_settings := '{}'::jsonb;
  end if;

  -- 모양 검사는 IF를 겹쳐 순서를 못박는다 (AND의 계산 순서는 정해져 있지 않아, counts가 객체가 아닐 때 jsonb_each가 먼저 돌면 오류가 난다)
  v_stats := v_settings -> 'stats';
  v_since := null;
  v_counts := null;
  if jsonb_typeof(v_stats) = 'object' then
    if jsonb_typeof(v_stats -> 'since') = 'string' and jsonb_typeof(v_stats -> 'counts') = 'object' then
      if not exists (select 1 from jsonb_each(v_stats -> 'counts') e where jsonb_typeof(e.value) <> 'number') then
        v_since := v_stats -> 'since';
        v_counts := v_stats -> 'counts';
      end if;
    end if;
  end if;
  if v_counts is null then
    v_since := to_jsonb(to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    v_counts := '{}'::jsonb;
  end if;

  for v_key, v_value in select e.key, e.value from jsonb_each(p_counts) e loop
    if jsonb_typeof(v_value) = 'number' then
      if v_value::numeric > 0 then
        v_counts := v_counts || jsonb_build_object(v_key, coalesce((v_counts -> v_key)::numeric, 0) + v_value::numeric);
        v_added := true;
      end if;
    end if;
  end loop;
  if not v_added then
    return false;
  end if;

  update public.connections c
     set settings = v_settings || jsonb_build_object('stats', jsonb_build_object('since', v_since, 'counts', v_counts))
   where c.id = p_connection_id and c.user_id = p_user_id;
  return true;
end;
$$;

revoke execute on function public.add_connection_stats from public, anon, authenticated;
grant execute on function public.add_connection_stats to service_role;
