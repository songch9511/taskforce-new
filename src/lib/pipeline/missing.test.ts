import { describe, expect, it } from "vitest";

import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";
import type { JevDecision } from "@/lib/ai/jev";

import type { CompleteJson } from "./extract";
import type { Decide } from "./judge";
import { InMemoryActionStore, mergeJudged } from "./merge";
import { classifyMiss, extractMissing, reportedQuoteOverlaps, reportMatchDecide, reportStore, trackedByEvidence } from "./missing";
import { resolveAction } from "./resolve";

const text = "김대표: 견적서도 같이 받을 수 있을까요?\n나: 네, 금요일까지 견적서 정리해서 드릴게요.\n김대표: 좋아요.";
const input = {
  text,
  kind: "meeting" as const,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"), // 월요일
  identity: { name: "나", aliases: [], emails: [] },
  quote: "금요일까지 견적서 정리해서 드릴게요",
};

function answers(my: number): JevDecision["answers"] {
  return {
    is_my_commitment: { type: "noul", noul: my },
    is_actionable: { type: "noul", noul: 0.9 },
    already_done: { type: "noul", noul: 0.05 },
    certainty: { type: "choice", choice: "tentative", probabilities: {} },
    statement_certainty: { type: "choice", choice: "tentative", probabilities: {} },
    speaker_role: { type: "choice", choice: "me", probabilities: {} },
    directness: { type: "choice", choice: "first_hand", probabilities: {} },
    audience: { type: "choice", choice: "shared", probabilities: {} },
  };
}

function fakeComplete(data: Record<string, unknown>) {
  const requests: { system: string; user: string }[] = [];
  const complete = (async (request: { system: string; user: string }) => {
    requests.push(request);
    return { model: "test/llm", usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.002 }, data };
  }) as unknown as CompleteJson;
  return { complete, requests };
}

// 후보 검증 질문에는 "내 약속 아님"으로 답한다: 신고는 그래도 auto로 반영되어야 한다.
const judgeDecide: Decide = async () => ({ model: "test/jev", answers: answers(0.1), usage: { input_tokens: 1, cost: 0.0005 } });

describe("extractMissing", () => {
  it("신고한 구절로 후보 하나를 만든다: 인용 · 담당 · 신호는 고정, 기한은 코드가 다시 계산, 결정은 auto", async () => {
    const { complete, requests } = fakeComplete({
      title: "김대표에게 견적서 전달",
      counterpart: "김대표",
      due_text: "금요일까지",
      due: "2025-09-27", // 요일을 틀림 → 코드가 고친다
      due_confidence: 0.8,
    });
    const result = await extractMissing(input, { complete, decide: judgeDecide });

    expect(result.judged.candidate).toMatchObject({
      signal: "commitment",
      quote: "금요일까지 견적서 정리해서 드릴게요",
      owner: "me",
      title: "김대표에게 견적서 전달",
      counterpart: "김대표",
      due: "2025-09-26",
      due_check: "corrected",
    });
    expect(result.judged.judge).toMatchObject({ decision: "auto", reasons: [] });
    // Claim 속성은 Jev 답을 그대로 쓴다
    expect(result.judged.judge.signals.statement_certainty.choice).toBe("tentative");
    expect(result.summary.cost).toBeCloseTo(0.0025);
    // 원문 전체가 아니라 구절과 앞뒤 문맥만 보낸다
    expect(requests[0].user).toContain("<신고한 구절>\n금요일까지 견적서 정리해서 드릴게요");
  });

  it("제목이 비었으면 구절을 제목으로 쓰고, 형식이 틀린 날짜는 버린다", async () => {
    const { complete } = fakeComplete({ title: " ", counterpart: "", due_text: null, due: "금요일", due_confidence: 0.5 });
    const result = await extractMissing(input, { complete, decide: judgeDecide });
    expect(result.judged.candidate).toMatchObject({ title: input.quote, counterpart: null, due: null, due_confidence: null });
  });

  it("짧은 줄 15개에 걸친 구절도 문맥을 찾아 보낸다 (원문에 있는 구절이면 몇 줄이든)", async () => {
    const lines = ["나: 다음 주 발표 준비할게요", ...Array.from({ length: 14 }, (_, i) => `- 항목 ${i + 1}`)];
    const long = ["김대표: 발표 자료는요?", ...lines, "김대표: 좋아요."].join("\n");
    const quote = lines.join("\n");
    const { complete, requests } = fakeComplete({ title: "발표 준비", counterpart: null, due_text: null, due: null, due_confidence: null });
    const result = await extractMissing({ ...input, text: long, quote }, { complete, decide: judgeDecide });

    expect(result.judged.candidate.quote).toBe(quote);
    expect(requests[0].user).toContain("김대표: 발표 자료는요?");
    expect(requests[0].user).toContain("- 항목 14\n김대표: 좋아요.");
  });

  it("원문에 없는 구절은 모델을 부르기 전에 거절한다", async () => {
    const { complete, requests } = fakeComplete({});
    await expect(extractMissing({ ...input, quote: "월요일에 미팅 잡을게요" }, { complete, decide: judgeDecide })).rejects.toThrow("원문에 없는 구절");
    expect(requests).toHaveLength(0);
  });
});

describe("누락 신고 흐름 (extractMissing → mergeJudged)", () => {
  const embed = async (texts: string[]) => texts.map(() => Object.assign(new Array(EMBEDDING_DIMENSIONS).fill(0), { 0: 1 }));
  const source = { id: "s1", text, kind: "meeting" as const, occurredAt: input.occurredAt };
  const { complete } = fakeComplete({ title: "견적서 전달", counterpart: "김대표", due_text: null, due: null, due_confidence: null });

  it("비슷한 Action이 없으면 새 Action을 만든다 (근거는 신고한 구절)", async () => {
    const store = new InMemoryActionStore();
    const { judged } = await extractMissing(input, { complete, decide: judgeDecide });
    const [outcome] = await mergeJudged(store, [judged], source, input.identity, { embed, decide: judgeDecide, newId: () => crypto.randomUUID() });

    expect(outcome.relation).toBe("new");
    const [action] = store.all();
    expect(action.evidence).toEqual([{ sourceId: "s1", quote: input.quote, role: "created" }]);
    expect(resolveAction(action.claims).owner.value).toBe("me");
    expect(action.confirmReasons).toEqual([]);
  });

  it("같은 열린 Action이 있으면 합치고, 매칭이 완료로 보더라도 끝내지 않는다", async () => {
    const store = new InMemoryActionStore();
    const existing = await store.create({ title: "견적서 전달", counterpart: "김대표", embedding: (await embed(["x"]))[0], claims: [], evidence: [], confirmReasons: [] });
    const saysDone: Decide = async (request) => {
      if (!("relation" in request.questions)) return judgeDecide(request);
      return {
        model: "test/jev",
        answers: {
          relation: { type: "choice", choice: "same_done", probabilities: { same_done: 0.5, same_restated: 0.4, new: 0.1 } },
          target: { type: "choice", choice: "t1", probabilities: { t1: 0.9 } },
        },
      };
    };
    const { judged } = await extractMissing(input, { complete, decide: judgeDecide });
    const [outcome] = await mergeJudged(store, [judged], source, input.identity, { embed, decide: reportMatchDecide(saysDone), newId: () => crypto.randomUUID() });

    expect(outcome).toMatchObject({ relation: "duplicate", actionId: existing.id });
    expect(store.all()).toHaveLength(1);
    expect(resolveAction(store.all()[0].claims).status.value).not.toBe("done");
    expect(store.all()[0].evidence.at(-1)).toMatchObject({ quote: input.quote, role: "duplicate" });
  });

  const matchAnswer = (choice: string, p: number, target = 0.9): Decide => async (request) => {
    if (!("relation" in request.questions)) return judgeDecide(request);
    return {
      model: "test/jev",
      answers: {
        relation: { type: "choice", choice, probabilities: { [choice]: p, new: 1 - p } },
        target: { type: "choice", choice: "t1", probabilities: { t1: target } },
      },
    };
  };

  it.each([
    ["same_changed", 0.5, 0.9],
    ["same_restated", 0.9, 0.4],
  ])("확신이 낮은 병합(%s %s, 대상 %s)은 병합 확인 대신 새 Action을 만든다", async (choice, p, target) => {
    const store = new InMemoryActionStore();
    const other = await store.create({ title: "견적서 검토", counterpart: null, embedding: (await embed(["x"]))[0], claims: [], evidence: [], confirmReasons: [] });
    const { judged } = await extractMissing(input, { complete, decide: judgeDecide });
    const [outcome] = await mergeJudged(store, [judged], source, input.identity, {
      embed,
      decide: reportMatchDecide(matchAnswer(choice, p, target)),
      newId: () => crypto.randomUUID(),
    });

    expect(outcome.relation).toBe("new");
    expect(store.all()).toHaveLength(2);
    // 기존 Action에는 근거도 확인 요청도 붙지 않는다
    expect(store.all()[0]).toMatchObject({ id: other.id, evidence: [], confirmReasons: [] });
    expect(store.all()[1].confirmReasons).toEqual([]);
  });

  it("확실한 변경은 기존 Action에 합친다 (already_tracked)", async () => {
    const store = new InMemoryActionStore();
    const existing = await store.create({ title: "견적서 전달", counterpart: "김대표", embedding: (await embed(["x"]))[0], claims: [], evidence: [], confirmReasons: [] });
    const { judged } = await extractMissing(input, { complete, decide: judgeDecide });
    const [outcome] = await mergeJudged(store, [judged], source, input.identity, {
      embed,
      decide: reportMatchDecide(matchAnswer("same_changed", 0.8)),
      newId: () => crypto.randomUUID(),
    });
    expect(outcome).toMatchObject({ relation: "update", actionId: existing.id });
    expect(store.all()[0].confirmReasons).toEqual([]);
  });

  it("다른 사람 담당 Action과는 합치지 않는다 (reportStore): 지금 할 일에 보이도록 새 Action을 만든다", async () => {
    const store = new InMemoryActionStore();
    const vector = (await embed(["x"]))[0];
    const at = input.occurredAt;
    const base = { occurredAt: at, speakerRole: "me", certainty: "firm", directness: "first_hand", audience: "shared", channel: "meeting" } as const;
    const claim = (field: "owner" | "status", value: string) => ({ id: crypto.randomUUID(), field, value, ...base });
    const colleague = await store.create({ title: "견적서 전달", counterpart: "김대표", embedding: vector, claims: [claim("owner", "김대리"), claim("status", "open")], evidence: [], confirmReasons: [] });
    expect((await store.shortlist(vector)).map((a) => [a.id, a.owner])).toEqual([[colleague.id, "other"]]);
    expect(await reportStore(store).shortlist(vector)).toEqual([]);

    const { judged } = await extractMissing(input, { complete, decide: judgeDecide });
    const [outcome] = await mergeJudged(reportStore(store), [judged], source, input.identity, {
      embed,
      decide: reportMatchDecide(matchAnswer("same_restated", 0.95)),
      newId: () => crypto.randomUUID(),
    });
    expect(outcome.relation).toBe("new");
    expect(store.all()).toHaveLength(2);
    expect(resolveAction(store.all()[1].claims).owner.value).toBe("me");
    expect(store.all()[0].evidence).toEqual([]);
  });
});

describe("trackedByEvidence", () => {
  const quote = "금요일까지 견적서 정리해서 드릴게요";

  it("이 원문의 근거 구절과 겹치면 그 Action (상태와 상관없이 처음 겹친 것)", () => {
    const evidence = [
      { actionId: "a1", quote: "다음 주에 미팅 잡을게요", owner: "me" as const },
      { actionId: "done", quote: "네, 금요일까지 견적서 정리해서 드릴게요.", owner: "me" as const },
      { actionId: "a3", quote: "견적서 정리해서 드릴게요", owner: "unknown" as const },
    ];
    expect(trackedByEvidence(evidence, quote)).toBe("done");
  });

  it("겹치는 근거가 없거나 다른 사람 담당 Action뿐이면 null", () => {
    expect(trackedByEvidence([], quote)).toBeNull();
    expect(trackedByEvidence([{ actionId: "a1", quote: "다음 주에 미팅 잡을게요", owner: "me" }], quote)).toBeNull();
    expect(trackedByEvidence([{ actionId: "a2", quote, owner: "other" }], quote)).toBeNull();
    expect(trackedByEvidence([{ actionId: "a2", quote: null, owner: "me" }], quote)).toBeNull();
  });
});

describe("reportMatchDecide", () => {
  const response = (choice: string, target = 0.9) => async () => ({
    model: "m",
    answers: {
      relation: { type: "choice" as const, choice, probabilities: { same_cancelled: 0.5, same_restated: 0.3, same_changed: 0.7, new: 0.2 } },
      target: { type: "choice" as const, choice: "t1", probabilities: { t1: target } },
    },
  });

  it("완료 · 취소는 같은 일의 반복으로 바꾸고 확률을 합친다. 확실한 변경 · 새 일은 그대로 둔다", async () => {
    const cancelled = await reportMatchDecide(response("same_cancelled"))({ state: {}, questions: {} });
    expect(cancelled.answers.relation).toMatchObject({ choice: "same_restated", probabilities: { same_restated: 0.8 } });
    const changed = await reportMatchDecide(response("same_changed"))({ state: {}, questions: {} });
    expect(changed.answers.relation).toMatchObject({ choice: "same_changed" });
    const fresh = await reportMatchDecide(response("new"))({ state: {}, questions: {} });
    expect(fresh.answers.relation).toMatchObject({ choice: "new" });
  });

  it("병합 확인이 필요한 확신(관계 · 대상 중 작은 값 < 0.6)이면 새 일로 바꾼다", async () => {
    // 관계 확률이 낮음: same_restated 0.3
    expect((await reportMatchDecide(response("same_restated"))({ state: {}, questions: {} })).answers.relation).toMatchObject({ choice: "new" });
    // 대상 확률이 낮음
    expect((await reportMatchDecide(response("same_changed", 0.5))({ state: {}, questions: {} })).answers.relation).toMatchObject({ choice: "new" });
    // 합친 확률도 낮으면 완료 → 반복이 아니라 새 일
    expect((await reportMatchDecide(response("same_cancelled", 0.55))({ state: {}, questions: {} })).answers.relation).toMatchObject({ choice: "new" });
  });
});

describe("reportedQuoteOverlaps", () => {
  it.each([
    ["금요일까지 견적서 드릴게요", "금요일까지 견적서 드릴게요.", true],
    ["견적서 정리해서 드릴게요", "네, 금요일까지 견적서 정리해서 드릴게요", true], // 한쪽이 다른 쪽에 들어 있음
    ["금요일까지 견적서 정리해 드릴게요", "금요일까지 견적서 정리해서 드릴게요", true], // 글자 쌍이 많이 겹침
    ["네", "네, 금요일까지 견적서 드릴게요", false], // 너무 짧은 말이 우연히 들어 있음
    ["다음 주에 미팅 잡을게요", "금요일까지 견적서 드릴게요", false],
    ["", "금요일까지", false],
  ])("%s ↔ %s → %s", (a, b, expected) => {
    expect(reportedQuoteOverlaps(a, b)).toBe(expected);
  });
});

describe("classifyMiss", () => {
  const quote = "금요일까지 견적서 정리해서 드릴게요";

  it("처리를 마치지 못한 원문은 processing_failed", () => {
    expect(classifyMiss({ processingStatus: "failed", logs: [], quote })).toBe("processing_failed");
    expect(classifyMiss({ processingStatus: "processing", logs: [{ quote, decision: "auto" }], quote })).toBe("processing_failed");
  });

  it("겹치는 후보가 없으면 not_extracted", () => {
    expect(classifyMiss({ processingStatus: "done", logs: [{ quote: "다음 주에 미팅 잡을게요", decision: "auto" }], quote })).toBe("not_extracted");
  });

  it("겹치는 후보를 Jev가 기각했으면 judge_rejected", () => {
    expect(classifyMiss({ processingStatus: "done", logs: [{ quote: "견적서 정리해서 드릴게요", decision: "reject" }], quote })).toBe("judge_rejected");
  });

  it("겹치는 후보가 통과했으면 merge_absorbed (기각된 후보가 같이 있어도 가장 멀리 간 단계)", () => {
    const logs = [
      { quote: "견적서 정리해서 드릴게요", decision: "reject" as const },
      { quote: "금요일까지 견적서 정리해서 드릴게요.", decision: "confirm" as const },
    ];
    expect(classifyMiss({ processingStatus: "done", logs, quote })).toBe("merge_absorbed");
  });
});
