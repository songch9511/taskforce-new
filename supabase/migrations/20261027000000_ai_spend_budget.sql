-- USD supplier spend is independent of execution product credits. No periodic reset.
create table public.ai_spend_attempts (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null check (endpoint in ('chat', 'decisions', 'embeddings')),
  model text not null,
  reserved_usd numeric not null check (reserved_usd > 0 and reserved_usd <= 10),
  cost_usd numeric check (cost_usd >= 0 and cost_usd < 'Infinity'::numeric),
  generation_id text,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  reconcile_checked_at timestamptz,
  unique (id, user_id)
);
create index ai_spend_attempts_user on public.ai_spend_attempts(user_id);
alter table public.ai_spend_attempts enable row level security;
create policy owner_read on public.ai_spend_attempts for select to authenticated using (user_id = auth.uid());
revoke all on public.ai_spend_attempts from anon, authenticated;
grant select on public.ai_spend_attempts to authenticated;

create function public.reserve_ai_spend(p_user_id uuid, p_id uuid, p_endpoint text, p_model text, p_reserved_usd numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_total numeric;
begin
  if p_reserved_usd is null or p_reserved_usd <= 0 or p_reserved_usd > 10 then
    raise exception 'ai_invalid_reservation';
  end if;
  -- One lock namespace for every route, reserve AND settle, across server instances.
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:' || p_user_id::text, 0));
  if exists(select 1 from ai_spend_attempts where user_id = p_user_id and cost_usd > reserved_usd) then
    raise exception 'ai_provider_bound_breached';
  end if;
  select coalesce(sum(coalesce(cost_usd, reserved_usd)), 0) into v_total
    from ai_spend_attempts where user_id = p_user_id;
  if v_total + p_reserved_usd > 10 then raise exception 'ai_budget_exhausted'; end if;
  insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd)
    values(p_id,p_user_id,p_endpoint,p_model,p_reserved_usd);
end;
$$;

create function public.settle_ai_spend(p_user_id uuid, p_id uuid, p_cost_usd numeric, p_generation_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_attempt ai_spend_attempts;
begin
  if p_cost_usd is not null and (p_cost_usd < 0 or p_cost_usd >= 'Infinity'::numeric) then
    raise exception 'ai_invalid_cost';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('ai_spend:' || p_user_id::text, 0));
  select * into v_attempt from ai_spend_attempts where id = p_id and user_id = p_user_id for update;
  if not found then raise exception 'ai_attempt_not_found'; end if;
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
    where id = p_id and user_id = p_user_id;
  -- An upstream contract violation must remain recorded even when actual > reserved.
  -- No implicit release, age expiry, or conversion of missing cost to zero.
end;
$$;
revoke all on function public.reserve_ai_spend(uuid,uuid,text,text,numeric) from public, anon, authenticated;
revoke all on function public.settle_ai_spend(uuid,uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.reserve_ai_spend(uuid,uuid,text,text,numeric) to service_role;
grant execute on function public.settle_ai_spend(uuid,uuid,numeric,text) to service_role;

-- This empty ledger prepares the new Mac beta budget. The period starts at the coordinated
-- guarded-code rollout after old paid work drains, not at login or this schema change alone.
-- Pre-beta development spend stays in its existing records, outside this ledger. No periodic reset.
