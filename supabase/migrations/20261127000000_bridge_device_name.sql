-- OA F1s: Mac 기기 이름(표시용)을 bridges에 둔다 + 병합 7aaffae 검토의 항목 5(만료 회수의 delivery_reason).
--
-- 만드는 것
--   1) bridges.device_name (text null, 기본값 없음 → 기존 행은 null) + CHECK bridges_device_name_shape(null 또는 1–64자 · 앞뒤 공백 없음 · 제어 문자 없음) + 앱 select 열 권한.
--      BC(20261118000000)가 bridges의 표 단위 select를 거두고 열 단위로 줬기 때문에 아래 grant 한 줄이 없으면 앱이 이 열을 읽지 못한다. insert · update 권한은 주지 않는다(쓰기는 서버만).
--   2) set_bridge_device_name(p_user_id, p_bridge_id, p_device_name): active bridge의 이름을 쓴다(service role만). 같은 이름이면 행을 잡지도 쓰지도 않는다. register_bridge · bridge_heartbeat는 교체하지 않는다.
--   3) bridges_clear_device_name 트리거: status가 revoked로 바뀌면 이름을 비운다(revoke_bridge 본문은 그대로, 폐기한 Mac의 이름은 어느 화면에도 쓰이지 않는다).
--   4) withdraw_bridge_command(uuid, text) 교체 — BC :180–203 정의에서 delivery_reason=p_reason 한 곳만 바꾼다: 이유가 expired이면 null을 쓴다.
--      상태가 이미 expired라 이유는 덧말이고 만료 sweep도 이유를 새로 쓰지 않는다. expired는 agentDeliveryReasonSchema 밖의 값이었다. 시그니처 · 반환이 같아 권한(BC 끝 do 블록)이 유지된다.
--      이미 저장된 expired 이유 행은 고치지 않는다(읽는 쪽이 모르는 이유를 버려 화면 영향 0). 운영 읽기 질의: select count(*) from public.conversation_messages where delivery_reason = 'expired'
--
-- 이전 규칙을 바꾸는 이유: GW(20261113000000)의 "bridges에 이름 열이 없다"와 device_ref "기기 이름 금지"는 식별에 이름을 쓰지 않기 위한 규칙이었다.
--   식별은 그대로다(device_ref는 서버가 만든 해시, device_id는 Mac 난수). 이 열은 식별에 쓰지 않는 표시용 글자 하나이고 어떤 판정 · 조인 · 열쇠에도 쓰지 않는다.
--   macOS 컴퓨터 이름은 사람 이름을 담을 수 있어 개인정보로 다룬다: 로그 · 지표 · 오류 문구 · AI 입력에 넣지 않고, 계정 삭제(user_id on delete cascade)와 그 Mac의 폐기 때 지운다.
--
-- 운영 적용: 병합 직전 승인 뒤 supabase db query --linked -f (db push 금지), 20261123000000(· 있으면 20261124–20261126) 뒤에.
-- 배포 순서: 이 마이그레이션 → 서버. 서버가 먼저 나가도 이름 쓰기는 실패를 삼키므로 bridge는 멈추지 않는다.
-- 되돌리기: drop trigger bridges_clear_device_name on public.bridges; drop function public.bridges_clear_device_name(); drop function public.set_bridge_device_name(uuid, uuid, text);
--   alter table public.bridges drop column device_name; + 20261118000000_bridge_commands.sql의 withdraw_bridge_command 정의를 다시 적용.
begin;
set local lock_timeout = '5s';
lock table public.bridges in access exclusive mode;

alter table public.bridges
  add column device_name text,
  add constraint bridges_device_name_shape check (device_name is null or (
    char_length(device_name) between 1 and 64 and device_name = btrim(device_name) and device_name !~ '[[:cntrl:]]'));
grant select (device_name) on public.bridges to authenticated;

create function public.set_bridge_device_name(p_user_id uuid, p_bridge_id uuid, p_device_name text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_rows integer;
begin
  if p_user_id is null or p_bridge_id is null or p_device_name is null then
    raise exception 'set_bridge_device_name: null argument' using errcode = '22023';
  end if;
  update public.bridges set device_name = p_device_name
    where id = p_bridge_id and user_id = p_user_id and status = 'active' and device_name is distinct from p_device_name;
  get diagnostics v_rows = row_count;
  if v_rows > 0 then return jsonb_build_object('status', 'updated'); end if;
  if exists (select 1 from public.bridges where id = p_bridge_id and user_id = p_user_id and status = 'active') then
    return jsonb_build_object('status', 'unchanged');
  end if;
  return jsonb_build_object('status', 'not_found');
end;
$$;
revoke all on function public.set_bridge_device_name(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.set_bridge_device_name(uuid, uuid, text) to service_role;

create function public.bridges_clear_device_name() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.device_name := null;
  return new;
end;
$$;
revoke all on function public.bridges_clear_device_name() from public, anon, authenticated;
create trigger bridges_clear_device_name
  before update of status on public.bridges
  for each row when (new.status = 'revoked' and new.device_name is not null)
  execute function public.bridges_clear_device_name();

create or replace function public.withdraw_bridge_command(p_command_id uuid,p_reason text) returns jsonb
language plpgsql set search_path = '' as $$
declare c public.bridge_commands; s public.execution_steps; t public.agent_tasks; r public.execution_runs;
begin
  select * into c from public.bridge_commands where id=p_command_id;
  select * into s from public.execution_steps where id=c.step_id;
  select * into t from public.agent_tasks where id=c.agent_task_id;
  select * into r from public.execution_runs where id=s.run_id;
  if s.state<>'prepared' or c.lease_owner is not null then return jsonb_build_object('status','stale','reason','not_prepared'); end if;
  perform set_config('execution.gate','bridge_withdraw',true);
  update public.execution_steps set state=case when p_reason='stale_answer' then 'skipped' else 'failed' end,
    receipt=jsonb_build_object('never_sent',true,'reason',p_reason),version=version+1 where id=s.id;
  if c.kind='message' then
    update public.conversation_messages set delivery_state=case when p_reason='expired' then 'expired' else 'not_sent' end,
      delivery_reason=case when p_reason='expired' then null else p_reason end where id=t.message_id and user_id=t.user_id;
    update public.agent_tasks set state='failed',pending_question=null where id=t.id;
  elsif c.kind='answer' and p_reason<>'stale_answer' and t.state='running' and t.answered_question is not null
    and r.state in ('queued','running') and t.cancel_requested_at is null then
    update public.agent_tasks set pending_question=answered_question,answered_question=null,state='awaiting_answer' where id=t.id;
  end if;
  update public.bridge_commands set outcome='withdrawn',outcome_at=public.db_now() where id=c.id;
  return jsonb_build_object('status','withdrawn','reason',p_reason);
end;
$$;
commit;
