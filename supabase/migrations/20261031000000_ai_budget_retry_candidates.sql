-- Apply consent and budget eligibility before the batch cap. Old preserved pauses
-- from withdrawn accounts must not occupy every slot in the retry queue.
create function public.ai_budget_retry_candidates(p_since timestamptz, p_limit integer default 50)
returns setof public.sources
language sql stable security definer set search_path = ''
as $$
  select s.*
  from public.sources s
  join public.profiles p on p.user_id = s.user_id and p.ai_consent_at is not null
  where s.processing_status in ('pending', 'processing', 'failed')
    and s.kind <> 'task'
    and s.raw_text_purged_at is null
    and (s.created_at >= p_since or s.processing_summary->>'budget_deferred' = 'true')
    and (s.processing_summary->>'budget_deferred' is null
      or (s.processing_summary->>'retry_at')::timestamptz <= now())
    and (s.processing_summary->>'retryable' is null or s.processing_summary->>'retryable' = 'true')
  order by s.created_at, s.id
  limit greatest(0, least(coalesce(p_limit, 50), 100));
$$;
revoke all on function public.ai_budget_retry_candidates(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.ai_budget_retry_candidates(timestamptz, integer) to service_role;
