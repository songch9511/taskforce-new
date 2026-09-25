import type { JevQuestion } from "@/lib/ai/jev";

// Jev 후보 검증 질문 (docs/TRUTH_RULES.md 1장). 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.
// 질문은 영어, state의 원문은 한국어 그대로 둔다 (한국어 질문과의 비교는 이후 과제).

export const JUDGE_PROMPT_VERSION = "judge-v2";

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
  speaker_role: {
    type: "choice",
    instructions: "Who made the statement in the quote?",
    criteria: { me: "The user", counterpart: "The person the action is for", third_party: "Someone else" },
  },
  directness: {
    type: "choice",
    instructions: "Is the statement first-hand or reported?",
    criteria: { first_hand: "Speaker states it directly", reported: "Relays what someone else said" },
  },
  audience: {
    type: "choice",
    instructions: "Was this said to the counterpart or written as a private note?",
    criteria: { shared: "Communicated to the counterpart", private: "User's own note or internal" },
  },
} as const satisfies Record<string, JevQuestion>;

export type JudgeQuestionKey = keyof typeof JUDGE_QUESTIONS;
