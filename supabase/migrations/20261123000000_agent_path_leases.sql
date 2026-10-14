begin;
set local lock_timeout = '5s';
lock table public.rate_limit_events, public.metric_events in access exclusive mode nowait;
lock table public.bridges, public.agent_sessions, public.execution_runs, public.agent_tasks, public.agent_artifacts in share row exclusive mode nowait;

create table public.agent_path_leases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  bridge_id uuid not null,
  run_id uuid not null,
  agent_session_id uuid not null,
  workspace_ref text not null check(char_length(workspace_ref) between 1 and 500),
  path_key text not null check(char_length(path_key) between 1 and 1000),
  rel_path text not null check(char_length(rel_path) between 1 and 1000),
  source text not null check(source in ('requested','approved','observed')),
  request_id text check(char_length(request_id) between 1 and 200),
  acquired_at timestamptz not null default now(),
  expires_at timestamptz,
  released_at timestamptz,
  release_reason text check(release_reason in ('run_ended','idle_expired','session_external','request_denied','conflict_resolved')),
  conflict_run_id uuid,
  conflict_at timestamptz,
  conflict_version integer not null default 0 check(conflict_version>=0),
  conflict_stop_at timestamptz,
  waiter_run_ids uuid[] not null default '{}' check(cardinality(waiter_run_ids)<=20),
  release_notified_at timestamptz,
  unique(id,user_id),
  foreign key(bridge_id,user_id) references public.bridges(id,user_id) on delete cascade,
  foreign key(run_id,user_id) references public.execution_runs(id,user_id) on delete cascade,
  check((released_at is null)=(release_reason is null)),
  check((conflict_run_id is null)=(conflict_at is null)),
  check(conflict_stop_at is null or conflict_run_id is not null),
  check(conflict_run_id is distinct from run_id),
  check((source='observed')=(request_id is null))
);
alter table public.agent_path_leases enable row level security;
create policy owner_all on public.agent_path_leases for all to authenticated
  using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
revoke all on public.agent_path_leases from public,anon,authenticated;
grant select on public.agent_path_leases to authenticated;
grant all on public.agent_path_leases to service_role;
create unique index agent_path_leases_active_key on public.agent_path_leases(user_id,bridge_id,path_key) where released_at is null;
create index agent_path_leases_run on public.agent_path_leases(run_id) where released_at is null;
create index agent_path_leases_session on public.agent_path_leases(agent_session_id) where released_at is null;
create index agent_path_leases_expiry on public.agent_path_leases(expires_at) where released_at is null and expires_at is not null;
create index agent_path_leases_conflicts on public.agent_path_leases(user_id,conflict_at) where conflict_run_id is not null;
create index agent_path_leases_pending_stop on public.agent_path_leases(user_id) where conflict_run_id is not null and conflict_stop_at is null;
create index agent_path_leases_notices on public.agent_path_leases(acquired_at,id) where release_notified_at is null and (released_at is not null or conflict_stop_at is not null);
create index agent_path_leases_retention on public.agent_path_leases(released_at) where released_at is not null and conflict_run_id is null;

create function public.agent_path_key(p_path text) returns text
language sql immutable set search_path = '' as $$
  select case when p_path is null or char_length(normalize(p_path,NFC))>1000 or left(p_path,1)<>'/'
    or p_path ~ '[\x01-\x1f\x7f]' or p_path like '%//%' or p_path ~ '(^|/)\.{1,2}(/|$)'
    or (p_path<>'/' and right(p_path,1)='/') then null
    else translate(replace(normalize(p_path,NFC),'ſ','s'),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') end
$$;

create function public.agent_write_gate_open(p_user_id uuid,p_provider text,p_mode text) returns boolean
language sql stable set search_path = '' as $$
  select exists(select 1 from public.execution_actors where user_id=p_user_id)
    and (select count(*)=3 and not coalesce(bool_or(blocked),true) from public.execution_controls
      where (scope,key) in (('global','*'),('provider',p_provider),('mode',p_mode)))
    and exists(select 1 from public.execution_tools where provider=p_provider and tool='message' and effect_class='external')
$$;

create function public.decide_agent_tool_call(p_user_id uuid,p_bridge_id uuid,p_session_id uuid,p_task_id uuid,
  p_turn_seq integer,p_mode text,p_decision jsonb) returns jsonb
language plpgsql set search_path = '' set lock_timeout = '250ms' as $$
declare
  t public.agent_tasks; r public.execution_runs; s public.agent_sessions; c public.agent_connections;
  l public.agent_path_leases; target record; v_workspace text; v_prefix text; v_key text; v_mode text;
  v_decision text:=p_decision->>'decision'; v_tool_reason text:=p_decision->>'reason';
  v_ids uuid[]:='{}'; v_holder jsonb; v_held uuid; v_flags jsonb:=coalesce(p_decision->'card_flags','[]'::jsonb);
  v_lease_op text:=p_decision->>'lease_op'; v_real text;
  v_started timestamptz:=clock_timestamp(); v_live text; v_limited boolean;
begin
  select * into t from public.agent_tasks where id=p_task_id and user_id=p_user_id;
  select * into r from public.execution_runs where id=t.run_id and user_id=p_user_id;
  select * into s from public.agent_sessions where id=p_session_id and user_id=p_user_id;
  select * into c from public.agent_connections where id=s.connection_id and user_id=p_user_id;
  if t.id is null or r.id is null or s.id is null or c.id is null or t.agent_session_id<>p_session_id
    or r.agent_session_id is distinct from p_session_id or r.kind<>'conversation' or c.bridge_id is distinct from p_bridge_id
    or c.adapter is distinct from (case when p_decision->>'call_kind' in ('claude_bash','claude_write') then 'agent:claude-code'
      when p_decision->>'call_kind' in ('codex_command','codex_file_change') then 'agent:codex' end) then
    return jsonb_build_object('status','not_found');
  end if;
  begin
    v_limited:=public.take_rate_limit(p_user_id,'bridge_decide',600,60,p_bridge_id) is not null;
    select * into s from public.agent_sessions where id=p_session_id and user_id=p_user_id for share;
    select * into r from public.execution_runs where id=t.run_id and user_id=p_user_id for share;
    select * into t from public.agent_tasks where id=p_task_id and user_id=p_user_id for share;
    select * into c from public.agent_connections where id=s.connection_id and user_id=p_user_id;
    v_live:=case when t.state='unreachable' then t.last_live_state else t.state end;
    if t.id is null or r.id is null or s.id is null or c.id is null or t.run_id is distinct from r.id
      or t.agent_session_id is distinct from s.id or r.agent_session_id is distinct from s.id
      or c.bridge_id is distinct from p_bridge_id
      or c.adapter is distinct from (case when p_decision->>'call_kind' in ('claude_bash','claude_write') then 'agent:claude-code' else 'agent:codex' end)
      or s.status not in ('bound','unreachable')
      or r.kind<>'conversation' or r.state not in ('queued','running') or t.turn_seq is distinct from p_turn_seq
      or v_live not in ('accepted','running','dispatched')
      or (v_live='dispatched' and not exists(select 1 from public.execution_steps where id=t.step_id and run_id=r.id
        and state='calling' and lease_owner like 'bridge:'||p_bridge_id::text||':%')) then
      v_decision:='deny';v_tool_reason:='not_live';
    else
      select mode into v_mode from public.execution_policies where user_id=p_user_id;
      if coalesce(v_mode,'manual') is distinct from p_mode then raise exception 'policy changed' using errcode='TF001'; end if;
      if v_limited then v_decision:='deny';v_tool_reason:='rate_limited';
      elsif c.status<>'active' or not public.agent_write_gate_open(p_user_id,c.adapter,p_mode)
        or coalesce(p_decision->>'access','none') not in ('write','read_only') then
        v_decision:='deny';v_tool_reason:='write_gate_closed';
      else
        v_workspace:=normalize(p_decision->>'workspace_real_path',NFC);
        v_prefix:=case when v_workspace='/' then '/' else v_workspace||'/' end;
        if public.agent_path_key(v_workspace) is null or v_workspace='/'
          or (left(s.workspace_ref,8)='pending:' and (v_workspace !~ '^/[^/]+/[^/]+' or v_workspace ~ '^/Users/[^/]+$'))
          or (left(s.workspace_ref,8)<>'pending:' and normalize(s.workspace_ref,NFC) is distinct from v_workspace) then
          v_decision:='deny';v_tool_reason:='workspace_mismatch';
        elsif p_decision->>'call_kind' in ('codex_command','codex_file_change') and exists(
          select 1 from public.execution_steps where run_id=r.id and user_id=p_user_id and kind='agent_message'
            and args->>'agent_task_id'=t.id::text and args->>'provider_request_id'=p_decision->>'request_id') then
          v_decision:='deny';v_tool_reason:='not_first_request';
        elsif v_decision<>'deny' and v_lease_op in ('reserve','acquire') then
          begin
            if exists(select 1 from jsonb_array_elements(p_decision->'targets') x where public.agent_path_key(x->>'real_path')
              ~ '/(\.git|\.claude|\.codex|\.vscode|\.idea|\.husky|\.githooks|\.cargo)(/|$)|/(\.envrc|\.mcp\.json|\.gitattributes|\.gitmodules|\.yarnrc\.yml|\.npmrc|\.pre-commit-config\.yaml|lefthook\.yml)$') then
              v_decision:='defer';v_tool_reason:='tool_config_write';v_lease_op:='reserve';
            end if;
            for target in select value,public.agent_path_key(value->>'real_path') key from jsonb_array_elements(p_decision->'targets') order by key loop
              v_key:=target.key;v_real:=normalize(target.value->>'real_path',NFC);
              if char_length(v_real)>1000 then v_decision:='deny';v_tool_reason:='path_too_long';raise exception 'long path' using errcode='TF002';end if;
              if v_key is null then v_decision:='deny';v_tool_reason:='outside_workspace';raise exception 'invalid target' using errcode='TF002'; end if;
              if left(v_real,char_length(v_prefix))<>v_prefix or v_real=v_workspace then
                if p_decision->>'call_kind'='claude_write' then v_decision:='deny';v_tool_reason:='outside_workspace';raise exception 'outside' using errcode='TF002'; end if;
                v_flags:='["runs_without_sandbox"]'::jsonb;
                continue;
              end if;
              select * into l from public.agent_path_leases where user_id=p_user_id and bridge_id=p_bridge_id and path_key=v_key and released_at is null for update;
              if found and (l.expires_at<=public.db_now() or exists(select 1 from public.execution_runs where id=l.run_id and state in ('done','failed','stopped'))) then
                update public.agent_path_leases set released_at=public.db_now(),release_reason=case when exists(select 1 from public.execution_runs where id=l.run_id and state in ('done','failed','stopped')) then 'run_ended' else 'idle_expired' end,
                  release_notified_at=case when cardinality(waiter_run_ids)=0 and conflict_stop_at is null then public.db_now() end where id=l.id;
                l.id:=null;
              end if;
              if l.id is null then
                insert into public.agent_path_leases(user_id,bridge_id,run_id,agent_session_id,workspace_ref,path_key,rel_path,source,request_id)
                  values(p_user_id,p_bridge_id,r.id,s.id,v_workspace,v_key,substring(v_real from char_length(v_prefix)+1),
                    case when v_lease_op='acquire' then 'approved' else 'requested' end,p_decision->>'request_id')
                  on conflict do nothing returning * into l;
                if not found then select * into l from public.agent_path_leases where user_id=p_user_id and bridge_id=p_bridge_id and path_key=v_key and released_at is null for update; end if;
                if not found then raise exception 'path lease changed' using errcode='55P03';end if;
              end if;
              if l.run_id<>r.id then
                v_held:=l.id;v_holder:=jsonb_build_object('rel_path',l.rel_path,'action_number',
                  (select a.number from public.execution_runs h join public.actions a on a.id=h.action_id and a.user_id=h.user_id where h.id=l.run_id));
                v_decision:='deny';v_tool_reason:='path_in_use';raise exception 'held' using errcode='TF002';
              end if;
              update public.agent_path_leases set expires_at=null,
                source=case when source='requested' and v_lease_op='acquire' then 'approved' else source end,
                request_id=case when source='requested' then p_decision->>'request_id' else request_id end where id=l.id;
              if not(l.id=any(v_ids)) then v_ids:=array_append(v_ids,l.id);end if;
            end loop;
          exception when sqlstate 'TF002' then
            v_decision:='deny';
            v_ids:='{}';
            if v_held is not null then
              update public.agent_path_leases set waiter_run_ids=array_append(waiter_run_ids,r.id)
                where id=v_held and not(r.id=any(waiter_run_ids)) and cardinality(waiter_run_ids)<20;
              v_ids:=array[v_held];
            end if;
          end;
        end if;
      end if;
    end if;
  exception when sqlstate 'TF001' then return jsonb_build_object('status','policy_changed');
    when lock_not_available then
      v_ids:='{}';v_holder:=null;
      if v_decision<>'deny' then v_decision:='defer';v_tool_reason:='server_busy';end if;
  end;
  insert into public.metric_events(user_id,type,props) values(p_user_id,'tool_call_decided',jsonb_strip_nulls(jsonb_build_object(
    'adapter',c.adapter,'call_kind',p_decision->>'call_kind','decision',v_decision,'reason',v_tool_reason,
    'access',coalesce(p_decision->>'access','none'),'mode',p_mode,'parse_reason',p_decision->>'parse_reason',
    'server_ms',greatest(0,coalesce((p_decision->>'server_ms')::numeric,0))+extract(epoch from(clock_timestamp()-v_started))*1000)));
  return jsonb_build_object('status','decided','decision',v_decision,'reason',v_tool_reason,'lease_ids',v_ids,'run_id',r.id,'card_flags',v_flags)
    || case when v_holder is null then '{}'::jsonb else jsonb_build_object('holder',v_holder) end;
end;
$$;

create function public.answer_agent_approval(p_user_id uuid,p_task_id uuid,p_provider_request_id text,p_answers jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare v_result jsonb; t public.agent_tasks; v_adapter text; v_answer text;
begin
  v_result:=public.answer_agent_question(p_user_id,p_task_id,p_provider_request_id,p_answers,false,null);
  if v_result->>'status'='duplicate' then
    select * into t from public.agent_tasks where id=p_task_id and user_id=p_user_id;
    if t.pending_question is not null or not exists(select 1 from public.execution_steps where id=(v_result->>'step_id')::uuid and args->'answers'=p_answers) then
      return jsonb_build_object('status','question_stale');
    end if;
  end if;
  if v_result->>'status'='answered' then
    select * into t from public.agent_tasks where id=p_task_id and user_id=p_user_id;
    if t.answered_question->>'kind' is distinct from 'approval'
      or jsonb_array_length(t.answered_question->'questions') is distinct from 1
      or t.answered_question->'questions'->0->>'id' is distinct from 'approval'
      or p_answers not in ('{"approval":"allow"}'::jsonb,'{"approval":"deny"}'::jsonb) then
      raise exception 'invalid approval answer' using errcode='P0004';
    end if;
    v_answer:=p_answers->>'approval';
    update public.agent_path_leases set source=case when v_answer='allow' then 'approved' else source end,
      released_at=case when v_answer='deny' then public.db_now() end,
      release_reason=case when v_answer='deny' then 'request_denied' end,release_notified_at=case when v_answer='deny' and cardinality(waiter_run_ids)=0 and conflict_stop_at is null then public.db_now() end
      where user_id=p_user_id and run_id=t.run_id and request_id=p_provider_request_id and source in ('requested','approved') and released_at is null;
    select c.adapter into v_adapter from public.agent_sessions s join public.agent_connections c on c.id=s.connection_id and c.user_id=s.user_id where s.id=t.agent_session_id;
    insert into public.metric_events(user_id,type,props) values(p_user_id,'question_answered',jsonb_build_object('kind','approval','adapter',v_adapter,'decision',v_answer));
  end if;
  return v_result;
exception when sqlstate 'P0004' then return jsonb_build_object('status','invalid_answer');
end;
$$;

create function public.agent_path_leases_task_state() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.state is distinct from old.state then
    if new.state in ('accepted','running','awaiting_answer') then update public.agent_path_leases set expires_at=null where run_id=new.run_id and released_at is null;
    elsif new.state in ('idle','failed','cancelled') then
      update public.agent_path_leases set released_at=public.db_now(),release_reason='request_denied',release_notified_at=case when cardinality(waiter_run_ids)=0 and conflict_stop_at is null then public.db_now() end where run_id=new.run_id and source='requested' and released_at is null;
      update public.agent_path_leases set expires_at=public.db_now()+interval '30 minutes' where run_id=new.run_id and released_at is null;
    end if;
  end if;return null;
end;$$;
create trigger agent_path_leases_task_state after update of state on public.agent_tasks for each row execute function public.agent_path_leases_task_state();
create function public.agent_path_leases_run_end() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.state in ('done','failed','stopped') and new.state is distinct from old.state then
    update public.agent_path_leases set released_at=public.db_now(),release_reason='run_ended',release_notified_at=case when cardinality(waiter_run_ids)=0 and conflict_stop_at is null then public.db_now() end where run_id=new.id and released_at is null;
  end if;return null;
end;$$;
create trigger agent_path_leases_run_end after update of state on public.execution_runs for each row execute function public.agent_path_leases_run_end();
create function public.agent_path_leases_session_external() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status='external' and new.status is distinct from old.status then
    update public.agent_path_leases set released_at=public.db_now(),release_reason='session_external',release_notified_at=null where agent_session_id=new.id and released_at is null;
  end if;return null;
end;$$;
create trigger agent_path_leases_session_external after update of status on public.agent_sessions for each row execute function public.agent_path_leases_session_external();

create function public.agent_path_leases_on_artifact() returns trigger language plpgsql set search_path = '' as $$
declare r public.execution_runs;s public.agent_sessions;c public.agent_connections;l public.agent_path_leases;v_key text;
begin
  select * into r from public.execution_runs where id=new.run_id and user_id=new.user_id and kind='conversation';
  if not found or r.state in ('done','failed','stopped') then return null;end if;
  select * into s from public.agent_sessions where id=r.agent_session_id and user_id=new.user_id;
  if not found or left(s.workspace_ref,8)='pending:' or s.status='external'
    or char_length(normalize(s.workspace_ref,NFC))>500 then return null;end if;
  select * into c from public.agent_connections where id=s.connection_id and user_id=new.user_id;
  v_key:=public.agent_path_key(rtrim(s.workspace_ref,'/')||'/'||new.path);
  if v_key is null or c.bridge_id is null then return null;end if;
  select * into l from public.agent_path_leases where user_id=new.user_id and bridge_id=c.bridge_id and path_key=v_key and released_at is null for update;
  if found and (l.expires_at<=public.db_now() or exists(select 1 from public.execution_runs where id=l.run_id and state in ('done','failed','stopped'))) then
    update public.agent_path_leases set released_at=public.db_now(),release_reason=case when exists(select 1 from public.execution_runs where id=l.run_id and state in ('done','failed','stopped')) then 'run_ended' else 'idle_expired' end,
      release_notified_at=case when cardinality(waiter_run_ids)=0 and conflict_stop_at is null then public.db_now() end where id=l.id;
    l.id:=null;
  end if;
  if l.id is null then
    insert into public.agent_path_leases(user_id,bridge_id,run_id,agent_session_id,workspace_ref,path_key,rel_path,source,expires_at)
      values(new.user_id,c.bridge_id,r.id,s.id,normalize(s.workspace_ref,NFC),v_key,normalize(new.path,NFC),'observed',
        case when exists(select 1 from public.agent_tasks where id=new.agent_task_id and state in ('idle','failed','cancelled'))
            then public.db_now()+interval '30 minutes' end)
      on conflict do nothing returning * into l;
    if not found then select * into l from public.agent_path_leases where user_id=new.user_id and bridge_id=c.bridge_id and path_key=v_key and released_at is null for update;end if;
    if not found then raise exception 'path lease changed' using errcode='55P03';end if;
  end if;
  if l.run_id<>r.id and l.source<>'requested' and l.conflict_run_id is null then
    update public.agent_path_leases set conflict_run_id=r.id,conflict_at=public.db_now(),conflict_version=conflict_version+1,conflict_stop_at=null,release_notified_at=null where id=l.id;
    insert into public.metric_events(user_id,type,props) values(new.user_id,'path_conflict_found',jsonb_build_object('adapter',c.adapter));
  end if;
  return null;
end;$$;
create trigger agent_path_leases_on_artifact after insert on public.agent_artifacts for each row execute function public.agent_path_leases_on_artifact();

create function public.sweep_agent_path_leases(p_limit integer) returns jsonb language plpgsql set search_path = '' as $$
declare v_expired integer;v_ended integer;
begin
  with candidates as(select l.id,r.state from public.agent_path_leases l join public.execution_runs r on r.id=l.run_id
    where l.released_at is null and (l.expires_at<=public.db_now() or r.state in ('done','failed','stopped'))
    order by l.path_key limit greatest(0,least(p_limit,500)) for update of l skip locked), changed as(
    update public.agent_path_leases l set released_at=public.db_now(),release_notified_at=case when cardinality(l.waiter_run_ids)=0 and l.conflict_stop_at is null then public.db_now() end,
      release_reason=case when c.state in ('done','failed','stopped') then 'run_ended' else 'idle_expired' end
    from candidates c where l.id=c.id returning l.release_reason)
  select count(*) filter(where release_reason='idle_expired'),count(*) filter(where release_reason='run_ended') into v_expired,v_ended from changed;
  return jsonb_build_object('expired',v_expired,'run_ended',v_ended);
end;$$;

create function public.list_pending_path_conflict_stops(p_user_id uuid,p_bridge_id uuid,p_limit integer) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'user_id',user_id) order by conflict_at,id),'[]'::jsonb)
  from (select l.id,l.user_id,l.conflict_at from public.agent_path_leases l
    join public.execution_runs r on r.id=l.conflict_run_id and r.user_id=l.user_id
    where l.conflict_stop_at is null and r.state in ('queued','running','waiting_approval')
      and (p_user_id is null or l.user_id=p_user_id) and (p_bridge_id is null or l.bridge_id=p_bridge_id)
    order by l.conflict_at,l.id limit greatest(0,least(p_limit,500))) pending
$$;

create function public.stop_agent_run_for_path_conflict(p_user_id uuid,p_lease_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare l public.agent_path_leases;r public.execution_runs;t record;v_tasks jsonb:='[]';v_cancel jsonb;
begin
  select * into l from public.agent_path_leases where id=p_lease_id and user_id=p_user_id;
  if not found or l.conflict_run_id is null then return jsonb_build_object('status','not_found','tasks',v_tasks);end if;
  select * into r from public.execution_runs where id=l.conflict_run_id and user_id=p_user_id for no key update;
  if not found then return jsonb_build_object('status','not_found','tasks',v_tasks);end if;
  if r.state in ('queued','running','waiting_approval') then
    for t in select id from public.agent_tasks where run_id=r.id and user_id=p_user_id and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id loop
      v_cancel:=public.request_agent_task_cancel(p_user_id,t.id);
      if v_cancel is not null then v_tasks:=v_tasks||jsonb_build_array(v_cancel);end if;
    end loop;
    perform set_config('execution.gate','path_conflict',true);
    update public.execution_runs set state='stopped',stopped_at=null where id=r.id;
  else
    return jsonb_build_object('status','noop','tasks',v_tasks);
  end if;
  update public.agent_path_leases set conflict_stop_at=coalesce(conflict_stop_at,public.db_now()),release_notified_at=null
    where id=p_lease_id and conflict_run_id=r.id and conflict_version=l.conflict_version and conflict_stop_at is null;
  return jsonb_build_object('status',case when r.state in ('queued','running','waiting_approval') then 'stopped' else 'noop' end,'tasks',v_tasks);
end;$$;

create function public.list_path_lease_notices(p_limit integer) returns jsonb
language sql stable set search_path = '' as $$
  with leases as (
    select l.* from public.agent_path_leases l where release_notified_at is null and (released_at is not null or conflict_stop_at is not null) and exists(
      select 1 from public.agent_tasks t where t.user_id=l.user_id and (
        (l.released_at is not null and t.run_id=any(l.waiter_run_ids))
        or (l.release_reason='session_external' and t.run_id=l.run_id)
        or (l.conflict_stop_at is not null and t.run_id in(l.run_id,l.conflict_run_id))))
    order by acquired_at,id limit greatest(0,least(p_limit,500))
  ), recipients as (
    select l.*,w.run_id recipient,true originating_only,'path-free:'||l.id||':'||w.run_id event_id,l.rel_path||' is free now' text
      from leases l cross join lateral unnest(l.waiter_run_ids) w(run_id) where l.released_at is not null
    union all
    select l.*,l.run_id,false,'path-external:'||l.agent_session_id||':'||floor(extract(epoch from l.released_at)),'File locks released'
      from leases l where l.release_reason='session_external'
    union all
    select l.*,l.run_id,true,'path-conflict:'||l.id||':'||l.run_id,'Both tasks changed '||l.rel_path||' · Review'
      from leases l where l.conflict_stop_at is not null
    union all
    select l.*,l.conflict_run_id,true,'path-conflict:'||l.id||':'||l.conflict_run_id,'Stopped · another task was using '||l.rel_path
      from leases l where l.conflict_stop_at is not null
  ) select coalesce(jsonb_agg(jsonb_build_object('lease_id',n.id,'user_id',n.user_id,'session_id',t.agent_session_id,
    'task_id',t.id,'turn_seq',t.turn_seq,'event_id',n.event_id,'text',n.text,'originating_only',n.originating_only,
    'released_at',n.released_at,'conflict_at',n.conflict_at,'conflict_stop_at',n.conflict_stop_at)),'[]')
  from recipients n join lateral (select id,agent_session_id,turn_seq from public.agent_tasks
    where run_id=n.recipient and user_id=n.user_id order by turn_seq desc,id desc limit 1) t on true
$$;

-- A stale delivery acknowledgement must not hide a newer release or conflict.
create function public.mark_path_lease_notices(p_ids jsonb) returns integer
language plpgsql set search_path = '' as $$
declare v_count integer;
begin
  with picked as (
    select l.id from public.agent_path_leases l join jsonb_to_recordset(p_ids)
      as s(lease_id uuid,released_at timestamptz,conflict_at timestamptz,conflict_stop_at timestamptz) on l.id=s.lease_id
    where l.released_at is not distinct from s.released_at and l.conflict_at is not distinct from s.conflict_at
      and l.conflict_stop_at is not distinct from s.conflict_stop_at and l.release_notified_at is null
    order by l.id for update of l skip locked
  ) update public.agent_path_leases set release_notified_at=public.db_now() where id in(select id from picked);
  get diagnostics v_count=row_count;return v_count;
end;$$;

create function public.list_path_conflicts(p_user_id uuid,p_limit integer) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
    select l.id lease_id,l.run_id holder_run_id,h.action_id holder_action_id,l.conflict_run_id,
      c.action_id conflict_action_id,l.rel_path,l.workspace_ref,l.conflict_at,l.conflict_version,l.released_at is not null released
    from public.agent_path_leases l join public.execution_runs h on h.id=l.run_id and h.user_id=l.user_id
      join public.execution_runs c on c.id=l.conflict_run_id and c.user_id=l.user_id
    where l.user_id=p_user_id and l.conflict_run_id is not null order by l.conflict_at,l.id
    limit greatest(0,least(p_limit,500))
  ) x
$$;
create function public.resolve_path_conflict(p_user_id uuid,p_lease_id uuid,p_keep text,p_conflict_version integer) returns jsonb
language plpgsql set search_path = '' as $$
declare l public.agent_path_leases;
begin
  if p_keep is null or p_keep not in ('holder','later') then raise exception 'invalid keep' using errcode='22023';end if;
  select * into l from public.agent_path_leases where id=p_lease_id and user_id=p_user_id for update;
  if not found then return jsonb_build_object('status','not_found');end if;
  if l.conflict_at is null or l.conflict_version is distinct from p_conflict_version then return jsonb_build_object('status','stale');end if;
  update public.agent_path_leases set conflict_run_id=null,conflict_at=null,conflict_stop_at=null,
    released_at=case when p_keep='later' and released_at is null then public.db_now() else released_at end,
    release_reason=case when p_keep='later' and released_at is null then 'conflict_resolved' else release_reason end,
    release_notified_at=case when p_keep='later' and released_at is null then case when cardinality(waiter_run_ids)=0 then public.db_now() end else release_notified_at end where id=l.id;
  insert into public.metric_events(user_id,type,props) values(p_user_id,'path_conflict_resolved',jsonb_build_object('keep',p_keep));
  return jsonb_build_object('status','resolved');
end;$$;
create function public.purge_agent_path_leases(p_before timestamptz,p_limit integer) returns integer
language plpgsql set search_path = '' as $$
declare v_count integer;
begin
  with picked as(select id from public.agent_path_leases where released_at<p_before and conflict_run_id is null
    order by released_at,id limit greatest(0,least(p_limit,500)) for update skip locked)
  delete from public.agent_path_leases where id in(select id from picked);
  get diagnostics v_count=row_count;return v_count;
end;$$;

-- OA 공통 블록: metric_events 확장 (Assistant 계약 v3 8장). 코디네이터 Opus 소유, 2026-10-13.
-- 이 블록은 metric_events에 처음 쓰는 OA WP들이 **글자 그대로** 자기 마이그레이션에 넣는다(지금: D1c-1 · D4c-1s).
-- 레인이 달라 어느 쪽이 먼저 적용돼도 결과가 같게 만든다: 열은 if not exists, CHECK · 정책은 계약 8장 전체 목록으로 통째로 교체.
-- 목록을 바꿔야 하면 작업자는 멈추고 코디네이터가 이 파일을 고쳐 두 WP에 같이 반영한다.
-- 기준: main의 마지막 정의 20261020000000_source_failure_visibility.sql:26 (app_opened · action_started · handoff_used ·
-- connection_created · connection_reauth · reconnect_notified · source_failed), 앱 insert 정책 20261001000000_metric_events_client_app_opened.sql.
-- v2 (2026-10-14, 코디네이터): D1d(대화 API) 쓰기 기록 5개 추가 — message_resent · question_answered · session_renamed ·
-- session_opened_external · session_resumed. v1(D1c-1 · D4c-1s, 이미 main)은 그대로 두고, 이후 metric CHECK를 바꾸는 WP는 이 v2 목록 전체를 쓴다.
-- v3 (2026-10-14, 코디네이터): D3c-2 승인 판정 · 경로 충돌 3개 추가 — tool_call_decided · path_conflict_found · path_conflict_resolved.

alter table public.metric_events
  add column if not exists props jsonb not null default '{}'::jsonb;

alter table public.metric_events drop constraint if exists metric_events_props_shape;
alter table public.metric_events add constraint metric_events_props_shape
  check (jsonb_typeof(props) = 'object');

alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
    'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed',
    'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved'
  ));

drop policy if exists "owner_insert_app_opened" on public.metric_events;
drop policy if exists "owner_insert_client_app_types" on public.metric_events;
create policy "owner_insert_client_app_types" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type in ('app_opened', 'assistant_opened'));

alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check(kind in ('ask','connection_start','action_create','run_create','bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide'));

create or replace function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int,p_bridge_id uuid default null)
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
  if p_kind in ('bridge_events','bridge_ack','bridge_poll','bridge_decide') and (p_bridge_id is null or not exists(
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
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create', 'bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide') then
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
  foreach f in array array['agent_path_key','agent_write_gate_open','decide_agent_tool_call','answer_agent_approval',
    'agent_path_leases_task_state','agent_path_leases_run_end','agent_path_leases_session_external','agent_path_leases_on_artifact',
    'sweep_agent_path_leases','list_pending_path_conflict_stops','stop_agent_run_for_path_conflict','list_path_lease_notices','mark_path_lease_notices',
    'list_path_conflicts','resolve_path_conflict','purge_agent_path_leases'] loop
    execute format('revoke execute on function public.%I from public,anon,authenticated',f);
    execute format('grant execute on function public.%I to service_role',f);
  end loop;
end;$$;
commit;
