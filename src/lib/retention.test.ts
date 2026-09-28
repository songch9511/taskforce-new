import { describe, expect, it } from "vitest";

import { RAW_TEXT_RETENTION_DAYS, retentionCutoff } from "./retention";

describe("retentionCutoff", () => {
  it("원문은 90일 보관한다", () => {
    expect(RAW_TEXT_RETENTION_DAYS).toBe(90);
    expect(retentionCutoff(new Date("2026-12-26T00:00:00Z"))).toEqual(new Date("2026-09-27T00:00:00Z"));
  });
});
