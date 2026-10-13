-- OA D4c-1s — 프로젝트 아이콘 · version. `work_contexts` 읽기는 RLS, 쓰기는 서버 함수만 한다.
begin;
set local lock_timeout = '5s';

alter table public.work_contexts
  add column icon text not null default 'compass'
    check (icon in ('rocket','briefcase','flask-conical','palette','code-xml','megaphone','book-open','building-2','leaf','compass','target','users')),
  add column version integer not null default 1 check (version >= 1);

update public.work_contexts
   set icon = (array['rocket','briefcase','flask-conical','palette','code-xml','megaphone','book-open','building-2','leaf','compass','target','users'])
     [1 + mod(abs(hashtext(id::text)::bigint), 12)::int];

-- OA 공통 블록: metric_events 확장 (Assistant 계약 v3 8장). 코디네이터 Opus 소유, 2026-10-13.
-- 이 블록은 metric_events에 처음 쓰는 OA WP들이 **글자 그대로** 자기 마이그레이션에 넣는다(지금: D1c-1 · D4c-1s).
-- 레인이 달라 어느 쪽이 먼저 적용돼도 결과가 같게 만든다: 열은 if not exists, CHECK · 정책은 계약 8장 전체 목록으로 통째로 교체.
-- 목록을 바꿔야 하면 작업자는 멈추고 코디네이터가 이 파일을 고쳐 두 WP에 같이 반영한다.
-- 기준: main의 마지막 정의 20261020000000_source_failure_visibility.sql:26 (app_opened · action_started · handoff_used ·
-- connection_created · connection_reauth · reconnect_notified · source_failed), 앱 insert 정책 20261001000000_metric_events_client_app_opened.sql.

alter table public.metric_events
  add column if not exists props jsonb not null default '{}'::jsonb;

alter table public.metric_events drop constraint if exists metric_events_props_shape;
alter table public.metric_events add constraint metric_events_props_shape
  check (jsonb_typeof(props) = 'object');

alter table public.metric_events drop constraint if exists metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in (
    'app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed',
    'assistant_opened', 'context_attached', 'agent_message_sent', 'stop_requested',
    'project_created', 'project_renamed', 'project_archived', 'project_icon_changed', 'issue_moved'
  ));

drop policy if exists "owner_insert_app_opened" on public.metric_events;
drop policy if exists "owner_insert_client_app_types" on public.metric_events;
create policy "owner_insert_client_app_types" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type in ('app_opened', 'assistant_opened'));

create function public.create_work_context(p_user_id uuid, p_name text, p_kind text, p_icon text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_icons text[] := array['rocket','briefcase','flask-conical','palette','code-xml','megaphone','book-open','building-2','leaf','compass','target','users'];
  v_context public.work_contexts;
begin
  insert into public.work_contexts (user_id, name, kind, icon)
  values (p_user_id, p_name, p_kind, coalesce(p_icon, v_icons[1 + floor(random() * cardinality(v_icons))::int]))
  returning * into v_context;

  insert into public.metric_events (user_id, type)
  values (p_user_id, 'project_created');

  return to_jsonb(v_context);
end;
$$;

create function public.update_work_context(
  p_user_id uuid,
  p_id uuid,
  p_expected_version integer,
  p_name text,
  p_icon text,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_context public.work_contexts;
  v_renamed boolean;
  v_icon_changed boolean;
  v_archived boolean;
begin
  select * into v_context
    from public.work_contexts w
   where w.id = p_id and w.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found', 'context', null);
  end if;
  if p_expected_version is null or v_context.version <> p_expected_version then
    return jsonb_build_object('status', 'conflict', 'context', null);
  end if;

  v_renamed := p_name is not null and v_context.name is distinct from p_name;
  v_icon_changed := p_icon is not null and v_context.icon is distinct from p_icon;
  v_archived := v_context.status = 'active' and p_status = 'archived';
  if not (v_renamed or v_icon_changed or v_context.status is distinct from coalesce(p_status, v_context.status)) then
    return jsonb_build_object('status', 'unchanged', 'context', to_jsonb(v_context));
  end if;

  update public.work_contexts w
     set name = coalesce(p_name, w.name),
         icon = coalesce(p_icon, w.icon),
         status = coalesce(p_status, w.status),
         version = w.version + 1
   where w.id = p_id and w.user_id = p_user_id
   returning * into v_context;

  if v_renamed then insert into public.metric_events (user_id, type) values (p_user_id, 'project_renamed'); end if;
  if v_icon_changed then insert into public.metric_events (user_id, type) values (p_user_id, 'project_icon_changed'); end if;
  if v_archived then
    insert into public.metric_events (user_id, type) values (p_user_id, 'project_archived');
    perform public.queue_context_bumps(array[p_id]);
    -- The existing deferred context_version_bumps trigger commits this increment after this RPC returns.
    v_context.context_version := v_context.context_version + 1;
  end if;

  return jsonb_build_object('status', 'ok', 'context', to_jsonb(v_context));
end;
$$;

revoke all on function public.create_work_context(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.update_work_context(uuid, uuid, integer, text, text, text) from public, anon, authenticated;
grant execute on function public.create_work_context(uuid, text, text, text) to service_role;
grant execute on function public.update_work_context(uuid, uuid, integer, text, text, text) to service_role;

commit;
