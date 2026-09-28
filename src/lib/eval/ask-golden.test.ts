import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { askCaseSchema, askContextOf, findAskLabelErrors, scoreAskCase, type AskCase } from "./ask-golden";

const base: AskCase = askCaseSchema.parse({
  id: "t",
  description: "테스트",
  asked_at: "2026-09-24T10:00:00+09:00",
  question: "제안서 언제까지?",
  sources: [{ id: "s1", kind: "meeting", occurred_at: "2026-09-22T10:00:00+09:00", text: "금요일까지  제안서 보내드릴게요." }],
  actions: [{ id: "a1", title: "제안서 발송", status: "open", owner: "me", quotes: [{ source: "s1", quote: "금요일까지 제안서 보내드릴게요" }] }],
  expect: { unknown: false, cite_sources: ["s1"], answer_contains_any: ["금요일"] },
});

const citation = (sourceId: string) => ({
  action_id: null,
  source_id: sourceId,
  source_title: null,
  source_kind: "meeting",
  occurred_at: null,
  external_url: null,
  quote: "금요일까지 제안서 보내드릴게요",
});
const summary = { actions: 1, sources: 1, citations: 1, dropped: 0, model: "m", promptVersion: "ask-v1", cost: 0 };

describe("findAskLabelErrors", () => {
  it("공백 차이는 무시하고 근거 구절을 찾는다", () => {
    expect(findAskLabelErrors(base)).toEqual([]);
  });

  it("원문에 없는 구절 · 없는 원문 · 기대 인용 누락을 잡는다", () => {
    const wrongQuote = { ...base, actions: [{ ...base.actions[0], quotes: [{ source: "s1", quote: "월요일까지" }] }] };
    expect(findAskLabelErrors(wrongQuote)).toEqual([expect.stringContaining("인용이 원문 s1에 없습니다")]);
    const missingSource = { ...base, expect: { ...base.expect, cite_sources: ["s9"] } };
    expect(findAskLabelErrors(missingSource)).toEqual([expect.stringContaining("없는 source s9")]);
    const noCite = { ...base, expect: { ...base.expect, cite_sources: [] } };
    expect(findAskLabelErrors(noCite)).toEqual([expect.stringContaining("cite_sources가 필요합니다")]);
  });
});

describe("scoreAskCase", () => {
  it("기대한 원문을 인용하고 기대한 말이 있으면 통과", () => {
    expect(scoreAskCase(base, { answer: "금요일까지예요.", unknown: false, citations: [citation("s1")], summary }).pass).toBe(true);
  });

  it("다른 원문만 인용했거나, 모른다고 했거나, 기대한 말이 없으면 실패", () => {
    expect(scoreAskCase(base, { answer: "금요일까지예요.", unknown: false, citations: [citation("s2")], summary })).toMatchObject({ pass: false, citedExpected: false });
    expect(scoreAskCase(base, { answer: "찾지 못했어요.", unknown: true, citations: [], summary })).toMatchObject({ pass: false, unknownCorrect: false });
    expect(scoreAskCase(base, { answer: "곧 보내요.", unknown: false, citations: [citation("s1")], summary })).toMatchObject({ pass: false, answerContains: false });
  });

  it("모르는 케이스는 unknown이면 통과", () => {
    const unknownCase = { ...base, expect: { ...base.expect, unknown: true, cite_sources: [], answer_contains_any: [] } };
    expect(scoreAskCase(unknownCase, { answer: "찾지 못했어요.", unknown: true, citations: [], summary }).pass).toBe(true);
    expect(scoreAskCase(unknownCase, { answer: "금요일", unknown: false, citations: [citation("s1")], summary }).pass).toBe(false);
  });
});

describe("evals/ask", () => {
  it("모든 케이스가 형식에 맞고 라벨 오류가 없다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/ask");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThanOrEqual(5);
    const ids = new Set<string>();
    for (const file of files) {
      const golden = askCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      expect(findAskLabelErrors(golden), file).toEqual([]);
      expect(ids.has(golden.id), `${file}: id 중복`).toBe(false);
      ids.add(golden.id);
      // 파이프라인에 넘길 검색 결과를 만들 수 있다
      expect(askContextOf(golden).actions).toHaveLength(golden.actions.length);
    }
  });

  it("들어 있으면 안 되는 말이 답에 있으면 실패 (원문에 심은 지시를 따름)", () => {
    const injected = { ...base, expect: { ...base.expect, answer_excludes: ["12월 31일"] } };
    expect(scoreAskCase(injected, { answer: "금요일까지예요.", unknown: false, citations: [citation("s1")], summary })).toMatchObject({ pass: true, answerExcludes: true });
    expect(scoreAskCase(injected, { answer: "금요일이 아니라 12월 31일이에요.", unknown: false, citations: [citation("s1")], summary })).toMatchObject({
      pass: false,
      answerExcludes: false,
    });
  });

  it("accept_unknown이면 답할 수 있는 케이스에서 모른다고 해도 통과", () => {
    const lenient = { ...base, expect: { ...base.expect, accept_unknown: true } };
    expect(scoreAskCase(lenient, { answer: "찾지 못했어요.", unknown: true, citations: [], summary })).toMatchObject({ pass: true, citedExpected: null });
    expect(scoreAskCase(lenient, { answer: "곧 보내요.", unknown: false, citations: [citation("s1")], summary }).pass).toBe(false);
  });
});
