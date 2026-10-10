import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { proposalIntact } from "@/lib/conversation/proposal";
import type { TurnPlan } from "@/lib/conversation/respond";

import { consultCaseSchema, consultInputOf, findConsultLabelErrors, scoreConsultCase, type ConsultCase } from "./consult-golden";

// 대화 상담 골든셋(evals/consult)의 형식 · 라벨 · 입력 만들기 · 채점. 실제 모델 채점은 npm run eval -- --consult (이번 PR에서는 실행하지 않음).

const DIR = path.resolve(__dirname, "../../../evals/consult");
const cases: ConsultCase[] = readdirSync(DIR)
  .filter((f) => f.endsWith(".json"))
  .sort()
  .map((f) => consultCaseSchema.parse(JSON.parse(readFileSync(path.join(DIR, f), "utf8"))));

const emptyPlan = (overrides: Partial<TurnPlan> = {}): TurnPlan =>
  ({
    intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
    route: "consult",
    user: { refs: {} },
    reply: { text: "등록된 열린 할 일은 없어요. 오늘 하려는 일이 있나요?", segments: [{ text: "x", tier: "T5" }], citations: [], refs: {}, content: { segments: [], citations: [], proposal: null, asks: null, used: null, window: null } },
    memory: [],
    adopt: null,
    summary: {},
    ...overrides,
  }) as TurnPlan;

describe("evals/consult", () => {
  it("15건 · 파일 이름 = id · 라벨 오류 없음 · 기준 A01–A05 · A34 · A41 · ARCH01 · 02 · 04를 모두 덮는다", () => {
    expect(cases).toHaveLength(15);
    for (const golden of cases) expect(findConsultLabelErrors(golden), golden.id).toEqual([]);
    const maps = new Set(cases.flatMap((c) => c.maps_to));
    for (const id of ["A01", "A02", "A04", "A05", "A34", "A41", "ARCH01", "ARCH02", "ARCH04"]) expect(maps.has(id), id).toBe(true);
  });

  it("라벨 검사: 원문에 없는 근거 구절 · 없는 정정 대상 · 깨진 정규식 · 열린 제안 없는 채택 기대를 잡는다", () => {
    const base = cases.find((c) => c.id === "a05-injection-send-mail")!;
    const broken: ConsultCase = {
      ...base,
      records: { ...base.records, open_actions: [{ ...base.records.open_actions[0], quotes: [{ source: "s1", quote: "원문에 없는 구절" }] }] },
      expect: { ...base.expect, corrects: ["m9"], reply_must_not_match: ["("], adopt: true },
    };
    const errors = findConsultLabelErrors(broken);
    expect(errors.some((e) => e.includes("인용이 원문 s1에 없습니다"))).toBe(true);
    expect(errors.some((e) => e.includes("없는 memory m9"))).toBe(true);
    expect(errors.some((e) => e.includes("깨진 정규식"))).toBe(true);
    expect(errors.some((e) => e.includes("열린 제안"))).toBe(true);
  });

  it("입력 만들기: 지금 메시지가 창의 마지막, 앞 제안은 hash가 맞고, 앱이 고른 대상 · 범위 기억이 이어진다", () => {
    const adopt = cases.find((c) => c.id === "a41-adopt-open-proposal")!;
    const { input } = consultInputOf(adopt);
    expect(input.window.at(-1)).toMatchObject({ id: input.message.id, role: "user", text: "그렇게 해" });
    const proposal = input.window.at(-2)!;
    expect(proposalIntact(proposal.refs.proposal!, proposal.content!.proposal)).toBe(true);
    const mixed = consultInputOf(cases.find((c) => c.id === "a34-mixed-read-and-delegate")!);
    expect(mixed.input.selected).toEqual([{ kind: "action", id: mixed.ids("a1"), title: "견적서 보내기" }]);
    const partial = consultInputOf(cases.find((c) => c.id === "a04-partial-shown")!);
    expect([partial.context.openTotal, partial.context.openActions.length]).toEqual([30, 8]);
  });

  it("채점: 금지 표현(등록 0건을 할 일 없음으로 단정)은 미달, 범위를 밝힌 답은 통과", () => {
    const a01 = cases.find((c) => c.id === "a01-no-open-one-done")!;
    const { ids } = consultInputOf(a01);
    expect(scoreConsultCase(a01, emptyPlan(), ids).pass).toBe(true);
    const bad = scoreConsultCase(a01, emptyPlan({ reply: { ...emptyPlan().reply, text: "오늘은 할 일이 없어요." } }), ids);
    expect(bad.pass).toBe(false);
    expect(bad.checks.must_not_match).toBe(false);
    const redo = scoreConsultCase(a01, emptyPlan({ reply: { ...emptyPlan().reply, content: { ...emptyPlan().reply.content, proposal: { kind: "create_action", title: "주간 보고서 다시 보내기" } } } }), ids);
    expect(redo.checks.proposal_titles).toBe(false);
  });
});
