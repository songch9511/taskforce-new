import { buildIntentState, INTENT_PROMPT_VERSION, INTENT_QUESTION, READ_QUESTION, REMEMBER_QUESTION } from "@/lib/ai/prompts/intent";
import { intentKindSchema, type IntentKind, type MessageIntent } from "@/lib/api/contract";
import type { Decide } from "@/lib/pipeline/judge";

import { INTENT_THRESHOLDS } from "./intent.config";

// J1 의도 · 기억 · 조회 분류 (런타임 계약 2장 "의도 분류"). Jev choice 한 번(질문 셋)으로 묻고, 분기는 이 파일의 규칙으로만 한다.
// DB와 분리된 순수 함수: route · eval · 테스트가 같은 코드를 쓴다.

export type IntentResult = {
  kind: IntentKind;
  confidence: number;
  /** 발화에 기억할 사실 · 조건 · 계획 · 정정이 있는가 (0–1) */
  remember: number;
  /** 발화에 지금 답할 조회 · 상담이 있는가 (0–1) */
  read: number;
  judgeVersion: string;
  cost: number;
};

export type IntentInput = Parameters<typeof buildIntentState>[0];

/** Jev에 묻는다. 모르는 선택지 · 빠진 답은 other(확신 0)로 읽는다: 확신이 낮으면 묻는 쪽으로 간다 */
export async function classifyIntent(input: IntentInput, decide: Decide): Promise<IntentResult> {
  const response = await decide({
    state: buildIntentState(input),
    questions: { intent: INTENT_QUESTION, remember: REMEMBER_QUESTION, read: READ_QUESTION },
  });
  const intent = response.answers.intent;
  const parsed = intent?.type === "choice" ? intentKindSchema.safeParse(intent.choice) : null;
  const kind: IntentKind = parsed?.success ? parsed.data : "other";
  const confidence =
    parsed?.success && intent?.type === "choice" ? clamp(intent.confidence ?? intent.probabilities[intent.choice] ?? 0) : 0;
  const noul = (key: "remember" | "read") => {
    const answer = response.answers[key];
    return answer?.type === "noul" ? clamp(answer.noul) : 0;
  };
  return { kind, confidence, remember: noul("remember"), read: noul("read"), judgeVersion: INTENT_PROMPT_VERSION, cost: response.usage?.cost ?? 0 };
}

const clamp = (value: number) => (Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0);

/** conversation_messages.intent에 남기는 값 */
export function messageIntent(result: IntentResult): MessageIntent {
  return { kind: result.kind, confidence: result.confidence, judge_version: result.judgeVersion };
}

/** 쓰기 의도 (대상이 정해진 뒤에만 쓴다). inform · correct는 memory_items에만 쓴다 (아키텍처 5.6) */
const WRITE_KINDS = new Set<IntentKind>(["adopt", "instruct", "modify", "answer", "stop", "preference", "inform", "correct"]);
/** 기억을 쓸 수 있는 의도: 알림 · 정정 · Taskforce가 물은 것에 답함 */
const MEMORY_KINDS = new Set<IntentKind>(["inform", "correct", "answer"]);
/** 실행에 닿는 의도: B2에는 실행 연결이 없다 (run 0, "아직 실행 연결이 없어요") */
const EXECUTION_KINDS = new Set<IntentKind>(["instruct", "modify", "stop"]);

export type IntentRoute =
  /** 무엇을 원하는지 묻는다 (확신 < 0.5). 쓰기 0 */
  | { kind: "clarify" }
  /** 조회 · 상담 · 그 밖: 답한다. memory: 기억 후보를 저장할 수 있는가 */
  | { kind: "consult"; memory: boolean }
  /** 기억할 내용(알림 · 정정 · 답). memory false면 묻기만 한다(0.5–0.8) */
  | { kind: "remember"; memory: boolean }
  /** 직전 제안 채택. confirm: 확신이 0.5–0.8이라 추가할지 한 번 묻는다 */
  | { kind: "adopt"; confirm: boolean }
  /** 실행 의도: 실행하지 않는다. 대상만 정하고(모호하면 묻기) 실행 연결이 없다고 말한다. alsoRead: 조회 부분이 있어 함께 답한다 */
  | { kind: "execution"; confirm: boolean; alsoRead: boolean }
  /** 선호: user_preferences는 아직 없다 (저장 0) */
  | { kind: "preference"; alsoRead: boolean };

/**
 * 의도 → 분기 (런타임 계약 2장 임계값). 쓰기는 확신 ≥ 0.8에서만 한다.
 * - 확신 < 0.5: 묻는다.
 * - 조회 · 상담 · 그 밖: 0.5 이상이면 답한다. 의도 확신 ≥ 0.8이고 발화에 기억할 내용이 확실하면(remember ≥ 0.8) 함께 저장할 수 있다.
 * - 알림 · 정정 · 답: ≥ 0.8이면 저장할 수 있다. 0.5–0.8이면 답하되 저장하지 않고 기억해 둘지 묻는다.
 */
export function routeIntent(
  result: Pick<IntentResult, "kind" | "confidence" | "remember" | "read">,
  /** 바로 앞 답이 물은 것 · 그 답에 열린 제안이 있는가: Taskforce의 질문에 답한 것(answer)이면 그 질문에 맞는 분기로 */
  previous: { asked: "remember" | "referent" | "clarify" | "adopt" | null; openProposal: boolean } = { asked: null, openProposal: false },
): IntentRoute {
  const { kind, confidence } = result;
  if (confidence < INTENT_THRESHOLDS.ask) return { kind: "clarify" };
  const sure = confidence >= INTENT_THRESHOLDS.act;
  const alsoRead = result.read >= INTENT_THRESHOLDS.act;
  if (kind === "answer") {
    // "추가할까요?"에 "응" = 채택, "어느 일인가요?"에 답 = 실행 의도의 대상(실행 연결은 없다), "무엇을 원하나요?"에 답 = 다시 읽어 답한다
    if (previous.asked === "adopt" && previous.openProposal) return { kind: "adopt", confirm: !sure };
    if (previous.asked === "referent") return { kind: "execution", confirm: !sure, alsoRead };
    if (previous.asked === "clarify") return { kind: "consult", memory: sure && result.remember >= INTENT_THRESHOLDS.act };
  }
  if (MEMORY_KINDS.has(kind)) return { kind: "remember", memory: sure };
  if (kind === "adopt") return { kind: "adopt", confirm: !sure };
  if (EXECUTION_KINDS.has(kind)) return { kind: "execution", confirm: !sure, alsoRead };
  if (kind === "preference") return { kind: "preference", alsoRead };
  // lookup · consult · other: 함께 말한 사실의 저장도 쓰기라 의도 확신 ≥ 0.8이 먼저다 (런타임 계약 2장)
  return { kind: "consult", memory: sure && result.remember >= INTENT_THRESHOLDS.act };
}

export function isWriteIntent(kind: IntentKind): boolean {
  return WRITE_KINDS.has(kind);
}
