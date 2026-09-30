import type { JevDecision, JevQuestion } from "@/lib/ai/jev";
import { kstDate } from "@/lib/ai/prompts/extract";
import { JUDGE_PROMPT_VERSION, JUDGE_QUESTIONS, WRITTEN_BY_ME_PROMPT_VERSION, WRITTEN_BY_ME_QUESTIONS } from "@/lib/ai/prompts/judge";

import {
  addressedAmbiguouslyToUser,
  addressedToUser,
  containsAmbiguousAssignee,
  findNameVariants,
  isAmbiguousUserName,
  quoteSpeaker,
  userPosition,
  type Participants,
  type UserIdentity,
} from "./identity";
import { JUDGE_THRESHOLDS, type JudgeThresholds } from "./judge.config";
import { quoteContext, quoteLineIndexes } from "./text";

// ③ Jev 판정 (docs/TRUTH_RULES.md 1장). 후보 하나에 질문 여러 개를 한 번에 묻고,
// 돌아온 확률을 임계값과 비교해 자동 반영 / 확인 요청 / 기각으로 나눈다. 판정 규칙은 순수 함수라 단위 테스트로 고정한다.

export type RejectReason = "NOT_MY_ACTION" | "INFO_ONLY" | "TENTATIVE" | "ALREADY_DONE";
export type JudgeDecision = "auto" | "confirm" | "reject";

export type JudgeCandidate = { title: string; quote: string; due_text: string | null; counterpart?: string | null; owner?: "me" | "unknown" };

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
  /**
   * 확률 표가 아니라 코드 규칙으로 정한 판정.
   * addressed_request: 사용자를 @이름으로 불렀다. sole_recipient_request: 사용자가 유일한 받는 사람인 메일이다.
   * identity_ambiguous: 참석자 중 동명이인과 겹치는 이름이 있어 화자·담당 확인이 필요하다.
   */
  rule?: "addressed_request" | "sole_recipient_request" | "identity_ambiguous";
};


export type JudgeResult = JudgeOutcome & {
  signals: JudgeSignals;
  /** 인용 줄의 화자 이름표 (코드가 원문에서 읽은 값, quoteSpeaker). 병합이 붙일 Action의 요청자와 비교해 화자 역할을 정한다 */
  speaker?: string;
  /** 화자 이름이 참석자 중 동명이인과 겹친다. 원문 이름표는 유지하고 Claim의 역할은 unknown으로 둔다. */
  speakerAmbiguous?: true;
  /** 사용자로 읽은 담당 이름이나 @호칭이 참석자 중 동명이인과 겹친다. 담당은 확인 전까지 모른다. */
  ownerAmbiguous?: true;
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
  const speaker = quoteSpeaker(source.text, candidate.quote, identity, source.participants);
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
      // 인용 줄의 화자 이름표 ("박지훈: …"). 코드가 원문에서 읽은 값이라 추측보다 확실하다 (judge-v5).
      ...(speaker ? { quote_speaker: speaker } : {}),
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

/**
 * 유일한 받는 사람 메일 규칙(sole_recipient_request)이 확인 요청으로 살리는 후보의 최소 `is_my_commitment`.
 * 이 아래는 사용자에게 한 요청이 아니라 남의 일 · 남의 말을 추출한 것에 가까워 기각 그대로 둔다: 골든셋 보정 표에서 0.0~0.2 구간의
 * 실제 내 약속 비율이 0/57이다. 개인화된 영업 메일("Open to a 15-min call Tuesday?")이 요청처럼 보여도 아는 사이인지는 파이프라인이 모르므로
 * (주소가 회사 도메인이 아닌 외부 거래처가 이 규칙의 주된 대상이다) 확률 아래쪽만 자른다. @이름 규칙(addressed_request)에는 쓰지 않는다: 이름을 직접 불렀다.
 */
export const SOLE_RECIPIENT_MIN_MINE = 0.2;

export type DecideContext = {
  /** 인용 줄이 사용자를 @이름으로 직접 부른다 (addressedToUser) */
  addressedToUser?: boolean;
  /** 사용자가 유일한 받는 사람인 메일의 후보다 (kind email + userPosition sole_recipient) */
  soleRecipient?: boolean;
};

/** 확률을 임계값과 비교해 자동 반영 / 확인 요청 / 기각을 정한다 (docs/TRUTH_RULES.md 1장 표). */
export function decideOutcome(
  signals: JudgeSignals,
  thresholds: JudgeThresholds = JUDGE_THRESHOLDS,
  context: DecideContext = {},
): JudgeOutcome {
  const rejects: RejectReason[] = [];
  if (signals.is_my_commitment < thresholds.reject) rejects.push("NOT_MY_ACTION");
  if (signals.is_actionable < thresholds.reject) rejects.push("INFO_ONLY");
  if (signals.certainty.choice === "none") rejects.push("TENTATIVE");
  if (signals.already_done >= thresholds.doneRejectAt) rejects.push("ALREADY_DONE");
  // 사용자를 @이름으로 직접 부른 요청, 사용자가 유일한 받는 사람인 메일의 요청은 아직 수락하지 않았다는 이유("내 약속 아님") 하나로는
  // 버리지 않고 묻는다 (원칙 3). 무엇을 가리키는지 원문에 없는 요청("@지호 이거 금요일까지 될까요?")이나 여러 이야기 사이에 묻힌
  // 메일 요청("계약서 사본도 한 부 보내주실 수 있을까요?")이 조용히 사라지지 않게 한다. 다른 사유가 함께 있으면 그대로 기각.
  const soleRecipient = context.soleRecipient === true && signals.is_my_commitment >= SOLE_RECIPIENT_MIN_MINE;
  const pendingRule = context.addressedToUser === true ? "addressed_request" : soleRecipient ? "sole_recipient_request" : null;
  const pendingRequest = pendingRule !== null && rejects.length === 1 && rejects[0] === "NOT_MY_ACTION";
  if (rejects.length > 0 && !pendingRequest) return { decision: "reject", reasons: rejects };

  const doubts: RejectReason[] = [];
  if (signals.is_my_commitment < thresholds.accept) doubts.push("NOT_MY_ACTION");
  if (signals.is_actionable < thresholds.accept) doubts.push("INFO_ONLY");
  if (signals.certainty.choice !== "firm") doubts.push("TENTATIVE");
  if (signals.already_done >= thresholds.doneAcceptBelow) doubts.push("ALREADY_DONE");
  // 규칙으로 살린 요청은 임계값 설정과 상관없이 확인 요청까지만 간다 (자동 반영하지 않는다).
  if (pendingRequest) return { decision: "confirm", reasons: [...new Set<RejectReason>(["NOT_MY_ACTION", ...doubts])], rule: pendingRule };
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
  const speaker = quoteSpeaker(source.text, candidate.quote, identity, source.participants);
  const speakerAmbiguous = Boolean(speaker && isAmbiguousUserName(speaker, identity, source.participants));
  const sourceLines = source.text.split("\n");
  const quoteLines = quoteLineIndexes(source.text, candidate.quote).map((index) => sourceLines[index]);
  const ownerAmbiguous = speakerAmbiguous || (
    containsAmbiguousAssignee(quoteLines.join("\n"), identity, source.participants) ||
    addressedAmbiguouslyToUser(source.text, candidate.quote, identity, source.participants)
  );
  const identityAmbiguous = speakerAmbiguous || ownerAmbiguous;
  const outcome = decideOutcome(signals, thresholds, {
    addressedToUser: addressedToUser(source.text, candidate.quote, identity, source.participants),
    soleRecipient: source.kind === "email" && userPosition(identity, source.participants) === "sole_recipient",
  });
  const judgedOutcome = identityAmbiguous && outcome.decision !== "reject"
    ? {
        ...outcome,
        decision: "confirm" as const,
        reasons: [...new Set<RejectReason>([...outcome.reasons, "NOT_MY_ACTION"])],
        rule: "identity_ambiguous" as const,
      }
    : outcome;
  return {
    ...judgedOutcome,
    signals,
    ...(speaker ? { speaker } : {}),
    ...(speakerAmbiguous ? { speakerAmbiguous: true as const } : {}),
    ...(ownerAmbiguous ? { ownerAmbiguous: true as const } : {}),
    promptVersion: self ? WRITTEN_BY_ME_PROMPT_VERSION : JUDGE_PROMPT_VERSION,
    model: response.model,
    cost: response.usage?.cost,
  };
}
