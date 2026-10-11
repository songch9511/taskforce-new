import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { MAX_CONCURRENT_COST_STEPS, MAX_LIVE_EXTERNAL_TASKS, MAX_OPEN_RUNS_PER_ACTION, MAX_STEPS, MAX_STEPS_BY_GOAL, WAITING_RUN_RETENTION_DAYS } from "./limits";
import { EXECUTABLE_GOALS, RUN_GOALS } from "./types";

// 0.2.0 C1: 런타임 계약 4장의 한도 값. 값만 정해 둔 것이다 — 이 묶음에서는 새 goal을 실행하지 않으므로 draft의 MAX_STEPS 말고는 어디서도 읽지 않는다.

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

describe("값만 있다: 새 상수를 읽는 코드가 아직 없다 (센다 · 막는다는 C2 · D1 몫)", () => {
  const ROOT = path.resolve(__dirname, "../../..");
  const files = (dir: string): string[] =>
    readdirSync(dir).flatMap((name) => {
      const full = path.join(dir, name);
      if (statSync(full).isDirectory()) return files(full);
      return /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name) ? [full] : [];
    });

  it("MAX_STEPS_BY_GOAL · 동시성 상수는 limits.ts 밖의 실행 코드에서 쓰지 않는다 (소비하는 단계가 이 목록을 함께 고친다)", () => {
    const consumers = files(path.join(ROOT, "src"))
      .filter((file) => !file.endsWith(path.join("execution", "limits.ts")))
      .filter((file) => /\b(MAX_STEPS_BY_GOAL|MAX_CONCURRENT_COST_STEPS|MAX_LIVE_EXTERNAL_TASKS|WAITING_RUN_RETENTION_DAYS|MAX_OPEN_RUNS_PER_ACTION)\b/.test(readFileSync(file, "utf8")))
      .map((file) => path.relative(ROOT, file));
    expect(consumers).toEqual([]);
  });
});
