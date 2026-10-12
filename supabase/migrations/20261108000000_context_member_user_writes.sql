-- 0.2.0 S3b 멤버십 쓰기: 사용자가 할 일을 범위에 넣고 · 빼고 · 옮긴다 (ProjectLink "Set by you" · Undo). 새 표 · 새 열 없음, 기존 함수 · 트리거 변경 없음.
-- 결정 기록: docs/context-layer.md 9장. 읽기는 앱이 RLS로(work_contexts · context_members select), 쓰기는 서버(service role)만 이 함수 하나로 한다.
--
-- change_context_membership_by_user(사용자, 할 일, 넣을 범위 + 그 범위 version, 뺄 범위 + 그 범위 version): 한 트랜잭션에서 사용자 명시 멤버십(origin user)을 **조건부로** 쓴다.
--   - 조건: 요청이 본 범위 version(work_contexts.context_version)이 지금과 같을 때만 쓴다. 다르면 쓰기 0 + status conflict.
--     옛 요청(응답을 잃은 재전송 · 오래 열린 화면 · 늦은 Undo)이 더 새 사용자 결정을 덮지 못한다: 같은 (사용자, 할 일)의 쓰기는 advisory 잠금으로 한 줄로 서므로
--     앞 쓰기의 version 올림이 먼저 커밋되고, 뒤따르는 옛 요청은 그 새 version을 읽어 conflict가 된다. 새 멱등성 저장소는 없다: 응답을 잃은 성공 요청의 재전송도 conflict다.
--     version은 범위 전체의 신호라 무관한 변경(다른 멤버 · 범위 기억 · 원문 revision)에도 올라 거짓 conflict가 생길 수 있다(보수적, 앱은 다시 읽고 다시 한다).
--   - 넣기(p_add_context_id): 그 범위에 user 멤버. 이미 auto · inferred 행이면 같은 행을 user로 승격(confidence 비움), 사용자가 뺀 행(removed_at)이면 되살린다.
--   - 빼기(p_remove_context_id): 행을 지우지 않고 removed_at을 남긴다(origin user). 자동 규칙은 unique (context_id, action_id)에 막혀 같은 멤버를 다시 넣지 못한다.
--     auto · inferred 행을 빼면 같은 행이 origin user + removed_at이 된다(CHECK context_members_removed_by_user). 멤버가 아니었어도 뺀 표시를 남긴다("여기 아님"도 사용자의 선택).
--   - 옮기기: 둘 다 주면 같은 트랜잭션에서 빼고 넣는다 (모두 검증한 뒤에만 쓴다: 한쪽만 쓰고 끝나지 않는다). 전체 교체가 아니다: 다른 범위의 멤버십은 그대로.
--   - 이미 그 상태(user 멤버 / 사용자가 뺀 행)면 행을 쓰지 않는다(조건은 통과해야 한다).
-- **실제 변화**(added_changed · removed_changed): "확인된 멤버(removed_at이 없고 origin이 inferred가 아닌 행)였나"가 바뀐 범위만 true다. 이미 멤버였던 도착 범위(옮기기)나 멤버가 아니던 출발 범위는
--   바뀐 것이 아니다. 앱의 Undo는 이 변화의 역연산만 보낸다(원래 있던 멤버를 지우지 않는다). 승격(auto → user)은 멤버가 바뀐 것이 아니다.
-- 돌려주는 행(added_member · removed_member, context_members 행에서 user_id만 뺀 jsonb)과 version(added_version · removed_version)은 이 쓰기가 반영된 직후 값이다: commit 직전에 도는 B1 version 올림 큐를 이 트랜잭션 안에서 먼저 비우고(범위 행 잠금을 잡는다)
--   읽으므로, 응답을 받은 앱이 그 값으로 보내는 Undo는 그 사이 다른 기기의 변경이 있었다면 conflict가 된다.
-- status: ok · conflict(version이 다름) · context_not_found(내 active 범위가 아님: 남의 · 없는 · 보관된 범위) · action_not_found(내 할 일이 아님). conflict 이외의 not_found가 먼저 판정된다.
--
-- 범위 version(work_contexts.context_version)은 B1 트리거(context_members_bump_version)가 올린다: 넣기 · 빼기 · inferred에서 user로의 확인(origin 변경).
-- B1 트리거 조건(context_id · removed_at · origin이 바뀜) 때문에 auto → user 승격도 한 번 오른다(멤버가 바뀐 것은 아니지만 거짓 stale 한 번, 새 SQL로 트리거를 고치지 않았다).
-- 잠그는 순서: (사용자, 할 일) advisory 잠금 → 범위 for key share(id 순) → 할 일 for key share → 멤버 행 → 범위 version 올림(범위 id 순, B1 bump_context_versions).
-- 같은 할 일의 사용자 쓰기끼리 반대 방향의 옮기기가 멤버 행을 서로 반대 순서로 잡아 교착하는 것을 막는다. 범위 · 할 일 행은 마지막 올림 전까지 for key share만 잡는다
-- (B3 move_memory_item과 같다). 자동 규칙의 멤버 추가(insert ... on conflict do nothing)와는 unique 인덱스에서 한 줄로 선다.
--
-- 멤버십 · 범위는 실행 권한에 닿지 않는다(I04 · I14 · D13): 이 함수는 execution_* 표를 읽거나 쓰지 않고 Action · Claim · 정책 · 승인을 바꾸지 않는다
-- (tests/db/context-members.scenarios.ts가 확인). 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지).
-- 20261104000000_context_layer 뒤에 적용한다.

begin;

create function public.change_context_membership_by_user(
  p_user_id uuid,
  p_action_id uuid,
  p_add_context_id uuid,
  p_expected_add_version integer,
  p_remove_context_id uuid,
  p_expected_remove_version integer
)
returns table (
  status text,
  added_member jsonb,
  removed_member jsonb,
  added_changed boolean,
  removed_changed boolean,
  added_version integer,
  removed_version integer
)
language plpgsql
set search_path = ''
as $$
declare
  v_step record;
  v_row public.context_members%rowtype;
  v_id uuid;
  v_was_member boolean;
  v_add_id uuid;
  v_remove_id uuid;
  v_add_member jsonb;
  v_remove_member jsonb;
  v_add_changed boolean := false;
  v_remove_changed boolean := false;
  v_add_version integer;
  v_remove_version integer;
begin
  if (p_add_context_id is null and p_remove_context_id is null) or p_add_context_id = p_remove_context_id
     or (p_add_context_id is null) <> (p_expected_add_version is null)
     or (p_remove_context_id is null) <> (p_expected_remove_version is null) then
    raise exception 'change_context_membership_by_user: give a context (with its expected version) to add and/or a different one to remove' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(concat_ws(':', 'context_member_user', p_user_id, p_action_id), 0));

  -- 내 active 범위만, 둘 다 확인한 뒤에만 쓴다 (id 순으로 잠근다). 읽은 version은 잠금을 잡은 뒤의 커밋된 값이다
  for v_step in
    select t.context_id from (values (p_add_context_id), (p_remove_context_id)) as t (context_id) where t.context_id is not null order by t.context_id
  loop
    perform 1 from public.work_contexts c where c.id = v_step.context_id and c.user_id = p_user_id and c.status = 'active' for key share;
    if not found then
      return query select 'context_not_found'::text, null::jsonb, null::jsonb, false, false, null::integer, null::integer;
      return;
    end if;
  end loop;

  perform 1 from public.actions a where a.id = p_action_id and a.user_id = p_user_id for key share;
  if not found then
    return query select 'action_not_found'::text, null::jsonb, null::jsonb, false, false, null::integer, null::integer;
    return;
  end if;

  -- 조건: 요청이 본 version과 지금이 다르면 쓰지 않는다
  perform 1 from public.work_contexts c
   where (c.id = p_add_context_id and c.context_version <> p_expected_add_version)
      or (c.id = p_remove_context_id and c.context_version <> p_expected_remove_version);
  if found then
    return query select 'conflict'::text, null::jsonb, null::jsonb, false, false, null::integer, null::integer;
    return;
  end if;

  for v_step in
    select t.context_id, t.included from (values (p_remove_context_id, false), (p_add_context_id, true)) as t (context_id, included) where t.context_id is not null
  loop
    v_id := null;
    select m.* into v_row from public.context_members m
     where m.user_id = p_user_id and m.context_id = v_step.context_id and m.action_id = p_action_id
     for update;
    if not found then
      insert into public.context_members as m (user_id, context_id, member_kind, action_id, origin, confidence, removed_at)
      values (p_user_id, v_step.context_id, 'action', p_action_id, 'user', null, case when v_step.included then null else now() end)
      on conflict (context_id, action_id) do nothing
      returning m.id into v_id;
      if v_id is not null then
        v_was_member := false;
      else
        -- 자동 규칙이 그 사이 같은 멤버를 넣었다 (그 행이 커밋되기를 기다린 뒤 읽는다)
        select m.* into v_row from public.context_members m
         where m.user_id = p_user_id and m.context_id = v_step.context_id and m.action_id = p_action_id
         for update;
      end if;
    end if;
    if v_id is null then
      v_was_member := v_row.removed_at is null and v_row.origin <> 'inferred';
      if v_row.origin = 'user' and (v_row.removed_at is null) = v_step.included then
        v_id := v_row.id;
      else
        update public.context_members m
           set origin = 'user', confidence = null, removed_at = case when v_step.included then null else now() end
         where m.id = v_row.id
        returning m.id into v_id;
      end if;
    end if;
    if v_step.included then
      v_add_id := v_id;
      v_add_changed := not v_was_member;
    else
      v_remove_id := v_id;
      v_remove_changed := v_was_member;
    end if;
  end loop;

  -- 이 쓰기가 올린 version을 commit 전에 확정한다 (B1 큐를 지금 비운다: 범위 행을 id 순으로 잠그고 올린다). 쓴 것이 없으면 큐도 비어 있다.
  -- 그 뒤 읽는 값은 우리가 잠근 행의 값이라 정확하다. 이 호출이 더 큰 트랜잭션 안일 수 있어 끝나면 다시 미룬다
  set constraints public.context_version_bumps_flush immediate;
  set constraints public.context_version_bumps_flush deferred;
  if p_add_context_id is not null then
    select c.context_version into v_add_version from public.work_contexts c where c.id = p_add_context_id;
    select to_jsonb(m) - 'user_id' into v_add_member from public.context_members m where m.id = v_add_id;
  end if;
  if p_remove_context_id is not null then
    select c.context_version into v_remove_version from public.work_contexts c where c.id = p_remove_context_id;
    select to_jsonb(m) - 'user_id' into v_remove_member from public.context_members m where m.id = v_remove_id;
  end if;

  return query select 'ok'::text, v_add_member, v_remove_member, v_add_changed, v_remove_changed, v_add_version, v_remove_version;
end;
$$;

-- 서버(service role)만 부른다. 앱 · 익명은 부르지 못한다 (앱은 work_contexts · context_members를 읽기만 한다)
revoke all on function public.change_context_membership_by_user(uuid, uuid, uuid, integer, uuid, integer) from public, anon, authenticated;
grant execute on function public.change_context_membership_by_user(uuid, uuid, uuid, integer, uuid, integer) to service_role;

commit;
