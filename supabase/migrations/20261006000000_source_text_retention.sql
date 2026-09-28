-- 원문 보관 기간 90일 (개인정보 처리방침). 매일 /api/cron/retention이 purge_expired_source_text를 부른다.
-- 90일이 지난 원문(sources.created_at 기준)은 글(raw_text)만 비우고 행 · 제목 · 링크 · 관련자 · 처리 결과는 남긴다.
-- 근거 인용(evidence.quote)과 Claim은 남는다: 할 일의 근거는 계속 보이고, 원문 링크로 원본을 열 수 있다.
-- raw_text는 not null이라 빈 문자열로 비우고 raw_text_purged_at에 지운 시각을 적는다 (앱은 이 값으로 "보관 기간이 지남"을 보여준다).
-- kind = 'task'는 structured(속성 스냅샷)에도 원문이 그대로 들어 있으므로 함께 비운다
-- (src/lib/connectors/store.ts의 taskStates · pendingTasks는 structured가 null이면 비교하지 않고 바뀐 것으로 본다).
-- Jev 판정 기록(judge_logs)에는 후보 구절이 들어 있으므로 90일이 지나거나(판정 자체가 오래됨) 원문이 이미 비워졌으면 행째 지운다.
-- 시도 기록(rate_limit_events · missing_reports)은 한도 창(10분, src/lib/api/rate-limit.ts)이 지나면 필요 없다 — 넉넉히 하루 지나면 지운다.

alter table public.sources add column raw_text_purged_at timestamptz;

create index sources_retention_idx on public.sources (created_at) where raw_text_purged_at is null;
create index judge_logs_created_idx on public.judge_logs (created_at);

-- 서버 전용. 한 번에 p_limit개씩만 지워 트랜잭션을 짧게 둔다 (남은 것은 다음 호출, cron이 반복해서 부른다).
create function public.purge_expired_source_text(p_before timestamptz, p_limit int default 5000)
returns table (sources_purged int, judge_logs_deleted int, rate_limit_events_deleted int, missing_reports_deleted int)
language plpgsql
set search_path = ''
as $$
declare
  v_sources int;
  v_logs int;
  v_rate_limit int;
  v_missing int;
  -- 한도 창은 최대 10분(MISSING_REPORT_LIMIT · ASK_LIMIT · CONNECTION_START_LIMIT)이라 하루는 넉넉한 여유
  v_events_before timestamptz := now() - interval '1 day';
begin
  update public.sources s
  set raw_text = '', raw_text_purged_at = now(),
      structured = case when s.kind = 'task' then null else s.structured end
  where s.id in (
    select id from public.sources
    where created_at < p_before and raw_text_purged_at is null
    order by created_at
    limit p_limit
  );
  get diagnostics v_sources = row_count;

  -- 판정 기록 자체가 90일이 지났거나(created_at), 그 원문이 이미 보관 기간이 지나 비워졌으면(원문 없이 후보 구절만 남는 게 의미가 없다) 지운다.
  delete from public.judge_logs j
  where j.id in (
    select jl.id
      from public.judge_logs jl
      join public.sources s on s.id = jl.source_id
     where jl.created_at < p_before or s.raw_text_purged_at is not null
     order by jl.created_at
     limit p_limit
  );
  get diagnostics v_logs = row_count;

  delete from public.rate_limit_events e
  where e.id in (
    select id from public.rate_limit_events where created_at < v_events_before order by created_at limit p_limit
  );
  get diagnostics v_rate_limit = row_count;

  delete from public.missing_reports m
  where m.id in (
    select id from public.missing_reports where created_at < v_events_before order by created_at limit p_limit
  );
  get diagnostics v_missing = row_count;

  return query select v_sources, v_logs, v_rate_limit, v_missing;
end;
$$;

revoke execute on function public.purge_expired_source_text from public, anon, authenticated;
grant execute on function public.purge_expired_source_text to service_role;
