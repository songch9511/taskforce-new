import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { JUDGE_REASON_PREFIX } from "../pipeline/merge";

// 서버가 actions.confirm_reasons에 남기는 확인 이유를 앱이 모두 알아보는지 본다.
// 앱(apple/.../Labels.swift ConfirmReasonText)은 모르는 이유를 "Needs review"로만 보여서, 서버 쪽 이름이 바뀌면 조용히 나빠진다.
// 이 테스트가 깨지면 Labels.swift의 표기(와 LabelsTests)를 함께 고친다.
const root = path.resolve(import.meta.dirname, "../../..");
const read = (file: string) => readFileSync(path.join(root, file), "utf8");
const swift = read("apple/Packages/TaskforceKit/Sources/TaskforceKit/Labels.swift");

/** 주석을 뺀 코드의 문자열 리터럴 중 "… 확인"으로 시작하는 것 */
function reasonLiterals(source: string): string[] {
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
  return [...code.matchAll(/["`]([가-힣]+ 확인)/g)].map((match) => match[1]);
}

/** 앱이 그 이유를 정확히 같은 이름(`"담당 확인": .owner`)이나 머리말(`hasPrefix("병합 확인")`)로 알아보는지 */
function swiftKnows(reason: string): boolean {
  return swift.includes(`"${reason}": .`) || swift.includes(`hasPrefix("${reason}`);
}

describe("확인 이유 (앱 ConfirmReasonText와 대조)", () => {
  it("판정 단계의 코드(RejectReason)를 앱이 모두 옮긴다", () => {
    const union = read("src/lib/pipeline/judge.ts").match(/export type RejectReason = ([^;]+);/);
    expect(union).not.toBeNull();
    const codes = [...union![1].matchAll(/"([A-Z_]+)"/g)].map((match) => match[1]);
    expect(codes).toContain("NOT_MY_ACTION");
    for (const code of codes) expect(swift, code).toContain(`"${code}": .`);
    // 판정 이유는 "판정 확인: NOT_MY_ACTION, TENTATIVE" 모양이다 (merge.ts mergeJudged)
    expect(read("src/lib/pipeline/merge.ts")).toContain("`${JUDGE_REASON_PREFIX}: ${judge.reasons.join(\", \")}`");
    expect(swift).toContain(`hasPrefix("${JUDGE_REASON_PREFIX}:")`);
  });

  it("Claim에서 다시 계산하는 이유(담당 · 기한 · 내용 · 상태 확인)를 앱이 모두 옮긴다", () => {
    const project = read("src/lib/actions/project.ts");
    expect(project).toContain("`${FIELD_LABELS[f]} 확인`");
    const labels = project.match(/const FIELD_LABELS[^=]*=\s*\{([^}]*)\}/);
    expect(labels).not.toBeNull();
    const derived = [...labels![1].matchAll(/"([가-힣]+)"/g)].map((match) => `${match[1]} 확인`);
    expect(derived).toHaveLength(4);
    for (const reason of derived) expect(swift, reason).toContain(`"${reason}": .`);
  });

  it("서버 코드에 적힌 확인 이유 글자를 앱이 모두 알아본다", () => {
    const files = [
      "src/lib/pipeline/merge.ts", // 판정 확인 · 담당 확인 · 병합 확인 (55%)
      "src/lib/pipeline/merge-task.ts", // 중복 확인 (72%): 제목
      "src/lib/actions/project.ts", // 담당 확인
      "src/lib/actions/rows.ts", // DERIVED_REASONS
    ];
    const reasons = [...new Set(files.flatMap((file) => reasonLiterals(read(file))))];
    expect(reasons).toEqual(expect.arrayContaining(["판정 확인", "병합 확인", "중복 확인", "담당 확인", "기한 확인", "내용 확인", "상태 확인"]));
    for (const reason of reasons) expect(swiftKnows(reason), reason).toBe(true);
  });
});
