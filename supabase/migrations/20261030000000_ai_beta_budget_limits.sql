-- One existing ledger: deleted accounts retain anonymous cost evidence for the global cap.
alter table public.ai_spend_attempts drop constraint ai_spend_attempts_user_id_fkey;
alter table public.ai_spend_attempts alter column user_id drop not null;
alter table public.ai_spend_attempts add constraint ai_spend_attempts_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- Operator policy, not user data. Clients cannot read or change shared limits.
create table public.ai_budget_policy (
  singleton boolean primary key default true check (singleton),
  global_daily_usd numeric not null default 5 check (global_daily_usd > 0 and global_daily_usd < 'Infinity'::numeric),
  user_daily_usd numeric not null default 3 check (user_daily_usd > 0 and user_daily_usd < 'Infinity'::numeric),
  global_total_usd numeric not null default 50 check (global_total_usd > 0 and global_total_usd < 'Infinity'::numeric)
);
insert into public.ai_budget_policy(singleton) values(true);
alter table public.ai_budget_policy enable row level security;
revoke all on public.ai_budget_policy from public, anon, authenticated;
grant select, update on public.ai_budget_policy to service_role;

create or replace function public.reserve_ai_spend(p_user_id uuid, p_id uuid, p_endpoint text, p_model text, p_reserved_usd numeric)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_policy ai_budget_policy;
  v_user_total numeric;
  v_user_daily numeric;
  v_global_total numeric;
  v_global_daily numeric;
  v_day timestamptz := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
begin
  if p_user_id is null then raise exception 'ai_user_required'; end if;
  if p_reserved_usd is null or p_reserved_usd <= 0 or p_reserved_usd > 10 then
    raise exception 'ai_invalid_reservation';
  end if;
  -- Same lock order in reserve and settle; includes competing accounts and server instances.
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:global', 0));
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:' || p_user_id::text, 0));
  select * into v_policy from ai_budget_policy where singleton for share;
  if not found then raise exception 'ai_budget_policy_unavailable'; end if;
  if exists(select 1 from ai_spend_attempts where user_id = p_user_id and cost_usd > reserved_usd) then
    raise exception 'ai_provider_bound_breached';
  end if;
  -- Unknown costs NEVER expire at midnight. Confirmed costs use admission date, not reconciliation date.
  select coalesce(sum(coalesce(cost_usd,reserved_usd)),0),
    coalesce(sum(coalesce(cost_usd,reserved_usd)) filter (where cost_usd is null or created_at >= v_day),0),
    coalesce(sum(coalesce(cost_usd,reserved_usd)) filter (where user_id=p_user_id),0),
    coalesce(sum(coalesce(cost_usd,reserved_usd)) filter (where user_id=p_user_id and (cost_usd is null or created_at >= v_day)),0)
  into v_global_total, v_global_daily, v_user_total, v_user_daily from ai_spend_attempts;
  if v_user_total + p_reserved_usd > 10 then raise exception 'ai_budget_exhausted'; end if;
  if v_global_total + p_reserved_usd > v_policy.global_total_usd then raise exception 'ai_global_budget_exhausted'; end if;
  if v_user_daily + p_reserved_usd > v_policy.user_daily_usd then raise exception 'ai_user_daily_budget_exhausted'; end if;
  if v_global_daily + p_reserved_usd > v_policy.global_daily_usd then raise exception 'ai_global_daily_budget_exhausted'; end if;
  insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd)
    values(p_id,p_user_id,p_endpoint,p_model,p_reserved_usd);
end;
$$;

create or replace function public.settle_ai_spend(p_user_id uuid, p_id uuid, p_cost_usd numeric, p_generation_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_attempt ai_spend_attempts;
begin
  if p_cost_usd is not null and (p_cost_usd < 0 or p_cost_usd >= 'Infinity'::numeric) then
    raise exception 'ai_invalid_cost';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:global', 0));
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:' || p_user_id::text, 0));
  -- Only service_role can call this RPC. An in-flight response may retain the original
  -- account ID after deletion anonymizes its attempt; preserve that known cost and ID.
  -- Lock by unique attempt ID first, then enforce ownership for every live account.
  select * into v_attempt from ai_spend_attempts where id = p_id for update;
  if not found or (v_attempt.user_id is not null and v_attempt.user_id is distinct from p_user_id) then
    raise exception 'ai_attempt_not_found';
  end if;
  if v_attempt.cost_usd is not null then
    if p_cost_usd is distinct from v_attempt.cost_usd then raise exception 'ai_cost_already_confirmed'; end if;
    return;
  end if;
  if v_attempt.generation_id is not null and p_generation_id is not null and v_attempt.generation_id <> p_generation_id then
    raise exception 'ai_generation_mismatch';
  end if;
  update ai_spend_attempts set cost_usd = p_cost_usd,
    generation_id = coalesce(generation_id, p_generation_id),
    settled_at = case when p_cost_usd is not null then now() else null end
    where id = p_id;
  -- An upstream contract violation must remain recorded even when actual > reserved.
  -- No implicit release, age expiry, or conversion of missing cost to zero.
end;
$$;

create or replace function public.task_source_states(p_user_id uuid, p_connection_id uuid, p_external_ids text[])
returns table (
  external_id text,
  source_id uuid,
  external_version text,
  structured jsonb,
  processing_status text,
  started_at timestamptz,                   -- 처리를 시작한 시각 (멈춘 처리를 가려낸다)
  linked boolean
)
language sql
stable
set search_path = ''
as $$
  with latest as (
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, case when (s.processing_summary->>'retryable' = 'false' or (s.processing_summary->>'budget_deferred' = 'true' and (s.processing_summary->>'retry_at' is null or (s.processing_summary->>'retry_at')::timestamptz > now()))) then 'blocked' else s.processing_status end as processing_status,
            coalesce((s.processing_summary->>'started_at')::timestamptz, s.created_at) as started_at
       from public.sources s
      where s.user_id = p_user_id and s.connection_id = p_connection_id and s.kind = 'task'
        and s.external_id = any (p_external_ids) and s.processing_status = 'done'
      order by s.external_id, s.occurred_at desc, s.created_at desc)
    union all
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, case when (s.processing_summary->>'retryable' = 'false' or (s.processing_summary->>'budget_deferred' = 'true' and (s.processing_summary->>'retry_at' is null or (s.processing_summary->>'retry_at')::timestamptz > now()))) then 'blocked' else s.processing_status end as processing_status,
            coalesce((s.processing_summary->>'started_at')::timestamptz, s.created_at) as started_at
       from public.sources s
      where s.user_id = p_user_id and s.connection_id = p_connection_id and s.kind = 'task'
        and s.external_id = any (p_external_ids) and s.processing_status <> 'done'
      order by s.external_id, s.occurred_at desc, s.created_at desc)
  )
  select l.external_id, l.id, l.external_version, l.structured, l.processing_status, l.started_at,
         exists (select 1 from public.action_links a
                  where a.user_id = p_user_id and a.connection_id = p_connection_id and a.external_id = l.external_id)
    from latest l;
$$;


alter table public.sources drop constraint sources_processing_error_code_check;
alter table public.sources add constraint sources_processing_error_code_check check (
  processing_error_code in ('ai_quota', 'ai_timeout', 'ai_output', 'consent', 'expired', 'internal',
    'ai_user_daily_budget_exhausted', 'ai_global_daily_budget_exhausted', 'ai_global_budget_exhausted',
    'ai_budget_exhausted', 'ai_pricing_unavailable', 'ai_provider_bound_violation', 'ai_budget_unavailable')
);

-- Filter superseded/ineligible task versions BEFORE the bounded retry batch.
-- Otherwise old deferred versions can permanently occupy every queue slot.
create function public.pending_task_sources(p_user_id uuid, p_connection_id uuid, p_since timestamptz)
returns table (id uuid, external_id text, external_version text, structured jsonb, occurred_at timestamptz, external_url text)
language sql stable security definer set search_path = public as $$
  with unfinished as (
    select distinct on (s.external_id) s.* from sources s
    where s.user_id=p_user_id and s.connection_id=p_connection_id and s.kind='task' and s.processing_status<>'done'
    order by s.external_id, s.occurred_at desc, s.created_at desc
  ), completed as (
    select distinct on (s.external_id) s.external_id, s.external_version from sources s
    where s.user_id=p_user_id and s.connection_id=p_connection_id and s.kind='task' and s.processing_status='done'
    order by s.external_id, s.occurred_at desc, s.created_at desc
  )
  select s.id,s.external_id,s.external_version,s.structured,s.occurred_at,s.external_url
  from unfinished s left join completed d on d.external_id=s.external_id
  where (d.external_version is null or s.external_version>d.external_version)
    and s.structured is not null
    and (s.processing_summary->>'retryable' is null or s.processing_summary->>'retryable'='true')
    and (s.created_at>=p_since or s.processing_summary->>'budget_deferred'='true')
    and (s.processing_summary->>'budget_deferred' is null or (s.processing_summary->>'retry_at')::timestamptz<=now())
    and (s.processing_status='failed' or coalesce((s.processing_summary->>'started_at')::timestamptz,s.created_at)<now()-interval '10 minutes')
  order by s.occurred_at,s.id limit 20;
$$;
revoke all on function public.pending_task_sources(uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.pending_task_sources(uuid,uuid,timestamptz) to service_role;
