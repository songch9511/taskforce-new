-- OA F2: 비밀값 질문을 "이 Mac에서 답했다"고 표시하는 SQL 함수 하나뿐이다. 표 · 열 · 색인 · 트리거 · 지표 CHECK 변경 0, 기존 함수 본문 교체 0.
--
-- answer_agent_question_locally(p_user_id, p_bridge_id, p_agent_task_id, p_request_digest, p_adapters) → jsonb
--   값은 서버로 오지 않는다. 인자에 값 자리가 없다: 사용자 · bridge · 작업 id, provider_request_id의 SHA-256 16진 64자, 열린 adapter 목록뿐이다.
--   서버가 남기는 것은 기존 `answer_agent_question`이 이미 남기는 것과 같다 — 답 단계(args = { agent_task_id, provider_request_id, answered_locally: true }, body 빈 글),
--   주인 bridge로 가는 answer 명령, 대화 줄 "Answered on this Mac" — 그리고 지표 한 줄 question_answered { kind: "input", adapter, answered_locally: true }.
--
-- 순서 (구조는 모두 이 함수 안에서 같은 트랜잭션이다):
--   1) digest 모양(소문자 16진 64자) · adapter 목록: 틀리면 쓰기 0 — invalid / not_found
--   2) 잠금 없이 풀기: 작업 → 대화 run → 세션 → 연결 → bridge. 연결이 이 bridge에 묶여 있지 않거나 bridge가 active가 아니거나 adapter가 목록 밖이면 not_found.
--      (같은 사용자의 다른 Mac이 표시하면 답 명령은 주인 Mac으로 가는데 거기엔 값이 없어 질문을 잃는다 — 그래서 표시는 세션을 가진 Mac만 한다)
--   3) 질문 고르기: pending_question의 열쇠(question_key[1] = provider_request_id)를 SHA-256 해 digest와 맞으면 그 질문, 아니면 answered_question이 맞으면 그 질문(다시 보낸 요청의 수렴용), 둘 다 아니면 stale/question_closed
--   4) 비밀값이 하나라도 있는 input 질문만: 승인 질문은 lease 확정(answer_agent_approval)이 없으므로 이 길로 답할 수 없다 — stale/not_secret
--   5) 아직 열린 질문인데 작업이 unreachable(heartbeat 공백)이면 stale/not_live — 참고 이유다. Mac이 heartbeat · reconcile로 작업을 되살린 뒤 한 번 다시 보낸다
--   6) answer_agent_question(user, task, 원래 provider_request_id, null, true, null)을 그대로 지난다: 질문 열쇠 CAS · 중복 수렴 · 답 단계 · bridge 명령 · 대화 줄이
--      Assistant · Review의 답과 같은 길이다. 인자는 SQL 상수(p_answers => null, p_answered_locally => true, p_answer_message_id => null)라 값이 들어갈 길이 없다
--   7) answered · duplicate이면 세션 · 작업을 쥔 채로 연결의 bridge_id가 이 bridge인지(와 bridge가 active인지) 한 번 더 본다. 다르면 TF005로 블록을 롤백하고 not_found
--      (지금은 연결의 bridge_id를 바꾸는 길이 없다. 그래도 안전을 "바꾸는 길이 없다"는 강제되지 않은 사실에 기대지 않는다). 같으면 answered에만 지표 한 줄 — 같은 트랜잭션
-- 잠금은 `answer_agent_question`의 것뿐이다(메시지 → 대화 → 세션 → run → 작업 → 단계). 이 함수는 잠그기 전에 잠금 없이 읽기만 하고, bridge · 연결 행은 잠그지 않는다:
--   revoke_bridge(bridge → 연결 → 세션 …)와 서로 반대 순서로 기다리지 않는다 (명령 행의 FK는 bridge에 KEY SHARE만 건다).
-- 함수는 lock_timeout = 2s: 넘으면 55P03(TS가 3번 다시 한 뒤 409). 멱등이라 다시 보내도 된다.
--
-- 반환: { status: "answered" | "duplicate", step_id } · { status: "stale", reason: "question_closed" | "not_live" | "not_secret" } · { status: "not_found" } · { status: "invalid" }
--   answer_agent_question이 secret_requires_local · invalid_answer를 돌려주면(1–5가 막으므로 오면 버그) raise — TS가 500으로 낸다.
--
-- 적용 순서: 20261121000000(question_answered 지표) 뒤. 파일 이름 순서로 적용한다.
-- 되돌리기: drop function public.answer_agent_question_locally(uuid, uuid, uuid, text, text[]);
begin;
set local lock_timeout = '5s';

create function public.answer_agent_question_locally(
  p_user_id uuid, p_bridge_id uuid, p_agent_task_id uuid, p_request_digest text, p_adapters text[]
) returns jsonb
language plpgsql
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  v_state text;
  v_pending jsonb;
  v_answered jsonb;
  v_adapter text;
  v_question jsonb;
  v_is_pending boolean;
  v_request text;
  v_result jsonb;
begin
  if p_request_digest is null or p_request_digest !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status', 'invalid');
  end if;
  if p_adapters is null or cardinality(p_adapters) = 0 then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- 잠금 없이 풀기: 이 Mac(bridge)이 이 작업의 세션을 가졌는가
  select t.state, t.pending_question, t.answered_question, c.adapter
    into v_state, v_pending, v_answered, v_adapter
    from public.agent_tasks t
    join public.execution_runs r on r.id = t.run_id and r.user_id = t.user_id and r.kind = 'conversation' and r.agent_session_id = t.agent_session_id
    join public.agent_sessions s on s.id = t.agent_session_id and s.user_id = t.user_id
    join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
    join public.bridges b on b.id = c.bridge_id and b.user_id = c.user_id
   where t.id = p_agent_task_id and t.user_id = p_user_id
     and c.bridge_id = p_bridge_id and b.status = 'active' and c.adapter = any (p_adapters);
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- 질문 고르기: 열린 질문 → 이미 답이 간 질문(같은 요청을 다시 보낸 경우)
  if v_pending is not null
    and encode(sha256(convert_to(v_pending->'question_key'->>1, 'UTF8')), 'hex') = p_request_digest then
    v_question := v_pending;
    v_is_pending := true;
  elsif v_answered is not null
    and encode(sha256(convert_to(v_answered->'question_key'->>1, 'UTF8')), 'hex') = p_request_digest then
    v_question := v_answered;
    v_is_pending := false;
  else
    return jsonb_build_object('status', 'stale', 'reason', 'question_closed');
  end if;
  v_request := v_question->'question_key'->>1;

  -- 비밀값이 있는 input 질문만 (승인 질문은 lease 확정이 있는 answer_agent_approval로만 답한다)
  if v_question->>'kind' is distinct from 'input'
    or not exists (select 1 from jsonb_array_elements(v_question->'questions') q where q->>'secret' = 'true') then
    return jsonb_build_object('status', 'stale', 'reason', 'not_secret');
  end if;

  -- 참고 이유: heartbeat가 끊겨 작업이 unreachable이면 Mac이 되살린 뒤 다시 보낸다 (쓰기 판정은 아래 answer_agent_question이 한다)
  if v_is_pending and v_state = 'unreachable' then
    return jsonb_build_object('status', 'stale', 'reason', 'not_live');
  end if;

  begin
    v_result := public.answer_agent_question(p_user_id, p_agent_task_id, v_request, null, true, null);
    case v_result->>'status'
      when 'answered', 'duplicate' then
        -- 권위 있는 확인: 세션 · 작업을 쥔 채 같은 트랜잭션에서 한 번 더. 다르면 이 블록의 쓰기를 모두 되돌린다
        select c.adapter into v_adapter
          from public.agent_tasks t
          join public.agent_sessions s on s.id = t.agent_session_id and s.user_id = t.user_id
          join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
          join public.bridges b on b.id = c.bridge_id and b.user_id = c.user_id
         where t.id = p_agent_task_id and t.user_id = p_user_id and c.bridge_id = p_bridge_id and b.status = 'active';
        if not found then
          raise exception 'answer_agent_question_locally: bridge changed' using errcode = 'TF005';
        end if;
        if v_result->>'status' = 'answered' then
          insert into public.metric_events (user_id, type, props)
            values (p_user_id, 'question_answered', jsonb_strip_nulls(jsonb_build_object('kind', 'input', 'adapter', v_adapter, 'answered_locally', true)));
        end if;
        return jsonb_build_object('status', v_result->>'status', 'step_id', v_result->'step_id');
      when 'question_stale' then
        -- answer_agent_question이 잡은 세션 · 작업 잠금이 아직 쥐어져 있다: 지금 값으로 이유를 붙인다 (sweep이 먼저 commit한 경우)
        if exists (
          select 1 from public.agent_tasks t
           where t.id = p_agent_task_id and t.user_id = p_user_id and t.state = 'unreachable'
             and encode(sha256(convert_to(t.pending_question->'question_key'->>1, 'UTF8')), 'hex') = p_request_digest
        ) then
          return jsonb_build_object('status', 'stale', 'reason', 'not_live');
        end if;
        return jsonb_build_object('status', 'stale', 'reason', 'question_closed');
      when 'not_found' then
        return jsonb_build_object('status', 'not_found');
      else
        raise exception 'answer_agent_question_locally: unexpected answer status %', v_result->>'status';
    end case;
  exception when sqlstate 'TF005' then
    return jsonb_build_object('status', 'not_found');
  end;
end;
$$;

revoke all on function public.answer_agent_question_locally(uuid, uuid, uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.answer_agent_question_locally(uuid, uuid, uuid, text, text[]) to service_role;
commit;
