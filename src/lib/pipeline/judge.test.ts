import { describe, expect, it } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";
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

import { buildJudgeState, decideOutcome, judgeCandidate, judgePromptVersionForSource, parseJudgeAnswers, SOLE_RECIPIENT_MIN_MINE, type Decide, type JudgeSignals } from "./judge";

const firm: JudgeSignals = {
  is_my_commitment: 0.95,
  is_actionable: 0.95,
  already_done: 0.05,
  certainty: { choice: "firm", probabilities: { firm: 0.9, tentative: 0.1, none: 0 } },
  statement_certainty: { choice: "firm", probabilities: { firm: 0.9 } },
  speaker_role: { choice: "me", probabilities: { me: 1 } },
  directness: { choice: "first_hand", probabilities: { first_hand: 1 } },
  audience: { choice: "shared", probabilities: { shared: 1 } },
};

const answers: JevDecision["answers"] = {
  is_my_commitment: { type: "noul", noul: 0.95 },
  is_actionable: { type: "noul", noul: 0.95 },
  already_done: { type: "noul", noul: 0.05 },
  certainty: { type: "choice", choice: "firm", probabilities: { firm: 0.9, tentative: 0.1, none: 0 } },
  statement_certainty: { type: "choice", choice: "firm", probabilities: { firm: 0.9 } },
  speaker_role: { type: "choice", choice: "me", probabilities: { me: 1 } },
  directness: { type: "choice", choice: "first_hand", probabilities: { first_hand: 1 } },
  audience: { type: "choice", choice: "shared", probabilities: { shared: 1 } },
  meeting_owner: { type: "choice", choice: "user", probabilities: { user: 0.95 } },
  document_owner: { type: "choice", choice: "user", probabilities: { user: 0.95 } },
};

const source = {
  text: ["김대표: 제안서 보고 싶어요.", "나: 네, 금요일까지 제안서 보내드릴게요.", "김대표: 좋아요."].join("\n"),
  kind: "meeting",
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
};
const candidate = { title: "제안서 발송", quote: "금요일까지 제안서 보내드릴게요", due_text: "금요일까지", signal: "commitment" as const };

describe("decideOutcome", () => {
  it("모든 확률이 높고 확정적이면 자동 반영", () => {
    expect(decideOutcome(firm)).toEqual({ decision: "auto", reasons: [] });
  });

  it("중간 구간이 하나라도 있으면 확인 요청", () => {
    expect(decideOutcome({ ...firm, is_my_commitment: 0.6 })).toEqual({ decision: "confirm", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome({ ...firm, already_done: 0.4 })).toEqual({ decision: "confirm", reasons: ["ALREADY_DONE"] });
  });

  it("확정적이지 않으면(tentative) 확인 요청", () => {
    expect(decideOutcome({ ...firm, certainty: { choice: "tentative", probabilities: {} } })).toEqual({
      decision: "confirm",
      reasons: ["TENTATIVE"],
    });
  });

  it("낮은 확률이나 약속 없음은 사유와 함께 기각", () => {
    expect(decideOutcome({ ...firm, is_my_commitment: 0.2 })).toEqual({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome({ ...firm, is_actionable: 0.1, certainty: { choice: "none", probabilities: {} } })).toEqual({
      decision: "reject",
      reasons: ["INFO_ONLY", "TENTATIVE"],
    });
    expect(decideOutcome({ ...firm, already_done: 0.9 })).toEqual({ decision: "reject", reasons: ["ALREADY_DONE"] });
  });

  it("@이름으로 부른 요청은 '내 약속 아님' 하나로는 기각하지 않고 확인 요청", () => {
    const pending = { ...firm, is_my_commitment: 0.3 };
    expect(decideOutcome(pending)).toEqual({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome(pending, undefined, { addressedToUser: true })).toEqual({
      decision: "confirm",
      reasons: ["NOT_MY_ACTION"],
      rule: "addressed_request",
    });
    // 다른 기각 사유가 함께 있으면 그대로 기각
    expect(decideOutcome({ ...pending, is_actionable: 0.2 }, undefined, { addressedToUser: true })).toEqual({
      decision: "reject",
      reasons: ["NOT_MY_ACTION", "INFO_ONLY"],
    });
    expect(decideOutcome({ ...pending, certainty: { choice: "none", probabilities: {} } }, undefined, { addressedToUser: true }).decision).toBe("reject");
    expect(decideOutcome({ ...pending, already_done: 0.9 }, undefined, { addressedToUser: true }).decision).toBe("reject");
  });

  it("@이름 규칙은 기각이 아닌 판정을 바꾸지 않고, 임계값이 뒤집혀도 자동 반영하지 않는다", () => {
    expect(decideOutcome({ ...firm, is_my_commitment: 0.6 }, undefined, { addressedToUser: true })).toEqual({ decision: "confirm", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome(firm, undefined, { addressedToUser: true })).toEqual({ decision: "auto", reasons: [] });
    const inverted = { accept: 0.3, reject: 0.5, doneAcceptBelow: 0.3, doneRejectAt: 0.7 };
    expect(decideOutcome({ ...firm, is_my_commitment: 0.4 }, inverted, { addressedToUser: true }).decision).toBe("confirm");
  });

  it("임계값은 설정으로 바꿀 수 있다", () => {
    const loose = { accept: 0.5, reject: 0.1, doneAcceptBelow: 0.5, doneRejectAt: 0.9 };
    expect(decideOutcome({ ...firm, is_my_commitment: 0.6 }, loose).decision).toBe("auto");
  });
});

describe("parseJudgeAnswers", () => {
  it("Jev 답을 신호로 바꾼다", () => {
    expect(parseJudgeAnswers(answers)).toEqual(firm);
  });

  it("정해진 선택지 밖의 답은 오류", () => {
    expect(() => parseJudgeAnswers({ ...answers, certainty: { type: "choice", choice: "maybe", probabilities: {} } })).toThrow();
  });
});

describe("buildJudgeState", () => {
  it("추출기의 추론 없이 후보와 인용 주변 원문, 인용 줄의 화자만 넣는다", () => {
    const state = buildJudgeState(candidate, source, { name: "나", aliases: ["Me"], emails: ["me@x.com"] });
    expect(state).toEqual({
      user: { name: "나", aliases: ["Me"], position: "unknown" },
      candidate: { title: candidate.title, due_text: candidate.due_text, quote: candidate.quote, quote_speaker: "나" },
      context: source.text,
      source: { kind: "meeting", occurred_at: "2025-09-22" },
    });
  });

  it("화자 표를 믿을 수 없으면 quote_speaker를 넣지 않는다", () => {
    const mail = { ...source, kind: "email", text: "제목: 제안서 일정\n금요일까지 제안서 보내드릴게요." };
    expect(buildJudgeState(candidate, mail, { name: "나", aliases: [], emails: [] }).candidate).toEqual({
      title: candidate.title,
      due_text: candidate.due_text,
      quote: candidate.quote,
    });
  });
});

describe("buildJudgeState의 작성자", () => {
  const identity = { name: "나", aliases: [], emails: [] };
  const doc = { text: "## 다음 단계\n- 도메인 연결 설정 바꾸기", kind: "doc", occurredAt: new Date("2026-10-12T21:00:00+09:00") };
  const todo = { title: "도메인 연결 설정 변경", quote: "도메인 연결 설정 바꾸기", due_text: null, signal: "commitment" as const };

  it("사용자가 직접 쓴 원문이면 source.written_by_me를 넘긴다", () => {
    const state = buildJudgeState(todo, { ...doc, writtenByMe: true }, identity);
    expect(state.source).toEqual({
      kind: "doc",
      occurred_at: "2026-10-12",
      written_by_me: true,
    });
    expect(state.document_context).toBe(doc.text);
  });

  it("다른 사람이 썼거나(false) 모르면(null · 없음) 넘기지 않는다", () => {
    for (const writtenByMe of [false, null, undefined]) {
      expect(buildJudgeState(todo, { ...doc, writtenByMe }, identity).source).toEqual({ kind: "doc", occurred_at: "2026-10-12" });
    }
  });

  it("문서는 후보별 담당 질문을 쓰고, 개인 체크리스트 문맥이 있을 때만 작성자 질문도 쓴다", async () => {
    const sent: unknown[] = [];
    const versions: string[] = [];
    const decide: Decide = async (request) => {
      sent.push(request.questions);
      return { model: "typesafe/jev-test", answers };
    };
    for (const writtenByMe of [true, false, null]) versions.push((await judgeCandidate(todo, { ...doc, writtenByMe }, identity, decide)).promptVersion);
    expect(sent).toEqual([WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS, DOCUMENT_JUDGE_QUESTIONS, DOCUMENT_JUDGE_QUESTIONS]);
    // judge_logs에서 어느 질문 묶음으로 물었는지 가를 수 있게 버전도 다르다.
    expect(versions).toEqual([WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION, DOCUMENT_JUDGE_PROMPT_VERSION, DOCUMENT_JUDGE_PROMPT_VERSION]);
    // 문서 소유 질문은 개인 체크리스트 여부를 따로 판정하고, 질문 전체에 작성자 메타데이터를 소유권으로 간주하지 말라고 명시한다.
    expect(WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS.document_owner).toEqual(DOCUMENT_JUDGE_QUESTIONS.document_owner);
    const changed = Object.keys(DOCUMENT_JUDGE_QUESTIONS).filter(
      (key) => JSON.stringify(DOCUMENT_JUDGE_QUESTIONS[key as keyof typeof DOCUMENT_JUDGE_QUESTIONS]) !== JSON.stringify(WRITTEN_BY_ME_DOCUMENT_JUDGE_QUESTIONS[key as keyof typeof DOCUMENT_JUDGE_QUESTIONS]),
    );
    expect(changed).toEqual(["is_my_commitment", "certainty"]);
    expect(JSON.stringify(JUDGE_QUESTIONS)).not.toContain("written_by_me");
  });

  it("비문서의 written_by_me 동작과 프롬프트 버전은 유지한다", async () => {
    const sent: unknown[] = [];
    const decide: Decide = async (request) => {
      sent.push(request.questions);
      return { model: "typesafe/jev-test", answers };
    };
    const note = { ...doc, kind: "note", writtenByMe: true };
    const result = await judgeCandidate(todo, note, identity, decide);
    expect(sent).toEqual([WRITTEN_BY_ME_QUESTIONS]);
    expect(result.promptVersion).toBe(WRITTEN_BY_ME_PROMPT_VERSION);
    expect(buildJudgeState(todo, note, identity).source).toHaveProperty("written_by_me", true);
    expect(judgePromptVersionForSource({ kind: "note", writtenByMe: true })).toBe(WRITTEN_BY_ME_PROMPT_VERSION);
  });
});

describe("judgeCandidate", () => {
  it("질문을 한 번에 묻고 판정을 돌려준다", async () => {
    const calls: unknown[] = [];
    const decide: Decide = async (request) => {
      calls.push(request);
      return { model: "typesafe/jev-test", answers, usage: { input_tokens: 10, cost: 0.00001 } };
    };
    const result = await judgeCandidate(candidate, source, { name: "나", aliases: [], emails: [] }, decide);
    expect(calls).toHaveLength(1);
    expect(result).toMatchObject({ decision: "auto", model: "typesafe/jev-test", cost: 0.00001 });
    expect(result.promptVersion).toBe(MEETING_JUDGE_PROMPT_VERSION);
    expect(calls[0]).toMatchObject({ questions: MEETING_JUDGE_QUESTIONS });
  });

  it("인용 줄의 화자 이름표를 결과에 넘기고, Jev의 화자 답은 바꾸지 않는다 (역할은 병합에서 정한다)", async () => {
    const decide: Decide = async () => ({
      model: "m",
      answers: { ...answers, speaker_role: { type: "choice", choice: "third_party", probabilities: { third_party: 0.6 } } },
    });
    const dm = {
      ...source,
      kind: "message",
      text: "[DM · 박지훈]\n박지훈: 경쟁사 가격표 건은 안 하셔도 돼요!\n송청혁: 넵",
      participants: { attendees: [{ name: "박지훈" }, { name: "송청혁" }] },
    };
    const cancel = { title: "경쟁사 가격표 정리", quote: "경쟁사 가격표 건은 안 하셔도 돼요", due_text: null, counterpart: "박지훈", signal: "cancellation" as const };
    const result = await judgeCandidate(cancel, dm, { name: "송청혁", aliases: [], emails: [] }, decide);
    expect(result.speaker).toBe("박지훈");
    expect(result.signals.speaker_role.choice).toBe("third_party");
    const unlabeled = await judgeCandidate(cancel, { ...dm, text: "경쟁사 가격표 건은 안 하셔도 돼요!" }, { name: "송청혁", aliases: [], emails: [] }, decide);
    expect(unlabeled.speaker).toBeUndefined();
  });

  it("동명이인 참석자와 겹치는 화자 이름은 자동 반영하지 않고 사용자 역할 확인으로 보낸다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const participants = { attendees: [{ name: "김도윤" }, { name: "박도윤" }] };
    const ambiguous = {
      ...source,
      text: "도윤님: 금요일까지 자료를 보내드릴게요",
      participants,
    };
    const result = await judgeCandidate(
      { title: "자료 전달", quote: "금요일까지 자료를 보내드릴게요", due_text: null, owner: "me", signal: "commitment" },
      ambiguous,
      identity,
      async () => ({ model: "m", answers }),
    );

    expect(result).toMatchObject({
      decision: "confirm",
      reasons: ["NOT_MY_ACTION"],
      rule: "identity_ambiguous",
      speaker: "도윤님",
      speakerAmbiguous: true,
      ownerAmbiguous: true,
      signals: { speaker_role: { choice: "me" } },
    });
  });

  it("알려진 요청자가 말했어도 동명이인에게 한 @요청은 담당만 확인한다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const participants = { attendees: [{ name: "김도윤" }, { name: "박도윤" }, { name: "박지훈" }] };
    const message = {
      ...source,
      text: "박지훈: @도윤 자료 부탁해요",
      participants,
    };
    const result = await judgeCandidate(
      { title: "자료 전달", quote: "자료 부탁해요", due_text: null, counterpart: "박지훈", owner: "me", signal: "commitment" },
      message,
      identity,
      async () => ({ model: "m", answers }),
    );

    expect(result).toMatchObject({
      decision: "confirm",
      reasons: ["NOT_MY_ACTION"],
      rule: "identity_ambiguous",
      speaker: "박지훈",
      ownerAmbiguous: true,
    });
    expect(result.speakerAmbiguous).toBeUndefined();
  });

  it("담당 추출이 unknown이어도 동명이인에게 보낸 비약속 변경은 확인하고 화자는 유지한다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const participants = { attendees: [{ name: "김도윤" }, { name: "박도윤" }, { name: "박지훈" }] };
    const message = {
      ...source,
      kind: "message",
      text: "박지훈: @도윤 이제 제안서는 안 보내셔도 돼요",
      participants,
    };
    const change = { title: "제안서 발송 취소", quote: "이제 제안서는 안 보내셔도 돼요", due_text: null, counterpart: "박지훈", owner: "unknown" as const, signal: "cancellation" as const };
    const result = await judgeCandidate(change, message, identity, async () => ({ model: "m", answers }));
    const rejected = await judgeCandidate(change, message, identity, async () => ({
      model: "m",
      answers: { ...answers, is_my_commitment: { type: "noul", noul: 0.2 } },
    }));

    expect(result).toMatchObject({
      decision: "confirm",
      reasons: ["NOT_MY_ACTION"],
      rule: "identity_ambiguous",
      speaker: "박지훈",
      ownerAmbiguous: true,
    });
    expect(result.speakerAmbiguous).toBeUndefined();
    expect(rejected).toMatchObject({ decision: "reject", speaker: "박지훈", ownerAmbiguous: true });
    expect(rejected.speakerAmbiguous).toBeUndefined();
  });

  it("동명이인 참석자와 겹치는 짧은 담당 이름만 확인하고 전체 이름은 그대로 판단한다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const participants = { attendees: [{ name: "김도윤" }, { name: "박도윤" }] };
    const decide: Decide = async () => ({ model: "m", answers });
    const short = await judgeCandidate(
      { title: "견적서 검토", quote: "- [ ] 담당: 도윤 — 금요일까지 견적서 검토", due_text: null, owner: "me", signal: "commitment" },
      { ...source, kind: "meeting", text: "회의 요약\n- [ ] 담당: 도윤 — 금요일까지 견적서 검토", participants },
      identity,
      decide,
    );
    const full = await judgeCandidate(
      { title: "프로젝트 일정표 발송", quote: "- [ ] 담당: 김도윤 — 목요일까지 프로젝트 일정표 발송", due_text: null, owner: "me", signal: "commitment" },
      { ...source, kind: "meeting", text: "회의 요약\n- [ ] 담당: 김도윤 — 목요일까지 프로젝트 일정표 발송", participants },
      identity,
      decide,
    );

    expect(short).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], ownerAmbiguous: true, rule: "identity_ambiguous" });
    expect(full).toMatchObject({ decision: "auto", reasons: [] });
    expect(full.ownerAmbiguous).toBeUndefined();

    const namedSpeaker = await judgeCandidate(
      { title: "자료 전달", quote: "도윤님에게 내가 보내드릴게요", due_text: null, owner: "me", signal: "commitment" },
      { ...source, kind: "meeting", text: "김도윤: 도윤님에게 내가 보내드릴게요", participants },
      identity,
      decide,
    );
    expect(namedSpeaker).toMatchObject({ decision: "auto", speaker: "김도윤" });
    expect(namedSpeaker.ownerAmbiguous).toBeUndefined();
  });

  it("짧은 인용은 같은 원문 줄의 담당 라벨만 보고 인접한 전체 이름 할 일은 자동 반영할 수 있다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const participants = { attendees: [{ name: "김도윤" }, { name: "박도윤" }] };
    const text = [
      "[Notion AI 요약 · 주간 운영 회의]",
      "- [ ] 담당: 도윤 — 금요일까지 견적서 검토",
      "- [ ] 담당: 김도윤 — 목요일까지 프로젝트 일정표 발송",
    ].join("\n");
    const meeting = { ...source, kind: "meeting", text, participants };
    const decide: Decide = async () => ({ model: "m", answers });

    const short = await judgeCandidate(
      { title: "견적서 검토", quote: "금요일까지 견적서 검토", due_text: null, owner: "me", signal: "commitment" },
      meeting,
      identity,
      decide,
    );
    const full = await judgeCandidate(
      { title: "프로젝트 일정표 발송", quote: "목요일까지 프로젝트 일정표 발송", due_text: null, owner: "me", signal: "commitment" },
      meeting,
      identity,
      decide,
    );

    expect(short).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], ownerAmbiguous: true, rule: "identity_ambiguous" });
    expect(full).toMatchObject({ decision: "auto", reasons: [] });
    expect(full.ownerAmbiguous).toBeUndefined();
  });

  it("회의 후보 구절이 다른 사람 또는 무담당으로 분류되면 새 약속을 기각한다", async () => {
    const meetingSource = { ...source, kind: "meeting", text: "# Weekly sync\n\n- [ ] Share the usability results\nMaya Chen: I'll share the usability results." };
    for (const meetingOwner of ["someone_else", "unassigned"] as const) {
      const result = await judgeCandidate(
        { title: "Share usability results", quote: "Share the usability results", due_text: null, signal: "commitment", owner: "me" },
        meetingSource,
        { name: "Alex Kim", aliases: ["Alex"], emails: [] },
        async () => ({
          model: "m",
          answers: { ...answers, meeting_owner: { type: "choice", choice: meetingOwner, probabilities: { [meetingOwner]: 0.95 } } },
        }),
      );
      expect(result).toMatchObject({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    }
  });

  it("회의의 다른 사람 약속은 후보 안에 사용자를 @멘션해도 그 멘션만으로 사용자 소유가 되지 않는다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: [] };
    const candidate = { title: "Send the report", quote: "@Alex, I will send the report by Friday.", due_text: "by Friday", signal: "commitment" as const, owner: "me" as const };
    for (const attendees of [
      [{ name: "Alex Kim" }, { name: "Maya Chen" }],
      [{ name: "Alex Jones" }, { name: "Maya Chen" }],
    ]) {
      const meetingSource = {
        ...source,
        kind: "meeting",
        text: "Maya Chen: @Alex, I will send the report by Friday.",
        participants: { attendees },
      };
      const result = await judgeCandidate(
        candidate,
        meetingSource,
        identity,
        async () => ({
          model: "m",
          answers: {
            ...answers,
            is_my_commitment: { type: "noul", noul: 0.3 },
            meeting_owner: { type: "choice", choice: "someone_else", probabilities: { someone_else: 0.95 } },
          },
        }),
      );

      expect(result).toMatchObject({ decision: "reject", reasons: ["NOT_MY_ACTION"], speaker: "Maya Chen" });
      expect(result.ownerAmbiguous).toBeUndefined();
    }
  });

  it("명시적인 사용자 할당은 확인할 수 있고 사용자의 첫인칭 화자 약속은 자동 판정까지 유지한다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: [] };
    const assignment = await judgeCandidate(
      { title: "Review the plan", quote: "Alex Kim, please review the plan by Friday", due_text: "by Friday", signal: "commitment" },
      { ...source, kind: "meeting", text: "Manager: Alex Kim, please review the plan by Friday" },
      identity,
      async () => ({
        model: "m",
        answers: { ...answers, is_my_commitment: { type: "noul", noul: 0.3 }, meeting_owner: { type: "choice", choice: "user", probabilities: { user: 0.9 } } },
      }),
    );
    expect(assignment).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], rule: "meeting_assignment" });

    const ownStatement = await judgeCandidate(
      { title: "Send the draft", quote: "I'll send the draft by Friday", due_text: "by Friday", signal: "commitment" },
      { ...source, kind: "meeting", text: "Alex Kim: I'll send the draft by Friday" },
      identity,
      async () => ({ model: "m", answers }),
    );
    expect(ownStatement).toMatchObject({ decision: "auto", speaker: "Alex Kim", signals: { meeting_owner: { choice: "user" } } });
  });

  it("명시적인 같은 이름의 담당 충돌은 무담당으로 잘못 기각하지 않고 확인에 남긴다", async () => {
    const identity = { name: "김도윤", aliases: [], emails: [] };
    const result = await judgeCandidate(
      { title: "Review estimate", quote: "담당: 도윤 — 금요일까지 견적서 검토", due_text: null, signal: "commitment" },
      { ...source, kind: "meeting", text: "- [ ] 담당: 도윤 — 금요일까지 견적서 검토", participants: { attendees: [{ name: "김도윤" }, { name: "박도윤" }] } },
      identity,
      async () => ({
        model: "m",
        answers: { ...answers, meeting_owner: { type: "choice", choice: "ambiguous", probabilities: { ambiguous: 0.95 } } },
      }),
    );
    expect(result).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], ownerAmbiguous: true, rule: "identity_ambiguous" });
  });

  it("문서 작성자가 사용자여도 다른 화자의 명시적 소유권은 멘션·참석자보다 우선한다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: [] };
    const result = await judgeCandidate(
      { title: "Send the report", quote: "@Alex, I will send the report by Friday", due_text: "by Friday", signal: "commitment", owner: "me" },
      {
        ...source,
        kind: "doc",
        text: "# Q3 notes\nMaya Chen: @Alex, I will send the report by Friday",
        participants: { attendees: [{ name: "Alex Kim" }, { name: "Maya Chen" }] },
        writtenByMe: true,
      },
      identity,
      async () => ({
        model: "m",
        answers: {
          ...answers,
          is_my_commitment: { type: "noul", noul: 0.3 },
          document_owner: { type: "choice", choice: "someone_else", probabilities: { someone_else: 0.95 } },
        },
      }),
    );

    expect(result).toMatchObject({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    expect(result.ownerAmbiguous).toBeUndefined();
    expect(result.promptVersion).toBe(WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION);
  });

  it("명시적 다른 담당은 화자 이름이 사용자 동명이인과 충돌해도 기각한다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@lumenfield.example"] };
    const participants = {
      attendees: [
        { name: "Alex Kim", email: "alex@lumenfield.example" },
        { name: "Alex Kim", email: "alex.other@example.test" },
        { name: "Maya Chen", email: "maya@example.test" },
      ],
    };
    for (const kind of ["meeting", "doc"] as const) {
      const result = await judgeCandidate(
        { title: "Send the report", quote: "Maya Chen will send the report tomorrow", due_text: "tomorrow", signal: "commitment", owner: "me" },
        {
          ...source,
          kind,
          text: "Alex Kim: Maya Chen will send the report tomorrow",
          participants,
          writtenByMe: kind === "doc" ? true : null,
        },
        identity,
        async () => ({
          model: "m",
          answers: {
            ...answers,
            ...(kind === "meeting"
              ? { meeting_owner: { type: "choice", choice: "someone_else", probabilities: { someone_else: 0.95 } } }
              : { document_owner: { type: "choice", choice: "someone_else", probabilities: { someone_else: 0.95 } } }),
          },
        }),
      );

      expect(result).toMatchObject({ decision: "reject", reasons: ["NOT_MY_ACTION"], speaker: "Alex Kim", speakerAmbiguous: true });
      expect(result.ownerAmbiguous).toBeUndefined();
    }
  });

  it("문서에서 사용자가 관련 인물로 명시됐지만 후보 담당이 무담당이면 자동화하지 않고 unknown 확인에 남긴다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: [] };
    const result = await judgeCandidate(
      { title: "Send the DPA", quote: "Send updated DPA draft by Monday", due_text: "by Monday", signal: "commitment", owner: "me" },
      {
        ...source,
        kind: "doc",
        text: "# Contract renewal notes\n\n- [ ] Send updated DPA draft by Monday",
        participants: { attendees: [{ name: "Alex Kim" }, { name: "Casey Nolan" }] },
        writtenByMe: true,
      },
      identity,
      async () => ({
        model: "m",
        answers: {
          ...answers,
          document_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } },
        },
      }),
    );

    expect(result).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], ownerAmbiguous: true });
    expect(result.decision).not.toBe("auto");
  });

  it("관련 인물만 있고 소유자가 무담당인 상태 변화 발언은 담당 확인을 새로 만들지 않는다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: [] };
    for (const kind of ["meeting", "doc"] as const) {
      const result = await judgeCandidate(
        { title: "Move the report deadline", quote: "The report deadline moved to Monday", due_text: null, signal: "update", owner: "unknown" },
        {
          ...source,
          kind,
          text: "Project update: The report deadline moved to Monday",
          participants: { attendees: [{ name: "Alex Kim" }, { name: "Casey Nolan" }] },
          writtenByMe: kind === "doc" ? true : null,
        },
        identity,
        async () => ({
          model: "m",
          answers: {
            ...answers,
            ...(kind === "meeting"
              ? { meeting_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } } }
              : { document_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } } }),
          },
        }),
      );

      expect(result.decision).toBe("auto");
      expect(result.ownerAmbiguous).toBeUndefined();
    }
  });

  it("사용자 별칭과 동명이인에 걸친 @이름 상태 변경은 회의·문서에서 계속 확인에 남긴다", async () => {
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@lumenfield.example"] };
    const participants = {
      attendees: [
        { name: "Alex Kim", email: "alex@lumenfield.example" },
        { name: "Alex", email: "alex.other@example.test" },
        { name: "Morgan Lee", email: "morgan@example.test" },
      ],
    };
    for (const kind of ["meeting", "doc"] as const) {
      const result = await judgeCandidate(
        { title: "Move the report deadline", quote: "@Alex, send the report by Monday instead", due_text: "by Monday", signal: "update", owner: "unknown" },
        {
          ...source,
          kind,
          text: "Morgan Lee: @Alex, send the report by Monday instead",
          participants,
          writtenByMe: kind === "doc" ? true : null,
        },
        identity,
        async () => ({
          model: "m",
          answers: {
            ...answers,
            ...(kind === "meeting"
              ? { meeting_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } } }
              : { document_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } } }),
          },
        }),
      );

      expect(result).toMatchObject({ decision: "confirm", ownerAmbiguous: true });
    }
  });

  it("인용 줄이 사용자를 @이름으로 부르면 확인 요청 규칙을 적용한다", async () => {
    const decide: Decide = async () => ({ model: "m", answers: { ...answers, is_my_commitment: { type: "noul", noul: 0.3 } } });
    const mention = { ...source, kind: "message", text: "[#sales · 스레드 중간부터]\n최유나: @윤지호 이거 금요일까지 될까요?" };
    const ask = { title: "최유나가 물은 건 처리", quote: "이거 금요일까지 될까요?", due_text: "금요일까지", signal: "commitment" as const };
    const identity = { name: "윤지호", aliases: [], emails: [] };
    expect((await judgeCandidate(ask, mention, identity, decide)).decision).toBe("confirm");
    const other = { ...mention, text: "최유나: @박지훈 이거 금요일까지 될까요?" };
    expect((await judgeCandidate(ask, other, identity, decide)).decision).toBe("reject");
    // 별칭이 이름만("Jiho")이어도 같은 이름으로 시작하는 다른 사람을 부른 요청은 기각 그대로
    const jiho = { name: "윤지호", aliases: ["Jiho"], emails: [] };
    const namesake = { ...mention, text: "최유나: @Jiho Park 이거 금요일까지 될까요?", participants: { attendees: [{ name: "최유나" }, { name: "Jiho Park" }] } };
    expect((await judgeCandidate(ask, namesake, jiho, decide)).decision).toBe("reject");
  });

  describe("사용자가 유일한 받는 사람인 메일 (E5, G12)", () => {
    // "내 약속 아님" 하나로만 기각될 확률(0.3)인 요청. 다른 답은 모두 자신 있다.
    const decide: Decide = async () => ({ model: "m", answers: { ...answers, is_my_commitment: { type: "noul", noul: 0.3 } } });
    const identity = { name: "가은", aliases: [], emails: ["gaeun@lumenfield.example"] };
    const ask = { title: "견적서 수정본 전달", quote: "견적서 수정본도 목요일까지 부탁드려도 될까요?", due_text: "목요일까지", signal: "commitment" as const };
    const me = { name: "가은", email: "gaeun@lumenfield.example" };
    const dohyun = { name: "차도현", email: "dohyun@saebyeok-logis.example" };
    const mail = {
      ...source,
      kind: "email",
      text: "제목: 미팅 내용 정리\n\n1. 창고 이전은 11월로 확정했습니다.\n\n아, 그리고 견적서 수정본도 목요일까지 부탁드려도 될까요?\n\n감사합니다.",
      participants: { from: dohyun, to: [me] },
    };

    it("기각 사유가 '내 약속 아님' 하나뿐이면 확인 요청까지 보낸다 (자동 반영은 아님)", async () => {
      const result = await judgeCandidate(ask, mail, identity, decide);
      expect(result).toMatchObject({ decision: "confirm", reasons: ["NOT_MY_ACTION"], rule: "sole_recipient_request" });
      // 다른 실행처럼 확률이 높으면 그냥 자동 반영이다 (규칙은 기각만 살린다)
      const sure = await judgeCandidate(ask, mail, identity, async () => ({ model: "m", answers }));
      expect(sure).toMatchObject({ decision: "auto", reasons: [] });
      expect(sure.rule).toBeUndefined();
    });

    it("받는 사람이 여럿이거나 참조로만 받았거나 내가 보낸 메일이거나 메일이 아니면 기각 그대로", async () => {
      const cases = {
        여럿: { ...mail, participants: { from: dohyun, to: [me, { name: "박서연", email: "s@x.example" }] } },
        참조: { ...mail, participants: { from: dohyun, to: [{ name: "박서연", email: "s@x.example" }], cc: [me] } },
        보낸사람: { ...mail, participants: { from: me, to: [dohyun] } },
        회의외문서: { ...mail, kind: "doc" },
        관련자없음: { ...mail, participants: undefined },
      };
      for (const [label, source] of Object.entries(cases)) {
        const notAssignedInDocument: Decide = async () => ({
          model: "m",
          answers: { ...answers, document_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } } },
        });
        const decideCase = label === "회의외문서" ? notAssignedInDocument : decide;
        expect((await judgeCandidate(ask, source, identity, decideCase)).decision, label).toBe("reject");
      }
    });

    it("다른 기각 사유가 함께 있으면(이미 했음 · 할 일 아님 · 약속 없음) 기각 그대로", async () => {
      const extras: JevDecision["answers"][] = [{ already_done: { type: "noul", noul: 0.9 } }, { is_actionable: { type: "noul", noul: 0.2 } }];
      for (const extra of extras) {
        const both: Decide = async () => ({ model: "m", answers: { ...answers, is_my_commitment: { type: "noul", noul: 0.3 }, ...extra } });
        expect((await judgeCandidate(ask, mail, identity, both)).decision).toBe("reject");
      }
    });

    it("@이름으로 부른 요청이면 규칙 이름은 addressed_request 그대로", async () => {
      const mentioned = { ...mail, text: `${mail.text}\n@가은 확인 부탁드려요` };
      const result = await judgeCandidate({ ...ask, quote: "@가은 확인 부탁드려요" }, mentioned, identity, decide);
      expect(result).toMatchObject({ decision: "confirm", rule: "addressed_request" });
    });
  });
});

describe("decideOutcome — 유일한 받는 사람 메일 규칙", () => {
  const pending = { ...firm, is_my_commitment: 0.3 };

  it("'내 약속 아님' 하나뿐인 기각만 확인 요청으로 살리고, 임계값이 뒤집혀도 자동 반영하지 않는다", () => {
    expect(decideOutcome(pending)).toEqual({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome(pending, undefined, { soleRecipient: true })).toEqual({ decision: "confirm", reasons: ["NOT_MY_ACTION"], rule: "sole_recipient_request" });
    expect(decideOutcome({ ...pending, is_actionable: 0.2 }, undefined, { soleRecipient: true }).decision).toBe("reject");
    expect(decideOutcome({ ...pending, certainty: { choice: "none", probabilities: {} } }, undefined, { soleRecipient: true }).decision).toBe("reject");
    expect(decideOutcome({ ...firm, is_my_commitment: 0.6 }, undefined, { soleRecipient: true })).toEqual({ decision: "confirm", reasons: ["NOT_MY_ACTION"] });
    const inverted = { accept: 0.3, reject: 0.5, doneAcceptBelow: 0.3, doneRejectAt: 0.7 };
    expect(decideOutcome({ ...firm, is_my_commitment: 0.4 }, inverted, { soleRecipient: true }).decision).toBe("confirm");
  });

  it("내 약속 확률이 너무 낮은 후보(남의 일을 추출한 것)는 살리지 않는다. 경계는 SOLE_RECIPIENT_MIN_MINE, @이름 규칙에는 하한이 없다", () => {
    expect(SOLE_RECIPIENT_MIN_MINE).toBe(0.2);
    expect(decideOutcome({ ...firm, is_my_commitment: 0.19 }, undefined, { soleRecipient: true })).toEqual({ decision: "reject", reasons: ["NOT_MY_ACTION"] });
    expect(decideOutcome({ ...firm, is_my_commitment: 0.2 }, undefined, { soleRecipient: true })).toMatchObject({ decision: "confirm", rule: "sole_recipient_request" });
    expect(decideOutcome({ ...firm, is_my_commitment: 0.05 }, undefined, { addressedToUser: true })).toMatchObject({ decision: "confirm", rule: "addressed_request" });
  });

  it("둘 다 해당하면 @이름 규칙으로 기록한다", () => {
    expect(decideOutcome(pending, undefined, { soleRecipient: true, addressedToUser: true }).rule).toBe("addressed_request");
  });
});

describe("buildJudgeState의 사용자 정보", () => {
  it("메일에서의 위치와 받아쓰기 오타 후보를 넣고 이메일 주소는 넣지 않는다", () => {
    const state = buildJudgeState(
      { title: "UX 기획", quote: "도연님 - UX 기획 진행", due_text: null },
      { ...source, text: "- [ ] 도연님 - UX 기획 진행", participants: { from: { email: "boss@x.com" }, cc: [{ email: "d@x.com" }] } },
      { name: "도윤", aliases: [], emails: ["d@x.com"] },
    );
    expect(state.user).toEqual({ name: "도윤", aliases: [], position: "cc_only", possibly_misspelled_as: ["도연"] });
    expect(JSON.stringify(state)).not.toContain("d@x.com");
  });

  it("회의 사람 이름은 명시하되 이메일은 제외하고 출석·문서 작성으로 Action 담당을 추정하지 않게 한다", () => {
    const state = buildJudgeState(
      { title: "Share results", quote: "Share results", due_text: null, signal: "commitment" },
      {
        ...source,
        kind: "meeting",
        participants: { attendees: [{ name: "Maya Chen", email: "maya@example.test" }] },
        writtenByMe: true,
      },
      { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@example.test"] },
    );
    expect(state.source).toMatchObject({ related_people: ["Maya Chen"] });
    expect(state.source).not.toHaveProperty("written_by_me");
    expect(JSON.stringify(state)).not.toContain("@example.test");
  });
});
