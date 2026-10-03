-- 실행의 글 보관 기간 (처리방침 D9a-1 5장, 2026-10-03 사용자 결정: 저장한 뒤 90일, 그때 실행 중이면 끝나는 대로). 매일 /api/cron/retention이 purge_expired_execution_text를 부른다.
--
-- - 지우는 글: 요청(execution_runs.request, 빈 문자열로) · 계획이 준 지시(execution_steps.args의 brief 키) ·
--   초안의 받는 사람 후보(execution_steps.receipt의 to 키) · 되묻는 질문(receipt의 question 키). 원문 · 다른 사람의 이메일을 담을 수 있다.
-- - 남기는 것: run · 단계 행과 id · 상태 · 결과 · hold · 시각, receipt의 글 아닌 값(decision · capability · model · prompt_version · error),
--   산출물 행(id · 제목. 본문은 purge_expired_artifacts가 따로 비운다) · 원가 · 원장 · intent · 승인 · 실행 이벤트(글이 없다).
-- - 기준은 저장한 시각(run을 만든 시각 execution_runs.created_at)이다: 만든 지 보관 기간이 지난 끝난 run(done · failed · stopped)의 글을 지운다.
--   지시 · receipt는 run이 열린 동안에만 쓰이므로 run을 만든 시각보다 늦다. 그래서 늦게 쓴 글은 90일보다 일찍 지워질 수 있지만 늦게 지워지지는 않는다.
--   끝나지 않은 run(막힌 run 포함)은 건드리지 않는다: 계획 · 초안 단계가 요청 · 지시를 다시 읽는다. 그때까지 열려 있던 run은 끝난 뒤 첫 정리에서 지운다
--   (= 만든 뒤 90일과 끝난 때 중 늦은 쪽). 끝 상태는 다시 열리지 않는다.
--   끝났어도 부르는 중 · 결과 불명인 단계가 남은 run은 그 단계가 나올 때까지 미룬다(응답이 receipt를 늦게 쓸 수 있다).
-- - 지운 시각을 run의 text_purged_at에 적는다(글 없이). 다시 불러도 같은 run을 두 번 지우지 않는다.
-- - execution_steps_replan 트리거는 끝난 단계의 args가 바뀌면 "plan is frozen"으로 막고, 준비된 단계의 args가 바뀌면 다시 계획한다(pending · version + 1).
--   지시를 지우는 것은 계획을 바꾸는 것이 아니므로, 이 함수가 정한 gate(execution.gate = 'retention', 트랜잭션 안에서만)이고
--   바뀐 것이 args의 brief 키를 뺀 것뿐일 때만 트리거가 그대로 통과시킨다(상태 · 버전 · intent 그대로, 이벤트 없음).
--   지시를 args 밖으로 옮기는 안은 실행기 코드와 기존 행을 함께 옮겨야 해서(그 옮기기도 트리거에 막힌다) 고르지 않았다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 적용 → 병합 순서
-- (병합 = 배포라 코드가 먼저 나가면 retention cron의 이 단계가 함수를 찾지 못해 500 · execution_text_purged null, 나머지 정리는 그대로 돈다).

-- 기존 표(execution_runs)에 열과 색인을 더하며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다.
-- 잠금을 잡는 변경을 맨 앞에 두어, 시간이 다 되면 새 객체를 만들기 전에 실패한다 (그때는 그대로 다시 적용한다).
-- 그 뒤에서 실패하면 파일 전체가 한 트랜잭션으로 돌았는지에 따라 남은 객체가 있을 수 있으니, 다시 적용하기 전에 확인한다.
set lock_timeout = '5s';

alter table public.execution_runs add column text_purged_at timestamptz;

create index execution_runs_text_retention_idx on public.execution_runs (created_at) where text_purged_at is null;

-- ─────────────────────────────────────────────
-- 1) 계획 동결 트리거: 20261021000000_execution_core와 같고, 보관 기간 정리(gate retention)의 지시 지우기만 통과시킨다
-- ─────────────────────────────────────────────
-- 계획(공급자 · 도구 · 효과 종류 · 목적 · 회차 · 연결 · 수신자 · 본문 · 인자 · 원문 revision)을 바꾸면 늘 pending으로 되돌리고 version을 올린다.
-- 부르는 중 · 끝난 단계는 못 바꾼다. 예외: 연결을 끊으면(connections 삭제 → set null) 그 단계의 기록은 상태 그대로 남긴다.
-- 예외: 보관 기간 정리(purge_expired_execution_text)가 지시(args.brief)만 지우면 어느 상태든 그대로 둔다 (계획이 아니라 글을 지우는 것이다)
create or replace function public.execution_steps_replan() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.connection_id,
      new.recipients, new.body, new.args, new.source_revision)
     is distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.connection_id,
      old.recipients, old.body, old.args, old.source_revision) then
    if coalesce(current_setting('execution.gate', true), '') = 'retention'
       and new.args = old.args - 'brief'
       and (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.connection_id, new.recipients, new.body, new.source_revision)
           is not distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.connection_id, old.recipients, old.body, old.source_revision) then
      return new;
    end if;
    if old.state not in ('pending', 'prepared') then
      if new.connection_id is null
         and (new.provider, new.tool, new.effect_class, new.purpose, new.occurrence, new.recipients, new.body, new.args, new.source_revision)
             is not distinct from (old.provider, old.tool, old.effect_class, old.purpose, old.occurrence, old.recipients, old.body, old.args, old.source_revision) then
        return new;
      end if;
      raise exception 'step % is %: plan is frozen', old.id, old.state;
    end if;
    new.state := 'pending';
    new.version := old.version + 1;
    new.intent_key := null;
    new.policy_version := null;
    new.needs_approval := null;
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────
-- 2) 정리 (retention cron, src/app/api/cron/retention/route.ts)
-- ─────────────────────────────────────────────
-- p_before(= 지금 - EXECUTION_TEXT_RETENTION_DAYS, src/lib/retention.ts)보다 먼저 만든 끝난 run의 글을 지운다. 지운 run 수.
-- 한 번에 p_limit개 run씩, 먼저 만든 것부터 (남은 것은 다음 날). 단계를 먼저, run을 나중에 쓴다(다른 함수와 같은 step → run 잠금 순서).
-- 상태를 바꾸지 않으므로 실행 이벤트 · 크레딧 해제 트리거는 돌지 않는다
create function public.purge_expired_execution_text(p_before timestamptz, p_limit integer default 5000)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_runs uuid[];
  v_count integer;
  v_gate text := current_setting('execution.gate', true); -- 부른 쪽의 gate (끝날 때 되돌린다)
begin
  if p_before is null or p_limit is null or p_limit < 1 then
    raise exception 'purge_expired_execution_text: 잘못된 인자';
  end if;
  select coalesce(array_agg(x.id), '{}') into v_runs from (
    select r.id from public.execution_runs r
    where r.text_purged_at is null
      and r.state in ('done', 'failed', 'stopped')
      and r.created_at < p_before
      and not exists (select 1 from public.execution_steps s where s.run_id = r.id and s.state in ('calling', 'unknown_outcome'))
    order by r.created_at
    limit p_limit
  ) x;
  if cardinality(v_runs) = 0 then
    return 0;
  end if;

  perform set_config('execution.gate', 'retention', true);
  update public.execution_steps s
    set args = s.args - 'brief', receipt = s.receipt - array['to', 'question']
    where s.run_id = any (v_runs) and (s.args ? 'brief' or s.receipt ?| array['to', 'question']);
  update public.execution_runs r set request = '', text_purged_at = public.db_now()
    where r.id = any (v_runs) and r.text_purged_at is null;
  get diagnostics v_count = row_count;
  -- 트리거 예외는 이 함수 안에서만: 부른 쪽의 gate로 되돌려(retention은 남기지 않는다), 같은 트랜잭션의 뒤 문장이 지시를 지우면 다시 계획 · 동결 규칙대로 돈다
  perform set_config('execution.gate', coalesce(nullif(v_gate, 'retention'), ''), true);
  return v_count;
end;
$$;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). execution_steps_replan은 바꿔 만들어도 권한이 그대로지만 함께 다시 적는다
do $$
declare
  f text;
begin
  foreach f in array array['execution_steps_replan', 'purge_expired_execution_text'] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
