-- OA D1c-2b: answer CAS, session Stop and user-Claim Done. Deliveries remain prepared.
begin;
set local lock_timeout = '5s';
lock table public.execution_runs in access exclusive mode nowait;
lock table public.agent_tasks in access exclusive mode nowait;
lock table public.agent_sessions in share row exclusive mode nowait;
lock table public.claims in share row exclusive mode nowait;

alter table public.agent_tasks add column answered_question jsonb,
  add column abandoned_question jsonb,
  add constraint agent_tasks_answered_question_check check (answered_question is null or (
    public.agent_pending_question_valid(answered_question)
    and answered_question->'question_key'->>0 is not distinct from id::text)),
  add constraint agent_tasks_abandoned_question_check check (abandoned_question is null or
    case when jsonb_typeof(abandoned_question) = 'array' then
      jsonb_array_length(abandoned_question) = 2
      and jsonb_typeof(abandoned_question->0) is not distinct from 'string'
      and abandoned_question->>0 is not distinct from id::text
      and jsonb_typeof(abandoned_question->1) is not distinct from 'string'
      and char_length(abandoned_question->>1) between 1 and 200
    else false end);

-- Answer text follows the same retention boundary as execution briefs.
create or replace function public.execution_steps_replan() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.connection_id,
      new.recipients, new.body, new.args, new.source_revision)
     is distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.connection_id,
      old.recipients, old.body, old.args, old.source_revision) then
    if coalesce(current_setting('execution.gate', true), '') = 'retention'
       and new.args = old.args - array['brief','answers']
       and (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.connection_id, new.recipients, new.body, new.source_revision)
           is not distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.connection_id, old.recipients, old.body, old.source_revision) then
      return new;
    end if;
    if old.state not in ('pending', 'prepared') then
      if new.connection_id is null
         and (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.recipients, new.body, new.args, new.source_revision)
             is not distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.recipients, old.body, old.args, old.source_revision) then
        return new;
      end if;
      raise exception 'step % is %: plan is frozen', old.id, old.state;
    end if;
    new.state := 'pending';
    new.version := old.version + 1;
    new.intent_key := null;
    new.policy_version := null;
    new.needs_approval := null;
  end if;
  return new;
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


create or replace function public.append_step(p_run_id uuid, p_seq integer, p_step jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_user uuid;
  v_state text;
  v_step uuid;
begin
  select user_id, state into v_user, v_state from public.execution_runs where id = p_run_id for no key update;
  if v_state is null or (v_state not in ('queued', 'running')
    and not (v_state in ('waiting_approval','stopped') and p_step->>'kind' = 'agent_cancel' and exists (
      select 1 from public.execution_runs where id = p_run_id and kind = 'conversation'))) then
    return null;
  end if;
  if p_seq <> (select coalesce(max(seq), 0) + 1 from public.execution_steps where run_id = p_run_id) then
    return null;
  end if;
  if p_step->>'kind' is null or not exists (
    select 1 from public.execution_runs where id = p_run_id
      and ((kind = 'conversation' and p_step->>'kind' in ('agent_message', 'agent_cancel'))
        or (kind = 'task' and p_step->>'kind' in ('plan', 'draft', 'external')))
  ) then
    raise exception 'append_step: 단계 종류 % 는 아직 붙이지 않는다 (plan · draft · external만)', p_step->>'kind' using errcode = '22023';
  end if;
  perform set_config('execution.gate', 'append', true);
  insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose,
                                      connection_id, recipients, body, args, source_revision, estimate_credits)
  values (
    v_user, p_run_id, p_seq, p_step->>'kind', p_step->>'provider', p_step->>'tool',
    coalesce((select t.effect_class from public.execution_tools t where t.provider = p_step->>'provider' and t.tool = p_step->>'tool'), 'external'),
    p_step->>'purpose', (p_step->>'connection_id')::uuid,
    coalesce(p_step->'recipients', '[]'), coalesce(p_step->>'body', ''), coalesce(p_step->'args', '{}'),
    coalesce((p_step->>'source_revision')::integer, 1), coalesce((p_step->>'estimate_credits')::integer, 0)
  )
  returning id into v_step;
  return v_step;
end;
$$;

create or replace function public.prepare_step(p_step uuid, p_version integer) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('execution.gate', 'prepare', true);
  update public.execution_steps s set
    state = 'prepared',
    version = s.version + 1,
    policy_version = p.version,
    intent_key = case
      when s.effect_class = 'internal' then concat_ws('|', 'internal', s.id)
      else concat_ws('|', r.action_id, s.provider, s.tool, s.purpose, public.norm_addresses(s.recipients)::text, s.occurrence)
    end
  from public.execution_runs r
  join public.execution_policies p on p.id = r.policy_id
  where s.id = p_step and s.state = 'pending' and s.version = p_version and r.id = s.run_id;
  if not found then
    return false;
  end if;
  update public.execution_steps
    set needs_approval = (effect_class = 'external' and not (kind in ('agent_message', 'agent_cancel') and exists (
      select 1 from public.execution_runs r where r.id = run_id and r.kind = 'conversation'))
      and public.auto_allowed(id) is not true)
    where id = p_step;
  update public.execution_runs set state = 'running'
    where id = (select run_id from public.execution_steps where id = p_step) and state = 'queued';
  return true;
end;
$$;

create function public.answer_agent_question(
  p_user_id uuid, p_agent_task_id uuid, p_provider_request_id text, p_answers jsonb, p_answered_locally boolean,
  p_answer_message_id uuid default null
) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_task public.agent_tasks;
  v_session public.agent_sessions;
  v_run public.execution_runs;
  v_message public.conversation_messages;
  v_question jsonb;
  v_item jsonb;
  v_answer jsonb;
  v_secret boolean;
  v_step uuid;
  v_args jsonb;
  v_label text;
  v_labels text[] := '{}';
  v_previous public.execution_steps;
  v_event_id text;
  v_event_text text;
  v_adapter text;
  v_retry integer;
  v_answer_message public.conversation_messages;
begin
  select * into v_task from public.agent_tasks where id = p_agent_task_id and user_id = p_user_id;
  if not found then return jsonb_build_object('status','not_found'); end if;
  v_event_id := 'answer:' || p_agent_task_id || ':' || encode(sha256(convert_to(p_provider_request_id,'UTF8')),'hex');
  -- Retry may replace its single event label; lock that row together with the origin before the conversation.
  perform 1 from public.conversation_messages where user_id = p_user_id and (id in (v_task.message_id,p_answer_message_id)
    or (external_event_id = v_event_id and conversation_id = (select conversation_id from public.conversation_messages where id = v_task.message_id))) order by id for update;
  select * into v_message from public.conversation_messages where id = v_task.message_id and user_id = p_user_id;
  perform 1 from public.conversations where id = v_message.conversation_id and user_id = p_user_id for update;
  select * into v_session from public.agent_sessions where id = v_task.agent_session_id and user_id = p_user_id for update;
  select * into v_run from public.execution_runs where id = v_task.run_id and user_id = p_user_id for no key update;
  select * into v_task from public.agent_tasks where id = p_agent_task_id and user_id = p_user_id for update;
  if v_task.id is null or v_session.id is null or v_run.id is null or v_message.id is null
    or v_run.kind <> 'conversation' or v_run.agent_session_id is distinct from v_session.id
    or v_task.run_id is distinct from v_run.id or v_task.agent_session_id is distinct from v_session.id
    or v_task.message_id is distinct from v_message.id
    or not exists (select 1 from public.conversations where id = v_message.conversation_id and user_id = p_user_id
      and target_kind = 'agent' and agent_session_id = v_session.id and agent_connection_id = v_session.connection_id) then
    return jsonb_build_object('status','not_found');
  end if;
  if v_run.state not in ('queued','running') or v_session.status in ('external','closed')
    or v_task.cancel_requested_at is not null
    or not exists (select 1 from public.agent_connections where id = v_session.connection_id and user_id = p_user_id and status = 'active')
    then return jsonb_build_object('status','question_stale'); end if;
  v_question := v_task.pending_question;
  if v_question is not null and v_question->'question_key' is distinct from jsonb_build_array(p_agent_task_id,p_provider_request_id) then
    return jsonb_build_object('status','question_stale');
  end if;
  select * into v_previous from public.execution_steps where run_id = v_run.id and user_id = p_user_id
    and args->>'agent_task_id' = p_agent_task_id::text and args->>'provider_request_id' = p_provider_request_id
    and kind = 'agent_message' order by seq desc limit 1 for update;
  if v_previous.id is not null and (v_question is not null or v_task.answered_question->'question_key' = jsonb_build_array(p_agent_task_id,p_provider_request_id))
    and not (v_previous.state = 'failed' and v_task.step_id = v_previous.id and v_question is not null and v_task.state = 'awaiting_answer') then
    return jsonb_build_object('status','duplicate','step_id',v_previous.id);
  end if;
  if v_task.state <> 'awaiting_answer' or v_question is null then return jsonb_build_object('status','question_stale'); end if;
  select exists (select 1 from jsonb_array_elements(v_question->'questions') q where (q->>'secret')::boolean) into v_secret;
  if v_secret then
    if p_answered_locally is not true or p_answer_message_id is not null then return jsonb_build_object('status','secret_requires_local'); end if;
    if p_answers is not null and p_answers not in ('null'::jsonb,'{}'::jsonb) then return jsonb_build_object('status','invalid_answer'); end if;
    v_args := jsonb_build_object('answered_locally',true);
  else
    if p_answered_locally is distinct from false or jsonb_typeof(p_answers) is distinct from 'object'
      or octet_length(p_answers::text) > 4096 then return jsonb_build_object('status','invalid_answer'); end if;
    if (select count(*) from jsonb_object_keys(p_answers)) <> jsonb_array_length(v_question->'questions') then
      return jsonb_build_object('status','invalid_answer');
    end if;
    for v_item in select value from jsonb_array_elements(v_question->'questions') loop
      v_answer := p_answers->(v_item->>'id');
      if v_question->>'kind' = 'approval' then
        if jsonb_typeof(v_answer) is distinct from 'string' or v_answer #>> '{}' not in ('allow','deny') then
          return jsonb_build_object('status','invalid_answer');
        end if;
        v_labels := array_append(v_labels, case when v_answer #>> '{}' = 'allow' then 'Allowed' else 'Denied' end);
      elsif (v_item->>'multi_select')::boolean then
        if jsonb_typeof(v_answer) is distinct from 'array' or jsonb_array_length(v_answer) = 0 then return jsonb_build_object('status','invalid_answer'); end if;
        if exists (select 1 from jsonb_array_elements(v_answer) a where jsonb_typeof(a) <> 'string'
          or not exists (select 1 from jsonb_array_elements(v_item->'options') o where o->'label' = a))
          or (select count(distinct a) from jsonb_array_elements(v_answer) a) <> jsonb_array_length(v_answer) then
          return jsonb_build_object('status','invalid_answer');
        end if;
        for v_label in select jsonb_array_elements_text(v_answer) loop v_labels := array_append(v_labels,v_label); end loop;
      else
        if jsonb_typeof(v_answer) is distinct from 'string' then return jsonb_build_object('status','invalid_answer'); end if;
        v_label := v_answer #>> '{}';
        if exists (select 1 from jsonb_array_elements(v_item->'options') o where o->>'label' = v_label) then
          v_labels := array_append(v_labels,v_label);
        elsif not (v_item->>'allow_other')::boolean or char_length(v_label) not between 1 and 2000
          or v_label !~ '[^[:space:]]' then
          return jsonb_build_object('status','invalid_answer');
        end if;
      end if;
    end loop;
    if p_answer_message_id is not null then
      select * into v_answer_message from public.conversation_messages where id = p_answer_message_id and user_id = p_user_id;
      if v_answer_message.id is null or v_answer_message.role <> 'user'
        or v_answer_message.conversation_id is distinct from v_message.conversation_id
        or v_answer_message.delivery_state not in ('queued','not_sent')
        or not coalesce(v_answer_message.seq > (select max(m.seq) from public.conversation_messages m
          where m.conversation_id = v_message.conversation_id and m.user_id = p_user_id
            and m.content->>'kind' = 'question' and m.content->>'turn_seq' = v_task.turn_seq::text),false)
        or v_answer_message.delivery_expires_at is null or v_answer_message.delivery_expires_at <= public.db_now()
        or v_question->>'kind' <> 'input' or jsonb_array_length(v_question->'questions') <> 1
        or not (v_question->'questions'->0->>'allow_other')::boolean
        or (v_question->'questions'->0->>'multi_select')::boolean
        or p_answers is distinct from jsonb_build_object(v_question->'questions'->0->>'id',v_answer_message.text) then
        return jsonb_build_object('status','invalid_answer');
      end if;
      v_args := jsonb_build_object('answer_message_id',p_answer_message_id);
    else
      v_args := jsonb_build_object('answers',p_answers);
    end if;
  end if;
  select adapter into v_adapter from public.agent_connections where id = v_session.connection_id and user_id = p_user_id;
  v_args := jsonb_build_object('agent_task_id',p_agent_task_id,'provider_request_id',p_provider_request_id) || v_args;
  select count(*)::integer into v_retry from public.execution_steps where run_id = v_run.id
    and args->>'agent_task_id' = p_agent_task_id::text and args->>'provider_request_id' = p_provider_request_id
    and kind = 'agent_message' and state = 'failed';
  v_step := public.append_step(v_run.id, (select coalesce(max(seq),0)+1 from public.execution_steps where run_id = v_run.id),
    jsonb_build_object('kind','agent_message','provider',v_adapter,'tool','message','purpose','answer:' || p_agent_task_id || ':' || p_provider_request_id,
      'body','','args',v_args));
  if v_step is null or not public.prepare_step(v_step,(select version from public.execution_steps where id = v_step)) then
    raise exception 'answer_agent_question: step not prepared' using errcode = '22023';
  end if;
  update public.execution_steps set intent_key = 'answer:' || p_agent_task_id || ':' || p_provider_request_id || ':' || v_retry where id = v_step;
  update public.agent_tasks set answered_question = pending_question, pending_question = null, state = 'running', step_id = v_step
    where id = p_agent_task_id;
  v_event_text := case when v_secret then 'Answered on this Mac' when cardinality(v_labels) > 0 then array_to_string(v_labels,', ') else 'Answered' end;
  perform public.conversation_append_agent_message(p_user_id,v_message.conversation_id,p_agent_task_id,v_task.turn_seq,v_event_id,v_event_text,'event');
  if v_previous.id is not null then
    update public.conversation_messages set text = v_event_text where user_id = p_user_id
      and conversation_id = v_message.conversation_id and external_event_id = v_event_id;
  end if;
  return jsonb_build_object('status','answered','step_id',v_step);
end;
$$;

create function public.route_agent_message(
  p_user_id uuid, p_message_id uuid, p_access text, p_live_limit integer,
  p_action_ids uuid[] default '{}', p_context_ids uuid[] default '{}'
) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_message public.conversation_messages;
  v_conversation public.conversations;
  v_task public.agent_tasks;
  v_origin uuid;
  v_answer_event text;
  v_session public.agent_sessions;
  v_result jsonb;
  v_question jsonb;
begin
  select * into v_message from public.conversation_messages where id = p_message_id and user_id = p_user_id and role = 'user';
  if not found then return jsonb_build_object('status','not_found'); end if;
  select * into v_conversation from public.conversations where id = v_message.conversation_id and user_id = p_user_id;
  select * into v_task from public.agent_tasks where agent_session_id = v_conversation.agent_session_id
    and user_id = p_user_id and state = 'awaiting_answer';
  v_origin := v_task.message_id;
  v_answer_event := 'answer:' || v_task.id || ':' || encode(sha256(convert_to(v_task.pending_question->>'provider_request_id','UTF8')),'hex');
  -- Lock both messages/conversations in one order before delegating to answer or start.
  perform 1 from public.conversation_messages where user_id = p_user_id and (id in (p_message_id,v_origin)
    or (external_event_id = v_answer_event and conversation_id = (select conversation_id from public.conversation_messages where id = v_origin))) order by id for update;
  perform pg_advisory_xact_lock(hashtextextended('agent_turn:' || p_user_id::text,0));
  perform 1 from public.conversations where user_id = p_user_id and id in (
    select conversation_id from public.conversation_messages where id in (p_message_id,v_origin) and user_id = p_user_id
  ) order by id for update;
  select * into v_message from public.conversation_messages where id = p_message_id and user_id = p_user_id;
  select * into v_conversation from public.conversations where id = v_message.conversation_id and user_id = p_user_id;
  select * into v_session from public.agent_sessions where id = v_conversation.agent_session_id and user_id = p_user_id for update;
  if v_message.id is null or v_message.role <> 'user' or v_conversation.id is null then
    return jsonb_build_object('status','not_found');
  end if;
  if v_conversation.target_kind <> 'agent' then return jsonb_build_object('status','wrong_target'); end if;
  if v_message.delivery_state not in ('queued','not_sent') then return jsonb_build_object('status','already_dispatched'); end if;
  if v_message.delivery_expires_at is null or v_message.delivery_expires_at <= public.db_now() then return jsonb_build_object('status','expired'); end if;
  if p_access is null or p_access not in ('write','read_only') or p_live_limit is null or p_live_limit < 1 then
    raise exception 'route_agent_message: invalid access or live limit' using errcode = '22023';
  end if;
  select * into v_task from public.agent_tasks where agent_session_id = v_session.id and user_id = p_user_id and state = 'awaiting_answer';
  if v_task.id is not null and v_conversation.target_kind = 'agent' and v_session.status = 'bound'
    and v_conversation.agent_connection_id = v_session.connection_id and v_task.cancel_requested_at is null
    and exists (select 1 from public.agent_connections where id = v_session.connection_id and user_id = p_user_id and status = 'active') then
    v_question := v_task.pending_question;
    if v_origin = v_task.message_id
      and v_message.conversation_id = (select conversation_id from public.conversation_messages where id = v_task.message_id)
      and v_message.seq > (select max(m.seq) from public.conversation_messages m
        where m.conversation_id = v_message.conversation_id and m.user_id = p_user_id
          and m.content->>'kind' = 'question' and m.content->>'turn_seq' = v_task.turn_seq::text)
      and v_answer_event = 'answer:' || v_task.id || ':' || encode(sha256(convert_to(v_question->>'provider_request_id','UTF8')),'hex')
      and v_question->>'kind' = 'input' and jsonb_array_length(v_question->'questions') = 1
      and (v_question->'questions'->0->>'allow_other')::boolean and not (v_question->'questions'->0->>'secret')::boolean
      and not (v_question->'questions'->0->>'multi_select')::boolean then
      v_result := public.answer_agent_question(p_user_id,v_task.id,v_question->>'provider_request_id',
        jsonb_build_object(v_question->'questions'->0->>'id',v_message.text),false,p_message_id);
      if v_result->>'status' in ('answered','duplicate') then
        update public.conversation_messages set delivery_state = 'dispatched', delivery_reason = null,
          refs = refs || jsonb_build_object('answer_for',v_question->'question_key') where id = p_message_id;
        return v_result;
      end if;
      if v_result->>'status' <> 'invalid_answer' then return v_result; end if;
    end if;
    v_result := public.start_agent_turn(p_user_id,p_message_id,p_action_ids,p_context_ids,p_access,p_live_limit);
    if v_result->>'status' = 'queued' and v_result->>'reason' = 'session_busy' then
      update public.conversation_messages set delivery_reason = 'question_open' where id = p_message_id;
      return jsonb_build_object('status','queued','reason','question_open');
    end if;
    return v_result;
  end if;
  return public.start_agent_turn(p_user_id,p_message_id,p_action_ids,p_context_ids,p_access,p_live_limit);
end;
$$;

-- Task terminal states leave no unleased delivery behind, including prepared answers/cancels.
create function public.skip_terminal_agent_task_steps() returns trigger
language plpgsql set search_path = ''
as $$
begin
  perform set_config('execution.gate','agent_terminal',true);
  with skipped as (update public.execution_steps s set state = 'skipped',version = s.version+1,
    policy_version = coalesce(s.policy_version,(select p.version from public.execution_runs r
      join public.execution_policies p on p.id = r.policy_id where r.id = new.run_id))
    where s.run_id = new.run_id and s.user_id = new.user_id and s.state in ('pending','prepared')
      and s.lease_owner is null and s.lease_expires_at is null
      and not exists (select 1 from public.execution_intents where step_id = s.id)
      and not exists (select 1 from public.execution_events where step_id = s.id and type = 'step' and to_state = 'calling')
      and (s.args->>'agent_task_id' = new.id::text or s.args->>'message_id' = new.message_id::text)
    returning s.id,s.kind,s.args)
  update public.agent_tasks set answered_question = null,
    abandoned_question = jsonb_build_array(new.id,skipped.args->>'provider_request_id'),
    step_id = (select s.id from public.execution_steps s where s.run_id = new.run_id and s.user_id = new.user_id
      and s.kind = 'agent_message' and s.state = 'called'
      and (s.args->>'agent_task_id' = new.id::text or s.args->>'message_id' = new.message_id::text)
      order by s.seq desc limit 1)
    from skipped where agent_tasks.id = new.id and skipped.id = new.step_id and skipped.kind = 'agent_message'
      and skipped.args->>'agent_task_id' = new.id::text
      and coalesce(new.answered_question,old.answered_question)->'question_key'
        = jsonb_build_array(new.id,skipped.args->>'provider_request_id');
  return null;
end;
$$;
create trigger skip_terminal_agent_task_steps after update of state on public.agent_tasks
  for each row when (new.state in ('idle','completed','failed','cancelled') and new.state is distinct from old.state)
  execute function public.skip_terminal_agent_task_steps();

-- Caller holds run before task. Earlier-order message locks use NOWAIT for Stop and user-Claim Done.
create function public.request_agent_task_cancel(p_user_id uuid, p_task_id uuid) returns jsonb
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

create function public.stop_agent_session(p_user_id uuid,p_session_id uuid,p_surface text,p_cancel_scope text default null) returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_session public.agent_sessions;
  v_run record;
  v_task record;
  v_conversation record;
  v_result jsonb;
  v_results jsonb := '[]';
  v_cancelled integer;
begin
  if p_surface is null or p_surface not in ('assistant','session_panel') then
    raise exception 'stop_agent_session: invalid surface' using errcode = '22023';
  end if;
  if p_cancel_scope is not null and p_cancel_scope not in ('turn','turn_and_processes','unknown') then
    raise exception 'stop_agent_session: invalid cancel scope' using errcode = '22023';
  end if;
  if not exists (select 1 from public.agent_sessions where id = p_session_id and user_id = p_user_id) then
    return jsonb_build_object('status','not_found');
  end if;
  -- Include dispatched origins as well as queues: event/answer/start also lock messages first.
  perform 1 from public.conversation_messages m join public.conversations c on c.id = m.conversation_id and c.user_id = m.user_id
    where c.agent_session_id = p_session_id and c.user_id = p_user_id and (
      (m.role = 'user' and m.delivery_state in ('queued','not_sent')) or exists (
        select 1 from public.agent_tasks t where t.message_id = m.id and t.user_id = p_user_id
          and t.agent_session_id = p_session_id and t.state in ('dispatched','accepted','running','awaiting_answer','unreachable')))
    order by m.id for update of m;
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update;
  select * into v_session from public.agent_sessions where id = p_session_id and user_id = p_user_id for update;
  if not found then return jsonb_build_object('status','not_found'); end if;
  -- New bindings/messages may have committed during the first scan. Earlier-order rechecks never wait:
  -- 55P03 rolls back before any writes, so the caller can retry without a lock-order cycle.
  perform 1 from public.conversations where agent_session_id = p_session_id and user_id = p_user_id order by id for update nowait;
  perform 1 from public.conversation_messages m join public.conversations c on c.id = m.conversation_id and c.user_id = m.user_id
    where c.agent_session_id = p_session_id and c.user_id = p_user_id and (
      (m.role = 'user' and m.delivery_state in ('queued','not_sent')) or exists (
        select 1 from public.agent_tasks t where t.message_id = m.id and t.user_id = p_user_id
          and t.agent_session_id = p_session_id and t.state in ('dispatched','accepted','running','awaiting_answer','unreachable')))
    order by m.id for update of m nowait;
  for v_run in select id from public.execution_runs where agent_session_id = p_session_id and user_id = p_user_id
    and kind = 'conversation' order by id for no key update loop
    if v_session.status <> 'external' then
      for v_task in select id from public.agent_tasks where run_id = v_run.id and user_id = p_user_id
        and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id loop
        v_result := public.request_agent_task_cancel(p_user_id,v_task.id);
        if v_result is not null then
          if p_cancel_scope = 'turn' and v_result->>'cancel' = 'requested_only' then v_result := v_result || jsonb_build_object('processes','may_continue'); end if;
          v_results := v_results || jsonb_build_array(v_result);
        end if;
      end loop;
    end if;
    perform public.stop_run(p_user_id,v_run.id);
  end loop;
  for v_conversation in select id from public.conversations where agent_session_id = p_session_id and user_id = p_user_id
    and v_session.status <> 'external' order by id loop
    update public.conversation_messages set delivery_state = 'cancelled', delivery_reason = null
      where conversation_id = v_conversation.id and user_id = p_user_id and role = 'user' and delivery_state in ('queued','not_sent');
    get diagnostics v_cancelled = row_count;
    if v_cancelled > 0 then
      insert into public.conversation_messages(user_id,conversation_id,seq,role,text,content)
        select p_user_id,v_conversation.id,coalesce(max(seq),0)+1,'event','Queued messages cancelled',jsonb_build_object('kind','event')
        from public.conversation_messages where conversation_id = v_conversation.id;
      update public.conversations set last_message_at = public.db_now() where id = v_conversation.id;
    end if;
  end loop;
  insert into public.metric_events(user_id,type,props) values(p_user_id,'stop_requested',jsonb_build_object('surface',p_surface));
  return jsonb_build_object('tasks',v_results);
end;
$$;

-- write_action writes the projection before its new Claims while retaining the Action lock.
create function public.stop_agent_runs_on_user_claim() returns trigger
language plpgsql set search_path = ''
as $$
declare v_run record; v_task record;
begin
  if new.origin <> 'user' or new.field <> 'status' or new.value not in ('done','dropped') then return null; end if;
  perform 1 from public.actions where id = new.action_id and user_id = new.user_id and status = new.value for update;
  if not found then return null; end if;
  for v_run in select id from public.execution_runs where action_id = new.action_id and user_id = new.user_id
    and kind = 'conversation' and state in ('queued','running','waiting_approval') order by id for no key update loop
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
create trigger stop_agent_runs_on_user_claim after insert on public.claims
  for each row execute function public.stop_agent_runs_on_user_claim();

create function public.stop_agent_runs_before_session_delete() returns trigger
language plpgsql set search_path = ''
as $$
declare v_run record;
begin
  for v_run in select id from public.execution_runs where agent_session_id = old.id and user_id = old.user_id
    and kind = 'conversation' and state in ('queued','running','waiting_approval') order by id for no key update loop
    perform set_config('execution.gate','session_deleted',true);
    update public.execution_runs set state = 'stopped',stopped_at = null where id = v_run.id;
  end loop;
  return old;
end;
$$;
create trigger stop_agent_runs_before_session_delete before delete on public.agent_sessions
  for each row execute function public.stop_agent_runs_before_session_delete();

create or replace function public.apply_agent_event(p_user_id uuid, p_event jsonb) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_type text := p_event->>'type';
  v_payload jsonb := coalesce(p_event->'payload', '{}'::jsonb);
  v_allowed text[];
  v_session public.agent_sessions;
  v_task public.agent_tasks;
  v_run public.execution_runs;
  v_step public.execution_steps;
  v_message public.conversation_messages;
  v_conversation public.conversations;
  v_task_id uuid;
  v_session_id uuid;
  v_seq bigint;
  v_turn integer;
  v_observed timestamptz;
  v_status text := 'applied';
  v_state text;
  v_append record;
  v_audit jsonb;
  v_question jsonb;
  v_accept boolean := false;
  v_bind boolean := false;
  v_answer boolean := false;
  v_restore boolean := false;
begin
  if p_user_id is null or jsonb_typeof(p_event) is distinct from 'object'
    or p_event - array['adapter','session_ref','agent_task_id','external_task_id','event_id','seq','turn_seq','type','payload','text','question','observed_at'] <> '{}'
    or jsonb_typeof(p_event->'adapter') is distinct from 'string'
    or not (p_event->>'adapter' ~ '^agent:[a-z0-9][a-z0-9_-]*$') or char_length(p_event->>'adapter') > 64
    or jsonb_typeof(p_event->'event_id') is distinct from 'string' or char_length(p_event->>'event_id') not between 1 and 200
    or jsonb_typeof(p_event->'session_ref') is distinct from 'object'
    or (p_event->'session_ref') - 'agent_session_id' <> '{}'
    or jsonb_typeof(p_event->'session_ref'->'agent_session_id') is distinct from 'string'
    or jsonb_typeof(p_event->'observed_at') is distinct from 'string'
    or not (p_event->>'observed_at' ~ '^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d+)?)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$')
    or v_type is null or v_type not in ('accepted','progress','message','question','artifact','turn_completed','failed','cancelled','unreachable','reconcile','session_bound')
    or jsonb_typeof(v_payload) is distinct from 'object' or octet_length(v_payload::text) > 4096 then
    raise exception 'apply_agent_event: invalid envelope' using errcode = '22023';
  end if;
  if (p_event ? 'agent_task_id' and jsonb_typeof(p_event->'agent_task_id') <> 'string')
    or (p_event ? 'external_task_id' and (jsonb_typeof(p_event->'external_task_id') <> 'string' or char_length(p_event->>'external_task_id') not between 1 and 200))
    or (p_event ? 'seq' and (jsonb_typeof(p_event->'seq') <> 'number' or not (p_event->>'seq' ~ '^[1-9][0-9]*$')))
    or (p_event ? 'turn_seq' and (jsonb_typeof(p_event->'turn_seq') <> 'number' or not (p_event->>'turn_seq' ~ '^[1-9][0-9]*$')))
    or (v_type in ('message','question') and jsonb_typeof(p_event->'text') is distinct from 'string')
    or (v_type not in ('message','question') and p_event ? 'text')
    or (v_type <> 'question' and p_event ? 'question') then
    raise exception 'apply_agent_event: invalid attribution or text' using errcode = '22023';
  end if;
  begin
    v_session_id := (p_event->'session_ref'->>'agent_session_id')::uuid;
    v_task_id := (p_event->>'agent_task_id')::uuid;
    v_seq := (p_event->>'seq')::bigint;
    v_turn := (p_event->>'turn_seq')::integer;
    v_observed := (p_event->>'observed_at')::timestamptz;
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
    raise exception 'apply_agent_event: invalid identity, timestamp or sequence' using errcode = '22023';
  end;
  if not isfinite(v_observed) or v_seq > 9007199254740991 then
    raise exception 'apply_agent_event: invalid timestamp or sequence' using errcode = '22023';
  end if;
  v_allowed := case v_type
    when 'session_bound' then array['external_session_id','workspace_ref']
    when 'artifact' then array['path','hash','summary']
    when 'failed' then array['reason']
    when 'reconcile' then array['state']
    else '{}'::text[] end;
  if v_payload - v_allowed <> '{}' then
    raise exception 'apply_agent_event: invalid payload keys' using errcode = '22023';
  end if;
  if (v_type = 'session_bound' and (
      jsonb_typeof(v_payload->'external_session_id') is distinct from 'string'
      or char_length(v_payload->>'external_session_id') not between 1 and 200 or v_payload->>'external_session_id' like 'pending:%'
      or (v_payload ? 'workspace_ref' and (jsonb_typeof(v_payload->'workspace_ref') <> 'string' or char_length(v_payload->>'workspace_ref') not between 1 and 500))))
    or (v_type = 'artifact' and (
      jsonb_typeof(v_payload->'path') is distinct from 'string' or char_length(v_payload->>'path') not between 1 and 1000
      or jsonb_typeof(v_payload->'hash') is distinct from 'string' or char_length(v_payload->>'hash') not between 1 and 200
      or jsonb_typeof(v_payload->'summary') is distinct from 'string' or char_length(v_payload->>'summary') > 2000))
    or (v_type = 'failed' and v_payload ? 'reason' and (jsonb_typeof(v_payload->'reason') is distinct from 'string'
      or v_payload->>'reason' not in ('sign_in_needed','usage_limited','spawn_failed','version_unsupported','agent_error')))
    or (v_type = 'reconcile' and v_payload ? 'state' and (jsonb_typeof(v_payload->'state') <> 'string'
      or v_payload->>'state' not in ('dispatched','accepted','running','awaiting_answer','idle','failed','cancelled'))) then
    raise exception 'apply_agent_event: invalid payload' using errcode = '22023';
  end if;

  if v_type = 'question' then
    if jsonb_typeof(p_event->'question') is distinct from 'object'
      or (p_event->'question') - array['provider_request_id','kind','structured','questions'] <> '{}' then
      raise exception 'apply_agent_event: invalid question' using errcode = '22023';
    end if;
    v_question := (p_event->'question') || jsonb_build_object(
      'question_key', jsonb_build_array(coalesce(v_task_id::text,'00000000-0000-0000-0000-000000000000'), p_event->'question'->>'provider_request_id'),
      'asked_at', p_event->>'observed_at');
    if not public.agent_pending_question_valid(v_question) then
      raise exception 'apply_agent_event: invalid question' using errcode = '22023';
    end if;
  end if;

  -- Resolve before locking, then recheck every relationship under the locks.
  select s.* into v_session from public.agent_sessions s
    join public.agent_connections c on c.id = s.connection_id and c.user_id = s.user_id
    where s.id = v_session_id and s.user_id = p_user_id and c.adapter = p_event->>'adapter';
  if not found then return jsonb_build_object('status','not_found','applied',false); end if;
  if v_task_id is null then
    if p_event ? 'external_task_id' then
      select id into v_task_id from public.agent_tasks where user_id = p_user_id and agent_session_id = v_session_id
        and external_task_id = p_event->>'external_task_id';
    elsif v_type in ('session_bound','unreachable','reconcile') then
      -- Retry the original observation even if a newer turn has since started.
      select t.id into v_task_id from public.execution_runs r
        join public.execution_events e on e.run_id = r.id and e.user_id = r.user_id
        join public.agent_tasks t on t.run_id = e.run_id and t.id::text = e.payload->>'agent_task_id' and t.user_id = e.user_id
        where r.user_id = p_user_id and r.agent_session_id = v_session_id
          and t.agent_session_id = v_session_id and e.type = 'agent'
          and e.external_event_id = p_event->>'event_id' and e.payload->>'event_type' = v_type
          and (v_type = 'session_bound' or v_turn is null or e.turn_seq = v_turn) order by e.at, e.id limit 1;
      if v_task_id is null then
        select id into v_task_id from public.agent_tasks where user_id = p_user_id and agent_session_id = v_session_id
          order by turn_seq desc nulls last, id limit 1;
      end if;
    else raise exception 'apply_agent_event: task identity required' using errcode = '22023';
    end if;
  end if;
  select * into v_task from public.agent_tasks where id = v_task_id and user_id = p_user_id and agent_session_id = v_session_id;
  if not found then return jsonb_build_object('status','not_found','applied',false); end if;

  -- Lock order: message -> conversation -> session -> run -> task -> step.
  -- D1c-1 also takes session before run; append/settle never acquire an earlier lock here.
  select * into v_message from public.conversation_messages where id = v_task.message_id and user_id = p_user_id for update;
  select * into v_conversation from public.conversations where id = v_message.conversation_id and user_id = p_user_id for update;
  select * into v_session from public.agent_sessions where id = v_session_id and user_id = p_user_id for update;
  select * into v_run from public.execution_runs where id = v_task.run_id and user_id = p_user_id for no key update;
  select * into v_task from public.agent_tasks where id = v_task_id and user_id = p_user_id for update;
  select * into v_step from public.execution_steps where id = v_task.step_id and user_id = p_user_id for update;
  if v_session.id is null or v_task.id is null or v_run.id is null or v_step.id is null
    or v_task.agent_session_id is distinct from v_session.id or v_run.agent_session_id is distinct from v_session.id
    or v_task.run_id is distinct from v_run.id or v_step.run_id is distinct from v_run.id
    or v_run.kind <> 'conversation' or v_step.kind <> 'agent_message'
    or not coalesce((v_step.args->>'message_id' is not distinct from v_task.message_id::text
      or (v_step.args->>'agent_task_id' = v_task.id::text
        and v_step.purpose = 'answer:' || v_task.id || ':' || (v_step.args->>'provider_request_id'))), false)
    or v_step.provider is distinct from p_event->>'adapter'
    or not exists (select 1 from public.agent_connections where id = v_session.connection_id and user_id = p_user_id and adapter = p_event->>'adapter')
    or (v_message.id is not null and (v_message.id is distinct from v_task.message_id or v_message.role <> 'user'
      or v_conversation.target_kind is distinct from 'agent' or v_conversation.agent_session_id is distinct from v_session.id
      or v_conversation.agent_connection_id is distinct from v_session.connection_id)) then
    return jsonb_build_object('status','not_found','applied',false);
  end if;
  v_answer := v_step.args->>'agent_task_id' = v_task.id::text and v_step.purpose = 'answer:' || v_task.id || ':' || (v_step.args->>'provider_request_id');
  if exists (select 1 from public.execution_events where run_id = v_run.id and external_event_id = p_event->>'event_id' and type = 'agent') then
    return jsonb_build_object('status','duplicate','applied',false,'task_state',v_task.state);
  end if;
  if p_event ? 'external_task_id' and v_task.external_task_id is not null
    and v_task.external_task_id <> p_event->>'external_task_id' then
    return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
  end if;
  if v_type <> 'session_bound' and ((v_turn is not null and v_turn is distinct from v_task.turn_seq)
    or ((v_type <> 'accepted' or v_answer) and v_seq is not null and v_seq <= v_task.last_event_seq)) then
    v_status := 'late';
  end if;
  v_state := case when v_task.state = 'unreachable' and v_type not in ('unreachable','reconcile')
    then v_task.last_live_state else v_task.state end;
  if v_type = 'message' and v_message.delivery_state = 'not_sent' then v_status := 'late'; end if;
  if v_type = 'question' and v_task.cancel_requested_at is not null then
    return jsonb_build_object('status','late','applied',false,'task_state',v_task.state);
  end if;

  -- The first activity proves acceptance even when its own update is seq-late.
  -- A foreign turn never proves acceptance; an unleased turn remains retryable.
  if v_type in ('accepted','progress','message','question','artifact','turn_completed') and (v_state = 'dispatched' or (v_answer and v_step.state <> 'called' and v_state = 'running'
      and (v_seq is null or v_seq > v_task.last_event_seq)))
    and (v_turn is null or v_turn = v_task.turn_seq) then
    if v_step.state <> 'calling' or v_step.lease_owner is null then
      return jsonb_build_object('status','step_not_calling','applied',false,'task_state',v_task.state);
    end if;
    v_accept := true;
    if v_state = 'dispatched' then v_state := 'accepted'; end if;
  end if;
  -- Decide every rejection before binding an id or settling a step.
  if v_status <> 'late' then
    if v_type = 'session_bound' then
      if v_session.external_session_id = v_payload->>'external_session_id' then
        v_status := 'ignored';
      elsif v_session.external_session_id not like 'pending:%' then
        return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
      end if;
    elsif v_type in ('accepted','turn_completed') then
      if v_type = 'turn_completed' and v_task.pending_question is not null then
        return jsonb_build_object('status','question_conflict','applied',false,'task_state',v_task.state);
      end if;
      if v_state in ('failed','cancelled','completed') then
        return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
      end if;
      if not v_accept and v_step.state <> 'called' then
        return jsonb_build_object('status','step_not_calling','applied',false,'task_state',v_task.state);
      end if;
      if v_type = 'turn_completed' then
        if v_state = 'idle' then v_status := 'ignored'; end if;
        v_state := 'idle';
      elsif not v_accept then v_status := 'ignored'; end if;
    elsif v_type = 'progress' then
      if v_state = 'running' then v_status := 'ignored';
      elsif v_state = 'accepted' then v_state := 'running';
      else return jsonb_build_object('status','invalid_state','applied',false,'task_state',v_task.state); end if;
    elsif v_type = 'question' then
      if v_task.pending_question is not null then
        return jsonb_build_object('status','question_conflict','applied',false,'task_state',v_task.state);
      end if;
      if v_state not in ('accepted','running') then
        return jsonb_build_object('status','invalid_state','applied',false,'task_state',v_task.state);
      end if;
      if v_message.id is null then return jsonb_build_object('status','not_found','applied',false); end if;
      v_question := jsonb_set(v_question, '{question_key}', jsonb_build_array(v_task.id, v_question->>'provider_request_id'));
      if not public.agent_pending_question_valid(v_question) then
        raise exception 'apply_agent_event: invalid question' using errcode = '22023';
      end if;
      v_state := 'awaiting_answer';
    elsif v_type = 'message' then
      if v_message.id is null then return jsonb_build_object('status','not_found','applied',false); end if;
    elsif v_type in ('failed','cancelled') then
      if v_type = 'failed' then
        if v_answer and v_task.answered_question is not null and v_step.state <> 'called' then
          if v_step.state <> 'calling' or v_step.lease_owner is null then
            return jsonb_build_object('status','step_not_calling','applied',false,'task_state',v_task.state);
          end if;
          v_restore := v_run.state in ('queued','running') and v_task.cancel_requested_at is null;
        elsif v_state = 'dispatched' or (v_state = 'failed' and v_message.delivery_state = 'not_sent') then
          if v_payload->>'reason' is null or v_payload->>'reason' not in ('sign_in_needed','usage_limited','spawn_failed','version_unsupported') then
            raise exception 'apply_agent_event: invalid pre-accept failure reason' using errcode = '22023';
          end if;
        elsif v_payload ? 'reason' and v_payload->>'reason' <> 'agent_error' then
          v_status := 'conflict';
        end if;
      end if;
      if v_status <> 'conflict' then
        if v_state = v_type then v_status := 'ignored';
        elsif v_state not in ('dispatched','accepted','running','awaiting_answer') then
          return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
        end if;
        if v_state = 'dispatched' then
          if v_step.state <> 'calling' or v_step.lease_owner is null then
            return jsonb_build_object('status','step_not_calling','applied',false,'task_state',v_task.state);
          end if;
          if v_message.id is null then return jsonb_build_object('status','not_found','applied',false); end if;
        end if;
        v_state := case when v_restore then 'awaiting_answer' else v_type end;
      end if;
    elsif v_type = 'unreachable' then
      if v_state in ('dispatched','accepted','running','awaiting_answer') then v_state := 'unreachable';
      else v_status := 'ignored'; end if;
    elsif v_type = 'reconcile' then
      if v_state <> 'unreachable' then
        if v_state in ('dispatched','accepted','running','awaiting_answer')
          and (not (v_payload ? 'state') or v_payload->>'state' = v_state) then v_status := 'ignored';
        else return jsonb_build_object('status','invalid_state','applied',false,'task_state',v_task.state); end if;
      else
        if v_payload ? 'state' and v_payload->>'state' is distinct from v_task.last_live_state then
          return jsonb_build_object('status','reconcile_conflict','applied',false,'task_state',v_task.state);
        end if;
        v_state := v_task.last_live_state;
        if v_state = 'awaiting_answer' and v_task.pending_question is null then
          return jsonb_build_object('status','question_conflict','applied',false,'task_state',v_task.state);
        end if;
      end if;
    end if;
  end if;

  -- Audit payload contains metadata only, never text, questions, or artifact summaries.
  v_audit := jsonb_build_object('event_type',v_type,'status',v_status,'agent_task_id',v_task.id)
    || (v_payload - array['summary']);
  if v_type = 'question' then
    v_audit := v_audit || jsonb_build_object('question_key', jsonb_build_array(v_task.id, v_question->>'provider_request_id'),
      'kind', v_question->>'kind', 'question_count', jsonb_array_length(v_question->'questions'));
  end if;
  if octet_length(v_audit::text) > 4096 then
    raise exception 'apply_agent_event: final payload exceeds 4096 bytes' using errcode = '22023';
  end if;

  if v_status in ('applied','ignored') or v_accept then
    if v_type = 'session_bound' and v_status = 'applied' then
      begin
        update public.agent_sessions set external_session_id = v_payload->>'external_session_id',
          workspace_ref = coalesce(v_payload->>'workspace_ref', workspace_ref) where id = v_session.id;
      exception when unique_violation then
        return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
      end;
    end if;
    v_bind := v_type <> 'session_bound' and v_task.external_task_id is null and p_event ? 'external_task_id';
    if v_bind then
      begin
        update public.agent_tasks set external_task_id = p_event->>'external_task_id' where id = v_task.id
          returning external_task_id into v_task.external_task_id;
      exception when unique_violation then
        return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
      end;
      if v_step.state = 'called' then
        update public.execution_steps set receipt = coalesce(receipt,'{}') || jsonb_build_object(
          'ack_level','agent','external_task_id',v_task.external_task_id) where id = v_step.id;
      end if;
    end if;
    if v_accept then
      if not public.settle_step(v_step.id, v_step.lease_owner, 'called', jsonb_strip_nulls(jsonb_build_object(
        'ack_level','agent','external_task_id',v_task.external_task_id))) then
        raise exception 'apply_agent_event: acceptance rejected' using errcode = '22023';
      end if;
    end if;
    if v_type in ('failed','cancelled') and v_status = 'applied'
      and (v_restore or (v_answer and v_step.state = 'calling') or v_task.state = 'dispatched'
        or (v_task.state = 'unreachable' and v_task.last_live_state = 'dispatched')) then
      if not public.settle_step(v_step.id, v_step.lease_owner, 'failed', case when v_type = 'cancelled'
        then jsonb_build_object('cancelled',true) else jsonb_build_object('reason',v_payload->>'reason') end) then
        raise exception 'apply_agent_event: failure rejected' using errcode = '22023';
      end if;
      if not coalesce(v_answer,false) then
        update public.conversation_messages set delivery_state = case when v_type = 'cancelled' then 'cancelled' else 'not_sent' end,
          delivery_reason = case when v_type = 'failed' then v_payload->>'reason' end where id = v_message.id;
      end if;
    end if;
    if v_type = 'artifact' and v_status = 'applied' then
      update public.agent_artifacts set superseded_at = public.db_now()
        where run_id = v_run.id and path = v_payload->>'path' and superseded_at is null and turn_seq <= v_task.turn_seq;
      insert into public.agent_artifacts (user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary,superseded_at)
        values (p_user_id,v_run.id,v_task.id,v_task.turn_seq,
          v_payload->>'path',v_payload->>'hash',v_payload->>'summary',
          case when exists (select 1 from public.agent_artifacts where run_id = v_run.id
            and path = v_payload->>'path' and superseded_at is null) then public.db_now() end);
    end if;
  end if;
  -- A delayed reply still belongs to its original turn, unless dispatch failed before acceptance.
  if (v_type = 'message' and v_message.id is not null and v_message.delivery_state <> 'not_sent'
      and (v_turn is null or v_turn = v_task.turn_seq)) or (v_type = 'question' and v_status = 'applied') then
    select * into v_append from public.conversation_append_agent_message(p_user_id, v_conversation.id,
      v_task.id, v_task.turn_seq, 'agent-message:' || v_run.id || ':' || encode(sha256(convert_to(p_event->>'event_id','UTF8')),'hex'),
      p_event->>'text', case when v_type = 'question' then 'question' else 'reply' end);
    if v_append.status not in ('created','duplicate') then
      raise exception 'apply_agent_event: append rejected' using errcode = '22023';
    end if;
  end if;
  insert into public.execution_events (user_id,run_id,step_id,type,external_event_id,external_seq,turn_seq,payload)
    values (p_user_id,v_run.id,v_step.id,'agent',p_event->>'event_id',v_seq,
      case when v_type = 'session_bound' then v_task.turn_seq else coalesce(v_turn,v_task.turn_seq) end,v_audit);
  if v_status in ('applied','ignored') or v_accept then
    update public.agent_tasks set
      last_live_state = case when v_type = 'unreachable' and v_status = 'applied' then v_task.state
        when v_task.state = 'unreachable' and v_state in ('dispatched','accepted','running','awaiting_answer')
        then v_state else last_live_state end,
      state = case when v_task.state = 'unreachable' and v_type <> 'reconcile' and v_state in ('dispatched','accepted','running','awaiting_answer')
        then 'unreachable' else v_state end,
      last_event_seq = case when v_type = 'session_bound' then last_event_seq else greatest(v_seq,last_event_seq) end,
      last_seen_at = greatest(v_observed,last_seen_at),
      answered_question = case when v_restore or v_state in ('failed','cancelled','idle')
        or (v_type = 'question' and v_status = 'applied') then null else answered_question end,
      pending_question = case when v_restore then answered_question when v_state in ('failed','cancelled') then null
        when v_type = 'question' and v_status = 'applied' then v_question else pending_question end
      where id = v_task.id returning state into v_state;
  else
    v_state := v_task.state;
  end if;
  return jsonb_build_object('status',v_status,'applied',v_status = 'applied','task_state',v_state);
end;
$$;

-- New entry points and replaced functions retain service-only execution.
do $$
declare f text;
begin
  foreach f in array array['append_step','prepare_step','answer_agent_question','route_agent_message',
    'request_agent_task_cancel','stop_agent_session','stop_agent_runs_on_user_claim',
    'stop_agent_runs_before_session_delete','apply_agent_event','execution_steps_replan','purge_expired_execution_text',
    'skip_terminal_agent_task_steps'] loop
    execute format('revoke all on function public.%I from public, anon, authenticated',f);
    execute format('grant execute on function public.%I to service_role',f);
  end loop;
end;
$$;
commit;
