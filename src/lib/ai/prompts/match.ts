import type { JevQuestion } from "@/lib/ai/jev";

// 새 후보와 기존 열린 Action의 관계를 묻는 Jev 질문 (Phase 2 매칭). 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.

export const MATCH_PROMPT_VERSION = "match-v1";

export const RELATION_QUESTION: JevQuestion = {
  type: "choice",
  instructions:
    "Compare state.candidate with each task in state.existing. Is the candidate a new task, or about one of the existing tasks? Same task means the same deliverable for the same counterpart, even if worded differently.",
  criteria: {
    new: "A different task from every existing task",
    same_restated: "The same task as an existing one, restated or re-promised without changing it",
    same_changed: "The same task, with a changed deadline, scope, or owner",
    same_done: "The same task, reported as delivered or finished",
    same_cancelled: "The same task, cancelled or no longer needed according to the requester",
  },
};

/** 후보가 가리키는 기존 Action. 선택지는 요청마다 목록으로 만든다. */
export function targetQuestion(existing: { key: string; label: string }[]): JevQuestion {
  return {
    type: "choice",
    instructions: "Which existing task in state.existing is the candidate about? Answer none if it is about none of them.",
    criteria: { ...Object.fromEntries(existing.map((e) => [e.key, e.label])), none: "None of the existing tasks" },
  };
}
