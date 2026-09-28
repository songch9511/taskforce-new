import { describe, expect, it } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";
import { JUDGE_PROMPT_VERSION, JUDGE_QUESTIONS, WRITTEN_BY_ME_PROMPT_VERSION, WRITTEN_BY_ME_QUESTIONS } from "@/lib/ai/prompts/judge";

import { buildJudgeState, decideOutcome, judgeCandidate, parseJudgeAnswers, type Decide, type JudgeSignals } from "./judge";

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
};

const source = {
  text: ["김대표: 제안서 보고 싶어요.", "나: 네, 금요일까지 제안서 보내드릴게요.", "김대표: 좋아요."].join("\n"),
  kind: "meeting",
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
};
const candidate = { title: "제안서 발송", quote: "금요일까지 제안서 보내드릴게요", due_text: "금요일까지" };

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
  it("추출기의 추론 없이 후보와 인용 주변 원문만 넣는다", () => {
    const state = buildJudgeState(candidate, source, { name: "나", aliases: ["Me"], emails: ["me@x.com"] });
    expect(state).toEqual({
      user: { name: "나", aliases: ["Me"], position: "unknown" },
      candidate,
      context: source.text,
      source: { kind: "meeting", occurred_at: "2025-09-22" },
    });
  });
});

describe("buildJudgeState의 작성자", () => {
  const identity = { name: "나", aliases: [], emails: [] };
  const doc = { text: "## 다음 단계\n- 도메인 연결 설정 바꾸기", kind: "doc", occurredAt: new Date("2026-10-12T21:00:00+09:00") };
  const todo = { title: "도메인 연결 설정 변경", quote: "도메인 연결 설정 바꾸기", due_text: null };

  it("사용자가 직접 쓴 원문이면 source.written_by_me를 넘긴다", () => {
    expect(buildJudgeState(todo, { ...doc, writtenByMe: true }, identity).source).toEqual({
      kind: "doc",
      occurred_at: "2026-10-12",
      written_by_me: true,
    });
  });

  it("다른 사람이 썼거나(false) 모르면(null · 없음) 넘기지 않는다", () => {
    for (const writtenByMe of [false, null, undefined]) {
      expect(buildJudgeState(todo, { ...doc, writtenByMe }, identity).source).toEqual({ kind: "doc", occurred_at: "2026-10-12" });
    }
  });

  it("사용자가 쓴 문서만 그에 맞춘 질문으로 묻고, 작성자를 모르면 전과 같은 질문을 보낸다", async () => {
    const sent: unknown[] = [];
    const versions: string[] = [];
    const decide: Decide = async (request) => {
      sent.push(request.questions);
      return { model: "typesafe/jev-test", answers };
    };
    for (const writtenByMe of [true, false, null]) versions.push((await judgeCandidate(todo, { ...doc, writtenByMe }, identity, decide)).promptVersion);
    expect(sent).toEqual([WRITTEN_BY_ME_QUESTIONS, JUDGE_QUESTIONS, JUDGE_QUESTIONS]);
    // judge_logs에서 어느 질문 묶음으로 물었는지 가를 수 있게 버전도 다르다.
    expect(versions).toEqual([WRITTEN_BY_ME_PROMPT_VERSION, JUDGE_PROMPT_VERSION, JUDGE_PROMPT_VERSION]);
    expect(WRITTEN_BY_ME_PROMPT_VERSION).toBe(`${JUDGE_PROMPT_VERSION}-self`);
    // 다른 것은 두 질문뿐이고, 공통 질문에는 작성자 조건이 없다.
    const changed = Object.keys(JUDGE_QUESTIONS).filter(
      (key) => JSON.stringify(JUDGE_QUESTIONS[key as keyof typeof JUDGE_QUESTIONS]) !== JSON.stringify(WRITTEN_BY_ME_QUESTIONS[key as keyof typeof JUDGE_QUESTIONS]),
    );
    expect(changed).toEqual(["is_my_commitment", "certainty"]);
    expect(JSON.stringify(JUDGE_QUESTIONS)).not.toContain("written_by_me");
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
    expect(result).toMatchObject({ decision: "auto", model: "typesafe/jev-test", cost: 0.00001, promptVersion: expect.stringMatching(/^judge-v\d+$/) });
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
});
