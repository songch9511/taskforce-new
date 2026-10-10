import type { JevQuestion } from "@/lib/ai/jev";

// 기억 후보 추출 (J7, 아키텍처 7.3). 상담 답(J2)과 같은 호출에서 memory_candidates로 받는다: consult.ts가 이 절을 시스템 프롬프트 끝에 붙인다.
// 코드는 후보를 그대로 믿지 않는다: 인용을 사용자 메시지와 대조하고(이어진 한 덩어리 · 4자 이상) 문장 ↔ 인용 연결을 확인한 뒤,
// Jev 판정(memorySupportQuestion: 인용이 문장을 그대로 말하는가)을 통과한 것만 explicit로 저장한다 (src/lib/conversation/memory.ts). 문구를 바꾸면 버전을 올리고 consult 골든셋(evals/consult) 실제 모델 결과를 PR에 적는다.

export const MEMORY_EXTRACT_PROMPT_VERSION = "memory-extract-v2";

/** 저장할 수 있는 기억 종류와 뜻 (identity_link는 대화에서 만들지 않는다: 신원은 연결 · 설정이 정한다) */
export const MEMORY_KIND_GUIDE = {
  goal: "이루려는 결과 (예: Shape를 이번 달에 출시)",
  condition: "무엇을 시작 · 끝내는 조건 (예: 디자인 확정 뒤 개발 시작)",
  outcome_criteria: "결과가 갖춰야 할 기준 (예: 견적서는 VAT 포함)",
  relationship: "사람 · 조직과의 관계 (예: 김대표는 고객사 대표)",
  fact: "일에 관한 사실 · 결정 (예: 디자인이 확정됨)",
  working_rule: "일하는 방식 (예: 금요일 오후에는 회의를 잡지 않음)",
  plan: "누가 · 무엇으로 · 어떻게 할 계획 (예: 개발은 Opus 5.5로)",
} as const;

export const MEMORY_EXTRACT_SECTION = `## 기억 후보 (memory_candidates)
- material.intent.allow_memory가 false면 memory_candidates는 빈 배열입니다.
- true면 material.memory_messages에 있는 사용자 메시지(U 번호)에서 사용자가 앞으로도 기억해 두기를 바라는 것만 뽑습니다: 사실 · 결정, 조건, 계획, 목표, 결과 기준, 일하는 방식, 관계.
- 지금 메시지가 아닌 앞 메시지("기억해 둘까요?"라는 질문 앞의 메시지)는 사용자가 지금 메시지에서 기억하라고 분명히 동의했을 때만 인용합니다. "아니" · "됐어" · 애매한 답이면 뽑지 않습니다.
- 사용자가 실제로 말한 것만. 추측 · 일반화 · 다른 범위로 넓히기를 하지 않습니다. assistant 메시지(R 번호) · 자료(sources) · 할 일(actions)에서는 뽑지 않습니다.
- 각 후보:
  - kind: ${Object.entries(MEMORY_KIND_GUIDE)
    .map(([kind, meaning]) => `${kind}(${meaning})`)
    .join(", ")} 중 하나
  - subject: 이 사실을 가리키는 짧은 이름 (예: "개발 에이전트", "개발 착수 조건"). 같은 사실이면 같은 subject, 다른 사실이면 다른 subject. 기존 기억(material.memory)과 같은 사실을 다시 말하거나 바꾼 것이면 그 기억의 subject를 그대로 씁니다.
  - statement: 기억할 한 문장, 사용자의 언어로. 사용자가 말한 내용만 담습니다.
  - message: 인용한 사용자 메시지 번호 (예: "U3")
  - quote: 그 메시지에 있는 이어진 구절 하나를 한 글자도 바꾸지 않고 복사합니다. statement의 근거가 되는 부분이어야 합니다.
  - corrects: 사용자가 기존 기억(material.memory의 M 번호)이 틀렸거나 바뀌었다고 하면 그 번호, 아니면 null. 그 기억과 같은 kind · 같은 사실일 때만 가리킵니다.
- 기억 후보를 뽑았다고 답(segments)에서 "기억했어요" · "저장했어요"라고 말하지 않습니다. 저장 결과는 시스템이 붙입니다.`;

/**
 * 기억 판정 (Jev noul, 후보마다 하나): 사용자가 인용한 말이 기억 문장을 그대로 말하는가. 기계 확인(인용 대조)을 통과한 후보만 묻는다
 * (src/lib/conversation/memory.ts checkMemorySupport). 덧붙임 · 부정 뒤집기 · 일반화 · 남의 말을 옮긴 것은 아니오.
 * 정정이면(previous_statement가 있으면) 그 말이 같은 대상의 이전 기억을 바꾸는 것인지도 본다 (무관한 사실이 옛 기억을 덮지 않게).
 */
export function memorySupportQuestion(index: number): JevQuestion {
  const c = `state.candidates[${index}]`;
  return {
    type: "noul",
    instructions:
      `In ${c}, the user wrote ${c}.message (replying to state.previous_reply when it is not null). ` +
      `Does the user's own words in ${c}.quote state exactly what ${c}.statement says? ` +
      `If ${c}.previous_statement is not null, also require that the user's words change that earlier memory about the same thing (not a different fact). ` +
      "Answer no if the statement adds anything, flips a negation, generalizes beyond what was said, or turns someone else's words or a question into the user's claim.",
  };
}

/**
 * 동의 판정 (Jev noul): Taskforce가 "기억해 둘까요?"라고 물었고(state.previous_reply) 사용자가 지금 답(state.current_message)을 했을 때,
 * 그 답이 기억하는 데 동의하는가. 앞 사용자 메시지를 인용한 후보는 이 판정을 통과해야 저장한다 ("아니, 됐어" · 망설임 · 애매함은 아니오).
 */
export const MEMORY_AGREE_QUESTION: JevQuestion = {
  type: "noul",
  instructions:
    "Taskforce asked state.previous_reply, offering to remember something the user said earlier. Does the user's reply state.current_message clearly agree that Taskforce should remember it? " +
    "Answer no if the user declines, hesitates, changes the subject, or the reply is unclear.",
};

/** 기억 판정 요청: 앞 답(600자) · 지금 답 · 후보들(+ 옛 기억 문장). 앞 메시지를 인용한 후보가 있으면 동의 판정도 함께. 원문 · 할 일은 보내지 않는다 */
export function buildMemorySupportRequest(
  candidates: { statement: string; quote: string; message: string; previous_statement: string | null }[],
  context: { previousReply: string | null; currentMessage: string; askAgreement: boolean },
) {
  return {
    state: { previous_reply: context.previousReply ? context.previousReply.slice(0, 600) : null, current_message: context.currentMessage, candidates },
    questions: {
      ...Object.fromEntries(candidates.map((_, i) => [`support_${i}`, memorySupportQuestion(i)])),
      ...(context.askAgreement ? { agrees: MEMORY_AGREE_QUESTION } : {}),
    },
  };
}
