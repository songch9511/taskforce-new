-- OA 결제 PR-B (BYOK): Lifetime 사용자의 OpenRouter 키를 서버에 암호화해 둔다 (계약 6장 · 7.2).
-- 모두 더하기뿐이다: 새 표 · 새 함수 · rate_limit 종류 하나. 옛 함수의 서명은 바꾸지 않는다.
-- 키 평문은 DB에 없다. 앱 쪽이 AES-256-GCM(AAD = openrouter:<user_id>)으로 봉인한 글자만 들어온다 (src/lib/ai/user-key.ts).
begin;

-- billing_accounts는 표 전체가 authenticated select라(billing.sql) 비밀을 한 행에 두지 않고 표를 따로 둔다.
-- 부모가 auth.users라 복합 외래키가 아니라 user_id 단일 외래키다 (billing_accounts와 같음).
create table public.user_ai_keys (
  user_id uuid primary key references auth.users (id) on delete cascade,
  provider text not null default 'openrouter' check (provider = 'openrouter'),
  sealed_key text not null check (octet_length(sealed_key) < 2048),
  key_version smallint not null default 1,
  status text not null default 'connected' check (status in ('connected', 'revoked')),
  verified_at timestamptz not null,
  last_ok_at timestamptz,
  revoked_at timestamptz,
  last_spend_error_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 저장소 패턴의 owner_all 정책을 두되, 암호문은 어떤 클라이언트에도 가면 안 되므로 권한을 0으로 둔다 (connection_secrets와 같은 선례).
-- 상태는 서버 API가 내려 주고, 쓰기는 서버가 키를 검사한 뒤 아래 함수로만 한다 (모든 쓰기는 이벤트를 남긴다).
alter table public.user_ai_keys enable row level security;
create policy "owner_all" on public.user_ai_keys for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.user_ai_keys from anon, authenticated;

-- ── 키 저장 · 지우기 · 폐기 표시 ───────────────────────────────────────────
-- 모두 service role만 부른다. 이벤트는 같은 트랜잭션에서 남긴다(billing_emit, 20261129000000). props에 키 · 키 일부 · 라벨은 없다.

-- 저장: 현재 Lifetime 권한이 있는 계정만. 권한 행을 공유 잠금으로 쥔 채 쓰므로, 환불 확정(billing_apply_lifetime, for update)과
-- 겹치면 한쪽이 기다린다: 환불이 먼저면 이 쓰기가 거절되고, 이 쓰기가 먼저면 환불이 곧바로 이 키를 지운다. 돌려주는 값 = 이전 키를 바꿨는가.
create function public.ai_key_put(p_user_id uuid, p_sealed_key text, p_key_version smallint)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.billing_accounts; v_replaced boolean;
begin
  if p_user_id is null or p_sealed_key is null or p_sealed_key = '' or p_key_version is null then raise exception 'ai_key_invalid'; end if;
  select * into a from public.billing_accounts where user_id = p_user_id for share;
  if not found or a.deleting or a.lifetime_status is distinct from 'active' then raise exception 'byok_not_entitled'; end if;
  insert into public.user_ai_keys (user_id, sealed_key, key_version, status, verified_at)
  values (p_user_id, p_sealed_key, p_key_version, 'connected', now())
  on conflict (user_id) do update set
    sealed_key = excluded.sealed_key, key_version = excluded.key_version, status = 'connected', verified_at = now(),
    last_ok_at = null, revoked_at = null, last_spend_error_at = null, updated_at = now()
  returning (xmax <> 0) into v_replaced;
  perform public.billing_emit(p_user_id, 'ai_key_saved', jsonb_build_object('replaced', v_replaced));
  return v_replaced;
end $$;

-- 지우기(사용자의 DELETE): 돌려주는 값 = 지웠는가. 이벤트는 아래 삭제 트리거가 남긴다. 이 길의 삭제임을 트리거에 알린다(이 문장 안에서만).
create function public.ai_key_delete(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows integer;
begin
  perform set_config('taskforce.ai_key_deleted_by', 'user', true);
  delete from public.user_ai_keys where user_id = p_user_id;
  get diagnostics v_rows = row_count;
  perform set_config('taskforce.ai_key_deleted_by', '', true);
  return v_rows > 0;
end $$;

-- 키가 어떤 길로 지워지든 지워진 한 번마다 ai_key_deleted를 남긴다 (같은 트랜잭션):
--   사용자의 DELETE → {}, Lifetime 환불 · 사기 확정이 PR-A의 billing_apply_lifetime 안에서 지울 때 → {by:"refund"}
--   (그 함수는 이미 적용돼 고칠 수 없어서 지운 문장을 트리거가 본다: 같은 트랜잭션에서 권한 행이 먼저 refunded · fraudulent가 된다),
--   그 밖에 직접 지운 것(운영자) → {by:"system"}.
-- 계정을 지우는 중이면(부모 행이 이미 없다) 셀 사람도 가리킬 행도 없다: 건너뛴다(그렇지 않으면 계정 삭제가 외래키로 막힌다).
create function public.ai_key_after_delete()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_props jsonb;
begin
  if not exists (select 1 from auth.users where id = old.user_id) then return null; end if;
  if nullif(current_setting('taskforce.ai_key_deleted_by', true), '') = 'user' then
    v_props := '{}'::jsonb;
  elsif exists (select 1 from public.billing_accounts where user_id = old.user_id and lifetime_status in ('refunded', 'fraudulent')) then
    v_props := jsonb_build_object('by', 'refund');
  else
    v_props := jsonb_build_object('by', 'system');
  end if;
  perform public.billing_emit(old.user_id, 'ai_key_deleted', v_props);
  return null;
end $$;

create trigger ai_key_deleted_event after delete on public.user_ai_keys
  for each row execute function public.ai_key_after_delete();

-- 제공자가 401로 거절한 키를 폐기한다. 호출이 쓴 바로 그 암호문일 때만(그 사이 사용자가 키를 바꿨으면 새 키를 건드리지 않는다),
-- connected → revoked로 바뀐 한 번만 이벤트를 남긴다. 돌려주는 값 = 이번에 폐기했는가.
create function public.ai_key_mark_revoked(p_user_id uuid, p_sealed_key text)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.user_ai_keys set status = 'revoked', revoked_at = now(), updated_at = now()
   where user_id = p_user_id and sealed_key = p_sealed_key and status = 'connected';
  if not found then return false; end if;
  perform public.billing_emit(p_user_id, 'ai_key_revoked', jsonb_build_object('by', 'provider'));
  return true;
end $$;

-- 402 · 403(잔액 · 키 한도 · 가드레일): 상태는 connected 그대로 두고 시각만 남긴다. 충전하면 바로 다시 된다.
create function public.ai_key_note_spend_error(p_user_id uuid, p_sealed_key text)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.user_ai_keys set last_spend_error_at = now(), updated_at = now()
   where user_id = p_user_id and sealed_key = p_sealed_key and status = 'connected';
$$;

-- 성공한 호출: 마지막 성공 시각을 남기고 앞선 한도 오류 표시를 거둔다.
create function public.ai_key_note_ok(p_user_id uuid, p_sealed_key text)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.user_ai_keys set last_ok_at = now(), last_spend_error_at = null, updated_at = now()
   where user_id = p_user_id and sealed_key = p_sealed_key and status = 'connected';
$$;

revoke all on function public.ai_key_put(uuid, text, smallint) from public, anon, authenticated;
revoke all on function public.ai_key_delete(uuid) from public, anon, authenticated;
revoke all on function public.ai_key_mark_revoked(uuid, text) from public, anon, authenticated;
revoke all on function public.ai_key_note_spend_error(uuid, text) from public, anon, authenticated;
revoke all on function public.ai_key_note_ok(uuid, text) from public, anon, authenticated;
revoke all on function public.ai_key_after_delete() from public, anon, authenticated, service_role;
grant execute on function public.ai_key_put(uuid, text, smallint) to service_role;
grant execute on function public.ai_key_delete(uuid) to service_role;
grant execute on function public.ai_key_mark_revoked(uuid, text) to service_role;
grant execute on function public.ai_key_note_spend_error(uuid, text) to service_role;
grant execute on function public.ai_key_note_ok(uuid, text) to service_role;

-- ── 속도 제한: 키 저장 · 검사는 사용자별 시간당 10회 (서버를 키 검증 도구로 쓰지 못하게) ──────────────────────────
-- 새 종류 ai_key 하나만 더한다. 나머지 본문은 20261123000000_agent_path_leases.sql의 take_rate_limit 그대로다.
alter table public.rate_limit_events drop constraint rate_limit_events_kind_check;
alter table public.rate_limit_events add constraint rate_limit_events_kind_check
  check(kind in ('ask','connection_start','action_create','run_create','bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key'));

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
  elsif p_kind in ('ask', 'connection_start', 'action_create', 'run_create', 'bridge_register','bridge_events','bridge_ack','bridge_poll','bridge_decide','ai_key') then
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
