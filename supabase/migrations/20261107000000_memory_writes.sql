-- 0.2.0 기억 쓰기 (구현 계획 B3, PR1): Remembered에서 사용자가 하는 잊기 · 범위 옮기기. 새 표 · 새 열 없음, 기존 함수 · 트리거 변경 없음.
-- 결정 기록: docs/context-layer.md 8장. 확인(Confirm) · 정정(Edit)은 B1 remember_memory_item(p_corrects · p_expected_version)을 그대로 쓴다.
-- 이 파일은 그 함수 하나로 한 번에 못 하는 둘만 더한다 (서버 service role만 부른다):
--   1) forget_memory_item: 잊기(revoked_at) + version 확인 + 이미 잊은 항목의 멱등 재시도를 한 트랜잭션에서.
--      범위 기억이면 범위 version은 기존 트리거(memory_items_bump_context_version_on_update)가 commit 직전에 한 번 올린다.
--   2) move_memory_item: 범위 옮기기 = 대상 범위에 같은 사실(kind · subject · statement)의 새 explicit 행 + 옛 행 잊음, 한 트랜잭션.
--      정정(superseded)과 다른 "옮김"이다: 옛 행은 revoked_at만 남기고(superseded_by 규칙은 같은 범위만 가리킨다), 새 행의 value.moved_from이 옮긴 출처 id다.
--      explicit 항목, 전체 · 범위(context)에서 전체 · 내 active 범위로만 옮긴다 (observed · inferred는 정책 보류, docs/context-layer.md 8장).
--      대상 범위에 같은 사실의 지금 행이 있으면 B1 규칙대로 그 범위 안에서만 정정된다(다른 범위의 같은 사실은 건드리지 않는다).
-- 기억은 실행 권한에 닿지 않는다(I04 · I14): 이 파일의 함수는 execution_* 표를 읽거나 쓰지 않고 Action · run · 정책을 만들지 않는다 (tests/db/memory-writes.scenarios.ts가 확인).
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 20261104000000_context_layer 뒤에 적용한다.

begin;

-- ─────────────────────────────────────────────
-- 1) 잊기. status: forgotten(이번에 잊음) · already_forgotten(이미 잊은 항목의 재시도, 쓰기 없음) · conflict · not_found
--    - 정정된 항목(superseded_at)은 잊지 않는다: 지금 행을 가리켜 다시 요청해야 한다 (conflict)
--    - 이미 잊은 항목: 요청의 expected_version이 이 행의 version 이하이면 같은 요청의 재전송(그 사이 원문 삭제 전파가 version을 더 올렸어도 같다)으로 보고 성공.
--      행이 가진 version보다 큰 값은 이 행에 대해 알 수 없는 값이라 conflict
--    - 행을 먼저 잠근다(for update): 같은 사실의 다시 말함 · 정정(remember_memory_item)과 한 줄로 선다
-- ─────────────────────────────────────────────
create function public.forget_memory_item(p_user_id uuid, p_id uuid, p_expected_version integer)
returns table (status text)
language plpgsql
set search_path = ''
as $$
declare
  v_row public.memory_items%rowtype;
begin
  select * into v_row from public.memory_items m where m.id = p_id and m.user_id = p_user_id for update;
  if not found then
    return query select 'not_found'::text;
    return;
  end if;
  if v_row.superseded_at is not null then
    return query select 'conflict'::text;
    return;
  end if;
  if v_row.revoked_at is not null then
    return query select case when p_expected_version <= v_row.version then 'already_forgotten' else 'conflict' end;
    return;
  end if;
  if v_row.version <> p_expected_version then
    return query select 'conflict'::text;
    return;
  end if;
  update public.memory_items m set revoked_at = now(), version = m.version + 1 where m.id = v_row.id;
  return query select 'forgotten'::text;
end;
$$;

-- ─────────────────────────────────────────────
-- 2) 범위 옮기기. status: moved · unchanged(이미 그 범위, 쓰기 없음) · conflict · not_found · target_not_found(내 active 범위가 아님) · unsupported
--    (explicit이 아니거나 전체 · 범위(context) 기억이 아님: 할 일 · 상대 · 에이전트 범위를 넓히지 않는다)
--    - 잠그는 순서: 같은 사실의 잠금(옛 범위 · 새 범위, 키 순서로) → 인용 원문(for share) → 옛 행 → 새 범위의 같은 사실의 지금 행(id 순) → (commit 직전) 범위.
--      remember_memory_item · 원문 글 지우기와 같은 순서라 서로 기다리다 교착하지 않는다. 범위 행은 for key share만 잡는다(commit 직전 범위 version 올리기와 충돌하지 않는다)
--    - 새 행: kind · subject · statement · value(+ moved_from) · 유효 구간 · 말한 시각(observed_at)을 그대로. origin explicit. 출처(source_ref)는 그대로 두되
--      지워진 원문을 가리키는 id · 인용은 뺀다(지운 원문을 새 행이 가리킬 수 없다: memory_items_purged_source_guard)
-- ─────────────────────────────────────────────
create function public.move_memory_item(p_user_id uuid, p_id uuid, p_expected_version integer, p_scope_kind text, p_context_id uuid)
returns table (status text, id uuid, superseded uuid[])
language plpgsql
set search_path = ''
as $$
declare
  v_seen public.memory_items%rowtype;
  v_old public.memory_items%rowtype;
  v_ref jsonb;
  v_source_found boolean := false;
  v_reason text;
  v_same boolean;
  v_key_old bigint;
  v_key_new bigint;
  v_new uuid;
  v_losers uuid[] := '{}';
begin
  if p_scope_kind not in ('global', 'context') or (p_scope_kind = 'context') <> (p_context_id is not null) then
    raise exception 'move_memory_item: the target is the global scope (no context) or a context' using errcode = '22023';
  end if;

  -- 잠그기 전에 읽는다. 정정 · 잊음 · version은 한 방향이라(오르기만 한다) 여기서 낡았으면 지금도 낡았다. origin · 범위 종류는 바뀌지 않는다
  select * into v_seen from public.memory_items m where m.id = p_id and m.user_id = p_user_id;
  if not found then
    return query select 'not_found'::text, null::uuid, '{}'::uuid[];
    return;
  end if;
  if v_seen.superseded_at is not null or v_seen.revoked_at is not null or v_seen.version <> p_expected_version then
    return query select 'conflict'::text, null::uuid, '{}'::uuid[];
    return;
  end if;
  if v_seen.origin <> 'explicit' or v_seen.scope_kind not in ('global', 'context') then
    return query select 'unsupported'::text, null::uuid, '{}'::uuid[];
    return;
  end if;

  v_same := v_seen.scope_kind = p_scope_kind and v_seen.context_id is not distinct from p_context_id;
  if not v_same and p_context_id is not null then
    perform 1 from public.work_contexts c where c.id = p_context_id and c.user_id = p_user_id and c.status = 'active' for key share;
    if not found then
      return query select 'target_not_found'::text, null::uuid, '{}'::uuid[];
      return;
    end if;
  end if;

  -- 같은 범위 · 같은 사실의 쓰기는 한 번에 하나씩 (remember_memory_item과 같은 키). 둘을 키 순서로 잡아 서로 반대 방향의 옮김과 교착하지 않는다
  if v_seen.subject is not null then
    v_key_old := hashtextextended(concat_ws(':', 'memory_fact', p_user_id, v_seen.kind, v_seen.subject, v_seen.scope_kind,
      v_seen.context_id, v_seen.action_id, v_seen.person_id, v_seen.agent_adapter), 0);
    v_key_new := hashtextextended(concat_ws(':', 'memory_fact', p_user_id, v_seen.kind, v_seen.subject, p_scope_kind,
      p_context_id, null::uuid, null::uuid, null::text), 0);
    perform pg_advisory_xact_lock(least(v_key_old, v_key_new));
    if v_key_old <> v_key_new then
      perform pg_advisory_xact_lock(greatest(v_key_old, v_key_new));
    end if;
  end if;

  -- 인용 원문을 기억 행보다 먼저 for share로 잠근다 (원문 글 지우기와 같은 순서)
  if coalesce(v_seen.source_ref ->> 'source_id', '') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    select s.raw_text_purge_reason into v_reason
      from public.sources s
     where s.id = (v_seen.source_ref ->> 'source_id')::uuid and s.user_id = p_user_id
     for share;
    v_source_found := found;
  end if;

  select * into v_old from public.memory_items m where m.id = p_id and m.user_id = p_user_id for update;
  if not found then
    return query select 'not_found'::text, null::uuid, '{}'::uuid[];
    return;
  end if;
  if v_old.superseded_at is not null or v_old.revoked_at is not null or v_old.version <> p_expected_version
     or v_old.subject is distinct from v_seen.subject then
    return query select 'conflict'::text, null::uuid, '{}'::uuid[];
    return;
  end if;
  if v_same then
    return query select 'unchanged'::text, v_old.id, '{}'::uuid[];
    return;
  end if;

  -- 대상 범위의 같은 사실의 지금 행을 넣기 전에 잠근다 (id 순)
  if v_old.subject is not null then
    perform 1
       from public.memory_items m
      where m.user_id = p_user_id and m.kind = v_old.kind and m.subject = v_old.subject and m.scope_kind = p_scope_kind
        and m.context_id is not distinct from p_context_id and m.action_id is null and m.person_id is null and m.agent_adapter is null
        and m.superseded_at is null and m.revoked_at is null
      order by m.id
      for update;
  end if;

  v_ref := v_old.source_ref;
  if v_ref ? 'source_id' then
    if not v_source_found then
      v_ref := v_ref - 'source_id' - 'quote';
    elsif v_reason = 'disconnected' then
      v_ref := v_ref - 'quote';
    end if;
    if not (v_ref ?| array['message_id', 'source_id', 'artifact_id', 'event_id']) then
      v_ref := null;
    end if;
  end if;

  insert into public.memory_items (user_id, kind, scope_kind, context_id, subject, statement, value, origin, source_ref, observed_at, valid_from, valid_until)
  values (p_user_id, v_old.kind, p_scope_kind, p_context_id, v_old.subject, v_old.statement,
          v_old.value || jsonb_build_object('moved_from', v_old.id), 'explicit', v_ref, v_old.observed_at, v_old.valid_from, v_old.valid_until)
  returning memory_items.id into v_new;

  if v_old.subject is not null then
    select coalesce(array_agg(m.id order by m.id), '{}') into v_losers
      from public.memory_items m
     where m.user_id = p_user_id and m.kind = v_old.kind and m.subject = v_old.subject and m.scope_kind = p_scope_kind
       and m.context_id is not distinct from p_context_id and m.action_id is null and m.person_id is null and m.agent_adapter is null
       and m.superseded_at is null and m.revoked_at is null and m.id <> v_new;
    if cardinality(v_losers) > 0 then
      update public.memory_items m set superseded_by = v_new, version = m.version + 1 where m.id = any (v_losers);
    end if;
  end if;

  update public.memory_items m set revoked_at = now(), version = m.version + 1 where m.id = v_old.id;
  return query select 'moved'::text, v_new, v_losers;
end;
$$;

-- ─────────────────────────────────────────────
-- 3) 권한: 서버(service role)만 부른다. 앱 · 익명은 부르지 못한다
-- ─────────────────────────────────────────────
revoke all on function public.forget_memory_item(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.move_memory_item(uuid, uuid, integer, text, uuid) from public, anon, authenticated;
grant execute on function public.forget_memory_item(uuid, uuid, integer) to service_role;
grant execute on function public.move_memory_item(uuid, uuid, integer, text, uuid) to service_role;

commit;
