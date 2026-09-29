-- 재연결 안내 지표 (docs/go-live/google-integration.md G9 · 2-2 · 2-7, 원칙 6).
-- 서버(service role)만 남기는 이벤트 두 개와, 서비스별로 가르는 열 하나를 더한다.
--   connection_reauth  연결이 reauth(갱신 토큰 만료 · 거절)로 바뀜. 알림이 갔는지와 상관없이 바뀔 때마다 한 줄 (recordSync가 남김).
--   reconnect_notified 재연결 알림이 기기에 실제로 갔음 (알림을 받은 기기가 있을 때만).
--   provider           위 두 이벤트와 connection_created의 서비스. 이전에 남긴 connection_created는 null이다.
-- 만료 수와 알림 수를 견주면 알림을 못 보낸 만료(기기 없음 · 권한 거부)가 보이고, 뒤이은 connection_created와 서비스별로 맞춰 다시 연결로 이어졌는지 본다.
--
-- 클라이언트: 앱이 남길 수 있는 것은 app_opened뿐이다 (20261001000000 정책). provider는 열 단위 insert 권한(type, action_id)에 없어서
-- 앱은 값을 넣을 수 없다 (서버 전용, 시각 · 사용자와 같다).
-- 적용 순서: 이 이벤트를 남기는 서버 코드를 배포하기 **전에** 적용한다. 먼저 배포하면 새 이벤트와 connection_created 기록이 실패하고(provider 열이 없어서. 오류 로그, 동기화 · 알림에는 영향 없음) /admin/metrics가 열리지 않는다(지표를 읽을 때 provider 열을 고른다, src/lib/metrics/load.ts).
alter table public.metric_events add column provider text
  check (provider in ('notion', 'google', 'gmail', 'slack', 'github'));

alter table public.metric_events drop constraint metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in ('app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified'));
