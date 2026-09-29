-- 앱은 연결 행을 직접 지우지 못한다 (docs/go-live/slack-integration.md 2-6 · 2-7).
-- 직접 지우면 서비스 쪽 토큰 폐기와 Slack 글자 지우기(D3)를 건너뛰고 sources.connection_id가 null이 되어, 어느 원문이 Slack에서 왔는지 찾을 수 없다.
-- 끊기는 DELETE /api/v1/connections/:id(서버 권한, disconnect_connection, 20261013000000)로만 한다. 앱은 이미 이 API로 끊는다(APIClient.swift).
--
-- 적용 순서: 서버 권한으로 끊는 코드(20261013000000과 같은 PR)를 배포한 **뒤에** 적용한다.
-- 예전 서버 코드는 이 정책으로(사용자 권한) 연결을 지우므로, 먼저 적용하면 배포 전까지 연결 끊기가 404가 된다.
drop policy "owner_delete" on public.connections;
