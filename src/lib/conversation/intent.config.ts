// 대화 의도 · 지시 대상의 기본값 (런타임 계약 2장 · 12장). 값을 바꾸면 이 파일 · 테스트 · consult 골든셋(evals/consult)을 함께 바꾸고
// 실제 모델 eval 결과를 PR에 적는다.

export const INTENT_THRESHOLDS = {
  /**
   * 이 이상이면 의도 그대로 (판정 자동 반영 0.8의 선례, pipeline/judge.config.ts JUDGE_THRESHOLDS.accept와 같은 보정 철학).
   * 쓰기(기억 · 채택)는 이 이상에서만 한다.
   */
  act: 0.8,
  /** 이 미만이면 무엇을 원하는지 묻는다. 0.5–0.8: 조회 · 상담은 그대로 답하고, 쓰기 의도는 한 가지를 묻는다(쓰기 0) */
  ask: 0.5,
} as const;

/** 지시 대상이 둘 이상일 때 들어 보이는 후보 수 상한 (한 번에 고르기 쉬운 수) */
export const REFERENT_CANDIDATE_LIMIT = 3;
