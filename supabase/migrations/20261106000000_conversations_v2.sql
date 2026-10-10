-- 0.2.0 대화 v2 (구현 계획 B2): 20261103000000_context_core의 conversations · conversation_messages 위에 메시지 쓰기 규칙을 더한다.
-- 새 표는 없다. 새 열 셋 · 서버 전용 함수 셋 · Slack D3 트리거 하나다. 코드: src/lib/conversation/store.ts. gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 route가 없다(404).
--
-- 1) 같은 제출을 두 번 저장 · 실행하지 않는다 (런타임 계약 2장 · 10장, A03 · D1):
--    - 사용자 메시지는 conversation_post_message 하나로만 쓴다. 대화 행을 잠그고 seq를 매긴다(max + 1, 대화마다 한 줄).
--      같은 client_message_id면 새로 쓰지 않는다: 글이 다르면 mismatch, 답이 있으면 answered(모델을 다시 부르지 않는다),
--      그 뒤에 새 사용자 메시지가 이미 있으면 stale, 처리 중이면 in_progress, 처리 표시가 풀렸으면 retry(다시 처리).
--    - reply_lease_until: 처리 중 표시(사용자 메시지에만). 처리가 실패하면 서버가 풀고(conversation_release_lease), 서버가 죽으면 시각이 지나 풀린다.
--    - reply_to: 이 답이 답한 사용자 메시지. 사용자 메시지 하나에 답은 하나다(unique). 같은 대화 · 같은 사용자의 메시지만 가리킨다(복합 외래키).
-- 2) 한 번의 답(turn)은 conversation_finish_turn 한 트랜잭션으로 쓴다: 기억(remember_memory_item) · 제안 채택(note 원문 + write_action) ·
--    답 메시지 · 앞의 열린 제안 superseded · 사용자 메시지의 의도 · 정한 대상(refs).
--    - 늦은 응답: 이 메시지 뒤에 새 사용자 메시지가 이미 있으면 아무것도 쓰지 않는다(stale). 옛 발화의 기억이 새 정정을 덮지 않게 한다.
--    - 같은 메시지의 답이 이미 있으면 아무것도 쓰지 않는다(answered).
--    - 기억 정정이 그 사이 바뀌었거나(version) 제안이 이미 채택 · 대체됐으면 그 turn의 쓰기를 모두 되돌린다(conflict).
--    - 채택은 proposal id로 멱등이다(A41): 제안 메시지 행을 잠그고 state가 open이고 id · payload_hash가 같을 때만 Action을 만든다.
-- 3) content: assistant 답의 구간(segments, 신뢰 등급) · 인용 · 제안 글 · 사용한 기억 · 원문 id. 앱이 RLS로 읽어 대화를 복원한다.
--    글이므로 대화 글 보관 기한(V08, 아직 정하지 않음)에 text와 함께 비워야 한다. refs에는 id만 둔다.
--    Slack 끊기 · 앱 제거(D3)는 인용 · 제목을 자리 표시로 바꾼다 (4장 트리거).
--
-- 대화 · 기억 · 제안은 실행 권한에 닿지 않는다(I04): 이 파일의 함수는 execution_* 표 · 함수를 읽거나 쓰지 않는다 (tests/db/conversations-v2.test.ts).
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 20261104000000_context_layer 뒤에 적용한다.

begin;
-- conversation_messages에 열 · 제약을 더하며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (그때는 그대로 다시 적용)
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 새 열
-- ─────────────────────────────────────────────
alter table public.conversation_messages
  add column reply_to uuid,
  add column content jsonb constraint conversation_messages_content_shape check (content is null or jsonb_typeof(content) = 'object'),
  add column reply_lease_until timestamptz,
  -- (id, conversation_id, user_id): reply_to가 같은 대화 · 같은 사용자의 메시지만 가리키게 하는 외래키 대상
  add constraint conversation_messages_id_conversation_user_key unique (id, conversation_id, user_id),
  add constraint conversation_messages_reply_role check (reply_to is null or role = 'assistant'),
  add constraint conversation_messages_lease_role check (reply_lease_until is null or role = 'user'),
  add constraint conversation_messages_reply_not_self check (reply_to <> id),
  add constraint conversation_messages_reply_to_fkey foreign key (reply_to, conversation_id, user_id)
    references public.conversation_messages (id, conversation_id, user_id) on delete cascade;

-- 사용자 메시지 하나에 답 하나 (창 읽기 · 늦은 응답 확인은 기존 unique (conversation_id, seq) 인덱스를 쓴다)
create unique index conversation_messages_reply_to_key on public.conversation_messages (reply_to) where reply_to is not null;

-- ─────────────────────────────────────────────
-- 2) 사용자 메시지 쓰기 (서버). 결과:
--    created(새로 씀) · retry(같은 제출, 답 없음, 처리 표시가 풀려 다시 처리) · answered(같은 제출, 답 있음) ·
--    in_progress(같은 제출을 처리 중) · mismatch(같은 client_message_id에 다른 글) · stale(같은 제출이지만 그 뒤 새 사용자 메시지가 있음) ·
--    not_found(대화가 없거나 남의 대화)
-- ─────────────────────────────────────────────
create function public.conversation_post_message(
  p_user_id uuid,
  p_conversation_id uuid,
  p_client_message_id uuid,
  p_text text,
  p_lease_seconds integer
) returns table (status text, message_id uuid, seq integer, reply_id uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages%rowtype;
  v_reply uuid;
  v_seq integer;
  v_id uuid;
begin
  if p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 600 then
    raise exception 'conversation_post_message: lease seconds out of range' using errcode = '22023';
  end if;

  -- 대화마다 한 줄로 선다: seq · 같은 제출 확인 · 늦은 응답 확인이 이 잠금 뒤에서 일어난다 (finish_turn과 같은 순서: 대화 → 메시지)
  perform 1 from public.conversations c where c.id = p_conversation_id and c.user_id = p_user_id for update;
  if not found then
    return query select 'not_found'::text, null::uuid, null::integer, null::uuid;
    return;
  end if;

  select * into v_message
    from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.client_message_id = p_client_message_id;
  if found then
    -- 글이 다르면 같은 제출이 아니다 (답이 있어도 그 답을 돌려주지 않는다)
    if v_message.text is distinct from p_text then
      return query select 'mismatch'::text, v_message.id, v_message.seq, null::uuid;
      return;
    end if;
    select r.id into v_reply from public.conversation_messages r where r.reply_to = v_message.id;
    if v_reply is not null then
      return query select 'answered'::text, v_message.id, v_message.seq, v_reply;
      return;
    end if;
    if exists (
      select 1 from public.conversation_messages n
       where n.conversation_id = p_conversation_id and n.role = 'user' and n.seq > v_message.seq
    ) then
      return query select 'stale'::text, v_message.id, v_message.seq, null::uuid;
      return;
    end if;
    if v_message.reply_lease_until is not null and v_message.reply_lease_until > now() then
      return query select 'in_progress'::text, v_message.id, v_message.seq, null::uuid;
      return;
    end if;
    update public.conversation_messages m
       set reply_lease_until = now() + make_interval(secs => p_lease_seconds)
     where m.id = v_message.id;
    return query select 'retry'::text, v_message.id, v_message.seq, null::uuid;
    return;
  end if;

  select coalesce(max(m.seq), 0) + 1 into v_seq from public.conversation_messages m where m.conversation_id = p_conversation_id;
  insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, reply_lease_until)
  values (p_user_id, p_conversation_id, v_seq, 'user', p_client_message_id, p_text, now() + make_interval(secs => p_lease_seconds))
  returning id into v_id;
  update public.conversations c set last_message_at = now() where c.id = p_conversation_id;
  return query select 'created'::text, v_id, v_seq, null::uuid;
end;
$$;

-- 처리 표시 풀기 (서버: 모델 실패 · 동의 철회 · 한도 · 오류 뒤). 사용자 메시지는 남는다 (같은 client_message_id로 다시 보내면 retry)
create function public.conversation_release_lease(p_user_id uuid, p_message_id uuid) returns void
language sql
set search_path = ''
as $$
  update public.conversation_messages m
     set reply_lease_until = null
   where m.id = p_message_id and m.user_id = p_user_id and m.role = 'user';
$$;

-- ─────────────────────────────────────────────
-- 3) 한 번의 답 쓰기 (서버). p_turn:
--    { user: { intent, refs }, reply: { text, refs, content },
--      memory: [{ item (remember_memory_item의 p_item), corrects uuid | null, expected_version int | null }],
--      adopt: null | { proposal_message_id, proposal_id, payload_hash, action_id,
--                       note: { id, title, raw_text, external_url }, action, claims, evidence, events } }
--    결과: written · answered(이미 답함) · stale(뒤에 새 사용자 메시지) · conflict(기억 version · 제안 상태가 바뀜, 아무것도 쓰지 않음) · not_found
--    서버가 정하는 값(호출자의 값을 믿지 않는다): 사용자 · 대화(메시지의 것), seq, reply_to, 기억 id · 채택 Action id를 refs에 더하기.
-- ─────────────────────────────────────────────
create function public.conversation_finish_turn(p_user_id uuid, p_message_id uuid, p_turn jsonb)
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
    -- 기억: 같은 범위 · 같은 사실 규칙은 remember_memory_item이 지킨다. 하나라도 conflict면 이 turn 전체를 되돌린다
    for v_item in select value from jsonb_array_elements(case when jsonb_typeof(p_turn -> 'memory') = 'array' then p_turn -> 'memory' else '[]'::jsonb end) loop
      select * into v_written
        from public.remember_memory_item(p_user_id, v_item -> 'item', (v_item ->> 'corrects')::uuid, (v_item ->> 'expected_version')::integer);
      if v_written.status is distinct from 'written' then
        raise exception 'conversation_finish_turn: memory conflict' using errcode = 'TF409';
      end if;
      v_memory_ids := v_memory_ids || v_written.id;
    end loop;

    -- 제안 채택 (A41): 제안 메시지를 잠그고, 같은 대화의 assistant 메시지 · 같은 proposal id · 같은 payload_hash · state open일 때만
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
    when sqlstate 'TF409' or sqlstate 'P0002' or sqlstate '40P01' then
      update public.conversation_messages m set reply_lease_until = null where m.id = p_message_id;
      return query select 'conflict'::text, null::uuid, null::integer, '{}'::uuid[], null::uuid;
      return;
  end;

  return query select 'written'::text, v_reply, v_seq, v_memory_ids, v_action;
end;
$$;

-- ─────────────────────────────────────────────
-- 4) Slack 끊기 · 앱 제거 (D3, CLAUDE.md 원칙 2 예외): 답 내용(content.citations)에 남은 Slack 원문 인용 · 제목을 지운다.
--    purge_slack_sources가 원문을 비우는 것(raw_text_purge_reason = 'disconnected')과 같은 트랜잭션에서, 근거 인용과 같은 자리 표시
--    ('Slack 연결을 끊어 지웠어요' = src/lib/retention.ts SLACK_DISCONNECTED_QUOTE · purge_slack_sources)와 원문 제목('Slack')으로 바꾼다.
--    보관 기간(90일) 정리는 근거 인용처럼 인용을 남긴다(원문 글만 지운다). 답 글(text · segments)은 모델이 만든 요약이라 할 일 제목처럼 남는다.
--    여러 번 불러도 같다 (이유가 처음 disconnected가 될 때만 돈다)
-- ─────────────────────────────────────────────
create function public.conversation_purge_slack_citations() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversation_messages m
     set content = jsonb_set(m.content, '{citations}', (
       select coalesce(jsonb_agg(
                case when c ->> 'source_id' = new.id::text
                  then c || jsonb_build_object('quote', 'Slack 연결을 끊어 지웠어요', 'source_title', 'Slack')
                  else c end
                order by t.ord), '[]'::jsonb)
         from jsonb_array_elements(m.content -> 'citations') with ordinality as t(c, ord)))
   where m.user_id = new.user_id and m.role = 'assistant'
     and jsonb_typeof(m.content -> 'citations') = 'array'
     and m.content -> 'citations' @> jsonb_build_array(jsonb_build_object('source_id', new.id::text));
  return null;
end;
$$;

create trigger sources_purge_conversation_citations
  after update of raw_text_purged_at, raw_text_purge_reason on public.sources
  for each row
  when (new.raw_text_purge_reason = 'disconnected' and old.raw_text_purge_reason is distinct from 'disconnected')
  execute function public.conversation_purge_slack_citations();

-- 함수는 모두 서버(service role) 전용이다 (write_action 패턴). 트리거 함수도 막는다 (트리거로 불릴 때는 권한을 보지 않는다)
revoke all on function public.conversation_purge_slack_citations() from public, anon, authenticated;
revoke all on function public.conversation_post_message(uuid, uuid, uuid, text, integer) from public, anon, authenticated;
revoke all on function public.conversation_release_lease(uuid, uuid) from public, anon, authenticated;
revoke all on function public.conversation_finish_turn(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.conversation_post_message(uuid, uuid, uuid, text, integer) to service_role;
grant execute on function public.conversation_release_lease(uuid, uuid) to service_role;
grant execute on function public.conversation_finish_turn(uuid, uuid, jsonb) to service_role;

commit;
