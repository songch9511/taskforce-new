import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { findPlanLabelErrors, planCaseSchema, planTotals, scorePlanCase, type PlanCase } from "./plan-golden";

const base: PlanCase = planCaseSchema.parse({
  id: "t",
  description: "테스트",
  now: "2026-10-02T10:00:00+09:00",
  user: { name: "김도윤" },
  request: "견적 회신 메일 초안 써 줘",
  action: { title: "견적 회신", counterpart: "박서준" },
  sources: [{ id: "s1", kind: "email", provider: "gmail", occurred_at: "2026-10-01T13:10:00+09:00", text: "영상 2편 견적 부탁드립니다." }],
  evidence: [{ source: "s1", quote: "영상 2편 견적 부탁드립니다" }],
  expect: { kind: "draft" },
});

describe("findPlanLabelErrors", () => {
  it("capability는 needs_connection에만, done은 성공한 초안이 있을 때만", () => {
    expect(findPlanLabelErrors(base)).toEqual([]);
    expect(findPlanLabelErrors({ ...base, expect: { kind: "needs_connection" } })).toEqual([expect.stringContaining("capability가 필요")]);
    expect(findPlanLabelErrors({ ...base, expect: { kind: "draft", capability: "send_email" } })).toEqual([expect.stringContaining("needs_connection에만")]);
    expect(findPlanLabelErrors({ ...base, expect: { kind: "done" } })).toEqual([expect.stringContaining("done은")]);
    const failedOnly = { ...base, history: [{ kind: "draft" as const, status: "failed" as const, brief: "b", title: null }], expect: { kind: "done" as const } };
    expect(findPlanLabelErrors(failedOnly)).toEqual([expect.stringContaining("done은")]);
  });

  it("근거 구절이 원문에 없으면 라벨 오류", () => {
    expect(findPlanLabelErrors({ ...base, evidence: [{ source: "s1", quote: "없는 구절" }] })).toEqual([expect.stringContaining("원문 s1에 없습니다")]);
  });
});

describe("scorePlanCase · planTotals", () => {
  it("스키마 · 종류 · capability · 인자를 따로 센다", () => {
    expect(scorePlanCase(base, { kind: "draft", brief: "견적 회신" })).toMatchObject({ schemaValid: true, kindCorrect: true, capabilityCorrect: null, argsPresent: true });
    expect(scorePlanCase(base, { kind: "draft", brief: " " })).toMatchObject({ kindCorrect: true, argsPresent: false });
    expect(scorePlanCase(base, { kind: "done" })).toMatchObject({ schemaValid: true, kindCorrect: false, actual: "done" });
    expect(scorePlanCase(base, null)).toMatchObject({ schemaValid: false, kindCorrect: false, actual: null });
    const send = { ...base, expect: { kind: "needs_connection" as const, capability: "send_email" as const } };
    expect(scorePlanCase(send, { kind: "needs_connection", capability: "send_message" })).toMatchObject({ kindCorrect: true, capabilityCorrect: false });
  });

  it("기대 × 결과 표를 만든다", () => {
    const t = planTotals([scorePlanCase(base, { kind: "draft", brief: "b" }), scorePlanCase(base, { kind: "done" }), scorePlanCase(base, null)]);
    expect(t).toMatchObject({ n: 3, schemaValid: 2, kindCorrect: 1 });
    expect(t.confusion.draft).toEqual({ draft: 1, needs_connection: 0, ask_user: 0, done: 1, invalid: 1 });
  });
});

describe("evals/plan", () => {
  it("20건 이상, 형식 · 라벨 오류 없음, 종류별 draft 8 · needs_connection 4 · ask_user 4 · done 4 이상, 관문 ① done 오답 유형 포함", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/plan");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThanOrEqual(20);
    const cases: PlanCase[] = [];
    for (const file of files) {
      const golden = planCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      expect(findPlanLabelErrors(golden), file).toEqual([]);
      expect(`${golden.id}.json`).toBe(file);
      cases.push(golden);
    }
    const count = (kind: string) => cases.filter((c) => c.expect.kind === kind).length;
    expect(count("draft")).toBeGreaterThanOrEqual(8);
    expect(count("needs_connection")).toBeGreaterThanOrEqual(4);
    expect(count("ask_user")).toBeGreaterThanOrEqual(4);
    expect(count("done")).toBeGreaterThanOrEqual(4);
    expect(cases.filter((c) => c.tags?.includes("done-trap") && c.expect.kind !== "done").length).toBeGreaterThanOrEqual(3);
  });
});
