// 원문 보관 기간 (개인정보 처리방침: 원문 90일). 매일 /api/cron/retention이 purge_expired_source_text를 부른다
// (supabase/migrations/20261006000000_source_text_retention.sql).
// 지우는 것: sources.raw_text(빈 문자열로, raw_text_purged_at에 시각) · judge_logs(후보 구절이 들어 있음).
// 남기는 것: 원문 행 · 제목 · 링크 · 관련자 · 처리 결과, 근거 인용(evidence) · Claim · 할 일.
// 글이 지워진 뒤: AI에게 넘기기와 물어보기는 저장된 근거 구절로 대신하고, 누락 신고는 400으로 거절한다.

export const RAW_TEXT_RETENTION_DAYS = 90;

export const PURGED_SOURCE_MESSAGE = "원문이 보관 기간(90일)이 지나 지워졌어요.";

/** 이 시각보다 먼저 들어온(created_at) 원문의 글을 지운다 */
export function retentionCutoff(now: Date, days = RAW_TEXT_RETENTION_DAYS): Date {
  return new Date(now.getTime() - days * 86_400_000);
}
