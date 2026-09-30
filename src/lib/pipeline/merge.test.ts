import { describe, expect, it } from "vitest";

import { projectAction } from "@/lib/actions/project";
import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";

import type { ActionCandidate } from "./extract";
import type { Decide, JudgeResult, JudgeSignals } from "./judge";
import { decideMatch, shortlistActions, type OpenAction } from "./match";
import {
  candidateClaims,
  InMemoryActionStore,
  isUserFirmCommitment,
  mergeJudged,
  settlingCommitment,
  withoutJudgeReasons,
  withSpeakerFromLabel,
  type MergeDeps,
  type MergeSource,
} from "./merge";
import { resolveAction } from "./resolve";
import type { JudgedCandidate } from "./run";
import type { VerifiedCandidate } from "./verify";

const identity = { name: "나", aliases: [], emails: [] };

// 주제별로 고정된 벡터: 같은 주제면 코사인 1
const TOPICS = ["제안서", "견적서", "회의록"];
const topicVector = (text: string) => {
  const v = new Array(EMBEDDING_DIMENSIONS).fill(0);
  v[Math.max(0, TOPICS.findIndex((t) => text.includes(t)))] = 1;
  return v;
};

function signals(over: Partial<{ speaker: "me" | "counterpart" | "third_party"; firm: boolean; audience: "shared" | "private" }> = {}): JudgeSignals {
  return {
    is_my_commitment: 0.9,
    is_actionable: 0.9,
    already_done: 0.1,
    certainty: { choice: over.firm === false ? "tentative" : "firm", probabilities: {} },
    statement_certainty: { choice: over.firm === false ? "tentative" : "firm", probabilities: {} },
    speaker_role: { choice: over.speaker ?? "me", probabilities: {} },
    directness: { choice: "first_hand", probabilities: {} },
    audience: { choice: over.audience ?? "shared", probabilities: {} },
  };
}

function judged(
  candidate: Partial<ActionCandidate> & Pick<ActionCandidate, "quote" | "signal">,
  sig: JudgeSignals = signals(),
  decision: JudgeResult["decision"] = "auto",
): JudgedCandidate {
  const c: VerifiedCandidate = {
    title: candidate.quote,
    owner: "me",
    owner_confidence: 0.9,
    counterpart: "김대표",
    due_text: null,
    due: null,
    due_confidence: null,
    rationale: "",
    due_check: "none",
    model_due: null,
    ...candidate,
  };
  return { candidate: c, judge: { decision, reasons: [], signals: sig, promptVersion: "judge-test", model: "m" } };
}

/** 같은 주제의 기존 Action이 있으면 후보의 signal대로 관계를 답하는 가짜 Jev */
const decide: Decide = async (request) => {
  const state = request.state as { candidate: { quote: string }; existing: { key: string; task: string }[] };
  const topic = TOPICS.find((t) => state.candidate.quote.includes(t));
  const target = state.existing.find((e) => topic && e.task.includes(topic));
  const quote = state.candidate.quote;
  const relation = !target
    ? "new"
    : /보내드렸|받았/.test(quote)
      ? "same_done"
      : /월요일|괜찮|될 듯/.test(quote)
        ? "same_changed"
        : "same_restated";
  return {
    model: "jev-test",
    answers: {
      relation: { type: "choice", choice: relation, probabilities: { [relation]: 0.9 } },
      target: { type: "choice", choice: target?.key ?? "none", probabilities: { [target?.key ?? "none"]: 0.9 } },
    },
  };
};

function deps(): MergeDeps {
  let n = 0;
  return { embed: async (texts) => texts.map(topicVector), decide, newId: () => `c${++n}` };
}

const source = (id: string, kind: MergeSource["kind"], iso: string): MergeSource => ({ id, kind, text: "", occurredAt: new Date(iso) });

describe("mergeJudged — 핵심 시나리오 (PRD 2장: 금요일 → 월요일)", () => {
  it("세 원문이 한 Action으로 합쳐지고 기한은 요청자의 연장으로 월요일이 된다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();

    await mergeJudged(
      store,
      [judged({ signal: "commitment", title: "김대표에게 제안서 발송", quote: "금요일까지 제안서 보내드릴게요", due: "2025-09-26" })],
      source("meeting", "meeting", "2025-09-22T10:00:00+09:00"),
      identity,
      d,
    );
    await mergeJudged(
      store,
      [judged({ signal: "update", title: "제안서 발송", quote: "제안서 월요일에 보내도 될 듯", due: "2025-09-29" }, signals({ firm: false, audience: "private" }))],
      source("note", "note", "2025-09-23T21:00:00+09:00"),
      identity,
      d,
    );
    const afterNote = resolveAction(store.all()[0].claims);
    expect(afterNote.due.value).toBe("2025-09-26");
    expect(afterNote.due.risks.map((r) => r.kind)).toContain("tentative_change");

    const outcomes = await mergeJudged(
      store,
      [judged({ signal: "update", title: "제안서 발송", quote: "제안서는 월요일에 받아도 괜찮아요", due: "2025-09-29" }, signals({ speaker: "counterpart" }))],
      source("slack", "message", "2025-09-24T14:30:00+09:00"),
      identity,
      d,
    );

    expect(outcomes[0]).toMatchObject({ relation: "update", actionId: "a1" });
    expect(store.all()).toHaveLength(1);
    const state = resolveAction(store.all()[0].claims);
    expect(state.due).toMatchObject({ value: "2025-09-29", rules: [0, 4] });
    expect(state.status.value).toBe("open");
    expect(store.all()[0].evidence.map((e) => e.sourceId)).toEqual(["meeting", "note", "slack"]);
  });
});

describe("mergeJudged", () => {
  it("완료 보고는 기존 Action을 끝내고, 다른 주제는 새 Action이 된다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    await mergeJudged(store, [judged({ signal: "commitment", quote: "금요일까지 제안서 보내드릴게요", due: "2025-09-26" })], source("s1", "meeting", "2025-09-22T10:00:00+09:00"), identity, d);
    await mergeJudged(
      store,
      [
        judged({ signal: "completion", quote: "제안서 보내드렸습니다" }, signals(), "reject"),
        judged({ signal: "commitment", quote: "견적서는 다음 주에 드릴게요" }),
      ],
      source("s2", "email", "2025-09-25T10:00:00+09:00"),
      identity,
      d,
    );
    expect(store.all().map((a) => [a.title, resolveAction(a.claims).status.value])).toEqual([
      ["금요일까지 제안서 보내드릴게요", "done"],
      ["견적서는 다음 주에 드릴게요", "open"],
    ]);
  });

  it("Jev가 기각한 새 약속은 넣지 않고, 이어질 곳 없는 변화 발언도 버린다", async () => {
    const store = new InMemoryActionStore();
    const outcomes = await mergeJudged(
      store,
      [judged({ signal: "commitment", quote: "견적서는 박팀장이 드릴게요" }, signals(), "reject"), judged({ signal: "completion", quote: "회의록 보내드렸습니다" })],
      source("s1", "email", "2025-09-25T10:00:00+09:00"),
      identity,
      deps(),
    );
    expect(outcomes.map((o) => o.relation)).toEqual(["rejected", "unmatched"]);
    expect(store.all()).toEqual([]);
  });

  it("같은 약속을 다시 말하면 새로 만들지 않고 근거만 더한다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    await mergeJudged(store, [judged({ signal: "commitment", quote: "금요일까지 제안서 보내드릴게요", due: "2025-09-26" })], source("s1", "meeting", "2025-09-22T10:00:00+09:00"), identity, d);
    await mergeJudged(store, [judged({ signal: "commitment", quote: "네 제안서 금요일까지 드릴게요", due: "2025-09-26" })], source("s2", "message", "2025-09-23T10:00:00+09:00"), identity, d);
    expect(store.all()).toHaveLength(1);
    expect(store.all()[0].evidence.map((e) => e.role)).toEqual(["created", "duplicate"]);
  });

  it("확인이 필요한 새 약속과 담당이 불확실한 약속은 이유를 남긴다", async () => {
    const store = new InMemoryActionStore();
    await mergeJudged(
      store,
      [judged({ signal: "commitment", quote: "제안서는 저희 쪽에서 드릴게요", owner: "unknown" }, signals(), "confirm")],
      source("s1", "meeting", "2025-09-22T10:00:00+09:00"),
      identity,
      deps(),
    );
    // 저장하는 것은 판정 단계의 이유뿐이다. 담당 확인은 Claim에서 다시 계산한다 (DB 저장소와 같게)
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: "]);
    expect(projectAction(store.all()[0].title, store.all()[0].claims, store.all()[0].confirmReasons).confirm_reasons).toEqual(["판정 확인: ", "담당 확인"]);
  });
});

describe("matching", () => {
  const action = (id: string, x: number): OpenAction => {
    const v = new Array(EMBEDDING_DIMENSIONS).fill(0);
    v[0] = x;
    v[1] = 1 - x;
    return { id, title: id, counterpart: null, due: null, latestQuote: null, embedding: v };
  };

  it("비슷한 순으로 최대 5개, 너무 다른 것은 뺀다", () => {
    const q = new Array(EMBEDDING_DIMENSIONS).fill(0);
    q[0] = 1;
    const list = [action("far", 0), action("near", 1), action("mid", 0.7), ...["a", "b", "c", "d"].map((id) => action(id, 0.9))];
    const result = shortlistActions(q, list).map((a) => a.id);
    expect(result[0]).toBe("near");
    expect(result).toHaveLength(5);
    expect(result).not.toContain("far");
  });

  it("확신이 낮은 병합은 확인을 받고, 대상이 없으면 새 약속으로 본다", () => {
    const shortlist = [action("x", 1)];
    const low = decideMatch(
      {
        relation: { type: "choice", choice: "same_changed", probabilities: { same_changed: 0.55 } },
        target: { type: "choice", choice: "t1", probabilities: { t1: 0.9 } },
      },
      shortlist,
      "update",
    );
    expect(low).toMatchObject({ relation: "update", actionId: "x", needsConfirmation: true });

    const none = decideMatch(
      { relation: { type: "choice", choice: "same_restated", probabilities: {} }, target: { type: "choice", choice: "none", probabilities: {} } },
      shortlist,
      "commitment",
    );
    expect(none.relation).toBe("new");
  });
});

describe("withSpeakerFromLabel — 이름표와 요청자로 화자 역할 정하기", () => {
  const me = { name: "윤지호", aliases: [], emails: [] };
  const reported: JudgeSignals = { ...signals({ speaker: "third_party" }), directness: { choice: "reported", probabilities: {} } };

  it("요청자 본인의 취소면 counterpart · 직접 발언 (이유로 남의 말을 붙여도)", () => {
    const out = withSpeakerFromLabel(reported, "박지훈", "박지훈", me, "cancellation");
    expect(out.speaker_role.choice).toBe("counterpart");
    expect(out.directness.choice).toBe("first_hand");
  });

  it("요청자 본인의 연장 · 변경은 counterpart지만 전언 여부는 Jev 답 그대로 (윗사람의 결정을 전할 수 있다)", () => {
    const out = withSpeakerFromLabel(reported, "박지훈", "박지훈", me, "update");
    expect(out.speaker_role.choice).toBe("counterpart");
    expect(out.directness.choice).toBe("reported");
  });

  it("요청자가 아닌 사람의 말이면 third_party, 전언 여부는 Jev 답 그대로", () => {
    const out = withSpeakerFromLabel({ ...reported, speaker_role: { choice: "counterpart", probabilities: {} } }, "서하린", "남궁현", me);
    expect(out.speaker_role.choice).toBe("third_party");
    expect(out.directness.choice).toBe("reported");
  });

  it("사용자 본인의 줄이면 me, 이름표나 요청자를 모르면 Jev 답 그대로", () => {
    expect(withSpeakerFromLabel(reported, "윤지호", "박지훈", me).speaker_role.choice).toBe("me");
    expect(withSpeakerFromLabel(reported, undefined, "박지훈", me)).toBe(reported);
    expect(withSpeakerFromLabel(reported, "박지훈", null, me)).toBe(reported);
  });
});

describe("mergeJudged — 요청자 이름표로 취소 · 연장 권한 가리기", () => {
  const me = { name: "윤지호", aliases: [], emails: [] };
  const at = (day: number) => new Date(`2026-10-0${day}T10:00:00+09:00`);
  // 기존 Action이 있으면 취소로 답하는 가짜 매칭 Jev
  const cancelDecide: Decide = async (request) => {
    const existing = (request.state as { existing: { key: string }[] }).existing;
    const [relation, target] = existing.length > 0 ? ["same_cancelled", existing[0].key] : ["new", "none"];
    return {
      model: "jev-test",
      answers: {
        relation: { type: "choice", choice: relation, probabilities: { [relation]: 0.95 } },
        target: { type: "choice", choice: target, probabilities: { [target]: 0.95 } },
      },
    };
  };
  const deps = (): MergeDeps => {
    let n = 0;
    return { embed: async (texts) => texts.map(topicVector), decide: cancelDecide, newId: () => `c${++n}` };
  };

  it("요청자가 직접 취소하면 이유가 전언이어도 dropped, 다른 사람이 전하면 그대로 open", async () => {
    for (const [speaker, expected] of [["박지훈", "dropped"], ["서하린", "open"]] as const) {
      const store = new InMemoryActionStore();
      const d = deps();
      await mergeJudged(store, [judged({ quote: "금요일까지 제안서 보내드릴게요", signal: "commitment", counterpart: "박지훈", due: "2026-10-09" })],
        { id: "s1", text: "윤지호: 금요일까지 제안서 보내드릴게요", kind: "message", occurredAt: at(5) }, me,
        d);
      const cancel: JudgedCandidate = {
        ...judged({ quote: "제안서는 안 하셔도 돼요", signal: "cancellation" }, { ...signals({ speaker: "third_party" }), directness: { choice: "reported", probabilities: {} } }, "reject"),
      };
      cancel.judge.speaker = speaker;
      await mergeJudged(store, [cancel], { id: "s2", text: `${speaker}: 제안서는 안 하셔도 돼요! 대표님이 이미 받으셨대요`, kind: "message", occurredAt: at(7) }, me, d);
      expect(resolveAction(store.all()[0].claims).status.value, speaker).toBe(expected);
    }
  });
});

describe("mergeJudged — 사용자의 확정 약속이 붙으면 남은 확인이 풀린다 (E3 · E4, 규칙 0 '양쪽이 말했는가')", () => {
  const me = { name: "나", aliases: [], emails: [] };
  const requestSignals: JudgeSignals = { ...signals({ speaker: "counterpart", firm: false }), is_my_commitment: 0.6 };
  const withReasons = (j: JudgedCandidate, reasons: JudgeResult["reasons"]): JudgedCandidate => ({ ...j, judge: { ...j.judge, reasons } });
  /** 요청 메일: 요청자의 추정 발언, Jev가 "내 약속 아님" 의심으로 확인 요청에 보낸 새 약속 */
  const request = () =>
    withReasons(
      judged({ signal: "commitment", title: "김대표에게 제안서 공유", quote: "제안서 금요일까지 보내주실 수 있을까요?", due: "2025-09-26" }, requestSignals, "confirm"),
      ["NOT_MY_ACTION"],
    );
  const requestStore = async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    await mergeJudged(store, [request()], source("s1", "email", "2025-09-22T10:00:00+09:00"), me, d);
    return { store, d };
  };
  const reasons = (store: InMemoryActionStore) => projectAction(store.all()[0].title, store.all()[0].claims, store.all()[0].confirmReasons).confirm_reasons;
  const accept = (over: Parameters<typeof signals>[0] = {}) =>
    judged({ signal: "commitment", title: "제안서 발송", quote: "네 제안서 금요일까지 드릴게요", due: "2025-09-26" }, signals(over));

  it("요청 메일만 있으면 판정 · 기한 · 내용 · 담당 · 상태 확인이 모두 남는다 (기준)", async () => {
    const { store } = await requestStore();
    expect(reasons(store)).toEqual(["판정 확인: NOT_MY_ACTION", "기한 확인", "내용 확인", "담당 확인", "상태 확인"]);
  });

  it("사용자의 수락 답장이 붙으면 내용 · 담당 · 상태 Claim이 더해지고 판정 확인이 풀려 확인 요청이 사라진다", async () => {
    const { store, d } = await requestStore();
    const outcomes = await mergeJudged(store, [accept()], source("s2", "email", "2025-09-22T12:00:00+09:00"), me, d);
    expect(outcomes[0]).toMatchObject({ relation: "duplicate", actionId: "a1" });
    expect(reasons(store)).toEqual([]);
    const action = store.all()[0];
    // 요청 메일이 만든 세 Claim 뒤에, 수락 답장이 더한 Claim (기한 말고)
    expect(action.claims.filter((c) => c.field !== "due").slice(3).map((c) => [c.field, c.value, c.speakerRole, c.certainty])).toEqual([
      ["scope", "김대표에게 제안서 공유", "me", "firm"],
      ["owner", "me", "me", "firm"],
      ["status", "open", "me", "firm"],
    ]);
    // 값은 그대로다: 제목을 바꾸지 않고, 기한은 같은 날
    const state = resolveAction(action.claims);
    expect([state.scope.value, state.owner.value, state.status.value, state.due.value]).toEqual(["김대표에게 제안서 공유", "me", "open", "2025-09-26"]);
    expect(action.evidence.map((e) => e.role)).toEqual(["created", "duplicate"]);
  });

  it("계산되는 이유(담당 확인 등)는 저장하지 않고 Claim으로 다시 정해진다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    const unowned = withReasons(judged({ signal: "commitment", title: "제안서 공유", quote: "제안서는 저희 쪽에서 드릴게요", owner: "unknown" }, requestSignals, "confirm"), ["NOT_MY_ACTION"]);
    await mergeJudged(store, [unowned], source("s1", "email", "2025-09-22T10:00:00+09:00"), me, d);
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: NOT_MY_ACTION"]);
    expect(reasons(store)).toContain("담당 확인");
    await mergeJudged(store, [accept()], source("s2", "email", "2025-09-22T12:00:00+09:00"), me, d);
    // 사용자가 내가 하겠다고 확정했으니 담당도 정해진다
    expect(store.all()[0].confirmReasons).toEqual([]);
    expect(reasons(store)).toEqual([]);
  });

  it("사용자의 발언이라도 확정적이지 않거나(추정) 요청자의 발언이면 풀지 않는다", async () => {
    for (const over of [{ firm: false }, { speaker: "counterpart" as const }]) {
      const { store, d } = await requestStore();
      await mergeJudged(store, [accept(over)], source("s2", "email", "2025-09-22T12:00:00+09:00"), me, d);
      expect(store.all()[0].confirmReasons, JSON.stringify(over)).toEqual(["판정 확인: NOT_MY_ACTION"]);
      expect(reasons(store), JSON.stringify(over)).toContain("내용 확인");
    }
  });

  it("같은 일이라는 확신이 0.6~0.8이면 붙이기만 하고(병합 확인 없음) 확인은 풀지 않는다. 더하는 Claim도 기한뿐이다", async () => {
    const { store } = await requestStore();
    const fairly: Decide = async (req) => {
      const key = (req.state as { existing: { key: string }[] }).existing[0].key;
      return {
        model: "jev-test",
        answers: {
          relation: { type: "choice", choice: "same_restated", probabilities: { same_restated: 0.7 } },
          target: { type: "choice", choice: key, probabilities: { [key]: 0.9 } },
        },
      };
    };
    let n = 0;
    await mergeJudged(store, [accept()], source("s2", "email", "2025-09-22T12:00:00+09:00"), me, { embed: async (t) => t.map(topicVector), decide: fairly, newId: () => `x${++n}` });
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: NOT_MY_ACTION"]);
    expect(store.all()[0].claims.filter((c) => c.id.startsWith("x")).map((c) => c.field)).toEqual(["due"]);
    expect(store.all()[0].evidence.map((e) => e.role)).toEqual(["created", "duplicate"]);
  });

  it("병합이 애매하면(같은 일이라는 확신이 낮으면) 풀지 않고 병합 확인을 더한다. 더하는 Claim도 기한뿐이다", async () => {
    const { store } = await requestStore();
    const unsure: Decide = async (req) => {
      const key = (req.state as { existing: { key: string }[] }).existing[0].key;
      return {
        model: "jev-test",
        answers: {
          relation: { type: "choice", choice: "same_restated", probabilities: { same_restated: 0.5 } },
          target: { type: "choice", choice: key, probabilities: { [key]: 0.9 } },
        },
      };
    };
    let n = 0;
    await mergeJudged(store, [accept()], source("s2", "email", "2025-09-22T12:00:00+09:00"), me, { embed: async (t) => t.map(topicVector), decide: unsure, newId: () => `x${++n}` });
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: NOT_MY_ACTION", "병합 확인 (50%)"]);
    expect(store.all()[0].claims.filter((c) => c.id.startsWith("x")).map((c) => c.field)).toEqual(["due"]);
  });

  it("E4: Notion 요약의 담당 없는 액션 아이템이 만든 판정 확인이 같은 회의 Meet 전사의 내 약속으로 풀린다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    const item = withReasons(
      judged({ signal: "commitment", title: "제안서 수정본 발송", quote: "제안서 수정본 발송 (금요일)", due: "2025-09-26" }, { ...signals({ speaker: "third_party", firm: false }), is_my_commitment: 0.5 }, "confirm"),
      ["NOT_MY_ACTION"],
    );
    await mergeJudged(store, [item], source("notion", "meeting", "2025-09-22T10:00:00+09:00"), me, d);
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: NOT_MY_ACTION"]);
    await mergeJudged(store, [accept()], source("meet", "meeting", "2025-09-22T10:00:40+09:00"), me, d);
    expect(reasons(store)).toEqual([]);
  });

  it("먼저 확정 약속이 있던 Action에 내 약속을 다시 말해도 내용 확인이 새로 생기지 않고 제목은 그대로다", async () => {
    const store = new InMemoryActionStore();
    const d = deps();
    await mergeJudged(store, [judged({ signal: "commitment", title: "김대표에게 제안서 발송", quote: "금요일까지 제안서 보내드릴게요", due: "2025-09-26" })], source("s1", "meeting", "2025-09-22T10:00:00+09:00"), me, d);
    await mergeJudged(store, [accept()], source("s2", "message", "2025-09-23T10:00:00+09:00"), me, d);
    expect(reasons(store)).toEqual([]);
    expect(projectAction("x", store.all()[0].claims).title).toBe("김대표에게 제안서 발송");
  });

  it("같은 일의 반복 · 변경이 아닌 관계(완료 등)는 이 규칙을 타지 않는다", async () => {
    const { store, d } = await requestStore();
    await mergeJudged(store, [judged({ signal: "completion", quote: "제안서 보내드렸습니다" })], source("s2", "email", "2025-09-25T10:00:00+09:00"), me, d);
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: NOT_MY_ACTION"]);
  });
});

describe("settlingCommitment · candidateClaims", () => {
  const target: OpenAction = { id: "a1", title: "제안서 발송", counterpart: "김대표", due: null, latestQuote: null, embedding: null, owner: "me" };
  const candidate = (over: Partial<VerifiedCandidate> = {}) => judged({ signal: "commitment", quote: "네 제안서 드릴게요", due: "2025-09-26", ...over }).candidate;
  const match = (over: { relation?: "duplicate" | "update" | "new" | "complete"; needsConfirmation?: boolean; confidence?: number } = {}) => ({
    relation: "duplicate" as const,
    needsConfirmation: false,
    confidence: 0.9,
    ...over,
  });
  let n = 0;
  const newId = () => `c${++n}`;
  const src: MergeSource = { id: "s", text: "", kind: "email", occurredAt: new Date("2025-09-22T10:00:00+09:00") };

  it("나 · 확정 · 직접 발언일 때만 사용자의 확정 약속이다", () => {
    expect(isUserFirmCommitment(signals())).toBe(true);
    expect(isUserFirmCommitment(signals({ firm: false }))).toBe(false);
    expect(isUserFirmCommitment(signals({ speaker: "counterpart" }))).toBe(false);
    expect(isUserFirmCommitment({ ...signals(), directness: { choice: "reported", probabilities: {} } })).toBe(false);
  });

  it("붙는 Action이 있고 확실한 반복 · 변경(commitment · update)일 때만 그 Action을 돌려준다", () => {
    expect(settlingCommitment(candidate(), signals(), "auto", match(), target)).toBe(target);
    expect(settlingCommitment(candidate({ signal: "update" }), signals(), "auto", match({ relation: "update" }), target)).toBe(target);
    expect(settlingCommitment(candidate(), signals(), "auto", match(), undefined)).toBeNull();
    expect(settlingCommitment(candidate(), signals(), "auto", match({ needsConfirmation: true }), target)).toBeNull();
    // 확신이 0.8 미만이면 붙이더라도 풀지 않는다 (경계 0.8은 푼다)
    expect(settlingCommitment(candidate(), signals(), "auto", match({ confidence: 0.79 }), target)).toBeNull();
    expect(settlingCommitment(candidate(), signals(), "auto", match({ confidence: 0.8 }), target)).toBe(target);
    expect(settlingCommitment(candidate(), signals(), "auto", match({ relation: "new" }), target)).toBeNull();
    expect(settlingCommitment(candidate(), signals(), "auto", match({ relation: "complete" }), target)).toBeNull();
    expect(settlingCommitment(candidate({ signal: "completion" }), signals(), "auto", match(), target)).toBeNull();
    expect(settlingCommitment(candidate(), signals({ firm: false }), "auto", match(), target)).toBeNull();
  });

  it("사용자의 발언 자체가 판정을 통과(자동 반영)하지 못했으면(확인 요청 · 기각) 풀지 않는다", () => {
    expect(settlingCommitment(candidate(), signals(), "confirm", match(), target)).toBeNull();
    expect(settlingCommitment(candidate({ signal: "update" }), signals(), "reject", match({ relation: "update" }), target)).toBeNull();
  });

  it("붙는 Action을 넘기면 내용(지금 제목) · 담당 · 상태 · 기한 Claim, 아니면 기한만", () => {
    const fields = (settles: OpenAction | null, c = candidate()) => candidateClaims(c, signals(), src, "duplicate", newId, settles).map((claim) => [claim.field, claim.value]);
    expect(fields(null)).toEqual([["due", "2025-09-26"]]);
    expect(fields(target)).toEqual([["scope", "제안서 발송"], ["owner", "me"], ["status", "open"], ["due", "2025-09-26"]]);
    // 변경(update)은 지금 제목을 받아들인 것이 아니라 내용 Claim은 더하지 않는다
    expect(candidateClaims(candidate({ signal: "update" }), signals(), src, "update", newId, target).map((claim) => [claim.field, claim.value])).toEqual([["owner", "me"], ["status", "open"], ["due", "2025-09-26"]]);
    expect(fields(target, candidate({ due: null }))).toEqual([["scope", "제안서 발송"], ["owner", "me"], ["status", "open"]]);
  });

  it("추출기가 담당을 모른다고 했거나 다른 사람 담당 Action이면 담당 Claim은 더하지 않는다", () => {
    const owners = (settles: OpenAction, c = candidate()) => candidateClaims(c, signals(), src, "update", newId, settles).filter((claim) => claim.field === "owner");
    expect(owners(target, candidate({ owner: "unknown" }))).toEqual([]);
    expect(owners({ ...target, owner: "other" })).toEqual([]);
    expect(owners({ ...target, owner: "unknown" })).toHaveLength(1);
  });

  it("판정 확인 이유만 골라 뺀다", () => {
    expect(withoutJudgeReasons(["판정 확인: NOT_MY_ACTION, TENTATIVE", "담당 확인", "병합 확인 (55%)", "중복 확인 (70%): 제안서"])).toEqual(["담당 확인", "병합 확인 (55%)", "중복 확인 (70%): 제안서"]);
  });
});
