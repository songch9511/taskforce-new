-- Agent-only grants. Operators enroll exact approved users separately; this migration seeds none.
-- Generic Taskforce begin_call and execution_actors are intentionally unchanged.
create table public.agent_execution_grants (
  user_id uuid not null references auth.users(id) on delete cascade,
  adapter text not null check (adapter in ('agent:claude-code','agent:codex')),
  created_at timestamptz not null default now(),
  primary key (user_id,adapter)
);
alter table public.agent_execution_grants enable row level security;
revoke all on public.agent_execution_grants from public, anon, authenticated;
grant select,insert,update,delete on public.agent_execution_grants to service_role;

create function public.agent_execution_allowed(p_user_id uuid,p_adapter text) returns boolean
language sql stable set search_path = '' as $$
  select coalesce(p_adapter in ('agent:claude-code','agent:codex'),false) and (
    exists(select 1 from public.execution_actors where user_id=p_user_id)
    or exists(select 1 from public.agent_execution_grants where user_id=p_user_id and adapter=p_adapter)
  )
$$;
revoke all on function public.agent_execution_allowed(uuid,text) from public,anon,authenticated;
grant execute on function public.agent_execution_allowed(uuid,text) to service_role;

-- Latest definitions: bridge_commands (20261118), agent_path_leases (20261123).
-- Only actor eligibility changes. All other lease, policy, tool, mode and lifecycle gates stay intact.
create or replace function public.agent_write_gate_open(p_user_id uuid,p_provider text,p_mode text) returns boolean
language sql stable set search_path = '' as $$
  select public.agent_execution_allowed(p_user_id,p_provider)
    and (select count(*)=3 and not coalesce(bool_or(blocked),true) from public.execution_controls
      where (scope,key) in (('global','*'),('provider',p_provider),('mode',p_mode)))
    and exists(select 1 from public.execution_tools where provider=p_provider and tool='message' and effect_class='external')
$$;

create or replace function public.lease_bridge_command(p_user_id uuid,p_bridge_id uuid,p_command_id uuid,p_access text,p_mode text)
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
      if not found then
        -- Keep first-delivery authorization serialized with grant revocation.
        perform 1 from public.agent_execution_grants
          where user_id=p_user_id and adapter=s.provider for share;
      end if;
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
        or not public.agent_execution_allowed(p_user_id,s.provider)
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
