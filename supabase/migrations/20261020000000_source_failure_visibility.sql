-- 원문 처리 실패를 보이게 한다 (docs/HANDOFF.md W4). 지금은 실패한 원문이 앱에 보이지 않고("All caught up"), 지표 이벤트도 없다.
--
-- 1) sources.processing_error_code: 실패 까닭 코드. processing_error(사용자에게 보이는 문구)와 함께 서버가 쓴다 (lib/sources/process.ts sourceFailureCode).
--      ai_quota    AI 공급자가 한도 · 잔액으로 거절 (OpenRouter 402 · 403, 운영 키 하루 한도)
--      ai_timeout  AI 응답 시간 초과
--      ai_output   AI 응답 형식이 깨짐 (빈 응답 · JSON 아님 · 스키마와 다름)
--      consent     처리 도중 외부 AI 처리 동의를 철회함
--      expired     들어온 지 하루가 지나도록 처리 중 · 대기에 멈춰 다시 처리하지 않고 닫음 (lib/sources/retry.ts)
--      internal    그 밖 (DB 오류, 처리 도중 함수가 끊긴 채 시도를 다 씀 등)
--    이 마이그레이션 전에 실패한 원문은 null이다 (backfill 없음). 처리가 끝나면(done) 다시 null.
--    앱은 자기 원문의 실패 목록을 RLS로 읽는다 (processing_status = 'failed', processing_error_code). 개수 · 마지막 실패는 GET /api/v1/now의 failed_sources.
alter table public.sources add column processing_error_code text
  check (processing_error_code in ('ai_quota', 'ai_timeout', 'ai_output', 'consent', 'expired', 'internal'));

-- GET /api/v1/now가 요청마다 사용자의 실패 원문 수와 마지막 실패를 읽는다. 실패는 드물어 부분 인덱스는 작다.
create index sources_failed_idx on public.sources (user_id, processed_at desc nulls last) where processing_status = 'failed';

-- 2) 지표 이벤트 source_failed: 원문을 더 다시 처리하지 않기로 실패로 닫았을 때 한 줄 (시도를 다 씀 · 창이 지남 · 동의 철회).
--    provider는 그 원문을 가져온 연결의 서비스 (직접 넣은 원문 · 연결을 끊은 원문은 null). 원문 · 까닭 글은 남기지 않는다.
--    서버(service role)만 남긴다. 클라이언트 insert 정책은 app_opened 그대로다 (20261001000000).
alter table public.metric_events drop constraint metric_events_type_check;
alter table public.metric_events add constraint metric_events_type_check
  check (type in ('app_opened', 'action_started', 'handoff_used', 'connection_created', 'connection_reauth', 'reconnect_notified', 'source_failed'));

-- 적용 순서: 이 열을 쓰는 서버 코드를 배포하기 **전에** 적용한다. 먼저 배포하면 원문 처리 결과(완료 · 실패) 기록이 모두 실패해
-- 원문이 "처리 중"에 멈추고(적용하면 재처리 cron이 이어 하되 그 사이 시도를 다 쓴 원문은 실패로 닫힌다), source_failed 기록이 실패하며(로그만),
-- GET /api/v1/now의 failed_sources는 0으로 나간다 (목록은 그대로).
