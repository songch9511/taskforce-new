import { describe, expect, it } from "vitest";

import type { Claim } from "@/lib/pipeline/resolve";

import { claimFromRow, claimToRow, storedReasons, toPgVector, type ClaimRow } from "./rows";

const claim: Claim = {
  id: "11111111-1111-4111-8111-111111111111",
  field: "due",
  value: "2025-09-26",
  occurredAt: new Date("2025-09-22T01:00:00.000Z"),
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
};

describe("claims 행 변환", () => {
  it("Claim → 행 → Claim이 되돌아온다", () => {
    const row = claimToRow(claim, "u1", "a1", { sourceId: "s1", quote: "금요일까지" });
    expect(row).toMatchObject({ user_id: "u1", action_id: "a1", source_id: "s1", quote: "금요일까지", origin: "source", occurred_at: "2025-09-22T01:00:00.000Z" });
    expect(claimFromRow(row)).toEqual({ ...claim, origin: "source", state: "active" });
  });

  it("disputed 상태를 저장하고 다시 읽는다", () => {
    const disputed = { ...claim, state: "disputed" as const };
    const row = claimToRow(disputed, "u1", "a1", { sourceId: "s1", quote: "금요일까지" });
    expect(row.state).toBe("disputed");
    expect(claimFromRow(row)).toEqual({ ...disputed, origin: "source" });
  });

  it("state가 빠진 예전 행은 active로 읽는다", () => {
    const { state, ...oldRow } = claimToRow(claim, "u1", "a1", { sourceId: "s1", quote: "금요일까지" });
    expect(state).toBe("active");
    const row: ClaimRow = oldRow;
    expect(claimFromRow(row)).toEqual({ ...claim, origin: "source", state: "active" });
  });

  it("사용자가 고친 값은 원문 없이 origin user", () => {
    expect(claimToRow({ ...claim, origin: "user" }, "u1", "a1", { sourceId: null, quote: null })).toMatchObject({ origin: "user", source_id: null, quote: null });
  });
});

describe("storedReasons", () => {
  it("판정에서 다시 계산되는 이유는 빼고 저장해 둔 이유만 남긴다", () => {
    expect(storedReasons(["판정 확인: NOT_MY_ACTION", "담당 확인", "기한 확인", "병합 확인 (55%)"])).toEqual(["판정 확인: NOT_MY_ACTION", "병합 확인 (55%)"]);
  });
});

it("pgvector 문자열", () => {
  expect(toPgVector([1, 0.5])).toBe("[1,0.5]");
});
