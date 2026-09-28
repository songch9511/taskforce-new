import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { findLabelErrors, goldenCaseSchema, type GoldenCase } from "./golden";

const base: GoldenCase = {
  id: "t",
  description: "테스트",
  origin: "synthetic",
  user: { name: "나", aliases: [], emails: [] },
  sources: [
    { id: "s1", kind: "meeting", occurred_at: "2025-09-22T10:00:00+09:00", text: "금요일까지  제안서 보내드릴게요" },
  ],
  expected_actions: [
    {
      title: "제안서 발송",
      owner: "me",
      due: "2025-09-26",
      status: "open",
      evidence: [{ source: "s1", quote: "금요일까지 제안서 보내드릴게요" }],
    },
  ],
  must_not_extract: [],
};

describe("findLabelErrors", () => {
  it("공백 차이는 무시하고 인용을 찾는다", () => {
    expect(findLabelErrors(base)).toEqual([]);
  });

  it("원문에 없는 인용을 잡는다", () => {
    const golden = {
      ...base,
      expected_actions: [{ ...base.expected_actions[0], evidence: [{ source: "s1", quote: "월요일까지" }] }],
    };
    expect(findLabelErrors(golden)).toEqual([expect.stringContaining("인용이 원문 s1에 없습니다")]);
  });

  it("없는 source를 가리키면 잡는다", () => {
    const golden = {
      ...base,
      must_not_extract: [{ source: "s9", quote: "x", reason: "INFO_ONLY" as const }],
    };
    expect(findLabelErrors(golden)).toEqual([expect.stringContaining("없는 source")]);
  });
});

describe("evals/golden", () => {
  it("모든 케이스가 형식에 맞고 라벨 오류가 없다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/golden");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThan(0);

    for (const file of files) {
      const golden = goldenCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      expect(findLabelErrors(golden), file).toEqual([]);
    }
  });
});
