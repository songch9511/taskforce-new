import type { JevDecision, JevQuestion } from "@/lib/ai/jev";
import { kstDate } from "@/lib/ai/prompts/extract";
import { JUDGE_PROMPT_VERSION, JUDGE_QUESTIONS, WRITTEN_BY_ME_PROMPT_VERSION, WRITTEN_BY_ME_QUESTIONS } from "@/lib/ai/prompts/judge";

import { findNameVariants, userPosition, type Participants, type UserIdentity } from "./identity";
import { JUDGE_THRESHOLDS, type JudgeThresholds } from "./judge.config";
import { quoteContext } from "./text";

// ③ Jev 판정 (docs/TRUTH_RULES.md 1장). 후보 하나에 질문 여러 개를 한 번에 묻고,
// 돌아온 확률을 임계값과 비교해 자동 반영 / 확인 요청 / 기각으로 나눈다. 판정 규칙은 순수 함수라 단위 테스트로 고정한다.

export type RejectReason = "NOT_MY_ACTION" | "INFO_ONLY" | "TENTATIVE" | "ALREADY_DONE";
export type JudgeDecision = "auto" | "confirm" | "reject";

export type JudgeCandidate = { title: string; quote: string; due_text: string | null; counterpart?: string | null };

export type JudgeSource = {
  text: string;
  kind: string;
  occurredAt: Date;
  participants?: Participants;
  /** 사용자가 직접 쓴 원문인가 (sources.written_by_me). true일 때만 판정에 넘긴다 */
  writtenByMe?: boolean | null;
};

type Choice<K extends string> = { choice: K; probabilities: Partial<Record<K, number>> };

/** Jev 답을 정리한 값. certainty · speaker_role · directness · audience는 Phase 2 진실 판정의 Claim 속성으로 쓴다. */
export type JudgeSignals = {
  is_my_commitment: number;
  is_actionable: number;
  already_done: number;
  certainty: Choice<"firm" | "tentative" | "none">;
  /** 인용 발언 자체의 확정도 (Claim의 certainty로 쓴다) */
  statement_certainty: Choice<"firm" | "tentative">;
  speaker_role: Choice<"me" | "counterpart" | "third_party">;
  directness: Choice<"first_hand" | "reported">;
  audience: Choice<"shared" | "private">;
};

export type JudgeOutcome = {
  decision: JudgeDecision;
  /** reject면 기각 사유, confirm이면 확인이 필요한 이유 */
  reasons: RejectReason[];
};

export type JudgeResult = JudgeOutcome & {
  signals: JudgeSignals;
  promptVersion: string;
  model: string;
  cost?: number;
};

export type Decide = (request: { state: unknown; questions: Record<string, JevQuestion> }) => Promise<JevDecision>;

/**
 * Jev에 보낼 state. 추출기의 추론(rationale)은 넣지 않고, 후보와 인용 주변 원문, 사용자가 누구인지만 넣는다.
 * 이메일 주소는 넣지 않는다 (사용자의 위치로 충분하다).
 */
export function buildJudgeState(candidate: JudgeCandidate, source: JudgeSource, identity: UserIdentity) {
  const variants = findNameVariants(source.text, identity, source.participants);
  return {
    user: {
      name: identity.name,
      aliases: identity.aliases,
      position: userPosition(identity, source.participants),
      ...(variants.length > 0 ? { possibly_misspelled_as: variants } : {}),
    },
    candidate: {
      title: candidate.title,
      due_text: candidate.due_text,
      quote: candidate.quote,
      // 상대가 누구인지 알려야 "누가 말했나(speaker_role)"를 요청한 쪽 · 제3자로 가를 수 있다.
      ...(candidate.counterpart ? { counterpart: candidate.counterpart } : {}),
    },
    context: quoteContext(source.text, candidate.quote) ?? candidate.quote,
    source: {
      kind: source.kind,
      occurred_at: kstDate(source.occurredAt).iso,
      // 사용자가 쓴 문서에 적은 할 일은 약속 · 요청 말투가 없어도 사용자가 정한 일이다 (WRITTEN_BY_ME_QUESTIONS).
      // 모르거나(null) 다른 사람이 쓴 문서(false)는 넘기지 않는다: 작성자 정보가 없던 때와 같은 기준으로 판정한다.
      ...(source.writtenByMe === true ? { written_by_me: true } : {}),
    },
  };
}

export function parseJudgeAnswers(answers: JevDecision["answers"]): JudgeSignals {
  const noul = (key: string) => {
    const answer = answers[key];
    if (answer?.type !== "noul") throw new Error(`Jev 답 형식 오류: ${key}`);
    return answer.noul;
  };
  const choice = <K extends string>(key: string, allowed: readonly K[]): Choice<K> => {
    const answer = answers[key];
    if (answer?.type !== "choice" || !allowed.includes(answer.choice as K)) throw new Error(`Jev 답 형식 오류: ${key}`);
    return { choice: answer.choice as K, probabilities: answer.probabilities as Partial<Record<K, number>> };
  };

  return {
    is_my_commitment: noul("is_my_commitment"),
    is_actionable: noul("is_actionable"),
    already_done: noul("already_done"),
    certainty: choice("certainty", ["firm", "tentative", "none"]),
    statement_certainty: choice("statement_certainty", ["firm", "tentative"]),
    speaker_role: choice("speaker_role", ["me", "counterpart", "third_party"]),
    directness: choice("directness", ["first_hand", "reported"]),
    audience: choice("audience", ["shared", "private"]),
  };
}

/** 확률을 임계값과 비교해 자동 반영 / 확인 요청 / 기각을 정한다 (docs/TRUTH_RULES.md 1장 표). */
export function decideOutcome(signals: JudgeSignals, thresholds: JudgeThresholds = JUDGE_THRESHOLDS): JudgeOutcome {
  const rejects: RejectReason[] = [];
  if (signals.is_my_commitment < thresholds.reject) rejects.push("NOT_MY_ACTION");
  if (signals.is_actionable < thresholds.reject) rejects.push("INFO_ONLY");
  if (signals.certainty.choice === "none") rejects.push("TENTATIVE");
  if (signals.already_done >= thresholds.doneRejectAt) rejects.push("ALREADY_DONE");
  if (rejects.length > 0) return { decision: "reject", reasons: rejects };

  const doubts: RejectReason[] = [];
  if (signals.is_my_commitment < thresholds.accept) doubts.push("NOT_MY_ACTION");
  if (signals.is_actionable < thresholds.accept) doubts.push("INFO_ONLY");
  if (signals.certainty.choice !== "firm") doubts.push("TENTATIVE");
  if (signals.already_done >= thresholds.doneAcceptBelow) doubts.push("ALREADY_DONE");
  return doubts.length > 0 ? { decision: "confirm", reasons: doubts } : { decision: "auto", reasons: [] };
}

export async function judgeCandidate(
  candidate: JudgeCandidate,
  source: JudgeSource,
  identity: UserIdentity,
  decide: Decide,
  thresholds: JudgeThresholds = JUDGE_THRESHOLDS,
): Promise<JudgeResult> {
  // 사용자가 직접 쓴 문서만 그에 맞춘 질문으로 묻는다. 작성자를 모르면 전과 같은 질문 (느슨해지지 않게).
  // 남기는 버전도 질문 묶음마다 다르다 (judge_logs에서 어느 질문으로 물었는지 가른다).
  const self = source.writtenByMe === true;
  const questions = self ? WRITTEN_BY_ME_QUESTIONS : JUDGE_QUESTIONS;
  const response = await decide({ state: buildJudgeState(candidate, source, identity), questions });
  const signals = parseJudgeAnswers(response.answers);
  return {
    ...decideOutcome(signals, thresholds),
    signals,
    promptVersion: self ? WRITTEN_BY_ME_PROMPT_VERSION : JUDGE_PROMPT_VERSION,
    model: response.model,
    cost: response.usage?.cost,
  };
}
