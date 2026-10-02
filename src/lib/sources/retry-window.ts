/**
 * 들어온 지 이만큼 안의 원문만 다시 처리한다. 오래된 원문을 뒤늦게 반영하면 이미 지난 약속이 새 할 일로 뜨고,
 * 그 사이 처리된 뒷 원문(완료 · 취소)과 순서가 뒤집힌다. 이 기능 전에 실패한 오래된 원문은 scripts/reprocess-sources.ts로 따로 본다.
 * 재처리(retry.ts)와 GET /api/v1/now의 실패 원문 수가 같이 쓴다 (이 파일은 다른 것을 import하지 않는다: /now가 처리 코드를 끌어오지 않게).
 */
export const RETRY_WINDOW_MS = 24 * 3_600_000;
