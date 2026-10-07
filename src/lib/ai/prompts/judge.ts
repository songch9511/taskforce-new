import type { JevQuestion } from "@/lib/ai/jev";

// Jev 후보 검증 질문 (docs/TRUTH_RULES.md 1장). 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.
// 질문은 영어, state의 원문은 한국어 그대로 둔다 (한국어 질문과의 비교는 이후 과제).

/**
 * 판정 질문 묶음의 버전. 문서 판정과 회의 판정은 각각 별도 버전을 쓴다 (eval 결과 파일 이름 · 요약에 쓴다).
 * 판정 한 건에 남기는 버전(judge_logs.model_version, JudgeResult.promptVersion)은 어느 질문 묶음으로 물었는지까지 가른다:
 * JUDGE_QUESTIONS는 이 값 그대로("judge-v5"), Slack message는 SLACK_JUDGE_PROMPT_VERSION, WRITTEN_BY_ME_QUESTIONS는 WRITTEN_BY_ME_PROMPT_VERSION("judge-v5-self").
 * judge-v5: speaker_role이 코드가 읽은 인용 줄의 화자(state.candidate.quote_speaker)를 보고, directness는 이유만 전해 들은 말이면 직접 발언으로 본다 (Slack 골든셋 F2).
 */
export const JUDGE_PROMPT_VERSION = "judge-v5";
export const SLACK_JUDGE_PROMPT_VERSION = "judge-v2-slack";
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

/**
 * Slack message만 쓰는 질문 묶음. 앱 DM의 개인별 의무와 명시적 broadcast 의무를 좁게 인식하되,
 * 일반 공지·사람/앱이 자기 일을 하겠다는 말은 사용자 소유로 돌리지 않는다.
 */
export const SLACK_JUDGE_QUESTIONS = {
  ...JUDGE_QUESTIONS,
  is_my_commitment: {
    type: "noul",
    instructions:
      "Is this the user's own current action? The user is state.user.name / aliases. An individualized Slack app DM can remind the user of a concrete task without a user-authored promise or formal acceptance: read the task and its required next step together across nearby app-authored lines in state.message_context. A task-specific deadline/status plus an instruction to complete or check it if still outstanding is a personal reminder even when the candidate quote is only the task or deadline line. If completion is uncertain, the task remains the user's but is tentative and must go to Review. Do not infer ownership from an app DM or a deadline alone when there is no concrete required step. A direct request to the user also counts before acceptance only while it remains outstanding; if the user clearly declines or passes it to someone else, it is no longer the user's current task. Do not count work that the app or another person says they will do, a task assigned to someone else, or a generic announcement. Use message_owner to distinguish a duty for every reader from a personal assignment.",
  },
  is_actionable: {
    type: "noul",
    instructions:
      "Is this a concrete required step for the candidate owner? A personal app reminder can be actionable even though it is formatted as a notice: the task name and required next step may appear in adjacent Slack app lines. An instruction to check or finish a named task if it is still outstanding is actionable but tentative when completion is unknown. General announcements, status information, product tips, promotions, optional suggestions, and channel references are not actionable.",
  },
  certainty: {
    ...JUDGE_QUESTIONS.certainty,
    criteria: {
      firm: "A clear user promise, accepted assignment, direct required request, explicit per-reader broadcast duty, or unconditional individualized app reminder that states a concrete required action",
      tentative: "Optional advice, a vague suggestion, a condition whose fulfillment is unknown, or a personal app reminder that says to act only if the named task is still outstanding",
      none: "No current user or per-reader duty, including an announcement, a task owned by someone else or the app, a request the user clearly declined, or a task the user passed to another person",
    },
  },
  message_owner: {
    type: "choice",
    instructions:
      "Classify ownership of this specific candidate as it stands now, using its quote and state.message_context, which contains the Slack header and a bounded nearby excerpt. Use only evidence that applies to this candidate; do not transfer ownership from unrelated messages elsewhere in the excerpt. A Slack header identifies the DM/channel but does not prove audience membership or assignment. A mention or channel name alone is not an assignment. If the user clearly declines this request, classify it as unassigned; if the user passes it to a named person, use someone_else. If quote_speaker is exactly 'Slack app', treat it as an app-authored statement: the app's first-person work is not the user's. In an individualized app DM, task-specific deadline/status information plus a nearby instruction to complete or check that named task if it remains outstanding establishes a personal reminder for the recipient even if the task and instruction are on different app-authored lines. The completion condition makes it tentative, not unassigned. A deadline, app delivery, generic progress note, or optional suggestion by itself does not establish a personal task. @channel/@everyone plus an explicit requirement for every reader to act individually is everyone_individually. @here targets people active at send time; without evidence that the user was active, use ambiguous, not user or everyone_individually. An announcement, optional suggestion, or unassigned channel item is unassigned.",
    criteria: {
      user: "The quote and nearby app-authored lines in an individualized DM establish a named concrete required task and a next step the recipient must complete/check if it remains outstanding, even if those facts are on separate lines; it is tentative when completion is unknown. The user's promise/acceptance or a direct required request to them also qualifies only if the user has not declined or passed it to someone else.",
      everyone_individually: "The message explicitly requires every reader to complete the concrete action individually, such as an @channel or @everyone obligation. Do not use this for @here.",
      someone_else: "A named person other than the user or the app itself owns the action; this includes a non-user human or app speaker saying they will do it.",
      unassigned: "The message is informational, an announcement, an optional suggestion, a deadline/status without a concrete required step, a channel reference, a task without a user-specific/per-reader assignment, or a request the user clearly declined without assigning another owner.",
      ambiguous: "A concrete owner or audience could include the user, but the message does not establish whether it does; @here without evidence of the user's active presence is an example.",
    },
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
