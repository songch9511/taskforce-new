-- Service-owned billing: clients may read their entitlement, never grant it.
create table public.billing_accounts (
 user_id uuid primary key references auth.users(id) on delete cascade,
 legacy_beta boolean not null default false,
 notice_ends_at timestamptz,
 onboarding_started_at timestamptz,
 trial_ends_at timestamptz,
 subscription_id text unique,
 customer_id text,
 order_id text,
 plan text check(plan in ('monthly','annual')),
 status text not null default 'none',
 current_period_ends_at timestamptz,
 provider_updated_at timestamptz,
 deleting_token uuid,
 deleting boolean not null default false
);
insert into public.billing_accounts(user_id,legacy_beta) select id,true from auth.users;
alter table public.billing_accounts enable row level security;
create policy owner_read on public.billing_accounts for select to authenticated using(user_id=auth.uid());
revoke all on public.billing_accounts from anon,authenticated;
grant select on public.billing_accounts to authenticated;
create table public.billing_checkout_intents (
 id uuid primary key default gen_random_uuid(),
 user_id uuid references auth.users(id) on delete set null,
 plan text not null check(plan in ('monthly','annual')),
 accepted_terms_version text not null,
 accepted_at timestamptz not null default now(),
 url text,
 expires_at timestamptz not null default now()+interval '1 hour',
 consumed_at timestamptz,
 created_at timestamptz not null default now()
);
create unique index billing_one_open_checkout on billing_checkout_intents(user_id) where consumed_at is null;
alter table public.billing_checkout_intents enable row level security;
revoke all on public.billing_checkout_intents from anon,authenticated;
create table public.billing_webhook_events (
 id text primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 processed_at timestamptz not null default now()
);
alter table public.billing_webhook_events enable row level security;
revoke all on public.billing_webhook_events from anon,authenticated;

create function public.billing_start_trial(p_user_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 insert into billing_accounts(user_id) values(p_user_id) on conflict do nothing;
 update billing_accounts set trial_ends_at=now()+interval '7 days'
 where user_id=p_user_id and trial_ends_at is null and not legacy_beta
 and not deleting;
end $$;

create function public.billing_apply_subscription(p_user_id uuid,p_event_id text,p_intent_id uuid,p_subscription_id text,p_customer_id text,p_plan text,p_status text,p_ends_at timestamptz,p_updated_at timestamptz)
returns void language plpgsql security definer set search_path=public as $$
declare account billing_accounts;
begin
 insert into billing_accounts(user_id) values(p_user_id) on conflict do nothing;
 select * into account from billing_accounts where user_id=p_user_id for update;
 if exists(select 1 from billing_webhook_events where id=p_event_id) then return; end if;
 if account.deleting and p_status not in ('cancelled','expired','refunded') then raise exception 'billing_account_deleting'; end if;
 if account.subscription_id is not null and account.subscription_id <> p_subscription_id and not (account.status='expired' and exists(select 1 from billing_checkout_intents where id=p_intent_id and user_id=p_user_id and plan=p_plan and consumed_at is null)) then raise exception 'billing_duplicate_subscription'; end if;
 if account.subscription_id is null and not exists(select 1 from billing_checkout_intents where id=p_intent_id and user_id=p_user_id and plan=p_plan) then raise exception 'billing_intent_missing'; end if;
 if account.provider_updated_at is null or p_updated_at >= account.provider_updated_at then
 update billing_accounts set subscription_id=p_subscription_id,customer_id=p_customer_id,plan=p_plan,status=p_status,current_period_ends_at=p_ends_at,provider_updated_at=p_updated_at where user_id=p_user_id;
 end if;
 update billing_checkout_intents set consumed_at=now() where id=p_intent_id and user_id=p_user_id and consumed_at is null
 and (account.subscription_id is null or account.subscription_id<>p_subscription_id);
 insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
end $$;
revoke all on function public.billing_start_trial(uuid) from public,anon,authenticated;
revoke all on function public.billing_apply_subscription(uuid,text,uuid,text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.billing_start_trial(uuid) to service_role;
grant execute on function public.billing_apply_subscription(uuid,text,uuid,text,text,text,text,timestamptz,timestamptz) to service_role;

-- Every endpoint shares the same reservation lock, including unresolved older charges.
create function public.billing_spend_window(p_user_id uuid,p_monthly_cap numeric,p_trial_cap numeric,p_initial_sync boolean default false)
returns table(cap numeric,starts_at timestamptz) language plpgsql stable security definer set search_path=public as $$
declare a billing_accounts;
begin
 if p_monthly_cap <= 0 or p_monthly_cap > 10 or p_trial_cap <= 0 or p_trial_cap > 10 then raise exception 'ai_invalid_budget'; end if;
 select * into a from billing_accounts where user_id=p_user_id;
 if not found or a.deleting then raise exception 'subscription_required'; end if;
 if a.status in ('active','cancelled') and a.current_period_ends_at > now() then
  return query select p_monthly_cap,date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
 elsif a.legacy_beta and (a.notice_ends_at is null or a.notice_ends_at > now()) then
  return query select 10::numeric,'-infinity'::timestamptz;
 elsif a.trial_ends_at > now() or (a.trial_ends_at is null and (a.onboarding_started_at is null or a.onboarding_started_at > now()-interval '1 day' or (p_initial_sync and a.subscription_id is null))) then
  return query select p_trial_cap,coalesce(a.onboarding_started_at,now());
 else raise exception 'subscription_required'; end if;
end $$;
create function public.reserve_billing_ai_spend(p_user_id uuid,p_id uuid,p_endpoint text,p_model text,p_reserved_usd numeric,p_monthly_cap numeric,p_trial_cap numeric,p_initial_sync boolean default false)
returns void language plpgsql security definer set search_path=public as $$
declare w record; v_total numeric;
begin
 if p_reserved_usd is null or p_reserved_usd<=0 or p_reserved_usd>10 then raise exception 'ai_invalid_reservation'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ai_spend:'||p_user_id::text,0));
 select * into w from billing_spend_window(p_user_id,p_monthly_cap,p_trial_cap,p_initial_sync);
 if exists(select 1 from ai_spend_attempts where user_id=p_user_id and cost_usd>reserved_usd) then raise exception 'ai_provider_bound_breached'; end if;
 select coalesce(sum(coalesce(cost_usd,reserved_usd)),0) into v_total from ai_spend_attempts where user_id=p_user_id and (created_at>=w.starts_at or cost_usd is null);
 if v_total+p_reserved_usd>w.cap then raise exception 'ai_budget_exhausted'; end if;
 insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd) values(p_id,p_user_id,p_endpoint,p_model,p_reserved_usd);
end $$;
create function public.billing_spend_summary(p_user_id uuid,p_monthly_cap numeric,p_trial_cap numeric)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare w record; result jsonb;
begin
 select * into w from billing_spend_window(p_user_id,p_monthly_cap,p_trial_cap);
 select jsonb_build_object('cap_usd',w.cap,'confirmed_usd',coalesce(sum(cost_usd) filter(where created_at>=w.starts_at),0),
 'reserved_usd',coalesce(sum(reserved_usd) filter(where cost_usd is null),0),'pending_count',count(*) filter(where cost_usd is null),
 'remaining_usd',greatest(0,w.cap-coalesce(sum(coalesce(cost_usd,reserved_usd)) filter(where created_at>=w.starts_at or cost_usd is null),0)),
 'status',case when coalesce(bool_or(cost_usd>reserved_usd),false) then 'provider_bound_violation' when coalesce(sum(coalesce(cost_usd,reserved_usd)) filter(where created_at>=w.starts_at or cost_usd is null),0)>=w.cap then 'exhausted' else 'available' end)
 into result from ai_spend_attempts where user_id=p_user_id;
 return result;
end $$;
revoke all on function public.billing_spend_window(uuid,numeric,numeric,boolean) from public,anon,authenticated;
revoke all on function public.reserve_billing_ai_spend(uuid,uuid,text,text,numeric,numeric,numeric,boolean) from public,anon,authenticated;
revoke all on function public.billing_spend_summary(uuid,numeric,numeric) from public,anon,authenticated;
grant execute on function public.billing_spend_window(uuid,numeric,numeric,boolean) to service_role;
grant execute on function public.reserve_billing_ai_spend(uuid,uuid,text,text,numeric,numeric,numeric,boolean) to service_role;
grant execute on function public.billing_spend_summary(uuid,numeric,numeric) to service_role;

create function public.billing_claim_checkout(p_user_id uuid,p_plan text,p_terms_version text)
returns billing_checkout_intents language plpgsql security definer set search_path=public as $$
declare a billing_accounts; intent billing_checkout_intents;
begin
 if p_terms_version is distinct from '2026-10-08' then raise exception 'billing_terms_required'; end if;
 select * into a from billing_accounts where user_id=p_user_id for update;
 if not found or a.deleting or (a.subscription_id is not null and a.status<>'expired') then raise exception 'billing_checkout_unavailable'; end if;
 update billing_checkout_intents set consumed_at=now() where user_id=p_user_id and consumed_at is null and expires_at<now();
 select * into intent from billing_checkout_intents where user_id=p_user_id and consumed_at is null;
 if found then
  if intent.plan<>p_plan or intent.url is null then raise exception 'billing_checkout_pending'; end if;
  return intent;
 end if;
 insert into billing_checkout_intents(user_id,plan,accepted_terms_version) values(p_user_id,p_plan,p_terms_version) returning * into intent;
 return intent;
end $$;
revoke all on function public.billing_claim_checkout(uuid,text,text) from public,anon,authenticated;
grant execute on function public.billing_claim_checkout(uuid,text,text) to service_role;

-- Keep only the random reference for delayed provider delivery after deletion.
create function public.billing_scrub_deleted_checkout() returns trigger language plpgsql set search_path=public as $$
begin
 if new.user_id is null then new.url=null; end if;
 return new;
end $$;
create trigger billing_scrub_deleted_checkout before update of user_id on public.billing_checkout_intents
for each row execute function public.billing_scrub_deleted_checkout();
create function public.purge_billing_checkout_intents() returns integer language plpgsql security definer set search_path=public as $$
declare removed integer;
begin
 delete from billing_checkout_intents where expires_at<now()-interval '7 days' and (user_id is null or consumed_at is not null);
 get diagnostics removed=row_count;
 return removed;
end $$;
revoke all on function public.billing_scrub_deleted_checkout() from public,anon,authenticated;
revoke all on function public.purge_billing_checkout_intents() from public,anon,authenticated;
grant execute on function public.purge_billing_checkout_intents() to service_role;

alter table public.sources drop constraint sources_processing_error_code_check;
alter table public.sources add constraint sources_processing_error_code_check check (
 processing_error_code in ('ai_quota','ai_timeout','ai_output','consent','expired','internal',
 'ai_budget_exhausted','ai_pricing_unavailable','ai_provider_bound_violation','ai_budget_unavailable','billing_required')
);

-- Sanitized provider routing metadata only; no raw payload or personal/card fields.
create table public.billing_webhook_inbox (
 id text primary key,
 event jsonb not null check(octet_length(event::text)<2048),
 next_attempt_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 processed_at timestamptz
);
alter table public.billing_webhook_inbox enable row level security;
revoke all on public.billing_webhook_inbox from anon,authenticated;
create index billing_webhook_pending on public.billing_webhook_inbox(next_attempt_at) where processed_at is null;
create or replace function public.purge_billing_checkout_intents() returns integer language plpgsql security definer set search_path=public as $$
declare removed integer;
begin
 delete from billing_webhook_inbox where created_at<now()-interval '7 days';
 delete from billing_checkout_intents where expires_at<now()-interval '7 days' and (user_id is null or consumed_at is not null);
 get diagnostics removed=row_count;
 return removed;
end $$;
