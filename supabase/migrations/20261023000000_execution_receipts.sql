-- U2 PR7: 실행 receipt → Claim/Evidence (docs/EXECUTION.md 9장, CLAUDE.md 원칙 2 · 5, A38 · A55 · A57).
--
-- - 끝낸 초안 단계의 receipt를 원문(kind execution)으로 남기고, Claim(origin execution, field artifact, 값 = 산출물 id) ·
--   근거(role executed) · 이벤트(artifact_created, actor agent)를 write_action 한 번과 같은 트랜잭션에서 붙인다.
-- - 진실 판정은 artifact Claim으로 Action 필드를 바꾸지 않는다: 초안은 완료가 아니다(A38). 사용자가 끝낸 할 일도 다시 열지 않는다(A57).
-- - 실행 결과 Claim은 origin user가 아니다(A55). 원문 · 인용이 없으면 들어가지 못한다(claims_source_origin은 user만 예외, 그대로).
-- - receipt 원문은 서버만 쓴다: 추출 파이프라인에 들어가지 않고(processing_status done), 클라이언트는 읽기만 한다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 적용 → 병합 순서
-- (병합 = 배포라 코드가 먼저 나가면 새 값이 제약에 막힌다). 실행기(executor.ts, 초안 단계를 끝낸 뒤)와 sweep(보조 안전망)이 부른다.

-- 기존 표(sources · claims · evidence · action_events)의 제약을 바꾸며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다.
-- 잠금을 잡는 변경을 맨 앞에 두어, 시간이 다 되면 새 객체를 만들기 전에 실패한다 (그때는 그대로 다시 적용한다).
-- 그 뒤에서 실패하면 파일 전체가 한 트랜잭션으로 돌았는지에 따라 남은 객체가 있을 수 있으니, 다시 적용하기 전에 확인한다.
set lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 값 넓히기 + 모양. 표마다 문장 하나: 제약을 지우고 넓혀 다시 만드는 사이에 제약 없는 표가 남지 않고, 표를 한 번만 훑는다.
--    기존 값은 모두 그대로 받고 실행 receipt의 값만 더한다.
--    - receipt 원문은 처리를 마친 것으로만 들어간다: 재처리 cron(pending · processing · failed만 고른다)이 고르지 않고,
--      추출 처리(processSource)가 processing으로 바꾸려 하면 sources_execution_receipt가 막는다. external_id = 단계 id
--    - 실행 Claim은 산출물 Claim뿐이고 산출물 Claim은 실행에서만 온다(claims_execution_artifact): 상태 · 기한 등 Action 필드를 실행 결과로 정하지 않는다
-- ─────────────────────────────────────────────
alter table public.sources
  drop constraint sources_kind_check,
  add constraint sources_kind_check check (kind in ('meeting', 'message', 'email', 'doc', 'note', 'task', 'execution')),
  add constraint sources_execution_receipt check (kind <> 'execution' or (processing_status = 'done' and external_id is not null));

alter table public.claims
  drop constraint claims_origin_check,
  add constraint claims_origin_check check (origin in ('source', 'user', 'tracker', 'execution')),
  drop constraint claims_field_check,
  add constraint claims_field_check check (field in ('due', 'scope', 'owner', 'status', 'artifact')),
  add constraint claims_execution_artifact check ((origin = 'execution') = (field = 'artifact'));

alter table public.evidence
  drop constraint evidence_role_check,
  add constraint evidence_role_check check (role in ('created', 'updated', 'completed', 'duplicate', 'executed'));

alter table public.action_events
  drop constraint action_events_type_check,
  add constraint action_events_type_check check (type in (
    'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
    'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created',
    'user_unstarted', 'artifact_created'
  )),
  drop constraint action_events_actor_check,
  add constraint action_events_actor_check check (actor in ('ai', 'user', 'agent'));

-- 단계 하나에 receipt 원문 하나 (같은 단계를 다시 써도 두 번 붙지 않는다)
create unique index sources_execution_receipt_idx on public.sources (user_id, external_id) where kind = 'execution';

-- ─────────────────────────────────────────────
-- 2) receipt 원문은 서버만 쓴다. sources는 본인 행을 쓸 수 있는 owner_all 그대로 두고(POST /api/v1/sources가 사용자 권한으로 넣는다),
--    실행 receipt만 클라이언트가 만들거나 고치거나 지우지 못하게 제한 정책을 더한다 (읽기는 그대로: 앱이 근거 원문으로 읽는다)
-- ─────────────────────────────────────────────
create policy "execution_receipt_no_client_insert" on public.sources as restrictive for insert to authenticated
  with check (kind <> 'execution');
create policy "execution_receipt_no_client_update" on public.sources as restrictive for update to authenticated
  using (kind <> 'execution') with check (kind <> 'execution');
create policy "execution_receipt_no_client_delete" on public.sources as restrictive for delete to authenticated
  using (kind <> 'execution');

-- ─────────────────────────────────────────────
-- 3) receipt 쓰기 (실행기, src/lib/execution/receipt.ts writeDraftReceipt)
-- ─────────────────────────────────────────────
-- 끝낸(called) 초안 단계의 receipt를 Action에 붙인다: receipt 원문 + Claim + 근거 + 이벤트를 write_action 한 번과 같은 트랜잭션에서.
-- receipt는 Action을 바꾸지 않는다(초안 ≠ 완료 A38, 사용자가 끝낸 할 일 그대로 A57): Action 값은 잠근 행 그대로 다시 쓰고(원칙 5: 진실 판정이
-- 앞서 계산한 값 그대로), 활동 시각도 되돌려 랭킹 · 확인 순서가 초안으로 바뀌지 않게 한다. 바뀌는 것은 버전(+1) · updated_at뿐이다.
-- 실행기는 부르기 전에 Claim을 더해 다시 판정해도 값이 같은지 확인한다(receipt.ts).
-- p_receipt: { source: { title, raw_text, external_url }, claim: { id, quote, speaker_role, certainty, directness, audience } }
-- 서버가 정하는 값(호출자의 값을 믿지 않는다): 사용자 · Action(run의 것), 원문 종류 · 외부 id(단계 id) · 시각(산출물 시각) · 처리 상태,
-- Claim의 필드 · origin · 값(산출물 id) · 시각 · 상태 · 채널, 근거의 역할 · 인용(Claim 인용), 이벤트 전부(글 없이 id만).
-- 확인하는 값: 인용이 receipt 글에 그대로 있다(원문 인용 실재 확인과 같은 뜻), 링크가 그 산출물을 가리킨다.
-- Action 행을 먼저 잠근다: 같은 단계의 receipt를 함께 쓰는 함수(실행기 · sweep)끼리 줄을 서고, 뒤의 것은 이미 붙은 것을 본다.
-- 결과: written(붙였다) · exists(이미 붙어 있다, 버전과 상관없이) · conflict(버전이 어긋나 아무것도 쓰지 않았다. 다시 읽어 부른다)
create function public.write_execution_receipt(p_step uuid, p_expected_version integer, p_receipt jsonb)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_step public.execution_steps;
  v_run public.execution_runs;
  v_artifact public.execution_artifacts;
  v_action public.actions;
  v_source uuid;
  v_text text := p_receipt->'source'->>'raw_text';
  v_quote text := p_receipt->'claim'->>'quote';
begin
  if p_expected_version is null then
    raise exception 'write_execution_receipt: 읽은 Action 버전이 없다';
  end if;
  select * into v_step from public.execution_steps where id = p_step;
  if not found or v_step.kind <> 'draft' or v_step.state <> 'called' then
    raise exception 'write_execution_receipt: 끝낸 초안 단계가 아니다' using errcode = 'P0002';
  end if;
  select * into v_artifact from public.execution_artifacts where step_id = p_step;
  if not found then
    raise exception 'write_execution_receipt: 산출물이 없다' using errcode = 'P0002';
  end if;
  select * into v_run from public.execution_runs where id = v_step.run_id;
  if coalesce(v_quote, '') = '' or coalesce(strpos(v_text, v_quote), 0) = 0 then
    raise exception 'write_execution_receipt: 인용이 receipt 글에 없다';
  end if;
  if (p_receipt->'source'->>'external_url') is distinct from 'taskforce://artifacts/' || v_artifact.id::text then
    raise exception 'write_execution_receipt: 링크가 산출물을 가리키지 않는다';
  end if;
  if jsonb_typeof(p_receipt->'claim'->'id') is distinct from 'string' then
    raise exception 'write_execution_receipt: Claim id가 없다';
  end if;

  select * into v_action from public.actions where id = v_run.action_id and user_id = v_run.user_id for update;
  if not found then
    raise exception 'action not found' using errcode = 'P0002';
  end if;

  select s.id into v_source from public.sources s
    where s.user_id = v_run.user_id and s.kind = 'execution' and s.external_id = p_step::text;
  if v_source is not null and exists (select 1 from public.claims c where c.source_id = v_source and c.origin = 'execution') then
    return 'exists';
  end if;
  if v_action.version <> p_expected_version then
    return 'conflict';
  end if;

  if v_source is null then
    insert into public.sources (user_id, kind, title, raw_text, occurred_at, external_url, external_id, processing_status, processed_at)
    values (v_run.user_id, 'execution', p_receipt->'source'->>'title', v_text, v_artifact.created_at,
            p_receipt->'source'->>'external_url', p_step::text, 'done', now())
    returning id into v_source;
  end if;

  if not public.write_action(
    v_run.user_id, v_run.action_id, p_expected_version,
    -- 잠근 행 그대로 (resolution이 null인 행은 null 그대로 남게 키를 빼고 넘긴다)
    jsonb_build_object(
      'title', v_action.title, 'owner', v_action.owner, 'due_date', v_action.due_date, 'due_at', v_action.due_at,
      'status', v_action.status, 'needs_confirmation', v_action.needs_confirmation, 'confirm_reasons', to_jsonb(v_action.confirm_reasons))
      || case when v_action.resolution is null then '{}'::jsonb else jsonb_build_object('resolution', v_action.resolution) end,
    jsonb_build_array((p_receipt->'claim') || jsonb_build_object(
      'source_id', v_source, 'field', 'artifact', 'origin', 'execution', 'value', v_artifact.id,
      'occurred_at', v_artifact.created_at, 'state', 'active', 'channel', null)),
    jsonb_build_array(jsonb_build_object('source_id', v_source, 'quote', v_quote, 'role', 'executed')),
    jsonb_build_array(jsonb_build_object(
      'type', 'artifact_created', 'actor', 'agent', 'source_id', v_source,
      'after', jsonb_build_object('artifact_id', v_artifact.id, 'run_id', v_run.id, 'step_id', p_step)))
  ) then
    raise exception 'write_execution_receipt: 잠근 버전으로 쓰지 못했다'; -- 위에서 잠그고 확인했으므로 일어나지 않는다
  end if;
  update public.actions set last_activity_at = v_action.last_activity_at where id = v_action.id and user_id = v_action.user_id;
  return 'written';
end;
$$;

-- receipt가 아직 없는 끝낸 초안 단계 (sweep의 보조 안전망: 실행기가 complete_internal_step 뒤 receipt를 쓰기 전에 죽은 경우).
-- 하루 안의 산출물만 본다: 계속 실패하는 단계가 매분 자리를 차지하지 않게. 오래된 것부터
create function public.missing_execution_receipts(p_limit integer default 20) returns table (step_id uuid)
language sql stable
set search_path = ''
as $$
  select a.step_id from public.execution_artifacts a
  join public.execution_steps s on s.id = a.step_id
  where s.state = 'called' and s.kind = 'draft' and a.created_at > public.db_now() - interval '1 day'
    and not exists (
      select 1 from public.sources x where x.user_id = a.user_id and x.kind = 'execution' and x.external_id = a.step_id::text
    )
  order by a.created_at
  limit p_limit
$$;

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴)
do $$
declare
  f text;
begin
  foreach f in array array['write_execution_receipt', 'missing_execution_receipts'] loop
    execute format('revoke execute on function public.%I from public, anon, authenticated', f);
    execute format('grant execute on function public.%I to service_role', f);
  end loop;
end;
$$;
