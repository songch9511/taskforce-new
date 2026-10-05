-- Only the authenticated API invokes this with its verified account ID. No attempt details.
create function public.ai_spend_summary(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cap_usd', 10,
    'confirmed_usd', confirmed,
    'reserved_usd', reserved,
    'pending_count', pending,
    'remaining_usd', greatest(0, 10 - confirmed - reserved),
    'status', case when breached then 'provider_bound_violation'
                   when confirmed + reserved >= 10 then 'exhausted' else 'available' end
  ) from (
    select coalesce(sum(cost_usd), 0) confirmed,
      coalesce(sum(reserved_usd) filter (where cost_usd is null), 0) reserved,
      count(*) filter (where cost_usd is null) pending,
      coalesce(bool_or(cost_usd > reserved_usd), false) breached
    from ai_spend_attempts where user_id = p_user_id
  ) totals;
$$;
revoke all on function public.ai_spend_summary(uuid) from public, anon, authenticated;
grant execute on function public.ai_spend_summary(uuid) to service_role;

-- Preserve nonretryable task versions without resubmitting AI work on every sync.
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
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, case when s.processing_summary->>'retryable' = 'false' then 'blocked' else s.processing_status end as processing_status,
            coalesce((s.processing_summary->>'started_at')::timestamptz, s.created_at) as started_at
       from public.sources s
      where s.user_id = p_user_id and s.connection_id = p_connection_id and s.kind = 'task'
        and s.external_id = any (p_external_ids) and s.processing_status = 'done'
      order by s.external_id, s.occurred_at desc, s.created_at desc)
    union all
    (select distinct on (s.external_id) s.external_id, s.id, s.external_version, s.structured, case when s.processing_summary->>'retryable' = 'false' then 'blocked' else s.processing_status end as processing_status,
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
    'ai_budget_exhausted', 'ai_pricing_unavailable', 'ai_provider_bound_violation', 'ai_budget_unavailable')
);
