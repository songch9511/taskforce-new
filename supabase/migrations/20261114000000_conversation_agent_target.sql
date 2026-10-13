-- 0.2.0 대화 대상과 에이전트 글 (구현 계획 D1b): 20261103000000_context_core의 conversations · conversation_messages 위에 "누구와 말하는 대화인가"(대상)와
-- "에이전트가 쓴 글 · 보낸 메시지의 전달 상태"를 더한다. 설계: Assistant 계약 v3 3.1 · 3.2 · 3.5, 코드: 이 묶음에는 없다(D1c-1 · D1c-2 · D1d가 붙는다).
-- 새 표는 없다. 열 · 제약 · 트리거 · 서버 전용 함수 둘 · 기존 함수 셋의 교체뿐이다. route · gate · 앱 화면 · 에이전트 실행은 없다.
--
-- 1) conversations: target_kind('taskforce' 기본 | 'agent') · agent_connection_id · agent_session_id.
--    - agent ↔ 연결 필수, taskforce → 세션 없음 (CHECK). 연결 · 세션은 같은 사용자의 것만 (복합 외래키).
--    - 대상과 연결은 만든 뒤 바뀌지 않는다 (before update 트리거). 세션은 null → 값으로 한 번만 묶인다: 값 → 다른 값만 거절한다.
--      세션을 지우면(on delete set null) 대화는 남고 agent_session_id만 비므로 값 → null은 트리거가 막지 않는다 (FK 동작과 직접 갱신을 구별하지 않는다. 앱은 쓰기 권한이 없다).
--    - 연결은 on delete restrict: 대화가 있는 연결은 지울 수 없다 (연결을 지우기 전에 대화를 정리한다). 계정 삭제(auth.users)는 사용자 cascade로 둘 다 지워진다.
-- 2) conversation_messages: delivery_state(대상 agent의 사용자 메시지 전달 상태) · delivery_reason · delivery_expires_at(저장 + 24시간) · external_event_id(에이전트 글의 멱등 열쇠).
--    external_event_id는 content가 글 보관 기한에 비워져도 남는다 (열쇠를 content에 두지 않는다, 계약 3.5 N7).
--    대화가 교차 표라 CHECK로 못 거는 "대상 일치"는 before insert/update 트리거가 백스톱으로 지킨다:
--      agent 대화 — 사용자 메시지는 delivery_state가 있어야 하고, reply_to가 있는 assistant 행(Taskforce 모델의 답)은 쓰지 못한다.
--      taskforce 대화 — delivery_state · delivery_expires_at · external_event_id는 null이어야 한다.
-- 3) conversation_post_message를 대상별로 교체한다 (아래 머리 주석). 대상 taskforce는 B2 그대로다.
-- 4) conversation_append_agent_message: 에이전트의 글(reply · question) · 세션 사건(event)을 대화에 쓴다 (계약 3.5). conversation_finish_turn과 달리 reply_to 없이 여러 번 쓴다.
-- 5) conversation_expire_agent_messages: 보관 기한(24시간)이 지난 queued · not_sent를 expired로 (service role cron, 한 번에 최대 1,000행).
-- 6) coordinator_on_user_message: 대상 agent 대화의 메시지는 코디네이터 사건을 만들지 않는다 (그 메시지는 전달 경로가 처리한다).
--    coordinator_recover_missing(회수 sweep)도 같다: 사용자 메시지 회수에서 agent 대화를 뺀다 (코디네이터 결정으로 추가, 본문은 그대로 옮기고 조건 한 줄만 더했다).
--
-- 이 파일의 함수는 agent_tasks · agent_sessions · agent_connections 표를 읽기만 하고 쓰지 않는다 (append의 작업 확인). 글 보관 기한 정리(V08)가 delivery_* · external_event_id를 어떻게 다룰지는 D1c가 정한다.
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 20261113000000_agent_gateway_core 뒤에 적용한다.

begin;
-- 대화 두 표를 바꾸며 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (그때는 그대로 다시 적용)
set local lock_timeout = '5s';
-- 정해진 순서(대화 → 메시지: conversation_post_message의 잠금 순서와 같다)로 먼저 확보해, 경합하면 5초 안에 빨리 실패하고 쓰기 함수와 교착하지 않게 한다.
-- 새 외래키가 agent_connections · agent_sessions에 거는 잠금은 그 뒤에 잡힌다
lock table public.conversations, public.conversation_messages in access exclusive mode;

-- ─────────────────────────────────────────────
-- 1) conversations: 대상
-- ─────────────────────────────────────────────
alter table public.conversations
  add column target_kind text not null default 'taskforce',
  add column agent_connection_id uuid,
  add column agent_session_id uuid,
  add constraint conversations_target_kind_check check (target_kind in ('taskforce', 'agent')),
  add constraint conversations_agent_target_check check ((target_kind = 'agent') = (agent_connection_id is not null)),
  add constraint conversations_taskforce_no_session check (target_kind = 'agent' or agent_session_id is null),
  add constraint conversations_agent_connection_fkey foreign key (agent_connection_id, user_id)
    references public.agent_connections (id, user_id) on delete restrict,
  add constraint conversations_agent_session_fkey foreign key (agent_session_id, user_id)
    references public.agent_sessions (id, user_id) on delete set null (agent_session_id);

-- 세션 삭제 시 set null이 표 전체를 훑지 않게, 연결 삭제의 restrict 확인이 표 전체를 훑지 않게
create index conversations_agent_session_idx on public.conversations (agent_session_id) where agent_session_id is not null;
create index conversations_agent_connection_idx on public.conversations (agent_connection_id) where agent_connection_id is not null;

-- 대상과 연결은 바뀌지 않고, 세션은 한 번 묶이면 다른 값으로 바뀌지 않는다.
-- 세션 삭제의 set null(값 → null)과 직접 갱신을 구별하지 않으므로 값 → null은 거절하지 않는다 (null → 값은 다시 묶는 것이다)
create function public.conversations_agent_target_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.target_kind is distinct from old.target_kind then
    raise exception 'conversations_agent_target_guard: target_kind is permanent' using errcode = 'check_violation';
  end if;
  if new.agent_connection_id is distinct from old.agent_connection_id then
    raise exception 'conversations_agent_target_guard: agent_connection_id is permanent' using errcode = 'check_violation';
  end if;
  if old.agent_session_id is not null and new.agent_session_id is not null and new.agent_session_id is distinct from old.agent_session_id then
    raise exception 'conversations_agent_target_guard: agent_session_id is already bound' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger conversations_agent_target_guard
  before update of target_kind, agent_connection_id, agent_session_id on public.conversations
  for each row execute function public.conversations_agent_target_guard();

-- ─────────────────────────────────────────────
-- 2) conversation_messages: 전달 상태 · 외부 사건 id
--    delivery_state: queued(보낼 차례를 기다림) · not_sent(보내지 못함, delivery_reason에 이유) · dispatched(전달 단계로 넘어감) · expired(보관 24시간 지남) · cancelled(사용자가 지움).
--    응답의 sent · accepted · unknown은 열이 아니라 전달 단계에서 계산한다 (계약 3.2) — 이 열은 보류 · 만료 판정의 원천이다.
-- ─────────────────────────────────────────────
alter table public.conversation_messages
  add column delivery_state text,
  add column delivery_reason text,
  add column delivery_expires_at timestamptz,
  add column external_event_id text,
  add constraint conversation_messages_delivery_state_check check (delivery_state in ('queued', 'not_sent', 'dispatched', 'expired', 'cancelled')),
  add constraint conversation_messages_delivery_reason_check check (delivery_reason ~ '^[a-z][a-z0-9_]{0,63}$'),
  add constraint conversation_messages_external_event_id_check check (char_length(external_event_id) between 1 and 200),
  add constraint conversation_messages_delivery_role check (delivery_state is null or role = 'user'),
  -- 이유는 보류 · 대기 · 만료 · 취소 상태에만 붙는다 (전달 상태가 없으면 이유도 없다: null in (...)이 통과하지 않게 coalesce)
  add constraint conversation_messages_delivery_reason_state check (delivery_reason is null or coalesce(delivery_state in ('not_sent', 'queued', 'expired', 'cancelled'), false)),
  add constraint conversation_messages_external_event_role check (external_event_id is null or role in ('assistant', 'event'));

-- 같은 에이전트 사건은 대화마다 한 번만 (멱등). 보류 조회 · 만료 sweep은 부분 인덱스로
create unique index conversation_messages_external_event_key on public.conversation_messages (conversation_id, external_event_id) where external_event_id is not null;
create index conversation_messages_delivery_pending_idx on public.conversation_messages (conversation_id, seq) where delivery_state in ('queued', 'not_sent');
create index conversation_messages_delivery_expiry_idx on public.conversation_messages (delivery_expires_at) where delivery_state in ('queued', 'not_sent');

-- 대상 일치 백스톱 (교차 표라 CHECK로 못 건다). 서버(D1c)가 대상별 경로를 지키는 것이 본 방어이고, 이것은 옛 경로(B2 답 쓰기 등)가 잘못 쓰는 것을 막는 마지막 방어선이다.
-- 대화는 만든 뒤 대상이 바뀌지 않으므로(위 트리거) 읽은 대상이 이 문장 사이에 바뀌지 않는다. 대화가 없으면 외래키가 막는다
create function public.conversation_messages_target_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_target text;
begin
  select c.target_kind into v_target from public.conversations c where c.id = new.conversation_id and c.user_id = new.user_id;
  if v_target = 'agent' then
    if new.role = 'user' and new.delivery_state is null then
      raise exception 'conversation_messages_target_guard: a user message in an agent conversation needs delivery_state' using errcode = 'check_violation';
    end if;
    if new.role = 'assistant' and new.reply_to is not null then
      raise exception 'conversation_messages_target_guard: an assistant message in an agent conversation cannot have reply_to' using errcode = 'check_violation';
    end if;
  elsif v_target = 'taskforce' then
    if new.delivery_state is not null or new.delivery_expires_at is not null or new.external_event_id is not null then
      raise exception 'conversation_messages_target_guard: a taskforce conversation message cannot have delivery_state, delivery_expires_at or external_event_id' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

create trigger conversation_messages_target_guard
  before insert or update of conversation_id, role, reply_to, delivery_state, delivery_expires_at, external_event_id on public.conversation_messages
  for each row execute function public.conversation_messages_target_guard();

-- ─────────────────────────────────────────────
-- 3) 사용자 메시지 쓰기 (서버) — 대상별 규칙. 시그니처 · 반환 모양은 20261106000000_conversations_v2와 같다.
--    결과: created(새로 씀) · retry · answered · in_progress · mismatch · refs_mismatch · stale · not_found (B2, 대상 taskforce) + exists(대상 agent).
--    대화 행을 잠근 뒤 대상(target_kind)을 읽는다. 대상은 바뀌지 않는다.
--    - 대상 taskforce: B2 그대로다. 처리 표시(reply_lease_until)를 걸고, 같은 client_message_id는 mismatch · refs_mismatch → answered → stale → in_progress → retry 순으로 판정한다.
--    - 대상 agent:
--        새 메시지 — 처리 표시를 걸지 않는다(reply_lease_until null: Taskforce 모델이 처리 중이라는 표시가 아니다). delivery_state = 'queued', delivery_reason = null,
--          delivery_expires_at = 저장 시각 + 24시간. 코디네이터 사건은 만들어지지 않는다(아래 6).
--        같은 client_message_id — 글이 다르면 mismatch, 고른 대상이 다르면 refs_mismatch(그대로). 그 밖에는 answered · stale · in_progress · retry를 판정하지 않고
--          exists(기존 id · seq)를 돌려준다. 행을 고치지 않는다. 뒤에 새 사용자 메시지가 있어도 앞 메시지를 버리지 않는다(B2의 stale 규칙을 쓰지 않는다, 계약 3.2-2).
--          전달 · 재전달은 전달 경로(D1d)가 delivery_state로 판단한다.
-- ─────────────────────────────────────────────
create or replace function public.conversation_post_message(
  p_user_id uuid,
  p_conversation_id uuid,
  p_client_message_id uuid,
  p_text text,
  p_selected jsonb,
  p_lease_seconds integer
) returns table (status text, message_id uuid, seq integer, reply_id uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_message public.conversation_messages%rowtype;
  v_target text;
  v_reply uuid;
  v_seq integer;
  v_id uuid;
begin
  if p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 600 then
    raise exception 'conversation_post_message: lease seconds out of range' using errcode = '22023';
  end if;

  -- 대화마다 한 줄로 선다: seq · 같은 제출 확인 · 늦은 응답 확인이 이 잠금 뒤에서 일어난다 (finish_turn과 같은 순서: 대화 → 메시지)
  select c.target_kind into v_target from public.conversations c where c.id = p_conversation_id and c.user_id = p_user_id for update;
  if not found then
    return query select 'not_found'::text, null::uuid, null::integer, null::uuid;
    return;
  end if;

  select * into v_message
    from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.client_message_id = p_client_message_id;
  if found then
    -- 글이나 고른 대상이 다르면 같은 제출이 아니다 (답이 있어도 그 답을 돌려주지 않는다. 대상은 서버가 정렬 · 중복 제거해 넘긴다).
    -- 앱이 고칠 곳을 알 수 있게 글 불일치(mismatch)와 대상 불일치(refs_mismatch)를 나눈다
    if v_message.text is distinct from p_text then
      return query select 'mismatch'::text, v_message.id, v_message.seq, null::uuid;
      return;
    end if;
    if coalesce(v_message.selected, '{}'::jsonb) is distinct from coalesce(p_selected, '{}'::jsonb) then
      return query select 'refs_mismatch'::text, v_message.id, v_message.seq, null::uuid;
      return;
    end if;
    -- 대상 agent: 같은 제출이다. Taskforce 모델의 답 · 처리 표시 판정은 없다 (행을 고치지 않는다)
    if v_target = 'agent' then
      return query select 'exists'::text, v_message.id, v_message.seq, null::uuid;
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
  if v_target = 'agent' then
    -- 보낼 차례를 기다리는 메시지 (24시간 안에 전달하지 못하면 sweep이 expired로 바꾼다, 계약 3.2)
    insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, selected, delivery_state, delivery_expires_at)
    values (p_user_id, p_conversation_id, v_seq, 'user', p_client_message_id, p_text, p_selected, 'queued', now() + interval '24 hours')
    returning id into v_id;
  else
    insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, selected, reply_lease_until)
    values (p_user_id, p_conversation_id, v_seq, 'user', p_client_message_id, p_text, p_selected, now() + make_interval(secs => p_lease_seconds))
    returning id into v_id;
  end if;
  update public.conversations c set last_message_at = now() where c.id = p_conversation_id;
  return query select 'created'::text, v_id, v_seq, null::uuid;
end;
$$;

-- ─────────────────────────────────────────────
-- 4) 에이전트의 글 쓰기 (서버, 계약 3.5). p_kind:
--      reply · question — 에이전트의 답 · 질문. role 'assistant'. 그 턴을 시작한 사용자 메시지의 대화에만 쓴다(작업의 message_id가 이 대화의 메시지일 때만).
--      event — 세션 단위 사건(중단 확인 · 연결 끊김 · 결과 검토). role 'event'. 작업의 세션이 대화의 세션과 같으면 된다 (묶인 모든 대화에 한 줄씩 쓰는 반복은 호출자 몫, D1c-2).
--    결과: created(씀) · duplicate(같은 p_event_id가 이미 있음: 기존 id · seq, 아무것도 쓰지 않음) · not_found(대화가 없거나 남의 것, 작업이 없거나 남의 것) ·
--          wrong_target(대화의 대상이 agent가 아님) · wrong_session(작업의 세션이 대화의 agent_session_id와 다름: 세션이 아직 안 묶인 대화 포함) · wrong_conversation(reply · question인데 작업의 메시지가 이 대화의 것이 아님).
--    글은 20,000자와 32,768바이트(UTF-8) 이하로 글자 단위로 자른다 (멀티바이트를 가르지 않는다). 잘랐으면 content.truncated = true. 전문은 Mac bridge 원장에 있다.
--    content = { author: { kind: 'agent', adapter }, kind, turn_seq?, truncated? } (turn_seq는 p_turn_seq가 null이면 키가 없다). reply_to는 null이다. 멱등 열쇠는 external_event_id 열이다.
--    잠금 순서: 대화 행(for update)만 잡는다. 작업 · 세션 · 연결은 읽기만 한다 (agent_tasks · execution_*를 쓰지 않는다).
-- ─────────────────────────────────────────────
create function public.conversation_append_agent_message(
  p_user_id uuid,
  p_conversation_id uuid,
  p_agent_task_id uuid,
  p_turn_seq integer,
  p_event_id text,
  p_text text,
  p_kind text
) returns table (status text, message_id uuid, seq integer)
language plpgsql
set search_path = ''
as $$
declare
  v_target text;
  v_connection uuid;
  v_session uuid;
  v_task_session uuid;
  v_task_message uuid;
  v_adapter text;
  v_text text;
  v_truncated boolean := false;
  v_low integer;
  v_high integer;
  v_mid integer;
  v_content jsonb;
  v_dup_id uuid;
  v_dup_seq integer;
  v_seq integer;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('reply', 'question', 'event') then
    raise exception 'conversation_append_agent_message: kind must be reply, question or event' using errcode = '22023';
  end if;
  if p_event_id is null or char_length(p_event_id) not between 1 and 200 then
    raise exception 'conversation_append_agent_message: event id must be 1-200 characters' using errcode = '22023';
  end if;
  if p_turn_seq is not null and p_turn_seq < 1 then
    raise exception 'conversation_append_agent_message: turn_seq must be null or at least 1' using errcode = '22023';
  end if;
  if p_text is null then
    raise exception 'conversation_append_agent_message: text is required' using errcode = '22023';
  end if;

  -- 대화마다 한 줄로 선다 (post_message와 같은 잠금): seq · 같은 사건 확인이 이 잠금 뒤에서 일어난다
  select c.target_kind, c.agent_connection_id, c.agent_session_id into v_target, v_connection, v_session
    from public.conversations c
   where c.id = p_conversation_id and c.user_id = p_user_id
   for update;
  if not found then
    return query select 'not_found'::text, null::uuid, null::integer;
    return;
  end if;
  if v_target is distinct from 'agent' then
    return query select 'wrong_target'::text, null::uuid, null::integer;
    return;
  end if;

  -- 같은 사건은 한 번만 (작업이 그 사이 바뀌었어도 이미 쓴 사건은 duplicate다)
  select m.id, m.seq into v_dup_id, v_dup_seq
    from public.conversation_messages m
   where m.conversation_id = p_conversation_id and m.external_event_id = p_event_id;
  if found then
    return query select 'duplicate'::text, v_dup_id, v_dup_seq;
    return;
  end if;

  select t.agent_session_id, t.message_id into v_task_session, v_task_message
    from public.agent_tasks t
   where t.id = p_agent_task_id and t.user_id = p_user_id;
  if not found then
    return query select 'not_found'::text, null::uuid, null::integer;
    return;
  end if;
  if v_task_session is distinct from v_session then
    return query select 'wrong_session'::text, null::uuid, null::integer;
    return;
  end if;
  if p_kind <> 'event' and not exists (
    select 1 from public.conversation_messages m
     where m.id = v_task_message and m.conversation_id = p_conversation_id and m.user_id = p_user_id
  ) then
    return query select 'wrong_conversation'::text, null::uuid, null::integer;
    return;
  end if;

  select a.adapter into v_adapter from public.agent_connections a where a.id = v_connection and a.user_id = p_user_id;

  -- 글 자르기: 20,000자 이하, 그 안에서 32,768바이트 이하가 되는 가장 긴 앞부분 (글자 단위 이분 탐색)
  v_text := p_text;
  if char_length(v_text) > 20000 then
    v_text := left(v_text, 20000);
    v_truncated := true;
  end if;
  if octet_length(v_text) > 32768 then
    v_truncated := true;
    v_low := 0;                      -- left(v_text, v_low)는 늘 한도 이하
    v_high := char_length(v_text);   -- left(v_text, v_high)는 늘 한도 초과
    while v_high - v_low > 1 loop
      v_mid := (v_low + v_high) / 2;
      if octet_length(left(v_text, v_mid)) <= 32768 then
        v_low := v_mid;
      else
        v_high := v_mid;
      end if;
    end loop;
    v_text := left(v_text, v_low);
  end if;

  v_content := jsonb_build_object('author', jsonb_build_object('kind', 'agent', 'adapter', v_adapter), 'kind', p_kind);
  if p_turn_seq is not null then
    v_content := v_content || jsonb_build_object('turn_seq', p_turn_seq);
  end if;
  if v_truncated then
    v_content := v_content || jsonb_build_object('truncated', true);
  end if;

  select coalesce(max(m.seq), 0) + 1 into v_seq from public.conversation_messages m where m.conversation_id = p_conversation_id;
  insert into public.conversation_messages (user_id, conversation_id, seq, role, text, content, external_event_id)
  values (p_user_id, p_conversation_id, v_seq, case when p_kind = 'event' then 'event' else 'assistant' end, v_text, v_content, p_event_id)
  returning id into v_id;
  update public.conversations c set last_message_at = now() where c.id = p_conversation_id;
  return query select 'created'::text, v_id, v_seq;
end;
$$;

-- ─────────────────────────────────────────────
-- 5) 전달 보관 기한 만료 (서버 cron, 계약 3.2). 지난 queued · not_sent를 expired로 바꾸고 바꾼 수를 돌려준다. 이유(delivery_reason)는 그대로 둔다.
--    dispatched · cancelled · 이미 expired · 아직 안 지난 것(만료 시각이 없는 것 포함)은 건드리지 않는다. 사용자 경계 없이 전체를 본다.
--    한 번에 최대 1,000행(가장 오래된 만료부터): 더 있으면 호출자가 0이 될 때까지 반복한다. 다른 트랜잭션이 잡은 행은 기다리지 않고 건너뛴다(다음 sweep이 본다).
-- ─────────────────────────────────────────────
create function public.conversation_expire_agent_messages(p_now timestamptz) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_now is null then
    raise exception 'conversation_expire_agent_messages: now is required' using errcode = '22023';
  end if;
  update public.conversation_messages m
     set delivery_state = 'expired'
   where m.id in (
           select x.id from public.conversation_messages x
            where x.delivery_state in ('queued', 'not_sent') and x.delivery_expires_at < p_now
            order by x.delivery_expires_at, x.id
            limit 1000
            for update skip locked)
     and m.delivery_state in ('queued', 'not_sent');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) 코디네이터: 대상 agent 대화의 사용자 메시지는 사건이 아니다 (그 메시지는 전달 경로가 처리한다, 계약 3.1). 그 밖은 20261110000000_coordinator_core 그대로.
--    함수 본문만 교체한다 (트리거 정의 · 권한 유지). 예외를 warning으로 삼키는 구조도 그대로다: 대상을 읽지 못해도 사용자 쓰기를 깨지 않는다
-- ─────────────────────────────────────────────
create or replace function public.coordinator_on_user_message() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    if exists (select 1 from public.conversations c where c.id = new.conversation_id and c.user_id = new.user_id and c.target_kind = 'agent') then
      return null;
    end if;
    perform public.coordinator_enqueue_internal(
      new.user_id, 'user_message', 'message:' || new.id::text,
      jsonb_build_object('conversation_id', new.conversation_id, 'message_id', new.id));
  exception when others then
    raise warning 'coordinator_on_user_message: 적재 실패 (SQLSTATE %)', sqlstate;
  end;
  return null;
end;
$$;

-- 6-2) 회수 sweep도 같다 (코디네이터 결정으로 추가, 계약 2.6 밖): coordinator_recover_missing은 최근 사용자 메시지 중 사건이 없는 것을 같은 dedup_key로 다시 쌓는다.
--      대상을 보지 않으면 생산자 트리거가 건너뛴 agent 대화의 메시지를 회수 cron이 user_message 사건으로 쌓는다. 그래서 사용자 메시지 회수의 안쪽 select에
--      대상 agent 대화 제외 조건 한 줄만 더한다 (limit이 제외 뒤의 메시지를 센다: agent 메시지가 taskforce 메시지의 자리를 차지하지 않는다).
--      본문은 20261110000000_coordinator_core의 정의를 글자 그대로 옮겼고 그 한 줄 말고 다른 동작은 바뀌지 않는다 (시그니처 · 권한 유지).
-- 최근 p_lookback_seconds 안의 원문 처리 완료 · 사용자 메시지 · 사용자 Action 결정 중 사건이 없는 것을 같은 dedup_key로 쌓는다(종류마다 p_limit개까지).
-- 원문은 처리 요약(processing_summary)이 있는 done만 센다: 처리 없이 바로 done으로 쓴 행(실행 receipt · 대화 채택 note)은 처리 성공이 아니다.
-- 이미 사건이 있으면 아무것도 하지 않아 겹쳐 돌려도 같다. 쌓은 수를 돌려준다
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
       where x.actor = 'user' and x.type in ('user_confirmed', 'user_deleted', 'user_edited', 'completed', 'dropped', 'reopened') and x.created_at >= v_since
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
-- 7) 권한: 새 함수는 서버(service role) 전용이다 (write_action 패턴). 트리거 함수도 막는다 (트리거로 불릴 때는 권한을 보지 않는다).
--    교체한 post_message · coordinator_on_user_message의 권한은 create or replace가 유지한다 (앱 · 익명 실행 불가). 앱(authenticated)의 표 권한은 늘리지 않는다: 새 열도 select뿐이다
-- ─────────────────────────────────────────────
revoke all on function public.conversations_agent_target_guard() from public, anon, authenticated;
revoke all on function public.conversation_messages_target_guard() from public, anon, authenticated;
revoke all on function public.conversation_append_agent_message(uuid, uuid, uuid, integer, text, text, text) from public, anon, authenticated;
revoke all on function public.conversation_expire_agent_messages(timestamptz) from public, anon, authenticated;
grant execute on function public.conversation_append_agent_message(uuid, uuid, uuid, integer, text, text, text) to service_role;
grant execute on function public.conversation_expire_agent_messages(timestamptz) to service_role;

commit;
