// Jev 판정 임계값 (docs/TRUTH_RULES.md 1장 "판정 결과 처리"). 골든셋 eval의 보정 표를 보고 조정한다.
// 값을 바꾸면 `npm run eval` 결과(Jev 전후 precision/recall)를 PR에 적는다.

export const JUDGE_THRESHOLDS = {
  /**
   * 이 이상이면 자동 반영 후보 (is_my_commitment, is_actionable).
   * 문서 초기값은 0.85였으나 합성 골든셋에서 Jev가 정답에도 0.8 안팎을 주어(0.6~0.8 구간 실제 100%)
   * 0.8로 낮췄다. 0.8에서 함정 문장의 자동 반영은 0건, 0.75부터 조건부 약속이 섞인다 (2026-09-25).
   */
  accept: 0.8,
  /** 이 미만이면 기각 (is_my_commitment, is_actionable) */
  reject: 0.4,
  /** already_done이 이 미만이어야 자동 반영 */
  doneAcceptBelow: 0.3,
  /** already_done이 이 이상이면 기각 */
  doneRejectAt: 0.7,
} as const;

export type JudgeThresholds = { [K in keyof typeof JUDGE_THRESHOLDS]: number };
