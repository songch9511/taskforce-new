import { describe, expect, it } from "vitest";

import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";

import type { ActionCandidate } from "./extract";
import type { Decide, JudgeResult, JudgeSignals } from "./judge";
import { decideMatch, shortlistActions, type OpenAction } from "./match";
import { InMemoryActionStore, mergeJudged, type MergeDeps, type MergeSource } from "./merge";
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
    expect(store.all()[0].confirmReasons).toEqual(["판정 확인: ", "담당 확인"]);
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
