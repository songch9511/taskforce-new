-- Claude 데스크톱 세션과 나눈 저장된 대화 모두 지우기 (OA D3v-s, 계약 handoffs/oa-external-sessions-contract.md 27장, DZ handoffs/oa-desktop-chat-view-dz 시트 6 · 9):
-- 사용자가 Settings(Mac) · 저장된 대화 목록(iPhone)에서 "Delete all saved chats"를 누르면 서버가 그 사용자의 저장된 대화(채팅 · 메시지 · 도구 이름)를 **한 번의 호출, 한 트랜잭션**으로 모두 지운다.
-- 한 건씩 보내면(최대 2,000번) 중간에 끊긴 "일부만 지워짐" 상태가 생기고 그 사이에 들어온 저장이 남는다 — 하나의 SQL 함수가 사용자별 잠금 아래 전부 지우므로 둘 다 없다.
--
-- 이 파일이 하는 일:
--   0) 적용 순서 가드: 맨 앞에서 20261207000000_claude_app_chats.sql의 것(묘비 표 · delete_claude_app_chat · 지표 종류 claude_app_chat_deleted · 속도 제한 종류 claude_app_chat_day)이 있는지 본다.
--      없으면 예외로 멈추고 아무것도 만들지 않는다. 이 파일은 두 종류 검사와 take_rate_limit을 "20261207의 것 + 새 종류 하나"로 다시 만들기 때문에, 순서가 바뀌면 20261207의 종류가 조용히 빠진다.
--   1) delete_all_claude_app_chats(p_user_id, p_max_seconds default 60) → { deleted: 지운 채팅 수 }: invoker, search_path 빈 값, service role만 실행 (save_claude_app_chat · delete_claude_app_chat과 같은 규칙).
--        - 저장 · 하나 지우기와 **같은 사용자별 advisory lock**: 겹친 저장은 줄을 선다. 지우기 전에 끝난 저장은 함께 지워지고, 지운 뒤에 온 저장은 묘비를 만나 되살리지 못한다 (고아 행도 되살림도 없다).
--        - 지우기 전에 사용자 글의 mac_ref를 묘비로 남긴다 (delete_claude_app_chat과 같은 규칙: 사용자 글만, 불투명 hex, 글 · 제목 · 도구 이름 없음). 사용자별 10,000개 상한이라 **가장 최근에 저장된** 사용자 글
--          10,000개만 남기고(재시도는 몇 분 안의 일이다), 합쳐서 10,000개를 넘는 옛 묘비는 가장 오래된 것부터 지운다. 묘비는 채팅을 지워도 남는다 (그래야 막는다).
--          **하루가 안 된 묘비는 상한을 넘어도 지우지 않는다** (보안 검토 P3-1): 방금 하나씩 지운 대화의 묘비가 밀려나면 그 대화의 재시도가 되살아난다. 하루 안에 지워진 사용자 글(그 사이 저장한 것 + 사용자별 저장 한도 안의 글)만큼이라 무한히 쌓이지 않는다.
--        - **자기 시간 제한** (보안 검토 P3-2): 채팅을 100개씩 지우며 사이사이에 p_max_seconds(기본 60초, 사용자별 잠금을 쥔 뒤부터 잰다)를 넘었는지 보고, 아직 지울 것이 남았는데 넘었으면 SQLSTATE 57014로 멈춘다 →
--          호출 전체가 롤백된다 (잠금을 오래 쥐지 않는다. route는 57014를 409 busy_retry로 돌려준다). 함수에 `set statement_timeout`을 붙이는 방법은 쓰지 못한다: 바깥 문장의 타이머는 시작될 때 이미 잡혀서 함수 안의
--          SET(function SET · set local)은 그 문장의 제한을 바꾸지 못한다 (실제 Postgres 17에서 확인: 1초로 줬는데 3초 돌았다, tests/db/claude-app-chats.scenarios.ts의 관찰 시험). 실제 서버 시간 제한(statement_timeout)이 걸려도 같은 57014다.
--        - bridge가 해제됐어도 지운다 (사용자의 기록이다). 다른 사용자의 행은 겨냥하지 않는다: 모든 문장이 user_id = p_user_id다.
--        - 지울 것이 없으면 { deleted: 0 }이고 묘비도 지표도 남기지 않는다.
--   1b) delete_claude_app_chat 다시 만들기 (묘비 상한 정리 한 문장만 바꾼다: 낡은 통계에서 분 단위로 느려지는 모양을 materialized CTE로 바꾸고, 하루가 안 된 묘비는 지우지 않는다). 20261207 파일은 고치지 않는다.
--   2) 지표 claude_app_chats_deleted_all (원칙 6): 지운 채팅이 있을 때 같은 트랜잭션에서 한 번, props는 { deleted: n } 뿐이다 (글 · 제목 · id 0). 하나씩 지우는 claude_app_chat_deleted와 섞이지 않게 따로 둔다
--      (모두 지우기를 얼마나 쓰는지가 별도 신호다). metric_events 종류 검사는 20261207의 전체 목록 + 이 종류 하나다. 앱 insert 정책(owner_insert_client_app_types)은 그대로다.
--      (앞으로 이 검사를 다시 만드는 마이그레이션은 이 종류를 목록에 이어 가져야 한다 — tests/metrics/agent-event-registry.test.ts가 최신 목록을 등록부와 대조한다.)
--   3) 속도 제한 종류 claude_app_chat_delete_all (모두 지우기 요청, 10분에 5번): 값은 route가 정한다 (src/lib/api/claude-app-chats.ts CLAUDE_APP_CHATS_DELETE_ALL_LIMIT).
--      저장(claude_app_chat)과 따로 센다: 저장이 가득 차도 지우기는 열려 있어야 하고, 지우기가 저장 한도를 먹지 않는다. 이 호출은 사용자별 잠금을 쥔 채 행 수에 비례해 일하므로 되풀이를 막는다.
--      rate_limit_events 종류 검사는 20261207의 목록 그대로 + 이 종류, take_rate_limit은 그 파일의 본문 그대로 + 이 종류 (create or replace).
--
-- 함수 규칙 (invoker + search_path 빈 값, public · anon · authenticated 실행 권한 없음, service role만):
--   - security definer가 아니다: 호출자는 서버의 service role(admin 클라이언트)뿐이고 쓰는 표는 service role이 이미 쓸 수 있다. 권한을 올려 줄 이유가 없다.
--   - 호출한 사용자 id는 route가 인증에서만 꺼내 넘긴다 (요청 본문 · 쿼리의 id는 받지 않는다).
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 한다 (원격 마이그레이션 기록이 없어 파일 하나씩 직접 적용; 일괄 push 금지). 한 트랜잭션으로 돈다.

begin;
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 0) 적용 순서 가드
-- ─────────────────────────────────────────────
do $$
begin
  if to_regclass('public.claude_app_chat_tombstones') is null
     or to_regprocedure('public.delete_claude_app_chat(uuid,uuid)') is null
     or not exists (
       select 1 from pg_catalog.pg_constraint
        where conname = 'metric_events_type_check' and conrelid = 'public.metric_events'::regclass
          and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_chat_deleted%'
     )
     or not exists (
       select 1 from pg_catalog.pg_constraint
        where conname = 'rate_limit_events_kind_check' and conrelid = 'public.rate_limit_events'::regclass
          and pg_catalog.pg_get_constraintdef(oid) like '%claude_app_chat_day%'
     ) then
    raise exception '20261208_claude_app_chats_delete_all: apply 20261207000000_claude_app_chats.sql first (tombstones, delete_claude_app_chat, claude_app_chat_deleted or claude_app_chat_day is missing)';
  end if;
end;
$$;

-- ─────────────────────────────────────────────
-- 1) delete_all_claude_app_chats: 사용자의 저장된 대화를 모두 지운다
-- ─────────────────────────────────────────────
-- 응답: { deleted: 지운 채팅 수 } (0이면 지울 것이 없었다). 메시지는 채팅의 cascade로 함께 지워진다.
-- p_max_seconds: 자기 시간 제한(초, 0–600, 기본 60): 채팅을 100개씩 지운 판이 끝날 때마다 보고, 아직 남았는데 넘었으면 57014로 멈추고 호출 전체를 롤백한다. 시험이 0으로 부른다 (route는 기본값만 쓴다).
create function public.delete_all_claude_app_chats(p_user_id uuid, p_max_seconds integer default 60) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c_max_tombstones constant integer := 10000;
  c_batch constant integer := 100;
  v_deleted integer := 0;
  v_round integer;
  v_started timestamptz;
begin
  if p_user_id is null or p_max_seconds is null or p_max_seconds not between 0 and 600 then
    raise exception 'delete_all_claude_app_chats: invalid argument' using errcode = '22023';
  end if;
  -- 저장 · 하나 지우기와 같은 사용자별 잠금: 저장이 끝난 뒤에 지우거나, 지운 뒤에 온 저장은 채팅이 없는 것(과 묘비)을 본다
  perform pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0));
  v_started := clock_timestamp();
  -- 묘비 (지우기 전에 남긴다 — 지운 뒤에는 사용자 글이 없다): 가장 최근에 저장된 사용자 글 10,000개의 (bridge, session_ref, mac_ref)
  insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref)
    select c.user_id, c.bridge_id, c.session_ref, m.mac_ref
      from public.claude_app_chat_messages m
      join public.claude_app_chats c on c.id = m.chat_id and c.user_id = m.user_id
     where m.user_id = p_user_id and m.role = 'user'
     order by m.created_at desc, m.seq desc
     limit c_max_tombstones
    on conflict do nothing;
  -- 채팅을 100개씩 지운다 (행은 cascade). 한 판이 100개에 못 미치면 다 지운 것이다
  loop
    delete from public.claude_app_chats where user_id = p_user_id and id in (select c.id from public.claude_app_chats c where c.user_id = p_user_id order by c.id limit c_batch);
    get diagnostics v_round = row_count;
    v_deleted := v_deleted + v_round;
    exit when v_round < c_batch;
    if clock_timestamp() - v_started > make_interval(secs => p_max_seconds) then
      raise exception 'delete_all_claude_app_chats: time limit exceeded' using errcode = '57014';
    end if;
  end loop;
  if v_deleted = 0 then
    return jsonb_build_object('deleted', 0);
  end if;
  -- 묘비 개수 상한: 옛 묘비까지 합쳐 10,000개 (가장 오래된 것부터 지운다; 방금 남긴 묘비가 가장 새롭다). 하루가 안 된 묘비는 상한을 넘어도 지우지 않는다 (방금 하나씩 지운 대화의 재시도가 되살아나지 않게)
  -- (materialized CTE: 넘친 묘비를 **한 번만** 구해 둔다. `(…) in (select … order by … offset …)` 모양은 사용자별 통계가 낡으면 계획기가 바깥을 1행으로 보고 부분 질의를 행마다 다시 돌려
  --  묘비 1만 개에서 분 단위로 느려진다 — 아래 3)의 delete_claude_app_chat도 같은 까닭으로 다시 만든다)
  with excess as materialized (
    select o.bridge_id, o.session_ref, o.mac_ref from public.claude_app_chat_tombstones o
     where o.user_id = p_user_id order by o.created_at desc, o.mac_ref desc offset c_max_tombstones
  )
  delete from public.claude_app_chat_tombstones t using excess e
   where t.user_id = p_user_id
     and t.created_at < now() - interval '1 day'
     and t.bridge_id = e.bridge_id and t.session_ref = e.session_ref and t.mac_ref = e.mac_ref;
  insert into public.metric_events (user_id, type, props) values (p_user_id, 'claude_app_chats_deleted_all', jsonb_build_object('deleted', v_deleted));
  return jsonb_build_object('deleted', v_deleted);
end;
$$;
revoke all on function public.delete_all_claude_app_chats(uuid, integer) from public, anon, authenticated;
grant execute on function public.delete_all_claude_app_chats(uuid, integer) to service_role;

-- ─────────────────────────────────────────────
-- 1b) delete_claude_app_chat 다시 만들기 (20261207의 본문 그대로 + 묘비 상한 정리 한 곳만)
-- ─────────────────────────────────────────────
-- 모두 지우기가 사용자에게 묘비 1만 개를 남기기 쉽게 만들므로, 20261207의 묘비 상한 정리가 그 사용자에게 걸리는 일이 많아진다. 그 문장(`(…) in (select … order by … offset …)`)은 사용자별 통계가 낡았을 때
-- (표 전체 통계가 "묘비는 다른 사용자 것"이라고 말하는데 이 사용자가 방금 1만 개를 쌓은 경우) 계획기가 바깥을 1행으로 보고 부분 질의를 행마다 다시 돌려 분 단위로 걸린다 (실제 Postgres 17에서 100초 넘게 재현:
-- tests/db/claude-app-chats.scenarios.ts). 두 가지만 바꾼다: ① 넘친 묘비를 materialized CTE로 한 번만 구한다 ② 위 delete_all_claude_app_chats처럼 하루가 안 된 묘비는 상한을 넘어도 지우지 않는다 (보안 검토 P3-1).
-- 나머지(잠금 · 묘비 · 지표 · 응답)는 20261207과 같다. 함수 이름 · 인자 · 권한이 같아 create or replace로 바꾼다 (권한은 아래에서 한 번 더 못 박는다).
create or replace function public.delete_claude_app_chat(p_user_id uuid, p_chat_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c_max_tombstones constant integer := 10000;
  v_id uuid;
begin
  if p_user_id is null or p_chat_id is null then
    raise exception 'delete_claude_app_chat: invalid argument' using errcode = '22023';
  end if;
  -- 저장과 같은 사용자별 잠금: 저장이 끝난 뒤에 지우거나, 지운 뒤에 온 저장은 채팅이 없는 것(과 묘비)을 본다
  perform pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0));
  insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref)
    select c.user_id, c.bridge_id, c.session_ref, m.mac_ref
      from public.claude_app_chats c
      join public.claude_app_chat_messages m on m.chat_id = c.id and m.user_id = c.user_id
     where c.id = p_chat_id and c.user_id = p_user_id and m.role = 'user'
    on conflict do nothing;
  delete from public.claude_app_chats where id = p_chat_id and user_id = p_user_id returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  -- 묘비 개수 상한: 가장 오래된 것부터 (재시도는 몇 분 안의 일이라 새 것이면 충분하다). 하루가 안 된 묘비는 지우지 않는다
  with excess as materialized (
    select o.bridge_id, o.session_ref, o.mac_ref from public.claude_app_chat_tombstones o
     where o.user_id = p_user_id order by o.created_at desc, o.mac_ref desc offset c_max_tombstones
  )
  delete from public.claude_app_chat_tombstones t using excess e
   where t.user_id = p_user_id
     and t.created_at < now() - interval '1 day'
     and t.bridge_id = e.bridge_id and t.session_ref = e.session_ref and t.mac_ref = e.mac_ref;
  insert into public.metric_events (user_id, type, props) values (p_user_id, 'claude_app_chat_deleted', '{}'::jsonb);
  return jsonb_build_object('status', 'deleted');
end;
$$;
revoke all on function public.delete_claude_app_chat(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_claude_app_chat(uuid, uuid) to service_role;

-- ─────────────────────────────────────────────
-- 2) metric_events: claude_app_chats_deleted_all
-- ─────────────────────────────────────────────
-- 종류 검사: 20261207000000의 전체 목록(20261206000000 + claude_app_message_sent · claude_app_chat_deleted) + 이 종류 하나. 앱 insert 정책은 바꾸지 않는다 (위 머리 주석).
-- 두 검사(여기와 아래 3)는 앞 파일들처럼 `drop constraint` 뒤 그냥 `add constraint`로 다시 만든다. `add … not valid` + `validate constraint`로 가르지 않는 까닭 (보안 검토 P3-3):
--   · 한 트랜잭션 안에서는 `drop constraint`가 잡은 ACCESS EXCLUSIVE 잠금이 commit까지 이어져서, 뒤의 validate가 더 약한 잠금으로 도는 이득이 없다 (잠금을 줄이려면 validate를 별도 트랜잭션으로 빼야 하는데,
--     이 저장소의 마이그레이션은 파일 하나 = begin … commit 하나다).
--   · 새 목록은 옛 목록의 상위 집합이라 옛 행이 어긋날 수 없고, 두 표의 행 수가 작으며, 맨 앞 lock_timeout 5초가 잠금을 기다리다 길어지는 것을 막는다.
--   · 이 저장소에서 not valid를 쓴 곳(20261110000000_coordinator_core.sql)은 옛 행을 검사하지 않으려는 목적이다.
alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved',
    'message_resent', 'question_answered', 'session_renamed', 'session_opened_external', 'session_resumed',
    'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved',
    'billing_checkout_started', 'billing_trial_started', 'billing_subscription_activated', 'billing_payment_succeeded',
    'billing_payment_failed', 'billing_plan_changed', 'billing_subscription_cancelled', 'billing_subscription_resumed',
    'billing_subscription_ended', 'billing_lifetime_purchased', 'billing_refund_requested', 'billing_refunded',
    'billing_portal_opened', 'billing_duplicate_purchase', 'billing_review_needed', 'billing_legacy_marked', 'billing_notice_scheduled',
    'ai_key_saved', 'ai_key_deleted', 'ai_key_revoked',
    'external_sessions_shown',
    'session_attached',
    'claude_app_session_opened',
    'claude_app_message_sent', 'claude_app_chat_deleted',
    'claude_app_chats_deleted_all'
  ));

-- ─────────────────────────────────────────────
-- 3) 속도 제한 종류 claude_app_chat_delete_all
-- ─────────────────────────────────────────────
-- 새 종류 하나만 더한다. 한도 값은 route가 정하고 지우는 함수보다 먼저 센다. 앞 목록 · 본문은 20261207000000_claude_app_chats.sql의 take_rate_limit 그대로다 (종류 목록 두 곳만 다르다).
alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check(kind in ('ask','connection_start','action_create','run_create','bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key','agent_attach','claude_app_chat','claude_app_sent','claude_app_chat_day','claude_app_chat_delete_all'));

create or replace function public.take_rate_limit(p_user_id uuid, p_kind text, p_max int, p_window_seconds int,p_bridge_id uuid default null)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
  v_window interval := make_interval(secs => p_window_seconds);
  v_since timestamptz;
  v_nth timestamptz;
begin
  if p_user_id is null or p_max < 1 or p_window_seconds < 1 then
    raise exception 'take_rate_limit: 잘못된 인자';
  end if;
  if p_kind in ('bridge_events','bridge_ack','bridge_poll','bridge_decide') and (p_bridge_id is null or not exists(
    select 1 from public.bridges where id=p_bridge_id and user_id=p_user_id)) then
    raise exception 'take_rate_limit: invalid bridge' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || p_kind || ':' || coalesce(p_bridge_id::text,'')));
  v_since := clock_timestamp() - v_window;

  if p_kind = 'missing_report' then
    select r.created_at into v_nth from public.missing_reports r
    where r.user_id = p_user_id and r.created_at > v_since
    order by r.created_at desc offset p_max - 1 limit 1;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.missing_reports (user_id, created_at) values (p_user_id, clock_timestamp());
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create', 'bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key','agent_attach','claude_app_chat','claude_app_sent','claude_app_chat_day','claude_app_chat_delete_all') then
    if p_bridge_id is not null then
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id = p_bridge_id and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    else
      select e.created_at into v_nth from public.rate_limit_events e
      where e.user_id = p_user_id and e.kind = p_kind and e.bridge_id is null and e.created_at > v_since
      order by e.created_at desc offset p_max - 1 limit 1;
    end if;
    if v_nth is not null then return v_nth + v_window; end if;
    insert into public.rate_limit_events (user_id, kind, created_at,bridge_id) values (p_user_id, p_kind, clock_timestamp(),p_bridge_id);
  else
    raise exception 'take_rate_limit: 모르는 종류 %', p_kind;
  end if;
  return null;
end;
$$;

revoke execute on function public.take_rate_limit from public, anon, authenticated;
grant execute on function public.take_rate_limit to service_role;

commit;
