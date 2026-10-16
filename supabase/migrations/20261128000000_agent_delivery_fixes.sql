-- OA F3: 에이전트 전달 정리 (서버 · SQL). 새 마이그레이션 파일 하나 - 기존 마이그레이션은 고치지 않는다.
--
-- 결함 1 (Done <-> 답 교착): 질문이 있는 작업을 Done이 취소하면 작업 행을 한 트랜잭션에서 두 번 갱신한다. PostgreSQL은 FK 열이 바뀌지 않은 UPDATE의 FK 확인을 건너뛰지만
--   옛 행이 같은 트랜잭션이 만든 것이면(앞서 같은 트랜잭션이 그 행을 이미 갱신했으면) 건너뛰지 않고 다시 확인하고, 그때 가리키는 행(세션 · 원 메시지)에 FOR KEY SHARE를 기다리며 건다.
--   Done은 Action -> run -> task 순으로 쥐고(QS), 답 · 사건 · lease는 메시지 -> 대화 -> 세션 -> run -> task 순이라(GWD 11장) 서로 기다리면 순환이다. PG가 한 쪽을 40P01로 끊었다.
--   고침: request_agent_task_cancel의 질문 갈래 첫 줄에서 세션 · 원 메시지를 FOR KEY SHARE NOWAIT로 먼저 쥔다(질문 없는 갈래는 갱신이 한 번이라 그대로). 못 쥐면 55P03으로 Done 전체가 롤백되고
--   writeRpc가 다시 한다. 같은 원인의 이웃 둘도 한 줄씩: revoke_bridge(작업 고리 첫 줄에 메시지 KEY SHARE NOWAIT), stop_agent_runs_on_user_claim(run을 session -> run 순으로 잡는다).
-- 결함 2 (만료한 lease 전 prepared): Mac이 lease 전에 꺼져 있으면 24시간이 지나도 메시지가 dispatched/prepared에 남아 Send again이 not_eligible이다.
--   새 함수 expire_unleased_agent_messages(p_limit)가 1분 cron(sweepBridge)에서 만료한 lease 전 message 명령을 lock_bridge_command 순서(메시지 -> 세션 -> run -> task -> step -> 명령)로 잠그고
--   withdraw_bridge_command(..., 'expired')로 회수한다 - Mac이 돌아와 lease가 거둘 것과 같은 함수, 같은 조건. 찾기용 부분 색인 하나.
--   검토 반영: (1) 백그라운드 작업은 사용자 경로(Done · 답 · heartbeat · 폐기)가 쥘 수 있는 잠금을 기다리지 않는다. 한 호출이 여러 세션 · bridge를 잠그고 성공한 후보의 잠금이 함수가 끝날 때까지 남아,
--   기다리면 heartbeat(bridge -> 세션 -> run) · sweep(bridge id 순) · Done(세션 -> run id 순)과 순서가 어긋나는 곳에서 순환이 난다. 그래서 회수는 세션 · run · task · 단계 · 명령을 NOWAIT로 쥐고,
--   sweep_bridge_heartbeats도 같은 잠금을 NOWAIT로 바꿔 교체한다(쥘 수 없으면 그 bridge는 롤백하고 다음 분에 처음부터). 사용자 경로는 기존의 한 순서를 그대로 지킨다.
--   (2) 후보가 p_limit보다 많으면 호출마다 창(p_limit개)을 돌려 가며 처리한다(작은 시퀀스 하나) - 영구히 건너뛰어지는 후보가 머리를 붙잡아 뒤 후보를 막지 못하게 한다.
--
-- 교체하는 함수는 일곱이고 각각 잠금 방식 · 순서만 다르다 (tests/db/agent-delivery-fixes.test.ts T2가 본문 동일성을 확인한다):
--   request_agent_task_cancel       QS의 정의 + `if v_question is not null then` 바로 뒤 세션 · 원 메시지 KEY SHARE NOWAIT 두 줄
--   revoke_bridge                   BC의 정의 + 작업 고리(`order by id for update loop`) 바로 뒤 메시지 KEY SHARE NOWAIT 한 줄
--   stop_agent_runs_on_user_claim   QS의 정의 + `order by id for no key update loop` -> `order by agent_session_id, id for no key update loop`
--   sweep_bridge_heartbeats         BC의 정의 + 세션 · run · task · 단계를 잡는 네 곳의 잠금만 NOWAIT (`for update of a0 loop` -> `for update of a0 nowait loop` 등)
--   sweep_agent_step_leases         BC의 정의 + 단계 앞에 run을 NO KEY UPDATE SKIP LOCKED로 먼저 쥔다 (step -> run 역순 제거)
--   sweep_expire                    EC의 정의 + 외부 효과 단계 갱신을 run -> 단계 SKIP LOCKED 잠금 CTE 뒤로
--   purge_expired_execution_text    QS의 정의 + 정리할 run을 고르는 select에 `for no key update of r skip locked`
-- 시그니처 · 반환이 같아 create or replace가 권한과 트리거를 그대로 둔다. 새 표 · 새 정책 · 새 열 0, metric_events를 건드리지 않는다. 새 객체는 함수 둘(회수 · 남은 만료 lease 수) · 색인 하나 · 시퀀스 하나.
--
-- 운영 적용은 병합 직전 승인 뒤 `supabase db query --linked -f`로 20261127000000 뒤에 한다 (db push 금지). 배포 순서: 마이그레이션 -> 서버 (서버가 먼저 나가면 sweepBridge의 새 RPC가
-- "함수 없음"으로 실패해 errors로만 세어지고 다음 분에 다시 한다. 마이그레이션만 먼저면 회수가 돌지 않을 뿐 결함 1 수정은 바로 효과가 있다).
-- 되돌리기: drop function public.expire_unleased_agent_messages(integer); drop index public.bridge_commands_unleased_message_idx; drop sequence public.bridge_reclaim_scan_seq; drop function public.count_overdue_agent_step_leases(integer);
-- 그리고 request_agent_task_cancel · stop_agent_runs_on_user_claim (20261116120000)과 revoke_bridge · sweep_bridge_heartbeats · sweep_agent_step_leases (20261118000000)와 sweep_expire (20261021000000)와 purge_expired_execution_text (20261116120000)의 정의를 그 파일 그대로 create or replace로 다시 적용한다.
begin;
set local lock_timeout = '5s';

-- 찾기용: 아직 lease되지 않은 message 명령만 담아 작다 (끝난 명령은 30일 뒤 지운다). 만들 때 bridge_commands에 SHARE 잠금이 걸린다 (위 lock_timeout이 상한).
create index bridge_commands_unleased_message_idx on public.bridge_commands (created_at)
  where kind = 'message' and lease_owner is null and outcome is null;

-- 회수 호출마다 하나씩 올라가는 번호: 후보가 p_limit보다 많으면 이 번호로 창(p_limit개)을 고른다. 상태는 이 번호뿐이고 롤백되지 않는다.
create sequence public.bridge_reclaim_scan_seq;
revoke all on sequence public.bridge_reclaim_scan_seq from public, anon, authenticated;
grant usage, select on sequence public.bridge_reclaim_scan_seq to service_role;

-- Caller holds run before task. Earlier-order locks use NOWAIT for Stop and user-Claim Done (OA F3: 질문 갈래의 세션 · 원 메시지도).
create or replace function public.request_agent_task_cancel(p_user_id uuid, p_task_id uuid) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_task public.agent_tasks;
  v_run public.execution_runs;
  v_adapter text;
  v_step uuid;
  v_origin_step public.execution_steps;
  v_live_state text;
  v_unleased boolean;
  v_question jsonb;
begin
  select * into v_task from public.agent_tasks where id = p_task_id and user_id = p_user_id;
  if not found then return null; end if;
  select * into v_run from public.execution_runs where id = v_task.run_id and user_id = p_user_id for no key update;
  select * into v_task from public.agent_tasks where id = p_task_id and user_id = p_user_id for update;
  if v_run.kind <> 'conversation' or v_task.state not in ('dispatched','accepted','running','awaiting_answer','unreachable')
    or not exists (select 1 from public.agent_sessions where id = v_task.agent_session_id and user_id = p_user_id and status <> 'external') then return null; end if;
  if v_task.cancel_requested_at is not null then return jsonb_build_object('agent_task_id',p_task_id,'cancel','requested_only'); end if;
  select c.adapter into v_adapter from public.agent_sessions s join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
    where s.id = v_task.agent_session_id and s.user_id = p_user_id;
  v_live_state := case when v_task.state = 'unreachable' then v_task.last_live_state else v_task.state end;
  select * into v_origin_step from public.execution_steps where id = v_task.step_id and run_id = v_run.id for update;
  v_unleased := v_origin_step.state in ('pending','prepared')
    and v_origin_step.lease_owner is null and v_origin_step.lease_expires_at is null
    and not exists (select 1 from public.execution_intents where step_id = v_origin_step.id)
    and not exists (select 1 from public.execution_events where step_id = v_origin_step.id and type = 'step' and to_state = 'calling');
  if v_live_state = 'dispatched' and v_unleased then
    -- Done holds Action/run first; never wait on a message held by a message-first route.
    perform 1 from public.conversation_messages where id = v_task.message_id and user_id = p_user_id for update nowait;
    update public.conversation_messages set delivery_state = 'cancelled',delivery_reason = null where id = v_task.message_id;
    update public.agent_tasks set state = 'cancelled',pending_question = null,answered_question = null,
      cancel_requested_at = public.db_now() where id = p_task_id;
    return jsonb_build_object('agent_task_id',p_task_id,'cancel','confirmed');
  end if;
  v_question := v_task.pending_question;
  if v_unleased and v_task.answered_question->'question_key' = jsonb_build_array(p_task_id,v_origin_step.args->>'provider_request_id')
    and v_origin_step.kind = 'agent_message' and v_origin_step.args->>'agent_task_id' = p_task_id::text then
    v_question := v_task.answered_question;
    perform 1 from public.conversation_messages where id = (v_origin_step.args->>'answer_message_id')::uuid
      and user_id = p_user_id for update nowait;
    update public.conversation_messages set delivery_state = 'cancelled',delivery_reason = null
      where id = (v_origin_step.args->>'answer_message_id')::uuid and user_id = p_user_id;
    perform set_config('execution.gate','agent_stop',true);
    update public.execution_steps set state = 'skipped',version = version+1,
      policy_version = coalesce(policy_version,(select version from public.execution_policies where id = v_run.policy_id))
      where id = v_origin_step.id;
    -- Later events describe the running turn, not the answer that was never delivered.
    update public.agent_tasks set answered_question = null,
      step_id = (select s.id from public.execution_steps s where s.run_id = v_run.id and s.user_id = p_user_id
        and s.kind = 'agent_message' and s.state = 'called'
        and (s.args->>'agent_task_id' = p_task_id::text or s.args->>'message_id' = v_task.message_id::text)
        order by s.seq desc limit 1)
      where id = p_task_id;
  end if;
  if v_question is not null then
    -- OA F3 (Done <-> 답 교착): 이 트랜잭션에서 작업 행을 둘째로 갱신하면(아래 갱신 다음, 또는 lease 전 답은 위 갱신 다음) PostgreSQL이 FK(세션 · 원 메시지)를 다시 확인하며
    -- FOR KEY SHARE를 기다린다 (ri_triggers.c RI_FKey_fk_upd_check_required: 옛 행이 같은 트랜잭션이 만든 것이면 건너뛰지 않는다). 메시지 -> ... -> 세션을 FOR UPDATE로 쥔 답 · 사건 · lease가
    -- 이 Done이 쥔 run을 기다리면 그 기다림이 순환이 된다. Done은 앞 순서 행을 기다리지 않는다(위 NOWAIT와 같은 규칙): 갱신 전에 NOWAIT로 먼저 쥐면 둘째 갱신은 이미 쥔 KEY SHARE를 다시 잡을 뿐이다.
    -- 질문이 없는 갈래(갱신 한 번)에는 두지 않는다: 사건이 흐르는 중에도 평범한 Done은 기다리지 않고 끝나야 한다.
    perform 1 from public.agent_sessions where id = v_task.agent_session_id and user_id = p_user_id for key share nowait;
    perform 1 from public.conversation_messages where id = v_task.message_id and user_id = p_user_id for key share nowait;
    update public.agent_tasks set abandoned_question = v_question->'question_key',pending_question = null,
      state = case when state = 'awaiting_answer' then 'running' else state end,
      last_live_state = case when last_live_state = 'awaiting_answer' then 'running' else last_live_state end where id = p_task_id;
  end if;
  if v_question is not null and v_adapter = 'agent:claude-code'
    and (v_live_state = 'awaiting_answer' or v_unleased) then
    insert into public.execution_events(user_id,run_id,step_id,type,external_event_id,turn_seq,payload)
      values(p_user_id,v_run.id,v_task.step_id,'agent','deny:' || p_task_id || ':' || encode(sha256(convert_to(v_question->>'provider_request_id','UTF8')),'hex'),v_task.turn_seq,jsonb_build_object(
        'event_type','question_denied','agent_task_id',p_task_id,'question_key',v_question->'question_key','decision','deny'));
    update public.agent_tasks set state = 'cancelled',pending_question = null,answered_question = null,cancel_requested_at = public.db_now() where id = p_task_id;
    return jsonb_build_object('agent_task_id',p_task_id,'cancel','confirmed');
  end if;
  v_step := public.append_step(v_run.id,(select coalesce(max(seq),0)+1 from public.execution_steps where run_id = v_run.id),
    jsonb_build_object('kind','agent_cancel','provider',v_adapter,'tool','cancel','purpose','cancel:' || p_task_id,
      'body','','args',jsonb_build_object('agent_task_id',p_task_id)));
  if v_step is null or not public.prepare_step(v_step,0) then
    raise exception 'request_agent_task_cancel: step not prepared' using errcode = '22023';
  end if;
  update public.execution_steps set intent_key = 'cancel:' || p_task_id where id = v_step;
  update public.agent_tasks set cancel_requested_at = public.db_now() where id = p_task_id;
  return jsonb_build_object('agent_task_id',p_task_id,'cancel','requested_only');
end;
$$;

create or replace function public.revoke_bridge(p_user_id uuid,p_bridge_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare b public.bridges; a public.agent_sessions; r public.execution_runs; t public.agent_tasks; v_result jsonb; v_tasks jsonb:='[]';
begin
  select * into b from public.bridges where id=p_bridge_id and user_id=p_user_id for no key update;
  if not found then return jsonb_build_object('status','not_found'); end if;
  update public.bridges set status='revoked',revoked_at=coalesce(revoked_at,public.db_now()),secret_hash=null where id=b.id;
  update public.agent_connections set status='revoked' where bridge_id=b.id and user_id=p_user_id;
  for a in select a0.* from public.agent_sessions a0 join public.agent_connections ac on ac.id=a0.connection_id and ac.user_id=a0.user_id
    where ac.bridge_id=b.id and a0.user_id=p_user_id order by a0.id for update of a0 loop
    for r in select r0.* from public.execution_runs r0 where r0.agent_session_id=a.id and r0.user_id=p_user_id
      and r0.kind='conversation' and (r0.state in ('queued','running','waiting_approval')
        or exists(select 1 from public.agent_tasks t0 where t0.run_id=r0.id and t0.user_id=p_user_id
          and t0.state in ('dispatched','accepted','running','awaiting_answer','unreachable'))) order by r0.id for no key update loop
      for t in select * from public.agent_tasks where run_id=r.id and user_id=p_user_id
        and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id for update loop
        -- OA F3: 아래 작업 행의 둘째 갱신(request_agent_task_cancel 뒤 state='cancelled')이 FK 재확인으로 메시지 KEY SHARE를 기다리지 않게, 폐기도 NOWAIT로 먼저 쥔다.
        -- 세션은 위 고리가 이미 FOR UPDATE로 쥐고 있다. 못 쥐면 55P03으로 폐기 전체가 롤백되고 revokeBridge가 다시 한다.
        perform 1 from public.conversation_messages where id=t.message_id and user_id=p_user_id for key share nowait;
        if a.status='external' then
          update public.agent_tasks set cancel_requested_at=coalesce(cancel_requested_at,public.db_now()) where id=t.id;
          v_result:=jsonb_build_object('agent_task_id',t.id,'cancel','requested_only');
        else
          v_result:=public.request_agent_task_cancel(p_user_id,t.id);
        end if;
        if v_result->>'cancel'='requested_only' then
          update public.agent_tasks set state='cancelled',last_live_state=case when t.state='unreachable' then t.last_live_state else t.state end,
            pending_question=null,answered_question=null where id=t.id;
        end if;
        if v_result is not null then v_tasks:=v_tasks||jsonb_build_array(v_result); end if;
      end loop;
      perform set_config('execution.gate','bridge_revoked',true);
      update public.execution_runs set state='stopped',stopped_at=null where id=r.id and state in ('queued','running','waiting_approval');
    end loop;
    update public.agent_sessions set status='closed' where id=a.id;
  end loop;
  return jsonb_build_object('status','revoked','tasks',v_tasks);
end;
$$;

create or replace function public.stop_agent_runs_on_user_claim() returns trigger
language plpgsql set search_path = ''
as $$
declare v_run record; v_task record;
begin
  if new.origin <> 'user' or new.field <> 'status' or new.value not in ('done','dropped') then return null; end if;
  perform 1 from public.actions where id = new.action_id and user_id = new.user_id and status = new.value for update;
  if not found then return null; end if;
  -- OA F3: heartbeat · 폐기 · sweep은 세션 id 순으로 세션을 쥐고 그 세션의 run을 쥔다. 같은 순서(세션 -> run)로 잡아야
  -- 한 이슈에 같은 bridge의 두 세션 run이 열려 있을 때 서로 run 하나씩 쥐고 기다리지 않는다.
  for v_run in select id from public.execution_runs where action_id = new.action_id and user_id = new.user_id
    and kind = 'conversation' and state in ('queued','running','waiting_approval') order by agent_session_id, id for no key update loop
    for v_task in select id from public.agent_tasks where run_id = v_run.id and user_id = new.user_id
      and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id loop
      perform public.request_agent_task_cancel(new.user_id,v_task.id);
    end loop;
    perform set_config('execution.gate','action_closed',true);
    update public.execution_runs set state = 'stopped',stopped_at = null where id = v_run.id;
  end loop;
  return null;
end;
$$;

-- OA F3 재검토: 백그라운드 작업은 사용자 경로(Done · 답 · heartbeat · 폐기)가 쥘 수 있는 잠금을 기다리지 않는다. 사용자 경로는 한 순서로만 잠그고(Done은 세션 -> run id 순, heartbeat · 폐기는 bridge -> 세션 -> run),
-- sweep은 bridge id 순으로 여러 bridge를 지나므로 순서가 달라지는 곳이 생긴다. 기다리지 않으면 순환이 생길 수 없다. 세션 · run · task · 단계 잠금을 NOWAIT로 바꿨다(본문은 이 잠금 방식 넷만 원본과 다르다).
-- 쥘 수 없는 bridge는 하위 트랜잭션 전체가 롤백되고(세션 상태 변경도 되돌아가므로 다음 분에 처음부터 다시 한다) 기존 실패 수(failure_count)로 세어진다 - sweepBridge의 errors.
create or replace function public.sweep_bridge_heartbeats(p_now timestamptz default null,p_limit integer default 50)
returns table(user_id uuid,bridge_id uuid,agent_session_id uuid,agent_task_id uuid,turn_seq integer,failure_count integer)
language plpgsql set search_path = '' as $$
declare b public.bridges; a public.agent_sessions; r public.execution_runs; t public.agent_tasks; s public.execution_steps; v_changed uuid[]; v_failures integer:=0;
begin
  for b in select b0.* from public.bridges b0 where b0.status='active' and b0.last_heartbeat_at<public.db_now()-interval '90 seconds'
    and exists(select 1 from public.agent_sessions a0 join public.agent_connections ac on ac.id=a0.connection_id and ac.user_id=a0.user_id
      where ac.bridge_id=b0.id and a0.user_id=b0.user_id and a0.status='bound')
    order by b0.id limit greatest(p_limit,0) for no key update skip locked loop
    begin
    v_changed:='{}';
    for a in select a0.* from public.agent_sessions a0 join public.agent_connections ac on ac.id=a0.connection_id and ac.user_id=a0.user_id
      where ac.bridge_id=b.id and a0.user_id=b.user_id and a0.status='bound' order by a0.id for update of a0 nowait loop
      update public.agent_sessions set status='unreachable' where id=a.id;
      for r in select r0.* from public.execution_runs r0 where r0.agent_session_id=a.id and r0.user_id=b.user_id order by r0.id for no key update nowait loop
        for t in select t0.* from public.agent_tasks t0 where t0.run_id=r.id and t0.agent_session_id=a.id and t0.user_id=b.user_id
          order by t0.id for update nowait loop
          select * into s from public.execution_steps where id=t.step_id and execution_steps.user_id=b.user_id for update nowait;
          if t.state in ('accepted','running','awaiting_answer') or (t.state='dispatched' and s.state in ('calling','unknown_outcome')
            and exists(select 1 from public.bridge_commands c where c.step_id=s.id and c.bridge_id=b.id and c.lease_owner is not null)) then
            update public.agent_tasks set last_live_state=state,state='unreachable' where id=t.id;
            insert into public.execution_events(user_id,run_id,type,bridge_id,external_event_id,turn_seq,payload)
              values(b.user_id,r.id,'agent',b.id,'bridge-unreachable:'||a.id||':'||floor(extract(epoch from b.last_heartbeat_at))::bigint,t.turn_seq,
                jsonb_build_object('event_type','bridge_unreachable','agent_session_id',a.id,'agent_task_id',t.id,
                  'turn_seq',t.turn_seq,'fanout_pending',true));
            v_changed:=array_append(v_changed,t.id);
          end if;
        end loop;
      end loop;
    end loop;
    return query select b.user_id,b.id,t0.agent_session_id,t0.id,t0.turn_seq,0
      from public.agent_tasks t0 where t0.id=any(v_changed) order by t0.agent_session_id,t0.id;
    exception when others then
      raise warning 'sweep_bridge_heartbeats: bridge %', b.id;
      v_failures:=v_failures+1;
    end;
  end loop;
  if v_failures>0 then return query select null::uuid,null::uuid,null::uuid,null::uuid,null::integer,v_failures; end if;
end;
$$;

-- OA F3 재검토 2: 같은 cron이 이어서 부르는 단계 lease 정리(sweep_agent_step_leases) · 실행 sweep(sweep_expire) · 보관 정리(purge_expired_execution_text)도 기다리지 않는다.
-- 이 셋은 단계를 먼저 잠그고(update) calling -> unknown_outcome 트리거(execution_steps_release_credits -> release_run_credits)가 그 run을 기다렸다: step -> run 순서.
-- Done · Stop · 폐기 · heartbeat · lease/settle/readback은 run -> task -> step 순서라 서로 기다리면 순환이다(40P01로 사용자 요청이 롤백됨).
-- 이제 run을 먼저 NO KEY UPDATE SKIP LOCKED로 쥔 다음 단계를 FOR UPDATE SKIP LOCKED로 쥔다(같은 순서, 기다리지 않음). 못 쥔 단계는 건드리지 않고 다음 분에 다시 후보가 된다.
-- 트리거가 run을 다시 잡아도 이미 쥔 잠금이라 기다리지 않는다. 본문은 잠금을 쥐는 문장만 원본과 다르다.
create or replace function public.sweep_agent_step_leases(p_now timestamptz) returns integer
language plpgsql set search_path = '' as $$
declare v_n integer;
begin
  perform set_config('execution.gate','lease_expired',true);
  with expired as (select s.id from public.execution_runs r join public.execution_steps s on s.run_id=r.id and s.user_id=r.user_id
    where r.kind='conversation' and s.kind in ('agent_message','agent_cancel') and s.state='calling' and s.lease_expires_at<public.db_now()
    order by s.id for no key update of r skip locked for update of s skip locked)
  update public.execution_steps set state='unknown_outcome',unknown_since=public.db_now(),version=version+1,lease_owner=null
    where id in(select id from expired);
  get diagnostics v_n=row_count; return v_n;
end;
$$;

create or replace function public.sweep_expire() returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_external integer;
begin
  perform set_config('execution.gate', 'lease_expired', true);
  with locked as (select s.id from public.execution_runs r join public.execution_steps s on s.run_id = r.id and s.user_id = r.user_id
    where s.state = 'calling' and s.lease_expires_at < public.db_now() and s.effect_class = 'external'
    order by s.id for no key update of r skip locked for update of s skip locked)
  update public.execution_steps set state = 'unknown_outcome', unknown_since = public.db_now(), version = version + 1, lease_owner = null
    where id in (select id from locked);
  get diagnostics v_external = row_count;
  return v_external + public.execution_retry_internal(array(
    select id from public.execution_steps where state = 'calling' and lease_expires_at < public.db_now() and effect_class = 'internal'
  ));
end;
$$;

create or replace function public.purge_expired_execution_text(p_before timestamptz, p_limit integer default 5000)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_runs uuid[];
  v_count integer;
  v_gate text := current_setting('execution.gate', true); -- 부른 쪽의 gate (끝날 때 되돌린다)
begin
  if p_before is null or p_limit is null or p_limit < 1 then
    raise exception 'purge_expired_execution_text: 잘못된 인자';
  end if;
  select coalesce(array_agg(x.id), '{}') into v_runs from (
    select r.id from public.execution_runs r
    where r.text_purged_at is null
      and r.state in ('done', 'failed', 'stopped')
      and r.created_at < p_before
      and not exists (select 1 from public.execution_steps s where s.run_id = r.id and s.state in ('calling', 'unknown_outcome'))
    order by r.created_at, r.id
    limit p_limit
    for no key update of r skip locked
  ) x;
  if cardinality(v_runs) = 0 then
    perform set_config('execution.gate', coalesce(nullif(v_gate, 'retention'), ''), true);
    return 0;
  end if;

  perform set_config('execution.gate', 'retention', true);
  update public.execution_steps s
    set args = s.args - array['brief','answers'], receipt = s.receipt - array['to', 'question']
    where s.run_id = any (v_runs) and (s.args ?| array['brief','answers'] or s.receipt ?| array['to', 'question']);
  update public.execution_runs r set request = '', text_purged_at = public.db_now()
    where r.id = any (v_runs) and r.text_purged_at is null;
  get diagnostics v_count = row_count;
  -- 트리거 예외는 이 함수 안에서만: 부른 쪽의 gate로 되돌려(retention은 남기지 않는다), 같은 트랜잭션의 뒤 문장이 지시를 지우면 다시 계획 · 동결 규칙대로 돈다
  perform set_config('execution.gate', coalesce(nullif(v_gate, 'retention'), ''), true);
  return v_count;
end;
$$;

-- 남은 만료 lease 수(못 쥐어 건너뛴 단계가 여기에 남는다): sweepBridge가 매 분 숫자로 보인다. 읽기만 한다.
create function public.count_overdue_agent_step_leases(p_grace_seconds integer) returns integer
language sql stable set search_path = '' as $$
  select count(*)::integer from public.execution_steps s join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
   where r.kind = 'conversation' and s.kind in ('agent_message', 'agent_cancel') and s.state = 'calling'
     and s.lease_expires_at < public.db_now() - make_interval(secs => greatest(coalesce(p_grace_seconds, 0), 0));
$$;
revoke all on function public.count_overdue_agent_step_leases(integer) from public, anon, authenticated;
grant execute on function public.count_overdue_agent_step_leases(integer) to service_role;

-- 만료한 lease 전 message 명령 회수 (cron 1분, sweepBridge). 후보는 잠금 없이 찾고 후보마다 하위 트랜잭션에서 메시지부터 잠근다:
-- 메시지(skip locked) -> 세션 -> run -> task -> step -> 명령(모두 NOWAIT, lock_bridge_command와 같은 순서) -> lock_bridge_command -> 같은 조건 다시 확인 -> withdraw_bridge_command(..., 'expired').
-- 백그라운드 작업이라 사용자 경로(Done · 답 · heartbeat · 폐기)가 쥘 수 있는 잠금을 기다리지 않는다: 쥘 수 없으면 그 후보만 busy로 세고 건너뛴다(다음 분에 다시). 기다리지 않으니 순환이 생길 수 없다.
-- 나머지 후보는 계속한다. 아래 lock_timeout은 NOWAIT로 못 막는 남은 기다림(트리거가 쓰는 다른 행 등)의 상한이다.
-- 조건은 lease의 message 만료 조건(BC lease_bridge_command)과 같고 세션 · 연결 · 실행 gate는 보지 않는다: 24시간이 지나면 이유보다 만료가 이긴다.
-- 쓰기는 withdraw_bridge_command가 하는 것뿐이다 (단계 failed + receipt, 메시지 expired + 이유 null, task failed, 명령 withdrawn). 지표 · 로그 0.
create function public.expire_unleased_agent_messages(p_limit integer) returns jsonb
language plpgsql set search_path = '' set lock_timeout = '1s'
as $$
declare
  v_candidate record;
  v_command public.bridge_commands;
  v_result jsonb;
  v_session uuid;
  v_item jsonb;
  v_sessions jsonb := '[]'::jsonb;
  v_reclaimed integer := 0;
  v_busy integer := 0;
  v_window bigint := nextval('public.bridge_reclaim_scan_seq');
  v_started timestamptz := clock_timestamp();
begin
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'expire_unleased_agent_messages: limit must be 1-200' using errcode = '22023';
  end if;
  -- 후보를 만료가 오래된 순으로 p_limit개씩 창으로 나누고, 이번 호출은 번호(v_window)가 가리키는 창 하나를 처리한다. 후보가 p_limit 이하면 창이 하나라 늘 같은 창이다.
  -- (성공한 후보의 잠금은 하위 트랜잭션이 끝나도 함수가 끝날 때까지 남지만, 이 함수는 어떤 잠금도 기다리지 않으므로 그 잠금이 순환의 한쪽이 될 수 없다.)
  for v_candidate in
    select e.command_id, e.bridge_id, e.user_id, e.message_id, e.session_id, e.run_id, e.task_id, e.step_id
      from (
        select c.id as command_id, c.bridge_id, c.user_id, t.message_id, t.id as task_id, s.id as step_id, s.run_id, r.agent_session_id as session_id, m.delivery_expires_at,
               row_number() over (order by m.delivery_expires_at, c.id) - 1 as pos, count(*) over () as total
          from public.bridge_commands c
          join public.execution_steps s on s.id = c.step_id and s.user_id = c.user_id
          join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
          join public.agent_tasks t on t.id = c.agent_task_id and t.user_id = c.user_id
          join public.conversation_messages m on m.id = t.message_id and m.user_id = c.user_id
         where c.kind = 'message' and c.lease_owner is null and c.outcome is null
           and s.state = 'prepared' and s.lease_owner is null
           and m.delivery_state = 'dispatched' and m.delivery_expires_at <= public.db_now()
      ) e
     where e.pos / p_limit = v_window % greatest((e.total + p_limit - 1) / p_limit, 1)
     order by e.pos
  loop
    -- cron(maxDuration 60초) 안에서 끝나게: 예산을 넘으면 남은 후보는 다음 분에 한다
    exit when clock_timestamp() - v_started > interval '10 seconds';
    begin
      perform 1 from public.conversation_messages where id = v_candidate.message_id and user_id = v_candidate.user_id for update skip locked;
      if not found then
        v_busy := v_busy + 1;
        continue;
      end if;
      -- lock_bridge_command가 잡을 행을 같은 순서로 먼저 NOWAIT로 쥔다(못 쥐면 55P03 -> 아래 예외 처리에서 busy). 뒤의 lock_bridge_command는 이미 쥔 행을 다시 잡을 뿐이라 기다리지 않는다
      perform 1 from public.agent_sessions where id = v_candidate.session_id and user_id = v_candidate.user_id for update nowait;
      perform 1 from public.execution_runs where id = v_candidate.run_id and user_id = v_candidate.user_id for no key update nowait;
      perform 1 from public.agent_tasks where id = v_candidate.task_id and user_id = v_candidate.user_id for update nowait;
      perform 1 from public.execution_steps where id = v_candidate.step_id and user_id = v_candidate.user_id for update nowait;
      perform 1 from public.bridge_commands where id = v_candidate.command_id and user_id = v_candidate.user_id for update nowait;
      v_command := public.lock_bridge_command(v_candidate.user_id, v_candidate.bridge_id, v_candidate.command_id);
      if v_command.id is null then continue; end if;
      -- 잠금 아래 다시 확인: 후보를 찾은 뒤 lease · 취소 · 재전송 등으로 바뀌었으면 건너뛴다
      select t.agent_session_id into v_session
        from public.bridge_commands c
        join public.execution_steps s on s.id = c.step_id and s.user_id = c.user_id
        join public.agent_tasks t on t.id = c.agent_task_id and t.user_id = c.user_id
        join public.conversation_messages m on m.id = t.message_id and m.user_id = c.user_id
       where c.id = v_command.id and c.kind = 'message' and c.lease_owner is null and c.outcome is null
         and s.state = 'prepared' and s.lease_owner is null
         and m.delivery_state = 'dispatched' and m.delivery_expires_at <= public.db_now();
      if not found then continue; end if;
      v_result := public.withdraw_bridge_command(v_command.id, 'expired');
      if v_result->>'status' = 'withdrawn' then
        v_reclaimed := v_reclaimed + 1;
        v_item := jsonb_build_object('user_id', v_command.user_id, 'agent_session_id', v_session);
        if not v_sessions @> jsonb_build_array(v_item) then v_sessions := v_sessions || jsonb_build_array(v_item); end if;
      end if;
    exception when lock_not_available or deadlock_detected then
      v_busy := v_busy + 1;
    end;
  end loop;
  return jsonb_build_object('reclaimed', v_reclaimed, 'busy', v_busy, 'sessions', v_sessions);
end;
$$;
revoke all on function public.expire_unleased_agent_messages(integer) from public, anon, authenticated;
grant execute on function public.expire_unleased_agent_messages(integer) to service_role;

commit;
