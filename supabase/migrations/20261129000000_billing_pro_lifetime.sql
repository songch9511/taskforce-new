-- Billing v2 (2026-10-09 pricing): Pro (card-required 3-day trial), Lifetime (one-time), 72-hour refund,
-- hidden per-account fair-use window, token usage, legacy beta conversion. Contract: handoffs/oa-billing-contract.md.
-- Review round 1 (contract ch.22) is folded in: this file is not applied anywhere yet, so it is edited in place.
-- Additive only: billing_start_trial, billing_apply_subscription, billing_spend_window, reserve_billing_ai_spend,
-- billing_spend_summary and billing_claim_checkout keep their signatures (old server processes and rollback).
-- New code calls only the *_v2 functions below. Every state transition writes its metric event inside the same
-- transaction that records the delivery digest, so redelivery never counts twice.

alter table public.billing_accounts
 add column first_subscription_at timestamptz,
 add column lifetime_order_id text unique,
 add column lifetime_status text check (lifetime_status in ('active','refunded','fraudulent')),
 add column lifetime_paid_at timestamptz,
 add column lifetime_updated_at timestamptz,
 add column last_payment_at timestamptz,
 add column last_invoice_id text,
 add column refund_requested_at timestamptz,
 add column self_refund_used_at timestamptz,
 add column last_swept_at timestamptz,
 add column sweep_claimed_at timestamptz,
 -- the intent a subscription was first bound through and what that intent offered at the time (contract ch.23)
 add column bound_intent_id uuid,
 add column bound_with_trial boolean,
 add column bound_with_discount boolean;

-- Subscription plans only; Lifetime lives in its own columns. plan CHECK on billing_accounts is unchanged.
alter table public.billing_checkout_intents drop constraint billing_checkout_intents_plan_check;
alter table public.billing_checkout_intents add constraint billing_checkout_intents_plan_check
 check(plan in ('monthly','annual','pro','lifetime'));
alter table public.billing_checkout_intents
 add column with_trial boolean not null default false,
 add column with_discount boolean not null default false,
 -- set once, at the first binding of a purchase to an account; a bound intent is never used for another subscription or order
 add column bound_subscription_id text,
 add column bound_order_id text;

alter table public.ai_spend_attempts
 add column prompt_tokens integer check(prompt_tokens>=0),
 add column completion_tokens integer check(completion_tokens>=0);

-- A client may see which attempts are its own but never what they cost: cost / reservation / token columns would let
-- anyone divide by the hidden fair-use cap. Owners keep RLS owner_read on the ownership columns only; the server reads everything.
revoke select on public.ai_spend_attempts from authenticated;
grant select (id,user_id,endpoint,model,created_at) on public.ai_spend_attempts to authenticated;

-- Metric events: the full list from 20261123000000_agent_path_leases.sql plus the billing / key events (contract ch.12).
-- The client insert policy there stays as is (app_opened, assistant_opened only).
alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
 check (type in (
  'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
  'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
  'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
  'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed',
  'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved',
  'billing_checkout_started', 'billing_trial_started', 'billing_subscription_activated', 'billing_payment_succeeded',
  'billing_payment_failed', 'billing_plan_changed', 'billing_subscription_cancelled', 'billing_subscription_resumed',
  'billing_subscription_ended', 'billing_lifetime_purchased', 'billing_refund_requested', 'billing_refunded',
  'billing_portal_opened', 'billing_duplicate_purchase', 'billing_review_needed', 'billing_legacy_marked', 'billing_notice_scheduled',
  'ai_key_saved', 'ai_key_deleted', 'ai_key_revoked'
 ));

-- Internal helpers: callable only from the SECURITY DEFINER functions below.
create function public.billing_emit(p_user_id uuid,p_type text,p_props jsonb default '{}'::jsonb)
returns void language sql security definer set search_path=public, pg_temp as $$
 insert into metric_events(user_id,type,props) values(p_user_id,p_type,coalesce(p_props,'{}'::jsonb));
$$;

-- Count an event once however many paths try (digest-style dedupe in the same transaction as the write that caused it).
create function public.billing_emit_once(p_user_id uuid,p_type text,p_props jsonb,p_dedupe_id text) returns boolean
language plpgsql security definer set search_path=public, pg_temp as $$
declare v_rows integer;
begin
 insert into billing_webhook_events(id,user_id) values(p_dedupe_id,p_user_id) on conflict do nothing;
 get diagnostics v_rows=row_count;
 if v_rows=0 then return false; end if;
 perform billing_emit(p_user_id,p_type,coalesce(p_props,'{}'::jsonb));
 return true;
end $$;

-- One definition of the entitlement state (mirrored by planState() in src/lib/billing/state.ts, parity-tested).
-- First matching row wins: deleting, lifetime, trial, pro, cancelled, past_due (16-day cap), beta, lapsed, none.
create function public.billing_plan_kind(a public.billing_accounts) returns text
language sql stable set search_path=public, pg_temp as $$
 select case
  when a.deleting then 'lapsed'
  when a.lifetime_status='active' then 'lifetime'
  when a.status='on_trial' and a.trial_ends_at>now() then 'trial'
  when a.status='active' and a.current_period_ends_at>now() then 'pro'
  when a.status='cancelled' and a.current_period_ends_at>now() then 'cancelled'
  when a.status in ('past_due','payment_pending') and a.current_period_ends_at is not null
   and now()<a.current_period_ends_at+interval '16 days' then 'past_due'
  when a.legacy_beta and (a.notice_ends_at is null or a.notice_ends_at>now()) then 'beta'
  when a.subscription_id is not null or a.lifetime_status is not null then 'lapsed'
  else 'none' end
$$;

-- A subscription that can no longer bill: a replacement purchase is allowed. A past_due subscription past its
-- grace period is NOT ended: LS may still recover or expire it.
create function public.billing_sub_ended(a public.billing_accounts) returns boolean
language sql stable set search_path=public, pg_temp as $$
 select a.subscription_id is null
  or a.status in ('expired','refunded','unpaid','paused')
  or (a.status='cancelled' and coalesce(a.current_period_ends_at,'-infinity'::timestamptz)<=now())
  or (a.status='payment_pending' and a.current_period_ends_at is null)
$$;

-- ── checkout ──────────────────────────────────────────────────────────────
create function public.billing_claim_checkout_v2(p_user_id uuid,p_plan text,p_terms_version text)
returns billing_checkout_intents language plpgsql security definer set search_path=public, pg_temp as $$
declare a billing_accounts; intent billing_checkout_intents; v_kind text; v_first boolean;
begin
 if p_plan is null or p_plan not in ('pro','lifetime') then raise exception 'billing_plan_invalid'; end if;
 -- The accepted version is checked against the single current value in src/lib/billing/prices.ts; the database
 -- insists on an explicit ISO date so a missing value can never be recorded as consent.
 if p_terms_version is null or p_terms_version !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'billing_terms_required'; end if;
 select * into a from billing_accounts where user_id=p_user_id for update;
 if not found or a.deleting or a.lifetime_status='active' then raise exception 'billing_checkout_unavailable'; end if;
 v_kind:=billing_plan_kind(a);
 if p_plan='pro' then
  if not billing_sub_ended(a) then raise exception 'billing_checkout_unavailable'; end if;
 else
  -- Lifetime while Pro is trialing, paying or recovering would bill twice; a cancelled Pro may still buy it.
  if v_kind in ('trial','pro','past_due') or (v_kind<>'cancelled' and not billing_sub_ended(a)) then raise exception 'billing_checkout_unavailable'; end if;
 end if;
 update billing_checkout_intents set consumed_at=now() where user_id=p_user_id and consumed_at is null and expires_at<now();
 select * into intent from billing_checkout_intents where user_id=p_user_id and consumed_at is null;
 if found then
  if intent.plan<>p_plan or intent.url is null then raise exception 'billing_checkout_pending'; end if;
  return intent;
 end if;
 -- Trial and first-month discount are offered once per account, decided here under the account lock.
 v_first:=p_plan='pro' and a.first_subscription_at is null;
 insert into billing_checkout_intents(user_id,plan,accepted_terms_version,with_trial,with_discount)
 values(p_user_id,p_plan,p_terms_version,v_first,v_first) returning * into intent;
 return intent;
end $$;

create function public.billing_checkout_url_v2(p_user_id uuid,p_intent_id uuid,p_url text)
returns boolean language plpgsql security definer set search_path=public, pg_temp as $$
declare i billing_checkout_intents;
begin
 update billing_checkout_intents set url=p_url where id=p_intent_id and user_id=p_user_id and url is null and consumed_at is null returning * into i;
 if not found then return false; end if;
 perform billing_emit(p_user_id,'billing_checkout_started',jsonb_build_object('plan',i.plan,'with_trial',i.with_trial,'with_discount',i.with_discount));
 return true;
end $$;

-- ── subscription entitlement ──────────────────────────────────────────────
create function public.billing_apply_subscription_v2(p_user_id uuid,p_event_id text,p_intent_id uuid,p_subscription_id text,p_customer_id text,
 p_status text,p_ends_at timestamptz,p_updated_at timestamptz,p_trial_ends_at timestamptz,p_payment_at timestamptz,p_invoice_id text,
 p_order_id text,p_variant_plan text,p_discounted boolean default false)
returns text language plpgsql security definer set search_path=public, pg_temp as $$
declare a billing_accounts; i billing_checkout_intents; same boolean; v_period timestamptz; v_trial timestamptz; v_pay timestamptz; v_inv text; v_props jsonb; v_clear text; v_review text; v_other boolean;
begin
 if p_variant_plan is null or p_variant_plan not in ('monthly','annual') then raise exception 'billing_plan_invalid'; end if;
 if p_status is null or p_status not in ('on_trial','active','paused','past_due','unpaid','cancelled','expired','payment_pending','refunded') then
  raise exception 'billing_status_invalid'; end if;
 insert into billing_accounts(user_id) values(p_user_id) on conflict do nothing;
 select * into a from billing_accounts where user_id=p_user_id for update;
 -- A subscription flagged below stays out for good, whatever its later deliveries say (the retry of the rejected delivery included:
 -- the caller cancels the provider subscription again if its first cancel failed).
 if exists(select 1 from billing_webhook_events where id='violation:'||p_subscription_id) then
  insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id) on conflict do nothing;
  return 'rejected_known';
 end if;
 if exists(select 1 from billing_webhook_events where id=p_event_id) then return 'replay'; end if;
 if a.deleting and p_status not in ('cancelled','expired','refunded') then raise exception 'billing_account_deleting'; end if;
 -- Lifetime wins (contract 5.2): a live Pro must not be recorded next to it. The caller cancels it in LS.
 if a.lifetime_status='active' and p_status in ('on_trial','active','past_due','payment_pending') then raise exception 'billing_lifetime_active'; end if;
 same:=a.subscription_id is not distinct from p_subscription_id and a.subscription_id is not null;
 select * into i from billing_checkout_intents where id=p_intent_id and plan='pro';
 -- Violations are judged ONCE, when a purchase is first bound to an account (contract ch.23). The buyer controls the reference, so
 -- the intent that was really issued for this account decides what that purchase may contain. After that the stored binding is the
 -- only record: a re-read without a reference (sweep, queued re-read) or a later delivery of the same subscription never creates a
 -- violation and never gets a legitimate customer cancelled; entitlement follows the payment facts.
 if same then
  -- first payment of a bound trial: discounted although the intent that was bound did not offer the first-month code
  if p_discounted and p_payment_at is not null and a.last_invoice_id is null and a.bound_with_discount is false then v_review:='discount_not_offered'; end if;
 else
  if a.subscription_id is not null then
   if not billing_sub_ended(a) or not found then raise exception 'billing_duplicate_subscription'; end if;
  elsif not found then
   raise exception 'billing_intent_missing';
  end if;
  v_other:=i.bound_order_id is not null or (i.bound_subscription_id is not null and i.bound_subscription_id<>p_subscription_id);
  -- clear tampering at the first binding: cancelled at the provider and sent to review. The server never issues a link that could
  -- legitimately lead here (a trial or a first-month price on an intent that was already used, or for an account that already subscribed)
  if i.user_id is distinct from p_user_id then v_clear:='other_user_intent';
  elsif p_status='on_trial' and not i.with_trial then v_clear:='trial_not_offered';
  elsif p_discounted and p_payment_at is not null and not i.with_discount then v_clear:='discount_not_offered';
  elsif p_status='on_trial' and (a.first_subscription_at is not null or v_other) then v_clear:='trial_reused';
  elsif p_discounted and p_payment_at is not null and v_other then v_clear:='discount_reused';
  -- anything else that looks odd is reviewed by a person; the payment is real, so the entitlement follows it
  elsif v_other then v_review:='intent_bound_elsewhere';
  elsif i.url is null then v_review:='intent_not_issued';
  end if;
 end if;
 if v_clear is not null then
  insert into billing_webhook_events(id,user_id) values('violation:'||p_subscription_id,p_user_id) on conflict do nothing;
  insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
  perform billing_emit(p_user_id,'billing_duplicate_purchase',jsonb_build_object('plan',p_variant_plan));
  return 'rejected';
 end if;
 if not same or a.provider_updated_at is null or p_updated_at>=a.provider_updated_at then
  if v_review is not null then
   perform billing_emit(p_user_id,'billing_review_needed',jsonb_build_object('plan',p_variant_plan,'reason',v_review));
  end if;
  -- Only a confirmed paid period grants time. past_due / payment_pending keep the last paid period; its 16-day grace
  -- is computed from it. A new subscription never inherits the previous one's period, payment or trial.
  v_period:=case
   when p_status in ('active','cancelled') then p_ends_at
   when p_status in ('past_due','payment_pending') and same then a.current_period_ends_at
   else null end;
  v_trial:=case when p_trial_ends_at is not null then p_trial_ends_at when same then a.trial_ends_at else null end;
  v_pay:=case when same then a.last_payment_at end;
  v_inv:=case when same then a.last_invoice_id end;
  if p_payment_at is not null and (v_pay is null or p_payment_at>=v_pay) then v_pay:=p_payment_at; v_inv:=p_invoice_id; end if;
  update billing_accounts set subscription_id=p_subscription_id,customer_id=p_customer_id,plan=p_variant_plan,status=p_status,
   current_period_ends_at=v_period,trial_ends_at=v_trial,provider_updated_at=p_updated_at,order_id=coalesce(p_order_id,a.order_id),
   first_subscription_at=coalesce(a.first_subscription_at,now()),last_payment_at=v_pay,last_invoice_id=v_inv,
   bound_intent_id=case when same then a.bound_intent_id else p_intent_id end,
   bound_with_trial=case when same then a.bound_with_trial else i.with_trial end,
   bound_with_discount=case when same then a.bound_with_discount else i.with_discount end,
   refund_requested_at=case when p_status='refunded' then null else a.refund_requested_at end
  where user_id=p_user_id;
  v_props:=jsonb_build_object('plan',p_variant_plan);
  if p_status='on_trial' and not same then perform billing_emit(p_user_id,'billing_trial_started',v_props); end if;
  if p_status='active' and p_payment_at is not null then
   if not same or a.last_invoice_id is null then
    perform billing_emit(p_user_id,'billing_subscription_activated',v_props||jsonb_build_object('after_trial',same and (a.status='on_trial' or a.trial_ends_at is not null)));
   elsif a.last_invoice_id is distinct from p_invoice_id then
    perform billing_emit(p_user_id,'billing_payment_succeeded',jsonb_build_object('kind',case when a.status in ('past_due','payment_pending') then 'recovered' else 'renewal' end));
   end if;
  end if;
  if p_status='past_due' and (not same or a.status is distinct from 'past_due') then perform billing_emit(p_user_id,'billing_payment_failed',v_props); end if;
  if p_status='cancelled' and (not same or a.status is distinct from 'cancelled') then perform billing_emit(p_user_id,'billing_subscription_cancelled',jsonb_build_object('by','user')); end if;
  if p_status='active' and same and a.status='cancelled' then perform billing_emit(p_user_id,'billing_subscription_resumed','{}'::jsonb); end if;
  if p_status in ('expired','unpaid','paused') and (not same or a.status is distinct from p_status) then
   perform billing_emit(p_user_id,'billing_subscription_ended',jsonb_build_object('reason',p_status)); end if;
  if p_status='refunded' and (not same or a.status is distinct from 'refunded') then
   perform billing_emit(p_user_id,'billing_refunded',v_props);
   perform billing_emit(p_user_id,'billing_subscription_ended',jsonb_build_object('reason','refunded'));
   -- The request path writes this event under the same key; whichever of the two comes first, it is counted once (an API success
   -- whose own write was lost still shows up here, at the provider's confirmation).
   if a.refund_requested_at is not null then
    perform billing_emit_once(p_user_id,'billing_refund_requested',v_props,'refund-requested:'||p_user_id::text||':'||extract(epoch from a.refund_requested_at)::text);
   end if;
  end if;
  if same and a.plan is not null and a.plan<>p_variant_plan then
   perform billing_emit(p_user_id,'billing_plan_changed',jsonb_build_object('from',a.plan,'to',p_variant_plan)); end if;
 end if;
 if not same then
  update billing_checkout_intents set consumed_at=coalesce(consumed_at,now()),bound_subscription_id=coalesce(bound_subscription_id,p_subscription_id)
  where id=p_intent_id and user_id=p_user_id;
 end if;
 insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
 return 'applied';
end $$;

-- ── lifetime entitlement ──────────────────────────────────────────────────
-- Returns applied | stale | duplicate | replay. A second paid order keeps the entitlement and is flagged for review.
create function public.billing_apply_lifetime(p_user_id uuid,p_event_id text,p_intent_id uuid,p_order_id text,p_customer_id text,
 p_status text,p_paid_at timestamptz,p_updated_at timestamptz)
returns text language plpgsql security definer set search_path=public, pg_temp as $$
declare a billing_accounts;
begin
 if p_status is null or p_status not in ('active','refunded','fraudulent') then raise exception 'billing_status_invalid'; end if;
 insert into billing_accounts(user_id) values(p_user_id) on conflict do nothing;
 select * into a from billing_accounts where user_id=p_user_id for update;
 if exists(select 1 from billing_webhook_events where id=p_event_id) then return 'replay'; end if;
 if p_status='active' then
  if a.deleting then raise exception 'billing_account_deleting'; end if;
  -- A refunded or fraudulent order is final: a paid snapshot delivered late never opens it again, whatever clock it carries.
  if a.lifetime_order_id is not distinct from p_order_id and a.lifetime_status in ('refunded','fraudulent') then
   insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
   return 'stale';
  end if;
  if a.lifetime_status='active' and a.lifetime_order_id is distinct from p_order_id then
   insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
   perform billing_emit(p_user_id,'billing_duplicate_purchase',jsonb_build_object('plan','lifetime'));
   return 'duplicate';
  end if;
  if a.lifetime_order_id is distinct from p_order_id
   and not exists(select 1 from billing_checkout_intents where id=p_intent_id and user_id=p_user_id and plan='lifetime' and url is not null) then
   raise exception 'billing_intent_missing'; end if;
 elsif a.lifetime_order_id is distinct from p_order_id then
  -- The refund of an order that is not the entitlement never touches the entitlement.
  if a.lifetime_status='active' then
   insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
   return 'stale';
  end if;
  -- The refund can overtake the first paid snapshot: bind the order to the account through the intent that was issued for it and
  -- store the final state, so that the late paid snapshot finds a closed order.
  if not exists(select 1 from billing_checkout_intents where id=p_intent_id and user_id=p_user_id and plan='lifetime' and url is not null) then
   raise exception 'billing_order_unknown'; end if;
  update billing_accounts set lifetime_order_id=p_order_id,lifetime_status=p_status,lifetime_paid_at=p_paid_at,lifetime_updated_at=p_updated_at,
   customer_id=coalesce(a.customer_id,p_customer_id) where user_id=p_user_id;
  update billing_checkout_intents set consumed_at=coalesce(consumed_at,now()),bound_order_id=coalesce(bound_order_id,p_order_id) where id=p_intent_id and user_id=p_user_id;
  insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
  return 'applied';
 end if;
 if a.lifetime_updated_at is not null and p_updated_at<a.lifetime_updated_at then
  insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
  return 'stale';
 end if;
 if p_status='active' then
  update billing_accounts set lifetime_order_id=p_order_id,lifetime_status='active',lifetime_paid_at=p_paid_at,lifetime_updated_at=p_updated_at,
   customer_id=coalesce(a.customer_id,p_customer_id) where user_id=p_user_id;
  if a.lifetime_status is distinct from 'active' or a.lifetime_order_id is distinct from p_order_id then
   perform billing_emit(p_user_id,'billing_lifetime_purchased','{}'::jsonb); end if;
  if a.lifetime_order_id is distinct from p_order_id then
   -- first binding of this order: an intent that already carries another order is odd (a stale link used again) but the payment is real
   if exists(select 1 from billing_checkout_intents where id=p_intent_id and bound_order_id is not null and bound_order_id<>p_order_id) then
    perform billing_emit(p_user_id,'billing_review_needed',jsonb_build_object('plan','lifetime','reason','intent_bound_elsewhere')); end if;
   update billing_checkout_intents set consumed_at=coalesce(consumed_at,now()),bound_order_id=coalesce(bound_order_id,p_order_id) where id=p_intent_id and user_id=p_user_id;
  end if;
 else
  update billing_accounts set lifetime_status=p_status,lifetime_updated_at=p_updated_at,refund_requested_at=null where user_id=p_user_id;
  if a.lifetime_status='active' and p_status='refunded' then
   perform billing_emit(p_user_id,'billing_refunded',jsonb_build_object('plan','lifetime'));
   if a.refund_requested_at is not null then
    perform billing_emit_once(p_user_id,'billing_refund_requested',jsonb_build_object('plan','lifetime'),'refund-requested:'||p_user_id::text||':'||extract(epoch from a.refund_requested_at)::text);
   end if;
  end if;
  -- The stored OpenRouter key is useless after the entitlement ends (BL-20). The key table arrives with the BYOK migration.
  if to_regclass('public.user_ai_keys') is not null then execute 'delete from public.user_ai_keys where user_id=$1' using p_user_id; end if;
 end if;
 insert into billing_webhook_events(id,user_id) values(p_event_id,p_user_id);
 return 'applied';
end $$;

-- Metric-only writes from the server (portal, refund request, system cancel, duplicate). p_dedupe_id makes a retry count once.
create function public.billing_record_event(p_user_id uuid,p_type text,p_props jsonb default '{}'::jsonb,p_dedupe_id text default null)
returns boolean language plpgsql security definer set search_path=public, pg_temp as $$
begin
 if p_type is null or p_type not in ('billing_portal_opened','billing_refund_requested','billing_subscription_cancelled','billing_duplicate_purchase') then
  raise exception 'billing_event_not_allowed'; end if;
 if p_props is null or jsonb_typeof(p_props)<>'object' then raise exception 'billing_event_invalid'; end if;
 if p_dedupe_id is not null then return billing_emit_once(p_user_id,p_type,p_props,p_dedupe_id); end if;
 perform billing_emit(p_user_id,p_type,p_props);
 return true;
end $$;

-- ── refund (72 hours from the paid invoice / order, one self-service per account) ──
create function public.billing_claim_refund(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path=public, pg_temp as $$
declare a billing_accounts; v_result jsonb;
begin
 select * into a from billing_accounts where user_id=p_user_id for update;
 if not found or a.deleting then raise exception 'billing_refund_unavailable'; end if;
 if a.refund_requested_at is not null then raise exception 'billing_refund_pending'; end if;
 if a.self_refund_used_at is not null then raise exception 'billing_refund_used'; end if;
 if a.lifetime_status='active' and a.lifetime_order_id is not null and a.lifetime_paid_at>now()-interval '72 hours' then
  v_result:=jsonb_build_object('kind','lifetime','order_id',a.lifetime_order_id);
 elsif a.subscription_id is not null and a.last_invoice_id is not null and a.last_payment_at>now()-interval '72 hours'
  and a.status in ('active','cancelled','past_due','payment_pending') then
  v_result:=jsonb_build_object('kind','subscription','subscription_id',a.subscription_id,'invoice_id',a.last_invoice_id,'plan',a.plan);
 else raise exception 'billing_refund_window_closed'; end if;
 update billing_accounts set refund_requested_at=now(),self_refund_used_at=now() where user_id=p_user_id;
 -- claim_key names this very request in the event ledger (the request path and the confirmation path write the same key)
 return v_result||jsonb_build_object('claim_key','refund-requested:'||p_user_id::text||':'||extract(epoch from now())::text);
end $$;

-- Give a claim back. p_clear_used = true only when the provider was never asked (a refusal before the refund call): the one
-- self-service use then returns too. Anything that may have reached the provider keeps the use spent; the outcome is settled by
-- re-reading the provider, and a request that never turns into a refund is released here without clearing the use.
create function public.billing_release_refund(p_user_id uuid,p_clear_used boolean) returns boolean
language plpgsql security definer set search_path=public, pg_temp as $$
declare v_rows integer;
begin
 update billing_accounts set refund_requested_at=null,self_refund_used_at=case when p_clear_used then null else self_refund_used_at end
 where user_id=p_user_id and refund_requested_at is not null;
 get diagnostics v_rows=row_count;
 return v_rows>0;
end $$;

-- ── retired spend window: a Lifetime account never reserves managed cost, not even through a rollback to the old reservation ──
create or replace function public.billing_spend_window(p_user_id uuid,p_monthly_cap numeric,p_trial_cap numeric,p_initial_sync boolean default false)
returns table(cap numeric,starts_at timestamptz) language plpgsql stable security definer set search_path=public, pg_temp as $$
declare a billing_accounts;
begin
 if p_monthly_cap <= 0 or p_monthly_cap > 10 or p_trial_cap <= 0 or p_trial_cap > 10 then raise exception 'ai_invalid_budget'; end if;
 select * into a from billing_accounts where user_id=p_user_id;
 if not found or a.deleting then raise exception 'subscription_required'; end if;
 if a.lifetime_status='active' then raise exception 'byok_required'; end if;
 if a.status in ('active','cancelled') and a.current_period_ends_at > now() then
  return query select p_monthly_cap,date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
 elsif a.legacy_beta and (a.notice_ends_at is null or a.notice_ends_at > now()) then
  return query select 10::numeric,'-infinity'::timestamptz;
 elsif a.subscription_id is null and (a.trial_ends_at > now() or (a.trial_ends_at is null and (a.onboarding_started_at is null or a.onboarding_started_at > now()-interval '1 day' or p_initial_sync))) then
  return query select p_trial_cap,coalesce(a.onboarding_started_at,now());
 else raise exception 'subscription_required'; end if;
end $$;

-- ── hidden fair-use window and reservations ──────────────────────────────
create function public.billing_spend_window_v2(p_user_id uuid,p_monthly_cap numeric,p_trial_cap numeric)
returns table(cap numeric,starts_at timestamptz,kind text) language plpgsql stable security definer set search_path=public, pg_temp as $$
declare a billing_accounts; v_kind text;
begin
 if p_monthly_cap is null or p_trial_cap is null or p_monthly_cap<=0 or p_monthly_cap>100 or p_trial_cap<=0 or p_trial_cap>100 then raise exception 'ai_invalid_budget'; end if;
 select * into a from billing_accounts where user_id=p_user_id;
 if not found then raise exception 'subscription_required'; end if;
 v_kind:=billing_plan_kind(a);
 if v_kind='trial' then
  return query select p_trial_cap,coalesce(a.first_subscription_at,now()),v_kind;
 elsif v_kind in ('pro','cancelled','past_due') then
  if a.last_payment_at is null then
   -- cancelled during the free trial: still the trial allowance, never the paid one
   return query select p_trial_cap,coalesce(a.first_subscription_at,now()),v_kind;
  else
   return query select p_monthly_cap,date_trunc('month',now() at time zone 'UTC') at time zone 'UTC',v_kind;
  end if;
 elsif v_kind='beta' then
  return query select 10::numeric,'-infinity'::timestamptz,v_kind;
 elsif v_kind='lifetime' then
  -- Managed-key cost can never be reserved for a Lifetime account (I15); its calls use the owner's own key.
  raise exception 'byok_required';
 else raise exception 'subscription_required'; end if;
end $$;

create function public.reserve_billing_ai_spend_v2(p_user_id uuid,p_id uuid,p_endpoint text,p_model text,p_reserved_usd numeric,p_monthly_cap numeric,p_trial_cap numeric)
returns void language plpgsql security definer set search_path=public, pg_temp as $$
declare w record; v_total numeric; v_policy ai_budget_policy; v_global_total numeric; v_global_daily numeric;
 v_day timestamptz := date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
begin
 if p_reserved_usd is null or p_reserved_usd<=0 or p_reserved_usd>10 then raise exception 'ai_invalid_reservation'; end if;
 perform pg_advisory_xact_lock(hashtextextended('ai_spend:global',0));
 perform pg_advisory_xact_lock(hashtextextended('ai_spend:'||p_user_id::text,0));
 -- Wait for an in-flight entitlement change (e.g. a Lifetime purchase) so a reservation never straddles it.
 perform 1 from billing_accounts where user_id=p_user_id for share;
 select * into w from billing_spend_window_v2(p_user_id,p_monthly_cap,p_trial_cap);
 if w.kind='beta' then
  perform reserve_ai_spend(p_user_id,p_id,p_endpoint,p_model,p_reserved_usd);
  return;
 end if;
 select * into v_policy from ai_budget_policy where singleton for share;
 if not found then raise exception 'ai_budget_policy_unavailable'; end if;
 if exists(select 1 from ai_spend_attempts where user_id=p_user_id and cost_usd>reserved_usd) then raise exception 'ai_provider_bound_breached'; end if;
 select coalesce(sum(coalesce(cost_usd,reserved_usd)),0) into v_total from ai_spend_attempts where user_id=p_user_id and (created_at>=w.starts_at or cost_usd is null);
 if v_total+p_reserved_usd>w.cap then raise exception 'ai_budget_exhausted'; end if;
 select coalesce(sum(coalesce(cost_usd,reserved_usd)),0),
  coalesce(sum(coalesce(cost_usd,reserved_usd)) filter(where cost_usd is null or created_at>=v_day),0)
 into v_global_total,v_global_daily from ai_spend_attempts;
 if v_global_total+p_reserved_usd>v_policy.global_total_usd then raise exception 'ai_global_budget_exhausted'; end if;
 if v_global_daily+p_reserved_usd>v_policy.global_daily_usd then raise exception 'ai_global_daily_budget_exhausted'; end if;
 insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd) values(p_id,p_user_id,p_endpoint,p_model,p_reserved_usd);
end $$;

-- Server-side only: the cap is never shown to the client. status exhausted means "paused until the next UTC month".
create function public.billing_spend_summary_v2(p_user_id uuid,p_monthly_cap numeric,p_trial_cap numeric)
returns jsonb language plpgsql stable security definer set search_path=public, pg_temp as $$
declare w record; result jsonb;
begin
 select * into w from billing_spend_window_v2(p_user_id,p_monthly_cap,p_trial_cap);
 if w.kind='beta' then return ai_spend_summary(p_user_id); end if;
 select jsonb_build_object('cap_usd',w.cap,'confirmed_usd',coalesce(sum(cost_usd) filter(where created_at>=w.starts_at),0),
  'reserved_usd',coalesce(sum(reserved_usd) filter(where cost_usd is null),0),'pending_count',count(*) filter(where cost_usd is null),
  'remaining_usd',greatest(0,w.cap-coalesce(sum(coalesce(cost_usd,reserved_usd)) filter(where created_at>=w.starts_at or cost_usd is null),0)),
  'status',case when coalesce(bool_or(cost_usd>reserved_usd),false) then 'provider_bound_violation'
   when coalesce(sum(coalesce(cost_usd,reserved_usd)) filter(where created_at>=w.starts_at or cost_usd is null),0)>=w.cap then 'exhausted' else 'available' end)
 into result from ai_spend_attempts where user_id=p_user_id;
 return result;
end $$;

-- ── token usage (reference value for the plan screen, never a limit) ─────
create function public.record_ai_spend_tokens(p_user_id uuid,p_id uuid,p_prompt_tokens integer,p_completion_tokens integer)
returns void language plpgsql security definer set search_path=public, pg_temp as $$
begin
 if p_prompt_tokens is null or p_completion_tokens is null or p_prompt_tokens<0 or p_completion_tokens<0 then raise exception 'ai_invalid_tokens'; end if;
 update ai_spend_attempts set prompt_tokens=p_prompt_tokens,completion_tokens=p_completion_tokens
 where id=p_id and user_id=p_user_id and prompt_tokens is null;
end $$;

create function public.billing_usage_tokens(p_user_id uuid,p_since timestamptz) returns jsonb
language sql stable security definer set search_path=public, pg_temp as $$
 select jsonb_build_object('prompt_tokens',coalesce(sum(prompt_tokens),0),'completion_tokens',coalesce(sum(completion_tokens),0))
 from ai_spend_attempts where user_id=p_user_id and created_at>=p_since;
$$;

-- ── missed-event sweep (cron) ───────────────────────────────────────────
-- Claiming is not completing. A claim leases the account for 5 minutes (overlapping cron runs never repeat it); only
-- billing_sweep_done(ok) stamps it as swept for the day. An account the run skipped (deadline) or that failed is therefore due again
-- on a later run, also at the edge of the 72-hour refund window; a failure backs off for an hour.
-- Covers trial / cancelled / past_due accounts, an active plan about to run out (a lost renewal delivery would lock out a paying
-- customer), a Lifetime inside its refund window, refund claims that never resolved, and a refunded subscription for 35 days
-- (the provider cancel after a refund may have failed, and a renewal would bill again).
create function public.billing_sweep_claim(p_limit integer) returns table(user_id uuid,subscription_id text,lifetime_order_id text,refund_stale boolean)
language plpgsql security definer set search_path=public, pg_temp as $$
begin
 return query
 with picked as (
  select b.user_id from billing_accounts b
  where not b.deleting
   and (b.sweep_claimed_at is null or b.sweep_claimed_at<now()-interval '5 minutes')
   and (b.last_swept_at is null or b.last_swept_at<now()-interval '1 day'
    or b.sweep_claimed_at is not null
    or (b.refund_requested_at<now()-interval '1 hour' and b.last_swept_at<now()-interval '30 minutes'))
   and ((b.subscription_id is not null and (b.status in ('on_trial','cancelled','past_due','payment_pending')
     or (b.status='active' and b.current_period_ends_at<now()+interval '1 day')
     or (b.status='refunded' and b.provider_updated_at>now()-interval '35 days')))
    or (b.lifetime_status='active' and b.lifetime_paid_at>now()-interval '72 hours')
    -- a claim nobody finished stays a candidate whatever the clock says (a Lifetime claimed at 71h59 and cut off by the deadline)
    or b.sweep_claimed_at is not null
    or b.refund_requested_at<now()-interval '1 hour')
  order by b.last_swept_at nulls first,b.user_id
  limit greatest(0,least(coalesce(p_limit,20),100))
  for update skip locked
 )
 update billing_accounts t set sweep_claimed_at=now() from picked
 where t.user_id=picked.user_id
 returning t.user_id,t.subscription_id,t.lifetime_order_id,coalesce(t.refund_requested_at<now()-interval '1 hour',false);
end $$;

create function public.billing_sweep_done(p_user_id uuid,p_ok boolean) returns void
language sql security definer set search_path=public, pg_temp as $$
 update billing_accounts set last_swept_at=case when p_ok then now() else last_swept_at end,
  sweep_claimed_at=case when p_ok then null else now()+interval '55 minutes' end
 where user_id=p_user_id;
$$;

-- ── legacy beta conversion (run once right before BILLING_ENABLED=true) ───
-- Why an agent message could not start (contract ch.23): the stored reason write_gate_closed is shared with the execution kill switch, so the
-- billing block is written on the message itself and the reading side shows billing_required only for a message that carries it.
create function public.billing_mark_agent_block(p_user_id uuid,p_message_id uuid,p_blocked boolean) returns boolean
language plpgsql security definer set search_path=public, pg_temp as $$
declare v_rows integer;
begin
 -- set: only on a message that is stopped by the shared gate reason; clear: whatever its state is now (a requeued message must not keep a stale mark)
 update conversation_messages
  set refs=case when p_blocked then refs||jsonb_build_object('blocked_by','billing') else refs-'blocked_by' end
 where id=p_message_id and user_id=p_user_id and role='user'
  and ((p_blocked and delivery_state='not_sent' and delivery_reason='write_gate_closed' and not (refs ? 'blocked_by'))
   or (not p_blocked and refs ? 'blocked_by'));
 get diagnostics v_rows=row_count;
 return v_rows>0;
end $$;

create function public.billing_seed_legacy(p_cutoff timestamptz) returns integer
language plpgsql security definer set search_path=public, pg_temp as $$
declare n integer; v_notice timestamptz;
begin
 if p_cutoff is null then raise exception 'billing_cutoff_required'; end if;
 if p_cutoff>now() then raise exception 'billing_cutoff_future'; end if;
 -- Order of operations is seed first, notify second. An account seeded after a notice already went out still gets at least 30 days
 -- from its own seeding (and never less than the date everyone else was promised), so no beta stays open-ended.
 select max(notice_ends_at) into v_notice from billing_accounts where legacy_beta and notice_ends_at is not null;
 -- Accounts created before the cutoff that never bought anything become legacy beta (free until the notice ends).
 with marked as (
  insert into billing_accounts(user_id,legacy_beta,notice_ends_at)
  select u.id,true,case when v_notice is null then null else greatest(v_notice,now()+interval '30 days') end from auth.users u where u.created_at<p_cutoff
  on conflict (user_id) do update set legacy_beta=true,notice_ends_at=excluded.notice_ends_at
   where billing_accounts.legacy_beta=false and billing_accounts.subscription_id is null
    and billing_accounts.lifetime_status is null and billing_accounts.deleting=false
  returning user_id
 ), ev as (
  insert into metric_events(user_id,type,props) select user_id,'billing_legacy_marked','{}'::jsonb from marked returning 1
 )
 select count(*) into n from marked;
 return n;
end $$;

-- The 30-day promise of the public terms is enforced here, not by the caller.
create function public.billing_schedule_legacy_notice(p_ends_at timestamptz) returns integer
language plpgsql security definer set search_path=public, pg_temp as $$
declare n integer;
begin
 if p_ends_at is null or p_ends_at<now()+interval '30 days' then raise exception 'billing_notice_too_soon'; end if;
 with scheduled as (
  update billing_accounts set notice_ends_at=p_ends_at where legacy_beta and notice_ends_at is null and not deleting returning user_id
 ), ev as (
  insert into metric_events(user_id,type,props) select user_id,'billing_notice_scheduled','{}'::jsonb from scheduled returning 1
 )
 select count(*) into n from scheduled;
 return n;
end $$;

-- Privileges: service role only. Internal helpers are not callable by any API role.
revoke all on function public.billing_emit(uuid,text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.billing_emit_once(uuid,text,jsonb,text) from public,anon,authenticated,service_role;
revoke all on function public.billing_plan_kind(public.billing_accounts) from public,anon,authenticated,service_role;
revoke all on function public.billing_sub_ended(public.billing_accounts) from public,anon,authenticated,service_role;
revoke all on function public.billing_claim_checkout_v2(uuid,text,text) from public,anon,authenticated;
revoke all on function public.billing_checkout_url_v2(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.billing_apply_subscription_v2(uuid,text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,timestamptz,text,text,text,boolean) from public,anon,authenticated;
revoke all on function public.billing_apply_lifetime(uuid,text,uuid,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function public.billing_record_event(uuid,text,jsonb,text) from public,anon,authenticated;
revoke all on function public.billing_claim_refund(uuid) from public,anon,authenticated;
revoke all on function public.billing_release_refund(uuid,boolean) from public,anon,authenticated;
revoke all on function public.billing_spend_window_v2(uuid,numeric,numeric) from public,anon,authenticated;
revoke all on function public.reserve_billing_ai_spend_v2(uuid,uuid,text,text,numeric,numeric,numeric) from public,anon,authenticated;
revoke all on function public.billing_spend_summary_v2(uuid,numeric,numeric) from public,anon,authenticated;
revoke all on function public.record_ai_spend_tokens(uuid,uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.billing_usage_tokens(uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.billing_sweep_claim(integer) from public,anon,authenticated;
revoke all on function public.billing_sweep_done(uuid,boolean) from public,anon,authenticated;
revoke all on function public.billing_mark_agent_block(uuid,uuid,boolean) from public,anon,authenticated;
revoke all on function public.billing_seed_legacy(timestamptz) from public,anon,authenticated;
revoke all on function public.billing_schedule_legacy_notice(timestamptz) from public,anon,authenticated;
grant execute on function public.billing_claim_checkout_v2(uuid,text,text) to service_role;
grant execute on function public.billing_checkout_url_v2(uuid,uuid,text) to service_role;
grant execute on function public.billing_apply_subscription_v2(uuid,text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,timestamptz,text,text,text,boolean) to service_role;
grant execute on function public.billing_apply_lifetime(uuid,text,uuid,text,text,text,timestamptz,timestamptz) to service_role;
grant execute on function public.billing_record_event(uuid,text,jsonb,text) to service_role;
grant execute on function public.billing_claim_refund(uuid) to service_role;
grant execute on function public.billing_release_refund(uuid,boolean) to service_role;
grant execute on function public.billing_spend_window_v2(uuid,numeric,numeric) to service_role;
grant execute on function public.reserve_billing_ai_spend_v2(uuid,uuid,text,text,numeric,numeric,numeric) to service_role;
grant execute on function public.billing_spend_summary_v2(uuid,numeric,numeric) to service_role;
grant execute on function public.record_ai_spend_tokens(uuid,uuid,integer,integer) to service_role;
grant execute on function public.billing_usage_tokens(uuid,timestamptz) to service_role;
grant execute on function public.billing_sweep_claim(integer) to service_role;
grant execute on function public.billing_sweep_done(uuid,boolean) to service_role;
grant execute on function public.billing_mark_agent_block(uuid,uuid,boolean) to service_role;
grant execute on function public.billing_seed_legacy(timestamptz) to service_role;
grant execute on function public.billing_schedule_legacy_notice(timestamptz) to service_role;
