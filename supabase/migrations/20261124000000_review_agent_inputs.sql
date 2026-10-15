-- OA D4b-s: Review 입력 연결 (서버). 읽기 전용 SQL 함수 하나뿐이다: 표 · 열 · 색인 · 트리거 · 지표 CHECK 변경 0, 새 쓰기 경로 0.
--
-- review_agent_inputs(p_user_id, p_adapters): 에이전트가 사용자의 결정을 기다리는 일을 한 스냅샷(문장 하나)에서 읽는다.
--   반환은 **scalar jsonb 하나**(입력 행의 배열, 없으면 `[]`)다. TABLE을 돌려주면 PostgREST `db-max-rows`(Supabase 기본 1000)가 행 수에 걸려 입력이 조용히 잘리고,
--   잘린 목록이 "완전함"으로 나간다 — 결과가 행 하나면 상한이 닿지 않는다. 배열 원소 = { kind, item_ref, action_id, run_id, version, created_at, due_at, detail }, kind · item_ref 순.
--   agent_question / agent_approval / agent_secret_question: agent_tasks.pending_question (대화 run의 작업만, 그 세션 연결의 adapter가 p_adapters 안일 때만)
--     항목 열쇠 = task id, version = question:<task id>:<provider_request_id> (질문이 바뀌면 같은 열쇠에 다른 version)
--   result_ready: 끝나지 않은 대화 run의 마지막 턴 작업이 idle이고, 검토하지 않은(turn_seq > reviewed_turn_seq) 현재 산출물이 있다
--     항목 열쇠 = run id, version = result:<run id>:<reviewed_turn_seq>:<마지막 turn_seq>:<산출물 수>
--   path_conflict: agent_path_leases.conflict_run_id가 남아 있다 (해제된 lease도 해소 전이면 나온다). 늦게 쓴 run의 Action이 열려 있을 때
--     항목 열쇠 = lease id, version = conflict:<lease id>:<conflict_version>
-- 글(질문 · 경로 · 제목)은 내지 않는다: id · 토큰 · version · 시각 · 불리언만. 개수 상한이 없다 (list_path_conflicts의 500 상한을 쓰지 않는다).
-- 질문 갈래만 p_adapters로 거른다: 결과 준비 · 충돌의 행동(검토 · 해소)은 adapter 플래그와 무관하다. 빈 배열이면 질문은 나오지 않는다 (TS는 빈 배열이면 부르지 않는다).
-- 되돌리기: drop function public.review_agent_inputs(uuid, text[]);
begin;
set local lock_timeout = '5s';

create function public.review_agent_inputs(p_user_id uuid, p_adapters text[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.kind, x.item_ref), '[]'::jsonb)
    from (
  select case
           when t.pending_question->>'kind' = 'approval' then 'agent_approval'
           when exists (select 1 from jsonb_array_elements(t.pending_question->'questions') q where q->>'secret' = 'true') then 'agent_secret_question'
           else 'agent_question'
         end::text as kind,
         t.id as item_ref, r.action_id as action_id, r.id as run_id,
         'question:' || t.id::text || ':' || (t.pending_question->>'provider_request_id') as version,
         least((t.pending_question->>'asked_at')::timestamptz, public.db_now()) as created_at,
         a.due_at as due_at,
         jsonb_build_object('task_id', t.id, 'session_id', t.agent_session_id, 'provider_request_id', t.pending_question->>'provider_request_id',
                            'adapter', c.adapter, 'bridge_id', c.bridge_id) as detail
    from public.agent_tasks t
    join public.execution_runs r on r.id = t.run_id and r.user_id = t.user_id
    join public.actions a on a.id = r.action_id and a.user_id = r.user_id
    join public.agent_sessions s on s.id = t.agent_session_id and s.user_id = t.user_id
    join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
   where t.user_id = p_user_id and t.pending_question is not null
     and r.kind = 'conversation' and a.status = 'open' and c.adapter = any (p_adapters)
  union all
  select 'result_ready'::text, r.id, r.action_id, r.id,
         'result:' || r.id::text || ':' || r.reviewed_turn_seq::text || ':' || max(ar.turn_seq)::text || ':' || count(*)::text,
         min(ar.created_at),
         a.due_at,
         jsonb_build_object('session_id', r.agent_session_id, 'reviewed_turn_seq', r.reviewed_turn_seq, 'last_turn_seq', max(ar.turn_seq), 'changed_at', max(ar.created_at))
    from public.execution_runs r
    join public.actions a on a.id = r.action_id and a.user_id = r.user_id
    join public.agent_artifacts ar on ar.run_id = r.id and ar.user_id = r.user_id
   where r.user_id = p_user_id and r.kind = 'conversation' and r.state not in ('done', 'failed', 'stopped') and a.status = 'open'
     and ar.superseded_at is null and ar.turn_seq > r.reviewed_turn_seq
     and (select lt.state from public.agent_tasks lt where lt.run_id = r.id and lt.user_id = r.user_id
           order by lt.turn_seq desc nulls last, lt.created_at desc, lt.id desc limit 1) = 'idle'
   group by r.id, a.id
  union all
  select 'path_conflict'::text, l.id, c.action_id, c.id,
         'conflict:' || l.id::text || ':' || l.conflict_version::text,
         l.conflict_at,
         a.due_at,
         jsonb_build_object('lease_id', l.id, 'conflict_version', l.conflict_version, 'holder_action_id', h.action_id, 'holder_run_id', l.run_id,
                            'later_run_id', l.conflict_run_id, 'released', l.released_at is not null, 'stopped', l.conflict_stop_at is not null)
    from public.agent_path_leases l
    join public.execution_runs h on h.id = l.run_id and h.user_id = l.user_id
    join public.execution_runs c on c.id = l.conflict_run_id and c.user_id = l.user_id
    join public.actions a on a.id = c.action_id and a.user_id = c.user_id
   where l.user_id = p_user_id and l.conflict_run_id is not null and a.status = 'open'
    ) x
$$;

revoke all on function public.review_agent_inputs(uuid, text[]) from public, anon, authenticated;
grant execute on function public.review_agent_inputs(uuid, text[]) to service_role;

commit;
