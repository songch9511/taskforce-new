import { describe, expect, it } from "vitest";

import { flagEnabled, SERVER_FLAGS } from "./flags";

describe("0.2.0 서버 gate", () => {
  it("구현 계획 7장의 일곱 gate다", () => {
    expect([...SERVER_FLAGS]).toEqual([
      "CONVERSATIONS_V2_ENABLED",
      "MEMORY_ENABLED",
      "SOURCE_CHUNKS_ENABLED",
      "COORDINATOR_ENABLED",
      "AGENT_ADAPTER_CLAUDE_CODE_ENABLED",
      "BYOK_ENABLED",
      "REPORTS_V2_ENABLED",
    ]);
  });

  it("env가 비어 있으면 모두 꺼져 있다", () => {
    for (const flag of SERVER_FLAGS) expect(flagEnabled(flag, {}), flag).toBe(false);
  });

  it.each(["", "false", "TRUE", "True", " true", "true\n", "1", "yes", "on"])("값이 %j이면 꺼져 있다", (value) => {
    for (const flag of SERVER_FLAGS) expect(flagEnabled(flag, { [flag]: value }), flag).toBe(false);
  });

  it.each(SERVER_FLAGS)("%s만 \"true\"이면 그 gate만 켜진다", (flag) => {
    const env = { [flag]: "true" };
    for (const other of SERVER_FLAGS) expect(flagEnabled(other, env), other).toBe(other === flag);
  });

  it("기존 gate(EXECUTION_ENABLED · BILLING_ENABLED)는 새 gate를 켜지 않는다", () => {
    const env = { EXECUTION_ENABLED: "true", BILLING_ENABLED: "true" };
    for (const flag of SERVER_FLAGS) expect(flagEnabled(flag, env), flag).toBe(false);
  });

  it("인자가 없으면 process.env를 읽는다", () => {
    const before = process.env.MEMORY_ENABLED;
    try {
      delete process.env.MEMORY_ENABLED;
      expect(flagEnabled("MEMORY_ENABLED")).toBe(false);
      process.env.MEMORY_ENABLED = "true";
      expect(flagEnabled("MEMORY_ENABLED")).toBe(true);
    } finally {
      if (before === undefined) delete process.env.MEMORY_ENABLED;
      else process.env.MEMORY_ENABLED = before;
    }
  });
});
