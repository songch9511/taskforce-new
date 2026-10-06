import type { JevQuestion } from "@/lib/ai/jev";

// Jev 후보 검증 질문 (docs/TRUTH_RULES.md 1장). 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.
// 질문은 영어, state의 원문은 한국어 그대로 둔다 (한국어 질문과의 비교는 이후 과제).

/**
 * 판정 질문 묶음의 버전. 문서 판정과 회의 판정은 각각 별도 버전을 쓴다 (eval 결과 파일 이름 · 요약에 쓴다).
 * 판정 한 건에 남기는 버전(judge_logs.model_version, JudgeResult.promptVersion)은 어느 질문 묶음으로 물었는지까지 가른다:
 * JUDGE_QUESTIONS는 이 값 그대로("judge-v5"), WRITTEN_BY_ME_QUESTIONS는 WRITTEN_BY_ME_PROMPT_VERSION("judge-v5-self").
 * judge-v5: speaker_role이 코드가 읽은 인용 줄의 화자(state.candidate.quote_speaker)를 보고, directness는 이유만 전해 들은 말이면 직접 발언으로 본다 (Slack 골든셋 F2).
 */
export const JUDGE_PROMPT_VERSION = "judge-v5";
export const WRITTEN_BY_ME_PROMPT_VERSION = `${JUDGE_PROMPT_VERSION}-self`;
export const MEETING_JUDGE_PROMPT_VERSION = "judge-v6-meeting";
export const DOCUMENT_JUDGE_PROMPT_VERSION = "judge-v7-document";
export const WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION = `${DOCUMENT_JUDGE_PROMPT_VERSION}-self`;

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

/**
 * 회의 원문은 참석·문서 접근·작성만으로 후보 담당을 정하지 않는다. 후보 구절에 붙은 담당 관계만 묻고,
 * 연결 사람이 없거나 메타데이터가 빠졌다는 이유만으로 참석하지 않았다고 판정하지 않는다.
 */
export const MEETING_JUDGE_QUESTIONS = {
  ...JUDGE_QUESTIONS,
  meeting_owner: {
    type: "choice",
    instructions:
      "Classify who this specific candidate says should do the action. Judge only the candidate quote and its immediate context, not unrelated mentions elsewhere in the meeting. A name or @mention alone does not assign the action: use it as ownership evidence only when the action is requested of that person or assigned to them. If a speaker addresses the user but explicitly commits to do the action themselves, the speaker owns it. Do not infer ownership from document access, document creation, or being listed as a meeting participant. Participant metadata may be incomplete or may describe related people; a missing user entry is not proof the user was absent. Use ambiguous only when a concrete person reference could refer to the user or another person, not merely because no user link is stated.",
    criteria: {
      user: "The quote itself clearly ties the action to the user: it explicitly assigns the action to them or requests that they do it, or it is a first-person commitment with quote_speaker identified as the user. A mention used only to address the user does not count if the speaker says they will do the action.",
      someone_else: "The quote itself clearly says another named person is responsible for the action, even if the user appears elsewhere in the meeting.",
      unassigned: "The quote contains an action but does not tie its owner to the user or clearly identify another doer.",
      ambiguous: "The quote assigns the action to a concrete name or reference that could identify either the user or another person, and the source cannot resolve which one.",
    },
  },
} as const satisfies Record<string, JevQuestion>;

const DOCUMENT_OWNER_QUESTION = {
  type: "choice",
  instructions:
    "Classify who this specific candidate says should do the action. Use the candidate quote, its nearby context, and document_context to identify whether this is a personal checklist or shared notes with multiple speakers. source.written_by_me means the connected user is recorded as the document creator; it does not prove that every action in the document belongs to them. When source.written_by_me is true and the document context clearly shows a personal checklist or personal notes, an unassigned next step can belong to the user. For meeting summaries, transcripts, or shared notes with multiple speakers, do not infer ownership from document creation, access, a checklist marker, or being listed among related people; require an explicit assignment to the user or a first-person commitment by the user. A name or @mention alone is not an assignment. If another person is named or is the identified speaker committing to do the action, classify that person as the owner. Use unassigned when no person is tied to the action and ambiguous only when a concrete person reference could mean the user or someone else.",
  criteria: {
    user: "The candidate is explicitly assigned or requested of the user, the quote is a first-person commitment by the user, or source.written_by_me is true and document_context clearly shows that this is the user's personal checklist or personal notes rather than shared meeting notes.",
    someone_else: "The action is explicitly assigned to another person or a different identified speaker says they will do it.",
    unassigned: "The action appears in shared notes, a meeting summary, or a document with no user-specific ownership link and no clearly identified other doer.",
    ambiguous: "A concrete assignment name or reference could refer to the user or another person, and the source cannot resolve which one.",
  },
} as const satisfies JevQuestion;

export const DOCUMENT_JUDGE_QUESTIONS = {
  ...JUDGE_QUESTIONS,
  document_owner: DOCUMENT_OWNER_QUESTION,
} as const satisfies Record<string, JevQuestion>;

export const WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS = {
  ...JUDGE_QUESTIONS,
  is_my_commitment: {
    type: "noul",
    instructions:
      "Did the user personally commit to, or get assigned and accept, this action? source.written_by_me means the connected user is recorded as the document creator, not that every action belongs to them. For a clearly personal checklist, an unassigned next step may be the user's; for multi-speaker or shared notes, use only explicit candidate-level evidence of user ownership.",
  },
  certainty: {
    ...JUDGE_QUESTIONS.certainty,
    criteria: {
      ...JUDGE_QUESTIONS.certainty.criteria,
      firm: "Explicit promise, accepted assignment, direct request to the user that they have not declined, or a next step in a clearly personal checklist; not an unassigned item in shared meeting notes",
    },
  },
  document_owner: DOCUMENT_OWNER_QUESTION,
} as const satisfies Record<string, JevQuestion>;
