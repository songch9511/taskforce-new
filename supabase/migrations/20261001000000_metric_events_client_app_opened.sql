-- 지표 이벤트: 앱이 직접 남길 수 있는 것은 app_opened뿐이다.
-- handoff_used는 POST /api/v1/actions/:id/handoff가, action_started는 POST /api/v1/actions/:id/start가 서버에서 남긴다.
-- 앱이 따로 또 남기면 지표 2(착수 시간)가 두 번 세어진다.
drop policy "owner_insert_client_types" on public.metric_events;
create policy "owner_insert_app_opened" on public.metric_events for insert to authenticated
  with check (user_id = (select auth.uid()) and type = 'app_opened');
