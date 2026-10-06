import type { JevDecision, JevQuestion } from "@/lib/ai/jev";
import { kstDate } from "@/lib/ai/prompts/extract";
import {
  DOCUMENT_JUDGE_PROMPT_VERSION,
  DOCUMENT_JUDGE_QUESTIONS,
  JUDGE_PROMPT_VERSION,
  JUDGE_QUESTIONS,
  MEETING_JUDGE_PROMPT_VERSION,
  MEETING_JUDGE_QUESTIONS,
  WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION,
  WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS,
  WRITTEN_BY_ME_PROMPT_VERSION,
  WRITTEN_BY_ME_QUESTIONS,
} from "@/lib/ai/prompts/judge";

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
import type { CandidateSignal } from "./extract";

// ③ Jev 판정 (docs/TRUTH_RULES.md 1장). 후보 하나에 질문 여러 개를 한 번에 묻고,
// 돌아온 확률을 임계값과 비교해 자동 반영 / 확인 요청 / 기각으로 나눈다. 판정 규칙은 순수 함수라 단위 테스트로 고정한다.

export type RejectReason = "NOT_MY_ACTION" | "INFO_ONLY" | "TENTATIVE" | "ALREADY_DONE";
export type JudgeDecision = "auto" | "confirm" | "reject";

export type JudgeCandidate = {
  title: string;
  quote: string;
  due_text: string | null;
  signal: CandidateSignal;
  counterpart?: string | null;
  owner?: "me" | "unknown";
};

type JudgeStateCandidate = Omit<JudgeCandidate, "signal"> & { signal?: CandidateSignal };

export type JudgeSource = {
  text: string;
  kind: string;
  occurredAt: Date;
  participants?: Participants;
  /** 사용자가 직접 쓴 원문인가 (sources.written_by_me). true일 때만 판정에 넘긴다 */
  writtenByMe?: boolean | null;
};

/** Source metadata selects the question-set version, including runs with no candidates. */
export function judgePromptVersionForSource(source: Pick<JudgeSource, "kind" | "writtenByMe">): string {
  if (source.kind === "meeting") return MEETING_JUDGE_PROMPT_VERSION;
  if (source.kind === "doc") return source.writtenByMe === true ? WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION : DOCUMENT_JUDGE_PROMPT_VERSION;
  return source.writtenByMe === true ? WRITTEN_BY_ME_PROMPT_VERSION : JUDGE_PROMPT_VERSION;
}

function boundedDocumentContext(text: string, quote: string): string {
  const maxChars = 5000;
  if (text.length <= maxChars) return text;
  const local = quoteContext(text, quote, 12, 3500, Number.POSITIVE_INFINITY);
  if (!local) return text.slice(0, maxChars);
  const prefix = text.slice(0, Math.max(0, maxChars - local.length - 12));
  if (local.startsWith(prefix)) return local.slice(0, maxChars);
  return `${prefix}\n[…]\n${local}`;
}

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
  /** 회의 후보 구절 자체가 사용자의 할 일인지 가리는 의미 판단 */
  meeting_owner?: Choice<"user" | "someone_else" | "unassigned" | "ambiguous">;
  /** 문서 후보 구절 자체가 사용자의 할 일인지 가리는 의미 판단 */
  document_owner?: Choice<"user" | "someone_else" | "unassigned" | "ambiguous">;
};

export type JudgeOutcome = {
  decision: JudgeDecision;
  /** reject면 기각 사유, confirm이면 확인이 필요한 이유 */
  reasons: RejectReason[];
  /**
   * 확률 표가 아니라 코드 규칙으로 정한 판정.
   * addressed_request: 사용자를 @이름으로 불렀다. sole_recipient_request: 사용자가 유일한 받는 사람인 메일이다.
   * identity_ambiguous: 참석자 중 동명이인과 겹치는 이름이 있어 화자·담당 확인이 필요하다.
   * meeting_assignment · document_assignment: 원문에서 사용자에게 직접 할당됐지만 수락 여부만 불확실하다.
   */
  rule?: "addressed_request" | "sole_recipient_request" | "identity_ambiguous" | "meeting_assignment" | "document_assignment";
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
export function buildJudgeState(candidate: JudgeStateCandidate, source: JudgeSource, identity: UserIdentity) {
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
      ...((source.kind === "meeting" || source.kind === "doc") && source.participants?.attendees?.length
        ? { related_people: [...new Set(source.participants.attendees.flatMap((person) => (person.name?.trim() ? [person.name.trim()] : [])))] }
        : {}),
      ...(source.kind !== "meeting" && source.writtenByMe === true ? { written_by_me: true } : {}),
    },
    ...(source.kind === "doc" ? { document_context: boundedDocumentContext(source.text, candidate.quote) } : {}),
  };
}

export function parseJudgeAnswers(answers: JevDecision["answers"], ownership: "meeting" | "document" | null = null): JudgeSignals {
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
    ...(ownership === "meeting" ? { meeting_owner: choice("meeting_owner", ["user", "someone_else", "unassigned", "ambiguous"]) } : {}),
    ...(ownership === "document" ? { document_owner: choice("document_owner", ["user", "someone_else", "unassigned", "ambiguous"]) } : {}),
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
  /** 회의 후보 자체가 사용자에게 명시적으로 할당된다는 Jev의 의미 판단 */
  meetingAssignment?: boolean;
  /** 문서 후보 자체가 사용자에게 명시적으로 할당되거나 사용자 개인 체크리스트로 판정된다는 Jev의 의미 판단 */
  documentAssignment?: boolean;
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
  const pendingRule = context.addressedToUser === true
    ? "addressed_request"
    : context.meetingAssignment === true
      ? "meeting_assignment"
      : context.documentAssignment === true
        ? "document_assignment"
        : soleRecipient
          ? "sole_recipient_request"
          : null;
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
  // 회의에서는 문서 작성·참석 정보가 후보 담당을 대신하지 않도록 별도의 같은 호출 질문을 쓴다.
  // 그 밖의 원문은 사용자가 직접 쓴 문서일 때만 그에 맞춘 질문을 묻는다.
  const meeting = source.kind === "meeting";
  const document = source.kind === "doc";
  const self = !meeting && source.writtenByMe === true;
  const questions = meeting
    ? MEETING_JUDGE_QUESTIONS
    : document
      ? self
        ? WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS
        : DOCUMENT_JUDGE_QUESTIONS
      : self
        ? WRITTEN_BY_ME_QUESTIONS
        : JUDGE_QUESTIONS;
  const response = await decide({ state: buildJudgeState(candidate, source, identity), questions });
  const ownership = meeting ? "meeting" : document ? "document" : null;
  const signals = parseJudgeAnswers(response.answers, ownership);
  const speaker = quoteSpeaker(source.text, candidate.quote, identity, source.participants);
  const speakerAmbiguous = Boolean(speaker && isAmbiguousUserName(speaker, identity, source.participants));
  const sourceLines = source.text.split("\n");
  const quoteLines = quoteLineIndexes(source.text, candidate.quote).map((index) => sourceLines[index]);
  const semanticOwner = meeting ? signals.meeting_owner?.choice : document ? signals.document_owner?.choice : undefined;
  const gatedCommitment = (meeting || document) && candidate.signal === "commitment";
  const explicitOtherOwner = gatedCommitment && semanticOwner === "someone_else";
  const ambiguousAddress = addressedAmbiguouslyToUser(source.text, candidate.quote, identity, source.participants);
  const unrelatedSourceOwnership = gatedCommitment && (semanticOwner === "someone_else" || semanticOwner === "unassigned");
  const relatedUserWithUnassignedAction = candidate.signal === "commitment" && (meeting || document) && semanticOwner === "unassigned" &&
    userPosition(identity, source.participants) === "attendee";
  const ownerAmbiguous = !explicitOtherOwner && (speakerAmbiguous || (
    containsAmbiguousAssignee(quoteLines.join("\n"), identity, source.participants) ||
    (ambiguousAddress && !unrelatedSourceOwnership)
  ) || relatedUserWithUnassignedAction);
  const identityAmbiguous = !explicitOtherOwner && (speakerAmbiguous || ownerAmbiguous);
  const addressed = addressedToUser(source.text, candidate.quote, identity, source.participants);
  const outcome = decideOutcome(signals, thresholds, {
    addressedToUser: addressed,
    soleRecipient: source.kind === "email" && userPosition(identity, source.participants) === "sole_recipient",
    meetingAssignment: meeting && candidate.signal === "commitment" && semanticOwner === "user",
    documentAssignment: document && candidate.signal === "commitment" && semanticOwner === "user",
  });
  const unrelatedCommitment = gatedCommitment && (explicitOtherOwner || (
    !identityAmbiguous && !relatedUserWithUnassignedAction && semanticOwner === "unassigned"
  ));
  const semanticOwnerAmbiguous = gatedCommitment && !explicitOtherOwner && (semanticOwner === "ambiguous" || relatedUserWithUnassignedAction);
  const canConfirmAmbiguous = identityAmbiguous || semanticOwnerAmbiguous;
  const judgedOutcome = unrelatedCommitment
    ? { decision: "reject" as const, reasons: [...new Set<RejectReason>([...outcome.reasons, "NOT_MY_ACTION"])] }
    : canConfirmAmbiguous && (outcome.decision !== "reject" || (semanticOwnerAmbiguous && outcome.reasons.every((reason) => reason === "NOT_MY_ACTION")))
      ? {
          ...outcome,
          decision: "confirm" as const,
          reasons: [...new Set<RejectReason>([...outcome.reasons, "NOT_MY_ACTION"])],
          ...(identityAmbiguous ? { rule: "identity_ambiguous" as const } : {}),
        }
      : outcome;
  return {
    ...judgedOutcome,
    signals,
    ...(speaker ? { speaker } : {}),
    ...(speakerAmbiguous ? { speakerAmbiguous: true as const } : {}),
    ...(ownerAmbiguous || semanticOwnerAmbiguous ? { ownerAmbiguous: true as const } : {}),
    promptVersion: judgePromptVersionForSource(source),
    model: response.model,
    cost: response.usage?.cost,
  };
}
