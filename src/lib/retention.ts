// 원문 보관 기간 (개인정보 처리방침: 원문 90일). 매일 /api/cron/retention이 purge_expired_source_text를 부른다
// (supabase/migrations/20261006000000_source_text_retention.sql). Slack 대기 데이터 정리(purge_slack_buffers)도 같은 cron이 부른다.
// 지우는 것: sources.raw_text(빈 문자열로, raw_text_purged_at에 시각) · judge_logs(후보 구절이 들어 있음).
// 남기는 것: 원문 행 · 제목 · 링크 · 관련자 · 처리 결과, 근거 인용(evidence) · Claim · 할 일.
// 글이 지워진 뒤: AI에게 넘기기와 물어보기는 저장된 근거 구절로 대신하고, 누락 신고는 400으로 거절한다.
// 예외: Slack 연결을 끊거나 앱을 지우면 Slack 원문은 제목 · 관련자까지, 근거 인용은 SLACK_DISCONNECTED_QUOTE로 바로 바꾼다
// (purge_slack_sources, 20261013000000, docs/go-live/slack-integration.md D3).
// 실행 산출물(내장 초안, execution_artifacts)은 행마다 보관 기한(retain_until, 열 기본값 90일 · 처리방침 D9a-1이 정한다)이 지나면
// 같은 cron이 본문만 비운다(purge_expired_artifacts, 20261022000000). 제목 · 기록 · 원가 · 원장은 남긴다. 기간을 바꾸려면 새 마이그레이션으로 열 기본값을 바꾼다.
// 실행의 글(요청 · 지시 · 받는 사람 후보 · 되묻는 질문)은 run을 만든 지 EXECUTION_TEXT_RETENTION_DAYS일이 지나면 같은 cron이 지운다
// (purge_expired_execution_text, 20261024000000). 그때 끝나지 않은 run은 건드리지 않고 끝난 뒤 첫 정리에서 지운다. run · 단계의 상태 · 기록 · 원가는 남긴다.

export const RAW_TEXT_RETENTION_DAYS = 90;

/**
 * 실행의 글 보관 기간: 저장한 뒤(run을 만든 뒤) 90일, 그때 실행 중이면 끝나는 대로 (처리방침 D9a-1 5장, purge_expired_execution_text, docs/EXECUTION.md 12장)
 */
export const EXECUTION_TEXT_RETENTION_DAYS = 90;

export const PURGED_SOURCE_MESSAGE = "원문이 보관 기간(90일)이 지나 지워졌어요.";
export const DISCONNECTED_SOURCE_MESSAGE = "Slack 연결을 끊어 원문을 지웠어요.";

/** Slack 연결을 끊거나 앱을 지우면 근거 인용 자리에 남는 글 (purge_slack_sources). 인용이 아니므로 AI에게 넘기기 · 물어보기 · 매칭(shortlist · 임베딩)에 넣지 않는다 */
export const SLACK_DISCONNECTED_QUOTE = "Slack 연결을 끊어 지웠어요";

/** 지운 원문을 고르거나 신고할 때의 안내 (sources.raw_text_purge_reason: disconnected = Slack 연결 끊기 · 앱 제거, 그 밖 = 90일) */
export const purgedSourceMessage = (reason: string | null | undefined) => (reason === "disconnected" ? DISCONNECTED_SOURCE_MESSAGE : PURGED_SOURCE_MESSAGE);

/** Slack 대기 메시지는 받은 지 3일, 추적 스레드는 마지막 활동 뒤 14일 지나면 지운다 (purge_slack_buffers, docs/go-live/slack-integration.md 2-6) */
export const SLACK_PENDING_RETENTION_DAYS = 3;
export const SLACK_THREAD_RETENTION_DAYS = 14;

/** 이 시각보다 먼저 들어온(created_at) 원문의 글을 지운다 */
export function retentionCutoff(now: Date, days = RAW_TEXT_RETENTION_DAYS): Date {
  return new Date(now.getTime() - days * 86_400_000);
}
