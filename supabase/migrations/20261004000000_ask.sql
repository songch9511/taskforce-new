-- 물어보기 (POST /api/v1/ask): 사용자의 Action을 임베딩으로 찾아 근거 인용과 함께 답한다.

-- 횟수 제한(10분에 20번)은 rate_limit_events · take_rate_limit(20261005000000)이 맡는다. 질문 · 답은 DB에 남기지 않는다.

-- 질문과 가까운 Action: 열린 것 + 최근(p_closed_since 이후)에 끝나거나 취소된 것 (서버 전용).
--    사용자가 지운(user_deleted) Action은 오판이므로 뺀다. match_open_actions처럼 사용자 행을 먼저 좁힌 뒤 정확히 잰다.
create function public.match_actions_for_ask(
  p_user_id uuid,
  p_embedding extensions.vector(1536),
  p_count int default 8,
  p_closed_since timestamptz default now() - interval '30 days'
)
returns table (id uuid, similarity double precision)
language sql stable
set search_path = ''
as $$
  with mine as materialized (
    select a.id, a.embedding from public.actions a
    where a.user_id = p_user_id
      and a.embedding is not null
      and (a.status = 'open' or a.updated_at >= p_closed_since)
      and not (
        a.status = 'dropped'
        and exists (
          select 1 from public.action_events e
          where e.action_id = a.id and e.user_id = p_user_id and e.type = 'user_deleted'
        )
      )
  )
  select m.id, 1 - (m.embedding operator(extensions.<=>) p_embedding) as similarity
  from mine m
  order by m.embedding operator(extensions.<=>) p_embedding
  limit p_count;
$$;

revoke execute on function public.match_actions_for_ask from public, anon, authenticated;
grant execute on function public.match_actions_for_ask to service_role;
