import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { MAX_CONCURRENT_COST_STEPS, MAX_LIVE_EXTERNAL_TASKS, MAX_OPEN_RUNS_PER_ACTION, MAX_STEPS, MAX_STEPS_BY_GOAL, WAITING_RUN_RETENTION_DAYS } from "./limits";
import { EXECUTABLE_GOALS, RUN_GOALS } from "./types";

// 0.2.0 C1 한도 값. D1c-1은 살아 있는 외부 작업 한도만 agents/turns.ts에서 소비한다.

describe("goal별 단계 상한 (런타임 계약 4장)", () => {
  it("draft 4(기존) · agent 12 · send 4 · followup 3, 모든 goal에 상한이 있다", () => {
    expect(MAX_STEPS_BY_GOAL).toEqual({ draft: 4, agent: 12, send: 4, followup: 3 });
    expect(Object.keys(MAX_STEPS_BY_GOAL).sort()).toEqual([...RUN_GOALS].sort());
  });

  it("지금 실행하는 draft의 상한은 기존 MAX_STEPS(4) 그대로다", () => {
    expect(MAX_STEPS).toBe(4);
    for (const goal of EXECUTABLE_GOALS) expect(MAX_STEPS_BY_GOAL[goal]).toBe(MAX_STEPS);
  });
});

describe("동시성 한도 (런타임 계약 4장)", () => {
  it("실행 동시성 3 · 살아 있는 외부 작업 5 · 대기 보관 30일 · Action당 열린 run 2", () => {
    expect([MAX_CONCURRENT_COST_STEPS, MAX_LIVE_EXTERNAL_TASKS, WAITING_RUN_RETENTION_DAYS, MAX_OPEN_RUNS_PER_ACTION]).toEqual([3, 5, 30, 2]);
  });
});

describe("한도 소비처는 구현된 입구만 허용한다", () => {
  const ROOT = path.resolve(__dirname, "../../..");
  const files = (dir: string): string[] =>
    readdirSync(dir).flatMap((name) => {
      const full = path.join(dir, name);
      if (statSync(full).isDirectory()) return files(full);
      return /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name) ? [full] : [];
    });

  it("agents/turns.ts만 MAX_LIVE_EXTERNAL_TASKS를 소비하고 다른 새 상수의 소비처는 없다", () => {
    const consumers = files(path.join(ROOT, "src"))
      .filter((file) => !file.endsWith(path.join("execution", "limits.ts")))
      .filter((file) => /\b(MAX_STEPS_BY_GOAL|MAX_CONCURRENT_COST_STEPS|MAX_LIVE_EXTERNAL_TASKS|WAITING_RUN_RETENTION_DAYS|MAX_OPEN_RUNS_PER_ACTION)\b/.test(readFileSync(file, "utf8")))
      .map((file) => path.relative(ROOT, file));
    expect(consumers).toEqual(["src/lib/agents/turns.ts"]);
    const turnSource = readFileSync(path.join(ROOT, consumers[0]), "utf8");
    expect(turnSource.match(/\b(MAX_STEPS_BY_GOAL|MAX_CONCURRENT_COST_STEPS|WAITING_RUN_RETENTION_DAYS|MAX_OPEN_RUNS_PER_ACTION)\b/g)).toBeNull();
  });
});
