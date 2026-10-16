-- 0.2.0 OA D4c-2 · D4c-3b: 이슈 이동 · 삭제 · 병합과 organize 의도 (서버). 계약: handoffs/oa-d4c2-contract.md (8.1 코디네이터 결정이 본문보다 이긴다).
-- 설계: Assistant 계약 v3 6.1(이동 · 삭제 · 병합 · 확인 카드 = 제안 · Undo · 이벤트) · 런타임 계약 2장(의도 · 제안과 채택).
-- 새 표 · 새 열은 없다. 서버(service role) 전용 함수 · 기존 함수 교체 · 제약 · 트리거 목록 · 색인뿐이다.
--
-- 이 파일이 하는 일
--  1) change_context_membership_with_metric: 기존 change_context_membership_by_user(S3b)를 그대로 부르고, 실제 변화가 있을 때만 같은 트랜잭션에서 metric_events issue_moved 한 줄.
--     메뉴 route 둘은 via 'menu', 말로 이동은 via 'talk'. by_user는 바꾸지 않는다 (시그니처 · 권한 · S3b 시험 그대로).
--  2) organize_lookup: 이 사용자의 이슈(번호 · id)와 범위를 한 번에 읽는다 (stable, 읽기만). 대화 모듈이 실행 표 이름을 직접 쓰지 않으려고 SQL 함수로 둔다.
--  3) apply_organize_moves: 말로 이동(여러 개)을 한 턴 안에서 차례로 쓰는 내부 함수. 앞 쓰기가 올린 범위 version은 같은 턴의 일이라 처음 본 version 하나만 조건으로 건다.
--  4) conversation_finish_turn 통째 교체 (2.11): 본문은 B2 원본(20261106000000)을 글자 그대로 옮기고 `-- D4c-2 시작` ~ `-- D4c-2 끝` 표시 사이만 더했다 (tests/db/issue-organize T4가 본문 동일성을 본다).
--     - adopt.kind가 move · delete · merge인 제안의 채택. adopt에 kind가 없으면(옛 create_action) 동작이 한 글자도 다르지 않다.
--     - p_turn.move(≤3): 말로 이동. 기억 · 채택 뒤, 답 쓰기 전에 같은 트랜잭션. 하나라도 어긋나면 이 turn 전체를 되돌린다 (conflict).
--     - 예외 목록에 55P03: 삭제 · 병합으로 닫는 쪽 Action의 대화 run 정리가 메시지 행을 NOWAIT로 잡다 실패하면 이 turn을 되돌리고 conflict.
--  5) 삭제 · 병합 (몫 ②): action_events.type에 user_merged(목록 전체 교체) · 색인 action_events_user_merged_into_idx("From #144" 읽기) ·
--     코디네이터 트리거 coordinator_on_action_decision의 WHEN 목록(함수 본문은 그대로) · coordinator_recover_missing 통째 교체(결정 회수 목록 한 줄) ·
--     match_actions_for_ask 통째 교체(병합으로 닫은 중복도 물어보기 검색에서 뺀다, 조건 한 줄). 두 교체도 원본(20261114000000 · 20261004000000)과 글자 그대로다(`-- D4c-2 변경` 표시 한 줄만).
--  6) apply_organize_change: 삭제 · 병합의 쓰기 (write_action으로 사용자 Claim dropped + 이벤트, 병합의 남는 쪽은 확인만). conversation_confirm_proposal · conversation_dismiss_proposal:
--     카드 버튼. 확인 한 번에 한 트랜잭션: 제안 adopted · 기록 줄(event) · 쓰기. 낡았으면 쓰기 0 + 409 superseded + 새 카드, 열린 대화 run 정리의 잠금 실패(55P03)는 busy. 글 "응"(adopt.kind delete · merge)은 finish_turn 안에서 같은 apply_organize_change를 부른다.
--  운영 적용은 병합 직전 승인 뒤 `supabase db query --linked -f`로 한다 (db push 금지). 20261123000000_agent_path_leases 뒤에 적용한다.
--  되돌리기: 새 함수를 drop하고 conversation_finish_turn을 20261106000000의 정의로 다시 적용한다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 이동 지표 래퍼. p_via: menu(멤버 route) · talk(말로 이동). 결과 행은 by_user 그대로다.
--    지표는 실제 멤버가 바뀐 때만(added_changed or removed_changed): 이미 그 상태인 쓰기 · conflict · not_found는 0행. Undo도 이동으로 센다 (앞뒤 줄로 분석에서 구별).
-- ─────────────────────────────────────────────
create function public.change_context_membership_with_metric(
  p_user_id uuid,
  p_action_id uuid,
  p_add_context_id uuid,
  p_expected_add_version integer,
  p_remove_context_id uuid,
  p_expected_remove_version integer,
  p_via text
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
  v_row record;
begin
  if p_via is null or p_via not in ('menu', 'talk') then
    raise exception 'change_context_membership_with_metric: via must be menu or talk' using errcode = '22023';
  end if;

  select * into v_row
    from public.change_context_membership_by_user(p_user_id, p_action_id, p_add_context_id, p_expected_add_version, p_remove_context_id, p_expected_remove_version);

  if v_row.status = 'ok' and (v_row.added_changed or v_row.removed_changed) then
    insert into public.metric_events (user_id, type, action_id, props)
    values (
      p_user_id, 'issue_moved', p_action_id,
      jsonb_build_object(
        'via', p_via,
        'from_context', case when v_row.removed_changed then to_jsonb(p_remove_context_id) else 'null'::jsonb end,
        'to_context', case when v_row.added_changed then to_jsonb(p_add_context_id) else 'null'::jsonb end
      )
    );
  end if;

  return query select v_row.status, v_row.added_member, v_row.removed_member, v_row.added_changed, v_row.removed_changed, v_row.added_version, v_row.removed_version;
end;
$$;

-- ─────────────────────────────────────────────
-- 2) 정리 읽기. actions는 number 또는 id가 맞는 이 사용자의 행만 (상태 무관: 지운 이슈를 "이미 지움"으로 답하려고). 배열은 각각 10개까지.
--    contexts(각 이슈): 확인된 멤버십만 (removed_at 없음 · origin이 inferred가 아님, change_context_membership_by_user의 "확인된 멤버"와 같은 정의).
--    open_sessions: 그 이슈의 대화 run들의 서로 다른 세션 중 닫히지 않은 수 (삭제 카드의 "열린 세션 수"). evidence_count: 근거 행 수 (병합 카드).
--    범위 전체(contexts)는 이 사용자의 work_contexts 전부(active · archived), 이름순 500개까지.
-- ─────────────────────────────────────────────
create function public.organize_lookup(p_user_id uuid, p_numbers integer[], p_action_ids uuid[])
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_actions jsonb;
  v_contexts jsonb;
begin
  if coalesce(cardinality(p_numbers), 0) > 10 or coalesce(cardinality(p_action_ids), 0) > 10 then
    raise exception 'organize_lookup: at most 10 numbers and 10 ids' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'number', a.number, 'title', a.title, 'status', a.status, 'version', a.version,
           'open_sessions', (
             select count(distinct r.agent_session_id)
               from public.execution_runs r
               join public.agent_sessions s on s.id = r.agent_session_id and s.user_id = r.user_id
              where r.action_id = a.id and r.user_id = a.user_id and r.kind = 'conversation' and s.status <> 'closed'),
           'evidence_count', (select count(*) from public.evidence e where e.action_id = a.id and e.user_id = a.user_id),
           'contexts', coalesce((
             select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'status', c.status, 'context_version', c.context_version) order by c.name, c.id)
               from public.context_members m
               join public.work_contexts c on c.id = m.context_id and c.user_id = m.user_id
              where m.action_id = a.id and m.user_id = a.user_id and m.member_kind = 'action' and m.removed_at is null and m.origin <> 'inferred'), '[]'::jsonb)
         ) order by a.number), '[]'::jsonb)
    into v_actions
    from public.actions a
   where a.user_id = p_user_id
     and (a.number = any (coalesce(p_numbers, '{}'::integer[])) or a.id = any (coalesce(p_action_ids, '{}'::uuid[])));

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status, 'context_version', c.context_version) order by c.name, c.id), '[]'::jsonb)
    into v_contexts
    from (select x.* from public.work_contexts x where x.user_id = p_user_id order by x.name, x.id limit 500) c;

  return jsonb_build_object('actions', v_actions, 'contexts', v_contexts);
end;
$$;

-- ─────────────────────────────────────────────
-- 3) 말로 이동(여러 개)을 차례로 쓰는 내부 함수. p_moves = [{ action_id, add: { context_id, expected_version } | null, remove: { … } | null }] (1–3개).
--    항목마다 래퍼(via talk). ok가 아니면(conflict · 범위나 이슈가 사라짐) TF409로 이 turn 전체를 되돌린다.
--    같은 범위가 앞 항목에서 version이 올라도 conflict가 아니다: 처음 본 version 하나만 조건이고, 이어지는 항목은 앞 쓰기가 돌려준 version을 쓴다.
--    p_turn의 답 내용 reply.content.organize.results[i].change(TS는 null로 보낸다)를 쓰기 직후 값 { added: [{ context_id, context_version }], removed: [...] }으로 채워 돌려준다
--    (실제 바뀐 범위만: 앱 Undo가 그 version을 조건으로 역연산을 보낸다).
--    잠금 순서 (검토 P2-3): 이슈마다 (사용자 × 이슈) advisory 잠금을 action_id 순으로 **모두 먼저** 잡은 뒤에야 범위 행을 건드린다.
--    메뉴 이동(change_context_membership_by_user)은 이슈 advisory 잠금 → 범위 순이라 같은 순서다. 먼저 잡지 않으면 일괄 [A,B]→P가 A의 잠금과 범위 P의 version 올림을 쥔 채 B를 기다리고,
--    메뉴 B→P가 B의 잠금을 쥔 채 P를 기다려 서로 기다린다(교착). 일괄끼리도 같은 순서라 반대 순서로 낀 두 요청이 기다리지 않는다.
-- ─────────────────────────────────────────────
create function public.apply_organize_moves(p_user_id uuid, p_moves jsonb, p_turn jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_turn jsonb := p_turn;
  v_move jsonb;
  v_idx integer;
  v_seen jsonb := '{}'::jsonb;
  v_add uuid;
  v_remove uuid;
  v_exp_add integer;
  v_exp_remove integer;
  v_row record;
  v_lock uuid;
begin
  if jsonb_typeof(p_moves) <> 'array' or jsonb_array_length(p_moves) not between 1 and 3 then
    raise exception 'apply_organize_moves: move must be an array of 1-3 items' using errcode = '22023';
  end if;

  -- 이슈 잠금을 id 순으로 먼저 (change_context_membership_by_user와 같은 잠금 키; 같은 트랜잭션이라 안쪽 호출이 다시 잡아도 기다리지 않는다)
  for v_lock in
    select distinct (m ->> 'action_id')::uuid as action_id from jsonb_array_elements(p_moves) as m order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended(concat_ws(':', 'context_member_user', p_user_id, v_lock), 0));
  end loop;

  for v_idx in 0 .. jsonb_array_length(p_moves) - 1 loop
    v_move := p_moves -> v_idx;
    v_add := nullif(v_move #>> '{add,context_id}', '')::uuid;
    v_remove := nullif(v_move #>> '{remove,context_id}', '')::uuid;
    v_exp_add := case when v_add is null then null else coalesce((v_seen ->> v_add::text)::integer, (v_move #>> '{add,expected_version}')::integer) end;
    v_exp_remove := case when v_remove is null then null else coalesce((v_seen ->> v_remove::text)::integer, (v_move #>> '{remove,expected_version}')::integer) end;

    select * into v_row
      from public.change_context_membership_with_metric(p_user_id, (v_move ->> 'action_id')::uuid, v_add, v_exp_add, v_remove, v_exp_remove, 'talk');
    if v_row.status is distinct from 'ok' then
      raise exception 'apply_organize_moves: %', coalesce(v_row.status, 'failed') using errcode = 'TF409';
    end if;

    if v_add is not null then v_seen := jsonb_set(v_seen, array[v_add::text], to_jsonb(v_row.added_version)); end if;
    if v_remove is not null then v_seen := jsonb_set(v_seen, array[v_remove::text], to_jsonb(v_row.removed_version)); end if;

    if jsonb_typeof(v_turn #> array['reply', 'content', 'organize', 'results', v_idx::text]) = 'object' then
      v_turn := jsonb_set(
        v_turn,
        array['reply', 'content', 'organize', 'results', v_idx::text, 'change'],
        jsonb_build_object(
          'added', case when v_row.added_changed then jsonb_build_array(jsonb_build_object('context_id', v_add, 'context_version', v_row.added_version)) else '[]'::jsonb end,
          'removed', case when v_row.removed_changed then jsonb_build_array(jsonb_build_object('context_id', v_remove, 'context_version', v_row.removed_version)) else '[]'::jsonb end
        )
      );
    end if;
  end loop;
  return v_turn;
end;
$$;

-- ─────────────────────────────────────────────
-- 4) 한 번의 답 쓰기 (서버) — B2(20261106000000)의 정의를 글자 그대로 옮기고 표시한 블록만 더했다.
--    p_turn: B2의 모양 + { move: null | [{ action_id, add, remove }] (≤3) }, adopt: null | B2의 create_action 모양(kind 없음) |
--      { kind: 'move', proposal_message_id, proposal_id, payload_hash, moves } | { kind: 'delete' | 'merge', …, writes }
--    결과 값 · 상태(written · answered · stale · conflict · not_found)는 그대로다.
-- ─────────────────────────────────────────────
create or replace function public.conversation_finish_turn(p_user_id uuid, p_message_id uuid, p_turn jsonb)
returns table (status text, reply_id uuid, reply_seq integer, memory_ids uuid[], action_id uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages%rowtype;
  v_proposal_message public.conversation_messages%rowtype;
  v_reply uuid;
  v_seq integer;
  v_item jsonb;
  v_written record;
  v_memory_ids uuid[] := '{}';
  v_adopt jsonb := p_turn -> 'adopt';
  v_action uuid;
  v_note uuid;
  -- JSON null은 SQL null처럼 읽는다 (빈 refs · 내용 없음 · 의도 없음)
  v_reply_refs jsonb := coalesce(nullif(p_turn -> 'reply' -> 'refs', 'null'::jsonb), '{}'::jsonb);
  v_user_refs jsonb := coalesce(nullif(p_turn -> 'user' -> 'refs', 'null'::jsonb), '{}'::jsonb);
  v_added jsonb;
  -- D4c-2 시작
  v_kind text;
  v_targets jsonb;
  -- D4c-2 끝
begin
  if jsonb_typeof(v_reply_refs) <> 'object' or jsonb_typeof(v_user_refs) <> 'object' then
    raise exception 'conversation_finish_turn: refs must be objects' using errcode = '22023';
  end if;

  select * into v_message from public.conversation_messages m where m.id = p_message_id and m.user_id = p_user_id and m.role = 'user';
  if not found then
    return query select 'not_found'::text, null::uuid, null::integer, '{}'::uuid[], null::uuid;
    return;
  end if;
  -- post_message와 같은 순서로 잠근다 (대화 → 메시지)
  perform 1 from public.conversations c where c.id = v_message.conversation_id and c.user_id = p_user_id for update;

  select r.id, r.seq into v_reply, v_seq from public.conversation_messages r where r.reply_to = p_message_id;
  if v_reply is not null then
    return query select 'answered'::text, v_reply, v_seq, '{}'::uuid[], null::uuid;
    return;
  end if;

  if exists (
    select 1 from public.conversation_messages n
     where n.conversation_id = v_message.conversation_id and n.role = 'user' and n.seq > v_message.seq
  ) then
    update public.conversation_messages m set reply_lease_until = null where m.id = p_message_id;
    return query select 'stale'::text, null::uuid, null::integer, '{}'::uuid[], null::uuid;
    return;
  end if;

  begin
    -- 답이 인용한 원문을 먼저 잠근다 (id 순, for share): 원문 글 지우기 · B1 기억 쓰기와 같은 순서(원문 → 기억 · 메시지 행)로 선다.
    -- 답을 넣을 때 가드(conversation_messages_citation_guard)가 같은 원문의 지금 상태로 인용을 고친다 (4장)
    perform 1
       from public.sources s
      where s.user_id = p_user_id
        and s.id in (
          select (c ->> 'source_id')::uuid
            from jsonb_array_elements(case when jsonb_typeof(p_turn -> 'reply' -> 'content' -> 'citations') = 'array'
                                           then p_turn -> 'reply' -> 'content' -> 'citations' else '[]'::jsonb end) c
           where coalesce(c ->> 'source_id', '') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      order by s.id
      for share;

    -- 기억: 같은 범위 · 같은 사실 규칙은 remember_memory_item이 지킨다. 하나라도 conflict면 이 turn 전체를 되돌린다
    for v_item in select value from jsonb_array_elements(case when jsonb_typeof(p_turn -> 'memory') = 'array' then p_turn -> 'memory' else '[]'::jsonb end) loop
      begin
        select * into v_written
          from public.remember_memory_item(p_user_id, v_item -> 'item', (v_item ->> 'corrects')::uuid, (v_item ->> 'expected_version')::integer);
      exception
        -- 기억의 범위(work_contexts)가 그 사이 지워짐: 다시 보내게 conflict (복합 외래키 (context_id, user_id))
        when foreign_key_violation then
          raise exception 'conversation_finish_turn: memory scope is gone' using errcode = 'TF409';
      end;
      if v_written.status is distinct from 'written' then
        raise exception 'conversation_finish_turn: memory conflict' using errcode = 'TF409';
      end if;
      v_memory_ids := v_memory_ids || v_written.id;
    end loop;

    -- 제안 채택 (A41): 제안 메시지를 잠그고, 같은 대화의 assistant 메시지 · 같은 proposal id · 같은 payload_hash · state open일 때만
    -- D4c-2 시작
    -- 이동 · 삭제 · 병합 제안의 채택 (adopt.kind). kind가 없거나 create_action이면 이 블록은 건너뛰고 아래 원래 본문이 그대로 받는다.
    -- 같은 대화의 assistant 메시지 · 같은 proposal id · 같은 payload_hash · 같은 종류 · state open일 때만. 하나라도 어긋나면 이 turn 전체를 되돌린다 (TF409).
    v_kind := coalesce(v_adopt ->> 'kind', 'create_action');
    if v_adopt is not null and jsonb_typeof(v_adopt) = 'object' and v_kind <> 'create_action' then
      if v_kind not in ('move', 'delete', 'merge') then
        raise exception 'conversation_finish_turn: unknown adopt kind' using errcode = '22023';
      end if;
      select * into v_proposal_message
        from public.conversation_messages m
       where m.id = (v_adopt ->> 'proposal_message_id')::uuid and m.user_id = p_user_id
         and m.conversation_id = v_message.conversation_id and m.role = 'assistant'
       for update;
      if not found
         or (v_proposal_message.refs -> 'proposal' ->> 'id') is distinct from (v_adopt ->> 'proposal_id')
         or (v_proposal_message.refs -> 'proposal' ->> 'payload_hash') is distinct from (v_adopt ->> 'payload_hash')
         or (v_proposal_message.refs -> 'proposal' ->> 'kind') is distinct from v_kind
         or (v_proposal_message.refs -> 'proposal' ->> 'state') is distinct from 'open' then
        raise exception 'conversation_finish_turn: proposal is not open' using errcode = 'TF409';
      end if;

      if v_kind = 'move' then
        p_turn := public.apply_organize_moves(p_user_id, v_adopt -> 'moves', p_turn);
        v_targets := (select coalesce(jsonb_agg(x ->> 'action_id'), '[]'::jsonb) from jsonb_array_elements(v_adopt -> 'moves') x);
      else
        -- 삭제 · 병합: 카드 버튼(conversation_confirm_proposal)과 같은 쓰기다. 대상이 카드 뒤에 바뀌었으면 TF409로 이 turn 전체를 되돌린다
        perform public.apply_organize_change(p_user_id, v_kind, v_adopt -> 'writes');
        v_targets := (select coalesce(jsonb_agg(distinct x ->> 'action_id'), '[]'::jsonb) from jsonb_array_elements(v_adopt -> 'writes') x);
      end if;

      update public.conversation_messages m
         set refs = jsonb_set(
                      jsonb_set(m.refs, '{proposal,state}', '"adopted"'::jsonb),
                      '{action_ids}',
                      (select coalesce(jsonb_agg(distinct t), '[]'::jsonb)
                         from jsonb_array_elements_text(coalesce(m.refs -> 'action_ids', '[]'::jsonb) || coalesce(v_targets, '[]'::jsonb)) t))
       where m.id = v_proposal_message.id;
      v_adopt := null;
    end if;
    -- D4c-2 끝
    if v_adopt is not null and jsonb_typeof(v_adopt) = 'object' then
      select * into v_proposal_message
        from public.conversation_messages m
       where m.id = (v_adopt ->> 'proposal_message_id')::uuid and m.user_id = p_user_id
         and m.conversation_id = v_message.conversation_id and m.role = 'assistant'
       for update;
      if not found
         or (v_proposal_message.refs -> 'proposal' ->> 'id') is distinct from (v_adopt ->> 'proposal_id')
         or (v_proposal_message.refs -> 'proposal' ->> 'payload_hash') is distinct from (v_adopt ->> 'payload_hash')
         or (v_proposal_message.refs -> 'proposal' ->> 'kind') is distinct from 'create_action'
         or (v_proposal_message.refs -> 'proposal' ->> 'state') is distinct from 'open' then
        raise exception 'conversation_finish_turn: proposal is not open' using errcode = 'TF409';
      end if;

      v_action := (v_adopt ->> 'action_id')::uuid;
      v_note := (v_adopt -> 'note' ->> 'id')::uuid;
      -- 채택한 발화 한 줄 = 사용자 원문(kind note). 처리할 원문이 아니다: 처리 완료로 넣어 재처리 cron이 추출하지 않게 한다
      insert into public.sources (id, user_id, kind, title, raw_text, occurred_at, external_url, processing_status, processed_at)
      values (v_note, p_user_id, 'note', v_adopt -> 'note' ->> 'title', v_adopt -> 'note' ->> 'raw_text', now(),
              v_adopt -> 'note' ->> 'external_url', 'done', now());
      if not public.write_action(
        p_user_id, v_action, null, v_adopt -> 'action',
        coalesce(v_adopt -> 'claims', '[]'::jsonb), coalesce(v_adopt -> 'evidence', '[]'::jsonb), coalesce(v_adopt -> 'events', '[]'::jsonb)
      ) then
        raise exception 'conversation_finish_turn: action not written';
      end if;
      update public.conversation_messages m
         set refs = jsonb_set(
                      jsonb_set(m.refs, '{proposal,state}', '"adopted"'::jsonb),
                      '{action_ids}', coalesce(m.refs -> 'action_ids', '[]'::jsonb) || jsonb_build_array(v_action))
       where m.id = v_proposal_message.id;
    end if;

    -- D4c-2 시작
    -- 말로 이동 (p_turn.move, ≤3): 기억 · 채택 뒤, 답 쓰기 전에 같은 트랜잭션으로 쓴다. 답 내용의 change는 쓰기 직후 값으로 채운다.
    -- 하나라도 어긋나면(범위 version 변경 · 범위나 이슈가 사라짐) TF409로 이 turn 전체를 되돌린다. 배열이 아니거나 3개를 넘으면 22023.
    if jsonb_typeof(p_turn -> 'move') = 'array' and jsonb_array_length(p_turn -> 'move') > 0 then
      p_turn := public.apply_organize_moves(p_user_id, p_turn -> 'move', p_turn);
    elsif coalesce(jsonb_typeof(p_turn -> 'move'), 'null') not in ('null', 'array') then
      raise exception 'conversation_finish_turn: move must be an array' using errcode = '22023';
    end if;
    -- D4c-2 끝
    -- 서버가 만든 것(기억 · 채택 Action)을 답과 사용자 메시지의 refs에 더한다
    v_added := jsonb_build_object(
      'memory_item_ids', coalesce(v_reply_refs -> 'memory_item_ids', '[]'::jsonb) || to_jsonb(v_memory_ids),
      'action_ids', coalesce(v_reply_refs -> 'action_ids', '[]'::jsonb) || case when v_action is null then '[]'::jsonb else jsonb_build_array(v_action) end
    );
    v_reply_refs := v_reply_refs || v_added;
    v_user_refs := v_user_refs || jsonb_build_object(
      'action_ids', coalesce(v_user_refs -> 'action_ids', '[]'::jsonb) || case when v_action is null then '[]'::jsonb else jsonb_build_array(v_action) end
    );

    -- 새 제안이 나오면 같은 대화의 앞 열린 제안은 superseded (런타임 계약 2장)
    if jsonb_typeof(v_reply_refs -> 'proposal') = 'object' then
      update public.conversation_messages m
         set refs = jsonb_set(m.refs, '{proposal,state}', '"superseded"'::jsonb)
       where m.conversation_id = v_message.conversation_id and m.role = 'assistant' and m.refs -> 'proposal' ->> 'state' = 'open';
    end if;

    select coalesce(max(m.seq), 0) + 1 into v_seq from public.conversation_messages m where m.conversation_id = v_message.conversation_id;
    insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, content, reply_to)
    values (p_user_id, v_message.conversation_id, v_seq, 'assistant', coalesce(p_turn -> 'reply' ->> 'text', ''), v_reply_refs,
            nullif(p_turn -> 'reply' -> 'content', 'null'::jsonb), p_message_id)
    returning id into v_reply;

    update public.conversation_messages m
       set intent = nullif(p_turn -> 'user' -> 'intent', 'null'::jsonb), refs = v_user_refs, reply_lease_until = null
     where m.id = p_message_id;
    update public.conversations c set last_message_at = now() where c.id = v_message.conversation_id;
  exception
    -- TF409: 기억 version · 제안 상태가 바뀜. P0002: 정정하려던 기억이 그 사이 지워짐 (remember_memory_item: memory not found).
    -- 40P01: 다른 쓰기(범위 삭제 등)와 잠금이 엇갈려 교착 — 이 turn만 되돌리고 다시 보내게 한다 (기억 쓰기는 서버가 잠금 열쇠 순서로 보낸다)
    when sqlstate 'TF409' or sqlstate 'P0002' or sqlstate '40P01'
    -- D4c-2 시작
    -- 55P03: 삭제 · 병합으로 닫는 쪽의 대화 run 정리가 메시지 행을 NOWAIT로 잡다 실패함 — 이 turn만 되돌리고 다시 보내게 한다
    or sqlstate '55P03'
    -- D4c-2 끝
    then
      update public.conversation_messages m set reply_lease_until = null where m.id = p_message_id;
      return query select 'conflict'::text, null::uuid, null::integer, '{}'::uuid[], null::uuid;
      return;
  end;

  return query select 'written'::text, v_reply, v_seq, v_memory_ids, v_action;
end;
$$;

-- ─────────────────────────────────────────────
-- 5) action_events에 user_merged (이슈 병합으로 사라지는 쪽을 닫는 사용자 이벤트, after: { status, into: 남는 쪽 id }).
--    20261029000000_action_notes의 목록 전체를 그대로 옮기고 user_merged 하나만 더했다 (이전 교체들과 같은 방식). 다른 값 · actor 제약은 그대로다.
-- ─────────────────────────────────────────────
alter table public.action_events
  drop constraint action_events_type_check,
  add constraint action_events_type_check check (type in (
    'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
    'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created',
    'user_unstarted', 'artifact_created', 'user_seen', 'user_notes_updated', 'user_merged'
  ));

-- "From #144" 읽기 (앱이 RLS로): 남는 쪽 id로 이어진 병합 이벤트를 찾는다
create index action_events_user_merged_into_idx on public.action_events (user_id, (after ->> 'into')) where type = 'user_merged';

-- ─────────────────────────────────────────────
-- 6) 코디네이터: 사용자 결정 사건 목록에 user_merged. 트리거 함수 본문(coordinator_on_action_decision)은 그대로, 트리거의 WHEN 목록만 바꾼다 (20261110000000_coordinator_core).
--    drop과 create가 한 트랜잭션(action_events 잠금)이라 사이에 놓치는 insert가 없다.
-- ─────────────────────────────────────────────
drop trigger coordinator_on_action_decision on public.action_events;
create trigger coordinator_on_action_decision
  after insert on public.action_events
  for each row
  when (new.actor = 'user' and new.type in ('user_confirmed', 'user_deleted', 'user_edited', 'completed', 'dropped', 'reopened', 'user_merged'))
  execute function public.coordinator_on_action_decision();

-- ─────────────────────────────────────────────
-- 7) 회수 sweep도 같은 목록이다: coordinator_recover_missing을 20261114000000_conversation_agent_target의 정의에서 글자 그대로 옮기고 결정 회수의 목록 한 줄에만 user_merged를 더했다
--    (표시: `-- D4c-2 변경`). 시그니처 · 권한 · agent 대화 제외 조건은 그대로다.
-- ─────────────────────────────────────────────
create or replace function public.coordinator_recover_missing(p_lookback_seconds integer, p_limit integer) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := public.db_now();
  v_since timestamptz;
  v_count integer;
  v_total integer := 0;
begin
  if p_lookback_seconds is null or p_lookback_seconds not between 60 and 604800 or p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'coordinator_recover_missing: 인자가 범위 밖이다 (기간 60초–7일 · limit 1–1000)' using errcode = '22023';
  end if;
  v_since := v_now - make_interval(secs => p_lookback_seconds);

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select s.user_id,
         case when cardinality(public.source_document_ids(s.user_id, s.id)) > 1 then 'source_revised' else 'source_processed' end,
         'source:' || s.id::text, jsonb_build_object('source_id', s.id, 'kind', s.kind), v_now
    from (
      select x.* from public.sources x
       where x.processing_status = 'done' and x.kind <> 'execution' and x.processing_summary is not null and x.processed_at >= v_since
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'source:' || x.id::text)
       order by x.processed_at, x.id limit p_limit
    ) s
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select m.user_id, 'user_message', 'message:' || m.id::text, jsonb_build_object('conversation_id', m.conversation_id, 'message_id', m.id), v_now
    from (
      select x.* from public.conversation_messages x
       where x.role = 'user' and x.created_at >= v_since
         and not exists (select 1 from public.conversations c where c.id = x.conversation_id and c.user_id = x.user_id and c.target_kind = 'agent')
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'message:' || x.id::text)
       order by x.created_at, x.id limit p_limit
    ) m
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  insert into public.inbox_events (user_id, type, dedup_key, refs, created_at)
  select a.user_id, 'decision_made', 'action_event:' || a.id::text, jsonb_build_object('action_id', a.action_id, 'action_event_id', a.id, 'kind', a.type), v_now
    from (
      select x.* from public.action_events x
       -- D4c-2 변경: 결정 회수 목록에 user_merged
       where x.actor = 'user' and x.type in ('user_confirmed', 'user_deleted', 'user_edited', 'completed', 'dropped', 'reopened', 'user_merged') and x.created_at >= v_since
         and not exists (select 1 from public.inbox_events e where e.user_id = x.user_id and e.dedup_key = 'action_event:' || x.id::text)
       order by x.created_at, x.id limit p_limit
    ) a
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  return v_total;
end;
$$;

-- ─────────────────────────────────────────────
-- 8) 물어보기 검색: 병합으로 닫은 중복도 지운 것(오판)처럼 뺀다 (원칙 4: 같은 일이 답에 두 번 나오지 않게).
--    match_actions_for_ask를 20261004000000_ask의 정의에서 글자 그대로 옮기고 제외 조건 한 줄만 넓혔다 (표시: `-- D4c-2 변경`). 시그니처 · 권한 그대로.
-- ─────────────────────────────────────────────
create or replace function public.match_actions_for_ask(
  p_user_id uuid,
  p_embedding extensions.vector(1536),
  p_count int default 8,
  p_closed_since timestamptz default now() - interval '30 days'
)
returns table (id uuid, similarity double precision)
language sql stable
set search_path = ''
as $$
  with mine as materialized (
    select a.id, a.embedding from public.actions a
    where a.user_id = p_user_id
      and a.embedding is not null
      and (a.status = 'open' or a.updated_at >= p_closed_since)
      and not (
        a.status = 'dropped'
        and exists (
          select 1 from public.action_events e
          -- D4c-2 변경: 병합으로 닫은 중복도 지운 것처럼 뺀다
          where e.action_id = a.id and e.user_id = p_user_id and e.type in ('user_deleted', 'user_merged')
        )
      )
  )
  select m.id, 1 - (m.embedding operator(extensions.<=>) p_embedding) as similarity
  from mine m
  order by m.embedding operator(extensions.<=>) p_embedding
  limit p_count;
$$;

-- ─────────────────────────────────────────────
-- 9) 삭제 · 병합을 쓰는 내부 함수. p_writes = [{ action_id, expected_version, action: obj | null, claims: [], events: [] }] (삭제 1–3개 / 병합 둘).
--    action_id 오름차순으로 처리한다 (잠금 순서: 같은 두 이슈를 반대로 병합하는 요청 둘이 서로 기다리지 않는다).
--    action이 있으면 write_action(읽은 version이 조건)으로 쓰고(삭제 경로와 같은 쓰기: user Claim status dropped + user_deleted/user_merged 이벤트),
--    없으면(병합의 남는 쪽) 값은 바꾸지 않고 version이 그대로이고 dropped가 아닌지만 for share로 확인한다 (그 사이 PATCH · 다른 병합이 끼어들지 못하게 잡아 둔다).
--    어긋나면 TF409. 열린 대화 run 정리는 쓰지 않는다: 사용자 Claim status dropped가 기존 트리거(stop_agent_runs_on_user_claim)로 Done과 같은 규칙으로 멈춘다
--    (그 트리거가 메시지 행을 NOWAIT로 잡다 실패하면 55P03 — 호출한 쪽이 되돌린다).
-- ─────────────────────────────────────────────
create function public.apply_organize_change(p_user_id uuid, p_kind text, p_writes jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_item jsonb;
  v_id uuid;
  v_row record;
  v_writing integer;
begin
  if p_kind is null or p_kind not in ('delete', 'merge') then
    raise exception 'apply_organize_change: kind must be delete or merge' using errcode = '22023';
  end if;
  if jsonb_typeof(p_writes) <> 'array' or jsonb_array_length(p_writes) not between 1 and 3 then
    raise exception 'apply_organize_change: writes must be an array of 1-3 items' using errcode = '22023';
  end if;
  select count(*) into v_writing from jsonb_array_elements(p_writes) x where jsonb_typeof(x -> 'action') = 'object';
  if (p_kind = 'delete' and v_writing <> jsonb_array_length(p_writes)) or (p_kind = 'merge' and (jsonb_array_length(p_writes) <> 2 or v_writing <> 1)) then
    raise exception 'apply_organize_change: unexpected shape for %', p_kind using errcode = '22023';
  end if;

  for v_item in select x.value from jsonb_array_elements(p_writes) x order by (x.value ->> 'action_id')::uuid loop
    v_id := (v_item ->> 'action_id')::uuid;
    if jsonb_typeof(v_item -> 'action') = 'object' then
      if not public.write_action(
        p_user_id, v_id, (v_item ->> 'expected_version')::integer, v_item -> 'action',
        coalesce(v_item -> 'claims', '[]'::jsonb), '[]'::jsonb, coalesce(v_item -> 'events', '[]'::jsonb)
      ) then
        raise exception 'apply_organize_change: action changed' using errcode = 'TF409';
      end if;
    else
      select a.version, a.status into v_row from public.actions a where a.id = v_id and a.user_id = p_user_id for share;
      if not found or v_row.version is distinct from (v_item ->> 'expected_version')::integer or v_row.status = 'dropped' then
        raise exception 'apply_organize_change: action changed' using errcode = 'TF409';
      end if;
    end if;
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 10) 확인 카드의 버튼: 삭제 · 병합 확인 (conversation_confirm_proposal) · 취소 (conversation_dismiss_proposal).
--    p_plan = { payload_hash, writes, event: { text, content }, reissue: { proposal, text, content } | null } — TS가 카드 · 지금 기록을 읽어 만든다 (순수 함수, 값은 삭제 경로와 같다).
--    잠금 순서는 finish_turn과 같다: 대화 → 카드 메시지 → (원문 없음) → Action(id 순) → claims → 트리거(run · task · 메시지 NOWAIT).
--    결과 status: confirmed(썼다) · already(이미 채택한 카드: 쓰기 0, 그 event 행 id) · superseded(TS가 읽은 대로 대상이 카드 뒤에 바뀜: 쓰기 0, 앞 카드는 superseded, card_id = 새 카드) ·
--      changed(TS가 읽은 뒤 쓰기 전에 바뀜: 쓰기 0, 아무것도 안 바뀜 — TS가 다시 읽어 계획한다) · not_open(취소됐거나 다른 제안으로 대체됨) ·
--      not_found(없는 · 남의 · 삭제/병합이 아닌 제안, 에이전트 대화) · busy(55P03 · 교착: 쓰기 0, 다시 보내면 된다).
--    확인은 AI를 부르지 않는다 (동의 검사 없음).
-- ─────────────────────────────────────────────
create function public.conversation_confirm_proposal(p_user_id uuid, p_conversation_id uuid, p_proposal_id uuid, p_plan jsonb)
returns table (status text, event_id uuid, card_id uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_card public.conversation_messages%rowtype;
  v_kind text;
  v_writes jsonb := coalesce(p_plan -> 'writes', '[]'::jsonb);
  v_reissue jsonb := nullif(p_plan -> 'reissue', 'null'::jsonb);
  v_targets jsonb;
  v_event uuid;
  v_new uuid;
  v_seq integer;
begin
  perform 1 from public.conversations c where c.id = p_conversation_id and c.user_id = p_user_id and c.target_kind = 'taskforce' for update;
  if not found then
    return query select 'not_found'::text, null::uuid, null::uuid;
    return;
  end if;
  select * into v_card
    from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.user_id = p_user_id and m.role = 'assistant' and (m.refs -> 'proposal' ->> 'id') = p_proposal_id::text
   for update;
  v_kind := v_card.refs -> 'proposal' ->> 'kind';
  if not found or v_kind is null or v_kind not in ('delete', 'merge') then
    return query select 'not_found'::text, null::uuid, null::uuid;
    return;
  end if;
  if v_card.refs -> 'proposal' ->> 'state' = 'adopted' then
    select m.id into v_event from public.conversation_messages m
     where m.conversation_id = p_conversation_id and m.role = 'event' and (m.refs -> 'proposal' ->> 'id') = p_proposal_id::text order by m.seq limit 1;
    return query select 'already'::text, v_event, null::uuid;
    return;
  end if;
  if v_card.refs -> 'proposal' ->> 'state' <> 'open' or (v_card.refs -> 'proposal' ->> 'payload_hash') is distinct from (p_plan ->> 'payload_hash') then
    return query select 'not_open'::text, null::uuid, null::uuid;
    return;
  end if;

  -- 쓰기 계획이 비어 있으면 TS가 이미 카드 뒤에 대상이 바뀐 것을 본 것이다: 쓰지 않고 아래 superseded로 간다
  if jsonb_array_length(v_writes) > 0 then
    begin
      perform public.apply_organize_change(p_user_id, v_kind, v_writes);
      v_targets := (select coalesce(jsonb_agg(distinct x ->> 'action_id'), '[]'::jsonb) from jsonb_array_elements(v_writes) x);
      update public.conversation_messages m
         set refs = jsonb_set(
                      jsonb_set(m.refs, '{proposal,state}', '"adopted"'::jsonb),
                      '{action_ids}',
                      (select coalesce(jsonb_agg(distinct t), '[]'::jsonb) from jsonb_array_elements_text(coalesce(m.refs -> 'action_ids', '[]'::jsonb) || v_targets) t))
       where m.id = v_card.id;
      select coalesce(max(m.seq), 0) + 1 into v_seq from public.conversation_messages m where m.conversation_id = p_conversation_id;
      insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, content)
      values (
        p_user_id, p_conversation_id, v_seq, 'event', coalesce(p_plan -> 'event' ->> 'text', ''),
        jsonb_build_object('proposal', jsonb_build_object('id', p_proposal_id, 'kind', v_kind, 'payload_hash', v_card.refs -> 'proposal' ->> 'payload_hash', 'state', 'adopted'), 'action_ids', v_targets),
        nullif(p_plan -> 'event' -> 'content', 'null'::jsonb)
      )
      returning id into v_event;
      update public.conversations c set last_message_at = now() where c.id = p_conversation_id;
      return query select 'confirmed'::text, v_event, null::uuid;
      return;
    exception
      -- TS가 카드 그대로라고 읽은 뒤 쓰기 전에 대상이 바뀜(version · 이미 닫힘) · 이슈가 사라짐: 쓰기 계획이 낡았다. 아무것도 바꾸지 않고 changed —
      -- TS가 지금 기록으로 다시 계획하면 쓰기 없이 새 카드를 담은 superseded가 된다 (낡은 기록으로 만든 새 카드를 대화에 내지 않으려고 여기서 내지 않는다)
      when sqlstate 'TF409' or sqlstate 'P0002' then
        return query select 'changed'::text, null::uuid, null::uuid;
        return;
      -- 열린 대화 run 정리가 메시지 행을 NOWAIT로 잡다 실패(55P03) · 교착(40P01): 이 확인만 되돌리고 다시 하게 한다
      when sqlstate '55P03' or sqlstate '40P01' then
        return query select 'busy'::text, null::uuid, null::uuid;
        return;
    end;
  end if;

  -- superseded: TS가 이미 카드 뒤에 바뀐 것을 읽었다(쓰기 계획 없음). 앞 카드는 더 쓸 수 없다. 새 카드가 있으면(대상이 아직 살아 있음) 대화에 낸다 — 앞 열린 제안은 모두 superseded (런타임 계약 2장)
  if v_reissue is not null then
    update public.conversation_messages m set refs = jsonb_set(m.refs, '{proposal,state}', '"superseded"'::jsonb)
     where m.conversation_id = p_conversation_id and m.role = 'assistant' and m.refs -> 'proposal' ->> 'state' = 'open';
    select coalesce(max(m.seq), 0) + 1 into v_seq from public.conversation_messages m where m.conversation_id = p_conversation_id;
    insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, content)
    values (
      p_user_id, p_conversation_id, v_seq, 'assistant', coalesce(v_reissue ->> 'text', ''),
      jsonb_build_object('proposal', v_reissue -> 'proposal', 'action_ids', coalesce(v_card.refs -> 'action_ids', '[]'::jsonb)),
      nullif(v_reissue -> 'content', 'null'::jsonb)
    )
    returning id into v_new;
    update public.conversations c set last_message_at = now() where c.id = p_conversation_id;
  else
    update public.conversation_messages m set refs = jsonb_set(m.refs, '{proposal,state}', '"superseded"'::jsonb) where m.id = v_card.id;
  end if;
  return query select 'superseded'::text, null::uuid, v_new;
end;
$$;

create function public.conversation_dismiss_proposal(p_user_id uuid, p_conversation_id uuid, p_proposal_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_card public.conversation_messages%rowtype;
  v_kind text;
begin
  perform 1 from public.conversations c where c.id = p_conversation_id and c.user_id = p_user_id and c.target_kind = 'taskforce' for update;
  if not found then return 'not_found'; end if;
  select * into v_card
    from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.user_id = p_user_id and m.role = 'assistant' and (m.refs -> 'proposal' ->> 'id') = p_proposal_id::text
   for update;
  v_kind := v_card.refs -> 'proposal' ->> 'kind';
  if not found or v_kind is null or v_kind not in ('delete', 'merge') then return 'not_found'; end if;
  case v_card.refs -> 'proposal' ->> 'state'
    when 'open' then
      update public.conversation_messages m set refs = jsonb_set(m.refs, '{proposal,state}', '"dismissed"'::jsonb) where m.id = v_card.id;
      return 'dismissed';
    when 'dismissed' then return 'already';
    else return 'not_open';
  end case;
end;
$$;

-- ─────────────────────────────────────────────
-- 11) 권한: 새 함수는 모두 서버(service role) 전용이다 (write_action 패턴). invoker · search_path 고정.
--    교체한 conversation_finish_turn의 권한은 create or replace가 유지한다.
-- ─────────────────────────────────────────────
revoke all on function public.change_context_membership_with_metric(uuid, uuid, uuid, integer, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.organize_lookup(uuid, integer[], uuid[]) from public, anon, authenticated;
revoke all on function public.apply_organize_moves(uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.apply_organize_change(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.conversation_confirm_proposal(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.conversation_dismiss_proposal(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.change_context_membership_with_metric(uuid, uuid, uuid, integer, uuid, integer, text) to service_role;
grant execute on function public.organize_lookup(uuid, integer[], uuid[]) to service_role;
grant execute on function public.apply_organize_moves(uuid, jsonb, jsonb) to service_role;
grant execute on function public.apply_organize_change(uuid, text, jsonb) to service_role;
grant execute on function public.conversation_confirm_proposal(uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.conversation_dismiss_proposal(uuid, uuid, uuid) to service_role;

commit;
