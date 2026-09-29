-- 지표 이벤트: 재연결 알림을 보냄 (docs/go-live/google-integration.md G9 · 2-3).
-- 연결이 reauth(갱신 토큰 만료 · 거절)로 바뀐 동기화에서 알림을 실제로 보냈을 때 서버(service role)가 한 줄 남긴다.
-- 이 뒤의 connection_created(다시 연결)와 견주어 알림이 다시 연결로 이어졌는지 잰다. 클라이언트 insert 정책은 app_opened 그대로다 (20261001000000).
--
-- 적용 순서: 이 이벤트를 남기는 서버 코드를 배포하기 **전에** 적용한다. 먼저 배포하면 알림은 가지만 이벤트 기록이 실패한다(오류 로그만, 동기화에는 영향 없음).
alter table public.metric_events drop constraint metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in ('app_opened', 'action_started', 'handoff_used', 'connection_created', 'reconnect_notified'));
