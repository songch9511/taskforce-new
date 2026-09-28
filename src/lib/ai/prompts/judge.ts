import type { JevQuestion } from "@/lib/ai/jev";

// Jev 후보 검증 질문 (docs/TRUTH_RULES.md 1장). 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.
// 질문은 영어, state의 원문은 한국어 그대로 둔다 (한국어 질문과의 비교는 이후 과제).

/**
 * 판정 질문 전체(JUDGE_QUESTIONS · WRITTEN_BY_ME_QUESTIONS)의 버전. 어느 쪽 문구를 바꿔도 올린다 (eval 결과 파일 이름 · 요약에 쓴다).
 * 판정 한 건에 남기는 버전(judge_logs.model_version, JudgeResult.promptVersion)은 어느 질문 묶음으로 물었는지까지 가른다:
 * JUDGE_QUESTIONS는 이 값 그대로("judge-v5"), WRITTEN_BY_ME_QUESTIONS는 WRITTEN_BY_ME_PROMPT_VERSION("judge-v5-self").
 * judge-v5: speaker_role이 코드가 읽은 인용 줄의 화자(state.candidate.quote_speaker)를 보고, directness는 이유만 전해 들은 말이면 직접 발언으로 본다 (Slack 골든셋 F2).
 */
export const JUDGE_PROMPT_VERSION = "judge-v5";
export const WRITTEN_BY_ME_PROMPT_VERSION = `${JUDGE_PROMPT_VERSION}-self`;

export const JUDGE_QUESTIONS = {
  is_my_commitment: {
    type: "noul",
    instructions:
      "Did the user personally commit to, or get assigned and accept, this action? The user is state.user.name, also called any of state.user.aliases; state.user.position says whether the user sent, received, or was only cc'd on the message. Answer no if someone else will do it.",
  },
  is_actionable: {
    type: "noul",
    instructions: "Is this a concrete action someone must do, not reference info, an announcement, an opinion, or an idea?",
  },
  already_done: {
    type: "noul",
    instructions: "Does the context show this action is already completed?",
  },
  certainty: {
    type: "choice",
    instructions: "How firm is the user's commitment to this action?",
    criteria: {
      firm: "Explicit promise, accepted assignment, or a direct request to the user that the user has not declined",
      tentative: "Maybe, considering, vague, or a promise that only applies once a future condition is met (e.g. 'once the contract is signed')",
      none: "No commitment by the user and no request made to the user",
    },
  },
  // 변경 · 완료 · 취소 발언도 Claim이 되므로, "사용자의 약속"이 아니라 인용 발언 자체가 얼마나 확정적인지 따로 묻는다.
  statement_certainty: {
    type: "choice",
    instructions: "How definite is the statement in the quote itself (a promise, a change, a completion, or a cancellation)?",
    criteria: {
      firm: "States a decision or fact, including polite softeners like '~것 같아요' or '~해도 될 것 같아요' that still decide",
      tentative: "Speculation, a question or proposal waiting for an answer, or conditional on something",
    },
  },
  speaker_role: {
    type: "choice",
    instructions:
      "Who made the statement in the quote? state.candidate.quote_speaker, when given, is the name label on the quoted line, i.e. the person who said it: compare it with state.user.name / state.user.aliases and state.candidate.counterpart.",
    criteria: {
      me: "The user",
      counterpart: "The person the action is for (state.candidate.counterpart when given), who asked for it",
      third_party: "Someone else",
    },
  },
  directness: {
    type: "choice",
    instructions:
      "Does the speaker of the quote decide it in their own voice, or pass on what another person decided or said? Read the quote's whole message in the context. Relaying someone else's decision or permission (e.g. '팀장님이 다음 주도 된다고 하셨어요') is reported, even if the quote leaves out who said it. A decision the speaker makes themselves is first-hand, even when its reason involves others (e.g. '대표님이 하자고 하셔서요', or '샘플은 안 보내셔도 됩니다, 본사에서 이미 확보했다고 하네요').",
    criteria: {
      first_hand: "The speaker states it themselves",
      reported: "The speaker relays another person's words, e.g. '민수님이 월요일도 괜찮대요'",
    },
  },
  audience: {
    type: "choice",
    instructions: "Was this said to the counterpart or written as a private note?",
    criteria: { shared: "Communicated to the counterpart", private: "User's own note or internal" },
  },
} as const satisfies Record<string, JevQuestion>;

export type JudgeQuestionKey = keyof typeof JUDGE_QUESTIONS;

/**
 * 사용자가 직접 쓴 문서(state.source.written_by_me: true)일 때의 질문 (judge-v4부터, 남기는 버전은 WRITTEN_BY_ME_PROMPT_VERSION). 자기 문서에 적은 할 일에는 약속 · 요청 말투가 없어
 * v3 질문으로는 certainty가 none이 되어 기각됐다. is_my_commitment와 certainty의 firm 기준만 다르다.
 * 작성자를 모르는 원문에는 JUDGE_QUESTIONS를 그대로 보낸다: 조건("written_by_me가 true면")을 공통 질문에 넣었더니
 * 작성자 정보가 없는 원문의 is_my_commitment도 올라갔다 (eval: 다른 사람이 쓴 같은 문서의 할 일이 자동 반영됨).
 */
export const WRITTEN_BY_ME_QUESTIONS = {
  ...JUDGE_QUESTIONS,
  is_my_commitment: {
    type: "noul",
    instructions:
      "Did the user personally commit to, or get assigned and accept, this action? The user is state.user.name, also called any of state.user.aliases. The user wrote this document themselves (state.source.written_by_me), so a to-do, plan, or next step listed in it is the user's own commitment unless it names someone else as the doer. Answer no if someone else will do it.",
  },
  certainty: {
    ...JUDGE_QUESTIONS.certainty,
    criteria: {
      ...JUDGE_QUESTIONS.certainty.criteria,
      firm: "Explicit promise, accepted assignment, a direct request to the user that the user has not declined, or a to-do, plan, or next step the user wrote down for themselves in this document (not an idea or wish), unless it names someone else as the doer or is marked done",
    },
  },
} as const satisfies Record<JudgeQuestionKey, JevQuestion>;
