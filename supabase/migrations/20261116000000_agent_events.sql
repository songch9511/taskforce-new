-- OA D1c-2a: bridge facts only; no Action writes, provider calls, or review steps.
begin;
set local lock_timeout = '5s';
lock table public.execution_runs in access exclusive mode nowait;
lock table public.agent_tasks in access exclusive mode nowait;

alter table public.agent_tasks add unique (id, run_id, user_id);
create unique index agent_tasks_external_task_idx on public.agent_tasks (agent_session_id, external_task_id)
  where external_task_id is not null;

-- Agent receipts have their own read model; the v1 draft table stays unchanged.
create table public.agent_artifacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  run_id uuid not null,
  agent_task_id uuid not null,
  turn_seq integer not null check (turn_seq >= 1),
  path text not null check (char_length(path) between 1 and 1000),
  content_hash text not null check (char_length(content_hash) between 1 and 200),
  summary text not null check (char_length(summary) <= 2000),
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (run_id, user_id) references public.execution_runs (id, user_id) on delete cascade,
  foreign key (agent_task_id, run_id, user_id) references public.agent_tasks (id, run_id, user_id) on delete cascade
);
alter table public.agent_artifacts enable row level security;
create policy owner_all on public.agent_artifacts for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
revoke all on public.agent_artifacts from public, anon, authenticated;
grant select on public.agent_artifacts to authenticated;
grant all on public.agent_artifacts to service_role;
create unique index agent_artifacts_current_path_idx on public.agent_artifacts (run_id, path)
  where superseded_at is null;

create index agent_artifacts_user_idx on public.agent_artifacts (user_id);
create index agent_artifacts_task_idx on public.agent_artifacts (agent_task_id);
create index agent_artifacts_run_idx on public.agent_artifacts (run_id);

-- CHECK and the event boundary share the full pending-question shape.
create function public.agent_pending_question_valid(p_question jsonb) returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  v_question jsonb;
  v_option jsonb;
begin
  if octet_length(p_question::text) > 32768
    or jsonb_typeof(p_question) is distinct from 'object'
    or p_question - array['question_key','provider_request_id','kind','structured','questions','asked_at'] <> '{}'
    or jsonb_typeof(p_question->'question_key') is distinct from 'array'
    or jsonb_typeof(p_question->'provider_request_id') is distinct from 'string'
    or char_length(p_question->>'provider_request_id') not between 1 and 200
    or jsonb_typeof(p_question->'kind') is distinct from 'string'
    or p_question->>'kind' not in ('input','approval')
    or jsonb_typeof(p_question->'structured') is distinct from 'boolean'
    or jsonb_typeof(p_question->'questions') is distinct from 'array'
    or jsonb_typeof(p_question->'asked_at') is distinct from 'string' then return false; end if;
  if jsonb_array_length(p_question->'question_key') <> 2
    or jsonb_typeof(p_question->'question_key'->0) is distinct from 'string'
    or jsonb_typeof(p_question->'question_key'->1) is distinct from 'string'
    or p_question->'question_key'->>1 is distinct from p_question->>'provider_request_id'
    or jsonb_array_length(p_question->'questions') not between 1 and 4 then return false; end if;
  if (select count(distinct value->>'id') from jsonb_array_elements(p_question->'questions'))
    <> jsonb_array_length(p_question->'questions') then return false; end if;
  for v_question in select value from jsonb_array_elements(p_question->'questions') loop
    if jsonb_typeof(v_question) is distinct from 'object'
      or v_question - array['id','header','text','options','multi_select','allow_other','secret'] <> '{}'
      or jsonb_typeof(v_question->'id') is distinct from 'string'
      or jsonb_typeof(v_question->'header') is distinct from 'string'
      or jsonb_typeof(v_question->'text') is distinct from 'string'
      or char_length(v_question->>'id') > 200 or char_length(v_question->>'header') > 200
      or char_length(v_question->>'text') > 4000
      or jsonb_typeof(v_question->'options') is distinct from 'array'
      or jsonb_typeof(v_question->'multi_select') is distinct from 'boolean'
      or jsonb_typeof(v_question->'allow_other') is distinct from 'boolean'
      or jsonb_typeof(v_question->'secret') is distinct from 'boolean' then return false; end if;
    if jsonb_array_length(v_question->'options') > 10 then return false; end if;
    for v_option in select value from jsonb_array_elements(v_question->'options') loop
      if jsonb_typeof(v_option) is distinct from 'object'
        or v_option - array['label','description'] <> '{}'
        or jsonb_typeof(v_option->'label') is distinct from 'string'
        or jsonb_typeof(v_option->'description') is distinct from 'string'
        or char_length(v_option->>'label') > 500 or char_length(v_option->>'description') > 1000 then return false; end if;
    end loop;
  end loop;
  return true;
end;
$$;
revoke all on function public.agent_pending_question_valid(jsonb) from public, anon, authenticated;
grant execute on function public.agent_pending_question_valid(jsonb) to service_role;
alter table public.agent_tasks drop constraint agent_tasks_pending_question_check,
  add constraint agent_tasks_pending_question_check check (
    pending_question is null or (public.agent_pending_question_valid(pending_question)
      and pending_question->'question_key'->>0 is not distinct from id::text));

create function public.apply_agent_event(p_user_id uuid, p_event jsonb) returns jsonb
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
    or v_step.args->>'message_id' is distinct from v_task.message_id::text
    or v_step.provider is distinct from p_event->>'adapter'
    or not exists (select 1 from public.agent_connections where id = v_session.connection_id and user_id = p_user_id and adapter = p_event->>'adapter')
    or (v_message.id is not null and (v_message.id is distinct from v_task.message_id or v_message.role <> 'user'
      or v_conversation.target_kind is distinct from 'agent' or v_conversation.agent_session_id is distinct from v_session.id
      or v_conversation.agent_connection_id is distinct from v_session.connection_id)) then
    return jsonb_build_object('status','not_found','applied',false);
  end if;
  if exists (select 1 from public.execution_events where run_id = v_run.id and external_event_id = p_event->>'event_id' and type = 'agent') then
    return jsonb_build_object('status','duplicate','applied',false,'task_state',v_task.state);
  end if;
  if p_event ? 'external_task_id' and v_task.external_task_id is not null
    and v_task.external_task_id <> p_event->>'external_task_id' then
    return jsonb_build_object('status','conflict','applied',false,'task_state',v_task.state);
  end if;
  if v_type <> 'session_bound' and ((v_turn is not null and v_turn is distinct from v_task.turn_seq)
    or (v_type <> 'accepted' and v_seq is not null and v_seq <= v_task.last_event_seq)) then
    v_status := 'late';
  end if;
  v_state := case when v_task.state = 'unreachable' and v_type not in ('unreachable','reconcile')
    then v_task.last_live_state else v_task.state end;
  if v_type = 'message' and v_message.delivery_state = 'not_sent' then v_status := 'late'; end if;

  -- The first activity proves acceptance even when its own update is seq-late.
  -- A foreign turn never proves acceptance; an unleased turn remains retryable.
  if v_type in ('accepted','progress','message','question','artifact','turn_completed') and v_state = 'dispatched'
    and (v_turn is null or v_turn = v_task.turn_seq) then
    if v_step.state <> 'calling' or v_step.lease_owner is null then
      return jsonb_build_object('status','step_not_calling','applied',false,'task_state',v_task.state);
    end if;
    v_accept := true;
    v_state := 'accepted';
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
        if v_state = 'dispatched' or (v_state = 'failed' and v_message.delivery_state = 'not_sent') then
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
        v_state := v_type;
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
      and (v_task.state = 'dispatched' or (v_task.state = 'unreachable' and v_task.last_live_state = 'dispatched')) then
      if not public.settle_step(v_step.id, v_step.lease_owner, 'failed', case when v_type = 'cancelled'
        then jsonb_build_object('cancelled',true) else jsonb_build_object('reason',v_payload->>'reason') end) then
        raise exception 'apply_agent_event: failure rejected' using errcode = '22023';
      end if;
      update public.conversation_messages set delivery_state = case when v_type = 'cancelled' then 'cancelled' else 'not_sent' end,
        delivery_reason = case when v_type = 'failed' then v_payload->>'reason' end where id = v_message.id;
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
      pending_question = case when v_state in ('failed','cancelled') then null
        when v_type = 'question' and v_status = 'applied' then v_question else pending_question end
      where id = v_task.id returning state into v_state;
  else
    v_state := v_task.state;
  end if;
  return jsonb_build_object('status',v_status,'applied',v_status = 'applied','task_state',v_state);
end;
$$;

revoke all on function public.apply_agent_event(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.apply_agent_event(uuid,jsonb) to service_role;
commit;
