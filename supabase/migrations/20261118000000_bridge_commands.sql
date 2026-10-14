-- Bridge transport: steps remain the state authority; command rows contain no message copies.
begin;
set local lock_timeout = '5s';
lock table public.bridges, public.rate_limit_events in access exclusive mode nowait;
lock table public.agent_connections in share row exclusive mode nowait;
lock table public.execution_steps in share row exclusive mode nowait;


alter table public.bridges
  add column heartbeat_result jsonb check (jsonb_typeof(heartbeat_result)='object'),
  add column secret_hash text check (secret_hash ~ '^[0-9a-f]{64}$'),
  add column secret_rotated_at timestamptz,
  add column app_version text check (char_length(app_version) between 1 and 50);
revoke select on public.bridges from authenticated;
grant select (id,user_id,device_ref,status,capabilities,last_heartbeat_at,revoked_at,created_at,updated_at,secret_rotated_at,app_version)
  on public.bridges to authenticated;
create unique index agent_connections_bridge_adapter_idx on public.agent_connections(bridge_id,adapter)
  where bridge_id is not null and status <> 'revoked';
create table public.bridge_commands (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  bridge_id uuid not null,
  step_id uuid not null unique,
  agent_task_id uuid not null,
  cursor bigint generated always as identity unique,
  kind text not null check (kind in ('message','answer','cancel')),
  lease_owner text check (char_length(lease_owner) <= 200),
  leased_at timestamptz,
  outcome text check (outcome in ('sent','task_unknown','received','not_received','unknown','request_closed','declined','withdrawn')),
  outcome_at timestamptz,
  created_at timestamptz not null default now(),
  unique(id,user_id),
  foreign key(bridge_id,user_id) references public.bridges(id,user_id) on delete cascade,
  foreign key(step_id,user_id) references public.execution_steps(id,user_id) on delete cascade,
  check ((lease_owner is null) = (leased_at is null)),
  check ((outcome is null) = (outcome_at is null))
);
create index bridge_commands_bridge_cursor_idx on public.bridge_commands(bridge_id,cursor);
create index bridge_commands_user_idx on public.bridge_commands(user_id);
create index execution_events_bridge_fanout_pending_idx on public.execution_events(at)
  where type='agent' and (payload->>'fanout_pending')='true';
alter table public.bridge_commands enable row level security;
create policy owner_all on public.bridge_commands to authenticated
  using(user_id = (select auth.uid())) with check(user_id = (select auth.uid()));
revoke all on public.bridge_commands from anon,authenticated;
grant select on public.bridge_commands to authenticated;
grant all on public.bridge_commands to service_role;
grant usage,select on sequence public.bridge_commands_cursor_seq to service_role;

create function public.bridge_commands_from_step() returns trigger
language plpgsql set search_path = '' as $$
declare v_bridge uuid; v_task uuid; v_kind text;
begin
  select c.bridge_id into v_bridge from public.execution_runs r
    join public.agent_sessions s on s.id=r.agent_session_id and s.user_id=r.user_id
    join public.agent_connections c on c.id=s.connection_id and c.user_id=s.user_id and c.status='active'
    join public.bridges b on b.id=c.bridge_id and b.user_id=c.user_id and b.status='active'
    where r.id=new.run_id and r.user_id=new.user_id and r.kind='conversation';
  if v_bridge is null then return new; end if;
  v_kind := case when new.kind='agent_cancel' then 'cancel' when new.purpose like 'answer:%' then 'answer'
    when new.purpose like 'message:%' then 'message' end;
  if v_kind is null then return new; end if;
  if v_kind='message' then
    select id into v_task from public.agent_tasks where run_id=new.run_id and user_id=new.user_id
      and message_id::text=new.args->>'message_id' order by turn_seq desc limit 1;
  else
    select id into v_task from public.agent_tasks where run_id=new.run_id and user_id=new.user_id
      and id::text=new.args->>'agent_task_id';
  end if;
  if v_task is not null then
    insert into public.bridge_commands(user_id,bridge_id,step_id,agent_task_id,kind)
      values(new.user_id,v_bridge,new.id,v_task,v_kind) on conflict(step_id) do nothing;
  end if;
  return new;
end;
$$;
create trigger bridge_commands_from_step after update of state on public.execution_steps for each row
  when(new.state='prepared' and old.state is distinct from 'prepared' and new.kind in ('agent_message','agent_cancel'))
  execute function public.bridge_commands_from_step();

create function public.register_bridge(p_user_id uuid,p_device_ref text,p_secret_hash text,p_app_version text,
  p_report jsonb,p_connect text[],p_reactivate boolean) returns jsonb
language plpgsql set search_path = '' as $$
declare v_bridge public.bridges; v_connection public.agent_connections; v_adapter text; v_entry jsonb;
  v_status text := 'registered'; v_next text; v_connections jsonb := '[]'; v_activated boolean;
begin
  if p_user_id is null or p_device_ref is null or p_secret_hash is null
    or jsonb_typeof(p_report) is distinct from 'object' or p_report-array['reported_at','adapters'] <> '{}'
    or jsonb_typeof(p_report->'adapters') is distinct from 'object' then
    raise exception 'register_bridge: invalid report' using errcode='22023';
  end if;
  for v_adapter,v_entry in select key,value from jsonb_each(p_report->'adapters') loop
    if v_adapter !~ '^agent:[a-z0-9][a-z0-9_-]*$' or char_length(v_adapter)>64
      or jsonb_typeof(v_entry) is distinct from 'object'
      or v_entry-array['installed','version','signed_in','managed_settings'] <> '{}' then
      raise exception 'register_bridge: invalid adapter report' using errcode='22023';
    end if;
  end loop;
  -- Serialize registration counts before taking bridge/connection row locks.
  perform pg_advisory_xact_lock(hashtext('bridge-registration:'||p_user_id::text));
  if not exists(select 1 from public.bridges where user_id=p_user_id and device_ref=p_device_ref and status='active')
    and (coalesce(p_reactivate,false) or not exists(select 1 from public.bridges where user_id=p_user_id and device_ref=p_device_ref))
    and (select count(*) from public.bridges where user_id=p_user_id and status='active')>=10 then
    return jsonb_build_object('status','too_many_bridges');
  end if;
  insert into public.bridges(user_id,device_ref) values(p_user_id,p_device_ref)
    on conflict(user_id,device_ref) do nothing returning * into v_bridge;
  if v_bridge.id is null then
    select * into v_bridge from public.bridges where user_id=p_user_id and device_ref=p_device_ref for no key update;
    if v_bridge.status='revoked' and not coalesce(p_reactivate,false) then
      return jsonb_build_object('status','revoked','bridge_id',v_bridge.id,'connections','[]'::jsonb);
    end if;
    v_status := case when v_bridge.status='revoked' then 'reactivated' else 'rotated' end;
  end if;
  update public.bridges set status='active',revoked_at=null,secret_hash=p_secret_hash,secret_rotated_at=public.db_now(),
    app_version=p_app_version,capabilities=p_report,last_heartbeat_at=public.db_now(),heartbeat_result=null where id=v_bridge.id;
  for v_connection in select * from public.agent_connections where bridge_id=v_bridge.id and user_id=p_user_id
    and status<>'revoked' order by id for no key update loop
    v_entry := p_report->'adapters'->v_connection.adapter;
    v_next := case when v_entry->'installed'='true'::jsonb then 'active' else 'error' end;
    v_activated := v_next='active' and (v_connection.status<>'active'
      or (v_entry->>'signed_in'='yes' and v_bridge.capabilities->'adapters'->v_connection.adapter->>'signed_in' is distinct from 'yes'));
    update public.agent_connections set status=v_next where id=v_connection.id;
    v_connections := v_connections || jsonb_build_array(jsonb_build_object('connection_id',v_connection.id,
      'adapter',v_connection.adapter,'status',v_next,'activated',v_activated));
  end loop;
  foreach v_adapter in array coalesce(p_connect,'{}') loop
    if not (p_report->'adapters' ? v_adapter) then raise exception 'register_bridge: missing adapter report' using errcode='22023'; end if;
    if not exists(select 1 from public.agent_connections where bridge_id=v_bridge.id and adapter=v_adapter and status<>'revoked') then
      v_next := case when p_report->'adapters'->v_adapter->'installed'='true'::jsonb then 'active' else 'error' end;
      insert into public.agent_connections(user_id,bridge_id,adapter,device_ref,status)
        values(p_user_id,v_bridge.id,v_adapter,p_device_ref,v_next) returning * into v_connection;
      v_connections := v_connections || jsonb_build_array(jsonb_build_object('connection_id',v_connection.id,
        'adapter',v_adapter,'status',v_next,'activated',v_next='active'));
    end if;
  end loop;
  return jsonb_build_object('status',v_status,'bridge_id',v_bridge.id,'connections',v_connections);
end;
$$;

-- Shared by lease and settlement: resolve first, lock in message/session/run/task/step/command order, recheck.
create function public.lock_bridge_command(p_user_id uuid,p_bridge_id uuid,p_command_id uuid)
returns public.bridge_commands language plpgsql set search_path = '' as $$
declare c public.bridge_commands; s public.execution_steps; r public.execution_runs; t public.agent_tasks;
  a public.agent_sessions; v_message uuid; v_answer uuid;
begin
  select * into c from public.bridge_commands where id=p_command_id and user_id=p_user_id and bridge_id=p_bridge_id;
  if not found then return null; end if;
  select * into s from public.execution_steps where id=c.step_id and user_id=p_user_id;
  select * into r from public.execution_runs where id=s.run_id and user_id=p_user_id;
  select * into t from public.agent_tasks where id=c.agent_task_id and user_id=p_user_id;
  v_message:=t.message_id; v_answer:=(s.args->>'answer_message_id')::uuid;
  if c.kind in ('message','answer') then
    perform 1 from public.conversation_messages where user_id=p_user_id and id in(v_message,v_answer) order by id for update;
  end if;
  select * into a from public.agent_sessions where id=r.agent_session_id and user_id=p_user_id for update;
  select * into r from public.execution_runs where id=r.id and user_id=p_user_id for no key update;
  select * into t from public.agent_tasks where id=c.agent_task_id and user_id=p_user_id for update;
  select * into s from public.execution_steps where id=c.step_id and user_id=p_user_id for update;
  select * into c from public.bridge_commands where id=p_command_id and user_id=p_user_id and bridge_id=p_bridge_id for update;
  if c.id is null or a.id is null or r.id is null or t.id is null or s.id is null
    or c.step_id is distinct from s.id or c.agent_task_id is distinct from t.id
    or r.kind<>'conversation' or r.agent_session_id is distinct from a.id or s.run_id is distinct from r.id
    or t.run_id is distinct from r.id or t.agent_session_id is distinct from a.id or t.message_id is distinct from v_message
    or (s.args->>'answer_message_id')::uuid is distinct from v_answer
    or not exists(select 1 from public.agent_connections ac join public.bridges b on b.id=ac.bridge_id and b.user_id=ac.user_id
      where ac.id=a.connection_id and ac.user_id=p_user_id and ac.bridge_id=p_bridge_id and ac.adapter=s.provider and b.status='active')
    or not coalesce(case c.kind
      when 'message' then s.kind='agent_message' and s.args->>'message_id'=t.message_id::text
        and (s.purpose='message:'||t.message_id or s.purpose ~ ('^message:'||t.message_id||':[0-9]+$'))
      when 'answer' then s.kind='agent_message' and s.args->>'agent_task_id'=t.id::text
        and s.purpose='answer:'||t.id||':'||(s.args->>'provider_request_id')
      when 'cancel' then s.kind='agent_cancel' and s.args->>'agent_task_id'=t.id::text end,false) then return null;
  end if;
  return c;
end;
$$;

-- Caller owns the shared command locks. Only never-leased prepared steps may be withdrawn.
create function public.withdraw_bridge_command(p_command_id uuid,p_reason text) returns jsonb
language plpgsql set search_path = '' as $$
declare c public.bridge_commands; s public.execution_steps; t public.agent_tasks; r public.execution_runs;
begin
  select * into c from public.bridge_commands where id=p_command_id;
  select * into s from public.execution_steps where id=c.step_id;
  select * into t from public.agent_tasks where id=c.agent_task_id;
  select * into r from public.execution_runs where id=s.run_id;
  if s.state<>'prepared' or c.lease_owner is not null then return jsonb_build_object('status','stale','reason','not_prepared'); end if;
  perform set_config('execution.gate','bridge_withdraw',true);
  update public.execution_steps set state=case when p_reason='stale_answer' then 'skipped' else 'failed' end,
    receipt=jsonb_build_object('never_sent',true,'reason',p_reason),version=version+1 where id=s.id;
  if c.kind='message' then
    update public.conversation_messages set delivery_state=case when p_reason='expired' then 'expired' else 'not_sent' end,
      delivery_reason=p_reason where id=t.message_id and user_id=t.user_id;
    update public.agent_tasks set state='failed',pending_question=null where id=t.id;
  elsif c.kind='answer' and p_reason<>'stale_answer' and t.state='running' and t.answered_question is not null
    and r.state in ('queued','running') and t.cancel_requested_at is null then
    update public.agent_tasks set pending_question=answered_question,answered_question=null,state='awaiting_answer' where id=t.id;
  end if;
  update public.bridge_commands set outcome='withdrawn',outcome_at=public.db_now() where id=c.id;
  return jsonb_build_object('status','withdrawn','reason',p_reason);
end;
$$;

create function public.lease_bridge_command(p_user_id uuid,p_bridge_id uuid,p_command_id uuid,p_access text,p_mode text)
returns jsonb language plpgsql set search_path = '' as $$
declare c public.bridge_commands; s public.execution_steps; r public.execution_runs; t public.agent_tasks;
  a public.agent_sessions; m public.conversation_messages; am public.conversation_messages;
  v_mode text; v_owner text; v_marker uuid; v_held uuid; v_command jsonb; v_replay boolean; v_reason text;
  v_count integer; v_blocked boolean; v_task record; v_close text;
begin
  c:=public.lock_bridge_command(p_user_id,p_bridge_id,p_command_id);
  if c.id is null then return jsonb_build_object('status','not_found'); end if;
  select * into s from public.execution_steps where id=c.step_id;
  select * into r from public.execution_runs where id=s.run_id;
  select * into t from public.agent_tasks where id=c.agent_task_id;
  select * into a from public.agent_sessions where id=r.agent_session_id;
  select * into m from public.conversation_messages where id=t.message_id and user_id=p_user_id;
  select * into am from public.conversation_messages where id=(s.args->>'answer_message_id')::uuid and user_id=p_user_id;
  v_replay:=s.state='calling' and c.lease_owner is not null and s.lease_owner=c.lease_owner;
  if not v_replay then
    if s.state<>'prepared' or c.lease_owner is not null then return jsonb_build_object('status','stale','reason','not_prepared'); end if;
    if c.kind<>'cancel' then
      if r.state not in ('queued','running') then return jsonb_build_object('status','stale','reason','run_closed'); end if;
      -- Done owns Action -> run. Reading Action here must never acquire an Action row lock.
      if not exists(select 1 from public.actions where id=r.action_id and user_id=p_user_id and status not in ('done','dropped')) then
        for v_task in select id from public.agent_tasks where run_id=r.id and user_id=p_user_id
          and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id loop
          perform public.request_agent_task_cancel(p_user_id,v_task.id);
        end loop;
        perform set_config('execution.gate','action_closed',true);
        update public.execution_runs set state='stopped',stopped_at=null where id=r.id;
        update public.bridge_commands set outcome='withdrawn',outcome_at=public.db_now() where id=c.id;
        return jsonb_build_object('status','withdrawn','reason','action_closed');
      end if;
      if a.status='unreachable' then return jsonb_build_object('status','stale','reason','heartbeat_first'); end if;
      v_reason:=case when a.status='external' then 'session_external' when a.status='closed' then 'session_closed' end;
      if v_reason is null and not exists(select 1 from public.agent_connections where id=a.connection_id and user_id=p_user_id and status='active') then
        v_reason:='not_connected';
      end if;
      if v_reason is not null then return public.withdraw_bridge_command(c.id,v_reason); end if;
      select mode into v_mode from public.execution_policies where id=r.policy_id and user_id=p_user_id for share;
      if p_mode is distinct from v_mode then return jsonb_build_object('status','stale','reason','policy_changed'); end if;
      perform 1 from public.execution_actors where user_id=p_user_id for share;
      if not found or p_access is null or p_access not in ('read_only','write') then
        return public.withdraw_bridge_command(c.id,'write_gate_closed');
      end if;
      select count(*),coalesce(bool_or(blocked),true) into v_count,v_blocked from (
        select blocked from public.execution_controls where (scope,key) in (('global','*'),('provider',s.provider),('mode',v_mode))
          order by scope,key for share) controls;
      if v_count<>3 or v_blocked then return public.withdraw_bridge_command(c.id,'write_gate_closed'); end if;
      perform 1 from public.execution_tools where provider=s.provider and tool='message' and effect_class='external' for share;
      if not found then return public.withdraw_bridge_command(c.id,'write_gate_closed'); end if;
      if c.kind='message' then
        if m.id is null or m.delivery_state is distinct from 'dispatched' or m.delivery_expires_at is null
          or m.delivery_expires_at<=public.db_now() then return public.withdraw_bridge_command(c.id,'expired'); end if;
        if t.state<>'dispatched' or t.step_id is distinct from s.id then return jsonb_build_object('status','stale','reason','wrong_state'); end if;
      elsif (s.args ? 'answer_message_id' and (am.id is null or am.delivery_expires_at is null
        or am.delivery_expires_at<=public.db_now() or nullif(am.text,'') is null))
        or (not(s.args ? 'answer_message_id') and s.args->'answered_locally' is distinct from 'true'::jsonb
          and (s.args->'answers' is null or s.args->'answers'='null'::jsonb)) then
        return public.withdraw_bridge_command(c.id,'expired');
      elsif t.state<>'running' or t.step_id is distinct from s.id
        or t.answered_question->'question_key'->>1 is distinct from s.args->>'provider_request_id' then
        return public.withdraw_bridge_command(c.id,'stale_answer');
      end if;
    else
      if a.status='external' then return jsonb_build_object('status','stale','reason','run_closed'); end if;
      if t.state not in ('dispatched','accepted','running','awaiting_answer','unreachable') or t.cancel_requested_at is null then
        return jsonb_build_object('status','stale','reason','wrong_state');
      end if;
    end if;
    perform set_config('execution.gate','bridge_lease',true);
    insert into public.execution_intents(intent_key,user_id,step_id) values(s.intent_key,p_user_id,s.id)
      on conflict(intent_key) do nothing;
    select step_id,marker into v_held,v_marker from public.execution_intents where intent_key=s.intent_key;
    if v_held is distinct from s.id then
      perform set_config('execution.gate','intent_held',true);
      update public.execution_steps set state='skipped',version=version+1 where id=s.id;
      return jsonb_build_object('status','stale','reason','not_prepared');
    end if;
    v_owner:='bridge:'||p_bridge_id||':'||c.id;
    update public.execution_steps set state='calling',version=version+1,lease_owner=v_owner,
      lease_expires_at=public.db_now()+interval '330 seconds',
      receipt=case when c.kind='cancel' then null else jsonb_build_object('bridge_access',p_access,'bridge_policy_mode',p_mode) end
      where id=s.id returning * into s;
    update public.bridge_commands set lease_owner=v_owner,leased_at=public.db_now(),outcome=null,outcome_at=null where id=c.id returning * into c;
  else
    if c.kind<>'cancel' then
      if p_access is null or p_access not in ('read_only','write')
        or not exists(select 1 from public.execution_actors where user_id=p_user_id)
        or not exists(select 1 from public.agent_connections where id=a.connection_id and user_id=p_user_id and status='active')
        or a.status<>'bound' or r.state not in ('queued','running')
        or not exists(select 1 from public.actions where id=r.action_id and user_id=p_user_id and status not in ('done','dropped'))
        or not exists(select 1 from public.execution_tools where provider=s.provider and tool='message' and effect_class='external') then
        return jsonb_build_object('status','stale','reason','write_gate_closed');
      end if;
      select mode into v_mode from public.execution_policies where id=r.policy_id and user_id=p_user_id;
      if p_mode is distinct from v_mode then return jsonb_build_object('status','stale','reason','policy_changed'); end if;
      select count(*),coalesce(bool_or(blocked),true) into v_count,v_blocked from public.execution_controls
        where (scope,key) in (('global','*'),('provider',s.provider),('mode',v_mode));
      if v_count<>3 or v_blocked then return jsonb_build_object('status','stale','reason','write_gate_closed'); end if;
    end if;
    select marker into v_marker from public.execution_intents where step_id=s.id and user_id=p_user_id;
    p_access:=s.receipt->>'bridge_access'; p_mode:=s.receipt->>'bridge_policy_mode';
  end if;
  v_command:=jsonb_build_object('id',c.id,'kind',c.kind,'agent_session_id',a.id,'agent_task_id',t.id,
    'turn_seq',t.turn_seq,'step_id',s.id,'adapter',s.provider,'marker',v_marker,'session',jsonb_build_object(
      'external_session_id',case when a.external_session_id like 'pending:%' then null else a.external_session_id end,
      'workspace_ref',case when a.workspace_ref like 'pending:%' then null else a.workspace_ref end,
      'resume',a.external_session_id not like 'pending:%'));
  if c.kind='message' then
    select e.payload->'question_key'->>1 into v_close from public.agent_tasks previous
      join public.execution_events e on e.run_id=previous.run_id and e.user_id=previous.user_id
        and e.payload->>'agent_task_id'=previous.id::text and e.payload->>'event_type'='question_denied'
      where previous.agent_session_id=a.id and previous.user_id=p_user_id and previous.turn_seq=t.turn_seq-1
        and s.provider='agent:claude-code' order by e.at desc limit 1;
    v_command:=v_command||jsonb_build_object('access',p_access,'policy_mode',p_mode,
      'message',jsonb_build_object('id',m.id,'text',case when m.delivery_expires_at>public.db_now() then m.text else '' end),
      'close_before',case when v_close is null then null else jsonb_build_object('provider_request_id',v_close) end);
  elsif c.kind='answer' then
    v_command:=v_command||jsonb_build_object('access',p_access,'policy_mode',p_mode,
      'provider_request_id',s.args->>'provider_request_id','question_kind',t.answered_question->>'kind',
      'structured',t.answered_question->'structured','answers',s.args->'answers',
      'answer_text',case when am.delivery_expires_at>public.db_now() then am.text end,
      'answered_locally',coalesce((s.args->>'answered_locally')::boolean,false));
  else
    v_command:=v_command||jsonb_build_object('abandoned_request_id',t.abandoned_question->>1,'cancel_scope','turn');
  end if;
  return jsonb_build_object('status',case when v_replay then 'replay' else 'leased' end,'command',v_command,'lease_expires_at',s.lease_expires_at);
end;
$$;

create function public.settle_bridge_command(p_user_id uuid,p_bridge_id uuid,p_command_id uuid,p_op text,p_result text,p_process_ended boolean)
returns jsonb language plpgsql set search_path = '' as $$
declare c public.bridge_commands; s public.execution_steps; t public.agent_tasks; r public.execution_runs;
  v_state text; v_receipt jsonb; v_result jsonb;
begin
  if p_op='readback' and p_result='not_received' and not coalesce(p_process_ended,false) then
    raise exception 'settle_bridge_command: process must have ended' using errcode='22023';
  end if;
  c:=public.lock_bridge_command(p_user_id,p_bridge_id,p_command_id);
  if c.id is null then return jsonb_build_object('status','not_found'); end if;
  select * into s from public.execution_steps where id=c.step_id;
  select * into t from public.agent_tasks where id=c.agent_task_id;
  select * into r from public.execution_runs where id=s.run_id;
  if p_op='decline' and p_result='unsupported_kind' and s.state='prepared' and c.lease_owner is null then
    v_result:=public.withdraw_bridge_command(c.id,'unsupported');
    update public.bridge_commands set outcome='declined',outcome_at=public.db_now() where id=c.id;
    return v_result;
  end if;
  -- Replaying the same committed acknowledgement repairs idempotent TS fanout without rewriting state.
  if c.lease_owner='bridge:'||p_bridge_id||':'||c.id and s.state in ('called','failed')
    and ((p_op='request_closed' and c.kind='answer' and c.outcome='request_closed')
      or (p_op='complete' and c.kind='cancel' and p_result in ('sent','task_unknown') and c.outcome=p_result)
      or (p_op='readback' and c.kind in ('message','answer') and p_result in ('received','not_received') and c.outcome=p_result)) then
    return jsonb_build_object('status','settled','task_state',t.state);
  end if;
  if c.lease_owner is distinct from 'bridge:'||p_bridge_id||':'||c.id or s.state not in ('calling','unknown_outcome')
    or (s.state='calling' and s.lease_owner is distinct from c.lease_owner) then
    if p_op='readback' and c.lease_owner='bridge:'||p_bridge_id||':'||c.id and s.state in ('calling','unknown_outcome') then
      update public.bridge_commands set outcome=coalesce(outcome,'unknown'),outcome_at=public.db_now() where id=c.id;
    end if;
    return jsonb_build_object('status','stale');
  end if;
  if p_op='complete' and c.kind='cancel' and p_result in ('sent','task_unknown') then
    v_state:='called'; v_receipt:=case when p_result='sent' then '{"sent":true}'::jsonb else '{"task_unknown":true}'::jsonb end;
  elsif p_op='readback' and c.kind in ('message','answer') and p_result in ('received','not_received','unknown') then
    v_state:=case p_result when 'received' then 'called' when 'not_received' then 'failed' end;
    v_receipt:=case when p_result='received' then '{"readback":"bridge_ledger"}'::jsonb else '{"reason":"not_received"}'::jsonb end;
  elsif p_op='request_closed' and c.kind='answer' then
    v_state:='failed'; v_receipt:='{"reason":"request_closed"}';
  else
    if p_op='readback' then update public.bridge_commands set outcome=coalesce(outcome,'unknown'),outcome_at=public.db_now() where id=c.id; end if;
    return jsonb_build_object('status','stale');
  end if;
  if v_state is not null then
    perform set_config('execution.gate','bridge_settle',true);
    update public.execution_steps set state=v_state,receipt=v_receipt,version=version+1,
      lease_owner=null,lease_expires_at=null where id=s.id;
  end if;
  if p_op='complete' and p_result='task_unknown' then
    update public.agent_tasks set state='cancelled',pending_question=null,answered_question=null where id=t.id;
  elsif p_op='readback' and p_result='received' and c.kind='message' then
    update public.agent_tasks set state=case when state='dispatched' then 'accepted' else state end,
      last_live_state=case when state='unreachable' and last_live_state='dispatched' then 'accepted' else last_live_state end where id=t.id;
  elsif p_op='readback' and p_result='not_received' then
    if c.kind='message' then
      if t.state in ('dispatched','unreachable') then
        update public.conversation_messages set delivery_state='not_sent',delivery_reason='not_received' where id=t.message_id and user_id=p_user_id;
        update public.agent_tasks set state='failed',pending_question=null where id=t.id;
      end if;
    elsif r.state in ('queued','running') and t.cancel_requested_at is null and t.answered_question is not null then
      update public.agent_tasks set pending_question=answered_question,answered_question=null,state='awaiting_answer' where id=t.id;
    end if;
  elsif p_op='request_closed' then
    update public.agent_tasks set abandoned_question=jsonb_build_array(t.id,s.args->>'provider_request_id'),answered_question=null,
      step_id=coalesce((select previous.id from public.execution_steps previous
        where previous.run_id=t.run_id and previous.user_id=p_user_id and previous.kind='agent_message' and previous.state='called'
          and (previous.args->>'agent_task_id'=t.id::text or previous.args->>'message_id'=t.message_id::text)
        order by previous.seq desc limit 1),t.step_id) where id=t.id;
  end if;
  update public.bridge_commands set outcome=case when p_op='request_closed' then 'request_closed' else p_result end,
    outcome_at=public.db_now() where id=c.id;
  select state into v_state from public.agent_tasks where id=t.id;
  return jsonb_build_object('status','settled','task_state',v_state);
end;
$$;

create function public.list_bridge_commands(p_user_id uuid,p_bridge_id uuid,p_after bigint,p_limit integer) returns jsonb
language sql set search_path = '' as $$
  with items as (
    select c.*,s.state,s.lease_owner as step_owner,r.agent_session_id,t.turn_seq,i.marker
      from public.bridge_commands c join public.execution_steps s on s.id=c.step_id and s.user_id=c.user_id
      join public.execution_runs r on r.id=s.run_id and r.user_id=s.user_id
      join public.agent_tasks t on t.id=c.agent_task_id and t.user_id=c.user_id and t.run_id=r.id
      join public.agent_sessions a on a.id=r.agent_session_id and a.user_id=r.user_id
      join public.agent_connections ac on ac.id=a.connection_id and ac.user_id=a.user_id and ac.bridge_id=c.bridge_id
      join public.bridges b on b.id=c.bridge_id and b.user_id=c.user_id and b.status='active'
      left join public.execution_intents i on i.step_id=s.id and i.user_id=s.user_id
      where c.user_id=p_user_id and c.bridge_id=p_bridge_id and r.kind='conversation' and s.state in ('prepared','calling','unknown_outcome')
  ), commands as (
    select * from items where (state='prepared' and lease_owner is null and cursor>p_after)
      or (state='calling' and lease_owner is not null and step_owner=lease_owner)
      order by (cursor>p_after) desc,cursor limit least(greatest(p_limit,0),50)
  ), readbacks as (
    select * from items where state='unknown_outcome' and lease_owner is not null and outcome_at is null order by outcome_at nulls first,cursor limit least(greatest(p_limit,0),50)
  ) select jsonb_build_object('commands',coalesce((select jsonb_agg(jsonb_build_object('id',id,'cursor',cursor,'kind',kind,
      'agent_session_id',agent_session_id,'agent_task_id',agent_task_id,'turn_seq',turn_seq,'created_at',created_at,
      'leased_by_me',state='calling') order by (cursor>p_after) desc,cursor) from commands),'[]'::jsonb),
    'readbacks',coalesce((select jsonb_agg(jsonb_build_object('command_id',id,'kind',kind,'agent_session_id',agent_session_id,
      'agent_task_id',agent_task_id,'turn_seq',turn_seq,'marker',marker,'leased_at',leased_at) order by outcome_at nulls first,cursor) from readbacks),'[]'::jsonb),
    'next_cursor',greatest(p_after,coalesce((select max(cursor) from commands),p_after)));
$$;

create function public.apply_bridge_event(p_user_id uuid,p_bridge_id uuid,p_event jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare a public.agent_sessions; t public.agent_tasks; r public.execution_runs; s public.execution_steps;
  c public.bridge_commands; m public.conversation_messages; v_task uuid; v_result jsonb; v_attached boolean:=false;
begin
  if not exists(select 1 from public.bridges where id=p_bridge_id and user_id=p_user_id and status='active') then
    return jsonb_build_object('status','not_found','applied',false);
  end if;
  begin
    select * into a from public.agent_sessions where id=(p_event->'session_ref'->>'agent_session_id')::uuid and user_id=p_user_id;
    v_task:=(p_event->>'agent_task_id')::uuid;
  exception when invalid_text_representation then raise exception 'apply_bridge_event: invalid identity' using errcode='22023'; end;
  if a.id is null then return jsonb_build_object('status','not_found','applied',false); end if;
  if not exists(select 1 from public.agent_connections where id=a.connection_id and user_id=p_user_id and bridge_id=p_bridge_id) then
    return jsonb_build_object('status','wrong_bridge','applied',false);
  end if;
  if v_task is null then
    if p_event ? 'external_task_id' then
      select id into v_task from public.agent_tasks where agent_session_id=a.id and user_id=p_user_id and external_task_id=p_event->>'external_task_id';
    elsif p_event->>'type' in ('session_bound','unreachable','reconcile') then
      select t0.id into v_task from public.execution_events e join public.execution_runs r0 on r0.id=e.run_id and r0.user_id=e.user_id
        join public.agent_tasks t0 on t0.id::text=e.payload->>'agent_task_id' and t0.run_id=r0.id and t0.user_id=r0.user_id
        where r0.agent_session_id=a.id and e.user_id=p_user_id and e.type='agent' and e.external_event_id=p_event->>'event_id'
        and e.payload->>'event_type'=p_event->>'type' order by e.at,e.id limit 1;
      if v_task is null then
        select id into v_task from public.agent_tasks where agent_session_id=a.id and user_id=p_user_id order by turn_seq desc nulls last,id limit 1;
      end if;
    end if;
  end if;
  select * into t from public.agent_tasks where id=v_task and user_id=p_user_id and agent_session_id=a.id;
  if t.id is null then return public.apply_agent_event(p_user_id,p_event); end if;
  select * into m from public.conversation_messages where id=t.message_id and user_id=p_user_id for update;
  perform 1 from public.conversations where id=m.conversation_id and user_id=p_user_id for update;
  select * into a from public.agent_sessions where id=a.id and user_id=p_user_id for update;
  select * into r from public.execution_runs where id=t.run_id and user_id=p_user_id for no key update;
  select * into t from public.agent_tasks where id=v_task and user_id=p_user_id for update;
  select * into s from public.execution_steps where id=t.step_id and user_id=p_user_id for update;
  select * into c from public.bridge_commands where step_id=s.id and user_id=p_user_id for update;
  if a.id is null or not exists(select 1 from public.agent_connections ac join public.bridges b on b.id=ac.bridge_id and b.user_id=ac.user_id
    where ac.id=a.connection_id and ac.user_id=p_user_id and ac.bridge_id=p_bridge_id and b.status='active') then
    return jsonb_build_object('status','wrong_bridge','applied',false);
  end if;
  begin
  if s.state='unknown_outcome' and c.bridge_id=p_bridge_id and c.agent_task_id=t.id
    and c.lease_owner='bridge:'||p_bridge_id||':'||c.id and t.agent_session_id=a.id and r.agent_session_id=a.id
    and t.run_id=r.id and s.run_id=r.id and r.kind='conversation'
    and (not(p_event ? 'turn_seq') or (p_event->>'turn_seq')::integer=t.turn_seq)
    and (not (p_event ? 'external_task_id') or t.external_task_id is null or t.external_task_id=p_event->>'external_task_id') then
    perform set_config('execution.gate','bridge_reattach',true);
    update public.execution_steps set state='calling',lease_owner=c.lease_owner,
      lease_expires_at=public.db_now()+interval '330 seconds',version=version+1 where id=s.id;
    update public.bridge_commands set outcome=null,outcome_at=null where id=c.id;
    v_attached:=true;
  end if;
  v_result:=public.apply_agent_event(p_user_id,p_event);
  -- Roll back both state and transition logs when an observation cannot justify reattachment.
  if v_attached and v_result->>'status' not in ('applied','ignored')
    and exists(select 1 from public.execution_steps where id=s.id and state='calling') then
    raise exception using errcode='PBR01',message='bridge observation did not apply';
  end if;
  exception when sqlstate 'PBR01' then
    return v_result;
  end;
  update public.execution_events set bridge_id=p_bridge_id where run_id=r.id and user_id=p_user_id
    and external_event_id=p_event->>'event_id' and type='agent';
  return v_result;
end;
$$;

create function public.next_bridge_agent_message(p_user_id uuid,p_agent_session_id uuid,p_retry_gate boolean default false) returns uuid
language sql set search_path = '' as $$
  select id from public.conversation_messages
    where user_id=p_user_id and id=public.next_queued_agent_message(p_user_id,p_agent_session_id)
      and (delivery_state='queued' or (p_retry_gate and delivery_state='not_sent'
        and delivery_reason in ('write_gate_closed','not_connected','adapter_disabled')));
$$;

create function public.bridge_heartbeat(p_user_id uuid,p_bridge_id uuid,p_tasks jsonb,
  p_report jsonb default null,p_app_version text default null) returns jsonb
language plpgsql set search_path = '' as $$
declare b public.bridges; a public.agent_sessions; r public.execution_runs; t public.agent_tasks;
  s public.execution_steps; c public.bridge_commands; ac public.agent_connections; v_entry jsonb; v_item jsonb;
  v_revived uuid[]:='{}'; v_kick uuid[]:='{}'; v_unknown uuid[]:='{}'; v_missing uuid[]:='{}'; v_known uuid[]:='{}';
  v_activated uuid[]:='{}'; v_pending integer; v_next text; v_result jsonb;
begin
  if jsonb_typeof(p_tasks) is distinct from 'array' or jsonb_array_length(p_tasks)>50 then
    raise exception 'bridge_heartbeat: invalid tasks' using errcode='22023'; end if;
  select * into b from public.bridges where id=p_bridge_id and user_id=p_user_id and status='active';
  if found and b.last_heartbeat_at>public.db_now()-interval '5 seconds' and b.heartbeat_result is not null then
    return b.heartbeat_result || jsonb_build_object('throttled',true);
  end if;
  select * into b from public.bridges where id=p_bridge_id and user_id=p_user_id and status='active' for no key update;
  if not found then return jsonb_build_object('status','not_found'); end if;
  if b.last_heartbeat_at>public.db_now()-interval '5 seconds' and b.heartbeat_result is not null then
    return b.heartbeat_result || jsonb_build_object('throttled',true);
  end if;
  if p_report is not null then
    if jsonb_typeof(p_report) is distinct from 'object' or p_report-array['reported_at','adapters']<>'{}'
      or jsonb_typeof(p_report->'adapters') is distinct from 'object' then raise exception 'bridge_heartbeat: invalid report' using errcode='22023'; end if;
    for v_item in select value from jsonb_each(p_report->'adapters') loop
      if jsonb_typeof(v_item) is distinct from 'object' or v_item-array['installed','version','signed_in','managed_settings']<>'{}' then
        raise exception 'bridge_heartbeat: invalid adapter report' using errcode='22023'; end if;
    end loop;
    for ac in select * from public.agent_connections where bridge_id=b.id and user_id=p_user_id and status<>'revoked' order by id for no key update loop
      v_entry:=p_report->'adapters'->ac.adapter;
      v_next:=case when v_entry->'installed'='true'::jsonb then 'active' else 'error' end;
      if v_next='active' and (ac.status<>'active' or (v_entry->>'signed_in'='yes'
        and b.capabilities->'adapters'->ac.adapter->>'signed_in' is distinct from 'yes')) then v_activated:=array_append(v_activated,ac.id); end if;
      update public.agent_connections set status=v_next where id=ac.id;
    end loop;
  end if;
  update public.bridges set last_heartbeat_at=public.db_now(),capabilities=coalesce(p_report,capabilities),
    app_version=coalesce(p_app_version,app_version) where id=b.id;
  for a in select a0.* from public.agent_sessions a0 join public.agent_connections ac0 on ac0.id=a0.connection_id and ac0.user_id=a0.user_id
    where ac0.bridge_id=b.id and a0.user_id=p_user_id and a0.status in ('bound','unreachable') order by a0.id for update of a0 loop
    if a.status='unreachable' then
      update public.agent_sessions set status='bound' where id=a.id;
      v_revived:=array_append(v_revived,a.id); a.status:='bound';
    end if;
    for r in select r0.* from public.execution_runs r0 where r0.agent_session_id=a.id and r0.user_id=p_user_id
      and exists(select 1 from public.agent_tasks t0 where t0.run_id=r0.id and t0.agent_session_id=a.id and t0.user_id=p_user_id
        and (t0.state in ('dispatched','accepted','running','awaiting_answer','unreachable')
          or t0.id::text in (select value->>'task_id' from jsonb_array_elements(p_tasks)))) order by r0.id for no key update loop
      for t in select * from public.agent_tasks where run_id=r.id and agent_session_id=a.id and user_id=p_user_id
        and (state in ('dispatched','accepted','running','awaiting_answer','unreachable')
          or id::text in (select value->>'task_id' from jsonb_array_elements(p_tasks))) order by id for update loop

        select value into v_item from jsonb_array_elements(p_tasks) where value->>'task_id'=t.id::text limit 1;
        select * into s from public.execution_steps where id=t.step_id and user_id=p_user_id for update;
        select * into c from public.bridge_commands where step_id=s.id and user_id=p_user_id and bridge_id=b.id;
        if v_item->'process_alive'='true'::jsonb and s.state='calling' and c.agent_task_id=t.id
          and c.lease_owner='bridge:'||b.id||':'||c.id and s.lease_owner=c.lease_owner then
          update public.execution_steps set lease_expires_at=greatest(lease_expires_at,public.db_now()+interval '330 seconds') where id=s.id;
        end if;
      end loop;
    end loop;
    if a.id=any(v_revived) then
      insert into public.execution_events(user_id,run_id,type,bridge_id,external_event_id,turn_seq,payload)
        select p_user_id,t0.run_id,'agent',b.id,'bridge-restored:'||a.id||':'||floor(extract(epoch from public.db_now()))::bigint,t0.turn_seq,
          jsonb_build_object('event_type','bridge_restored','agent_session_id',a.id,'agent_task_id',t0.id,
            'turn_seq',t0.turn_seq,'fanout_pending',true)
        from public.agent_tasks t0 where t0.agent_session_id=a.id and t0.user_id=p_user_id
        order by t0.turn_seq desc,t0.id limit 1;
    end if;
    if a.status='bound' and cardinality(v_kick)<5 and (a.id=any(v_revived) or (
      not exists(select 1 from public.agent_tasks where agent_session_id=a.id and user_id=p_user_id and state in ('dispatched','accepted','running','awaiting_answer','unreachable'))
      and public.next_bridge_agent_message(p_user_id,a.id) is not null)) then v_kick:=array_append(v_kick,a.id); end if;
  end loop;
  select coalesce(array_agg(t0.id),'{}'::uuid[]) into v_known from public.agent_tasks t0
    join public.agent_sessions a0 on a0.id=t0.agent_session_id and a0.user_id=t0.user_id
    join public.agent_connections ac0 on ac0.id=a0.connection_id and ac0.user_id=a0.user_id
    where ac0.bridge_id=b.id and t0.user_id=p_user_id;
  select coalesce(array_agg(id),'{}'::uuid[]) into v_missing from (
    select t0.id from public.agent_tasks t0 left join public.execution_steps s0 on s0.id=t0.step_id
      left join public.bridge_commands c0 on c0.step_id=s0.id
    where t0.id=any(v_known) and not exists(select 1 from jsonb_array_elements(p_tasks) item where item->>'task_id'=t0.id::text)
      and (t0.state in ('accepted','running','awaiting_answer','unreachable') or
        (t0.state='dispatched' and c0.lease_owner is not null and s0.state in ('calling','unknown_outcome')))
    order by t0.id limit 50) missing;
  for v_item in select value from jsonb_array_elements(p_tasks) loop
    if not ((v_item->>'task_id')::uuid=any(v_known)) then v_unknown:=array_append(v_unknown,(v_item->>'task_id')::uuid); end if;
  end loop;
  select count(*) into v_pending from public.bridge_commands c0 join public.execution_steps s0 on s0.id=c0.step_id
    where c0.bridge_id=b.id and c0.user_id=p_user_id and s0.state in ('prepared','calling','unknown_outcome');
  v_result:=jsonb_build_object('revived_session_ids',v_revived,'kick_session_ids',v_kick,'unknown_task_ids',v_unknown,
    'missing_task_ids',v_missing,'pending_commands',v_pending,'activated_connection_ids',v_activated);
  update public.bridges set heartbeat_result=v_result where id=b.id;
  return v_result;
end;
$$;

create function public.sweep_bridge_heartbeats(p_now timestamptz default null,p_limit integer default 50)
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
      where ac.bridge_id=b.id and a0.user_id=b.user_id and a0.status='bound' order by a0.id for update of a0 loop
      update public.agent_sessions set status='unreachable' where id=a.id;
      for r in select r0.* from public.execution_runs r0 where r0.agent_session_id=a.id and r0.user_id=b.user_id order by r0.id for no key update loop
        for t in select t0.* from public.agent_tasks t0 where t0.run_id=r.id and t0.agent_session_id=a.id and t0.user_id=b.user_id
          order by t0.id for update loop
          select * into s from public.execution_steps where id=t.step_id and execution_steps.user_id=b.user_id for update;
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

create function public.sweep_agent_step_leases(p_now timestamptz) returns integer
language plpgsql set search_path = '' as $$
declare v_n integer;
begin
  perform set_config('execution.gate','lease_expired',true);
  with expired as (select s.id from public.execution_steps s join public.execution_runs r on r.id=s.run_id and r.user_id=s.user_id
    where r.kind='conversation' and s.kind in ('agent_message','agent_cancel') and s.state='calling' and s.lease_expires_at<public.db_now()
    order by s.id for update of s skip locked)
  update public.execution_steps set state='unknown_outcome',unknown_since=public.db_now(),version=version+1,lease_owner=null
    where id in(select id from expired);
  get diagnostics v_n=row_count; return v_n;
end;
$$;

create function public.revoke_bridge(p_user_id uuid,p_bridge_id uuid) returns jsonb
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

create function public.next_unbound_agent_messages(p_user_id uuid,p_connection_id uuid,p_limit integer,p_retry_gate boolean default false) returns uuid[]
language sql set search_path = '' as $$
  with heads as (
    select distinct on(c.id) m.id,m.created_at,m.seq,m.delivery_state,m.delivery_reason from public.conversations c
      join public.conversation_messages m on m.conversation_id=c.id and m.user_id=c.user_id
      where c.user_id=p_user_id and c.agent_connection_id=p_connection_id and c.target_kind='agent' and c.agent_session_id is null
        and m.role='user' and m.delivery_state in ('queued','not_sent') and m.delivery_expires_at>public.db_now()
        and not(m.refs ? 'referent_candidates' and m.refs->>'referent_action_id' is null)
        and coalesce(m.delivery_reason,'') not in ('invalid_referent','session_closed','not_found','already_dispatched')
      order by c.id,m.seq
  ) select coalesce(array_agg(id order by created_at,seq,id),'{}'::uuid[]) from (
    select * from heads where delivery_state='queued' or (p_retry_gate and delivery_state='not_sent'
      and delivery_reason in ('write_gate_closed','not_connected','adapter_disabled'))
    order by created_at,seq,id limit greatest(p_limit,0)) chosen;
$$;

create function public.bridge_redelivery_candidates(p_limit integer)
returns table(user_id uuid,agent_session_id uuid,conversation_id uuid)
language sql set search_path = '' as $$
  with heads as (
    select distinct on(c.id) c.user_id,c.agent_session_id,c.id as conversation_id,m.delivery_state,m.delivery_reason,m.created_at,m.seq
      from public.conversations c join public.conversation_messages m on m.conversation_id=c.id and m.user_id=c.user_id
      left join public.agent_sessions s on s.id=c.agent_session_id and s.user_id=c.user_id
      where c.target_kind='agent' and (c.agent_session_id is null or s.status='bound')
        and m.role='user' and m.delivery_state in ('queued','not_sent') and m.delivery_expires_at>public.db_now()
        and not(m.refs ? 'referent_candidates' and m.refs->>'referent_action_id' is null)
        and coalesce(m.delivery_reason,'') not in ('invalid_referent','session_closed','not_found','already_dispatched')
      order by c.id,m.seq
  ), candidates as (
    select *,row_number() over(order by created_at,seq,conversation_id)-1 as position,count(*) over() as total
      from heads where delivery_state='not_sent' and delivery_reason in ('write_gate_closed','not_connected','adapter_disabled')
  ) select user_id,agent_session_id,conversation_id from candidates
    -- Rotate the bounded probe each server minute so blocked heads cannot starve other conversations.
    order by ((position-floor(extract(epoch from public.db_now())/60)::bigint*greatest(p_limit,1)::bigint)%total+total)%total
    limit greatest(p_limit,0);
$$;

create function public.purge_bridge_commands(p_before timestamptz,p_limit integer) returns integer
language plpgsql set search_path = '' as $$
declare v_n integer;
begin
  with expired as (select c.id from public.bridge_commands c join public.execution_steps s on s.id=c.step_id and s.user_id=c.user_id
    where c.created_at<p_before and s.state in ('called','failed','skipped') order by c.cursor limit greatest(p_limit,0)
    for update of c skip locked)
  delete from public.bridge_commands where id in(select id from expired);
  get diagnostics v_n=row_count; return v_n;
end;
$$;

alter table public.rate_limit_events add column bridge_id uuid,
  add foreign key(bridge_id,user_id) references public.bridges(id,user_id) on delete cascade;
create index rate_limit_events_bridge_idx on public.rate_limit_events(user_id,bridge_id,kind,created_at) where bridge_id is not null;
alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check(kind in ('ask','connection_start','action_create','run_create','bridge_register','bridge_events','bridge_ack','bridge_poll'));

drop function public.take_rate_limit(uuid,text,integer,integer);
create function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int,p_bridge_id uuid default null)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
  v_window interval := make_interval(secs => p_window_seconds);
  v_since timestamptz;
  v_nth timestamptz;
begin
  if p_user_id is null or p_max < 1 or p_window_seconds < 1 then
    raise exception 'take_rate_limit: 잘못된 인자';
  end if;
  if p_kind in ('bridge_events','bridge_ack','bridge_poll') and (p_bridge_id is null or not exists(
    select 1 from public.bridges where id=p_bridge_id and user_id=p_user_id)) then
    raise exception 'take_rate_limit: invalid bridge' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || p_kind || ':' || coalesce(p_bridge_id::text,'')));
  v_since := clock_timestamp() - v_window;

  if p_kind = 'missing_report' then
    select r.created_at into v_nth from public.missing_reports r
    where r.user_id = p_user_id and r.created_at > v_since
    order by r.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.missing_reports (user_id, created_at) values (p_user_id, clock_timestamp());
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create', 'bridge_register','bridge_events','bridge_ack','bridge_poll') then
    if p_bridge_id is not null then
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id = p_bridge_id and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    else
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id is null and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    end if;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.rate_limit_events (user_id, kind, created_at,bridge_id) values (p_user_id, p_kind, clock_timestamp(),p_bridge_id);
  else
    raise exception 'take_rate_limit: 모르는 종류 %', p_kind;
  end if;
  return null;
end;
$$;

revoke execute on function public.take_rate_limit from public, anon, authenticated;
grant execute on function public.take_rate_limit to service_role;

do $$
declare f text;
begin
  foreach f in array array['bridge_commands_from_step','register_bridge','lock_bridge_command','withdraw_bridge_command',
    'lease_bridge_command','settle_bridge_command','list_bridge_commands','apply_bridge_event','bridge_heartbeat',
    'sweep_bridge_heartbeats','sweep_agent_step_leases','revoke_bridge','next_unbound_agent_messages',
    'next_bridge_agent_message','bridge_redelivery_candidates','purge_bridge_commands'] loop
    execute format('revoke all on function public.%I from public, anon, authenticated',f);
    execute format('grant execute on function public.%I to service_role',f);
  end loop;
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.bridge_commands;
  end if;
end;
$$;
commit;
