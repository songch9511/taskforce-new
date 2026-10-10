import { describe, expect, it } from "vitest";

import type { MemoryItem } from "@/lib/api/contract";

import { isStale, planConfirm, planEdit, sameStatement } from "./memory-edit";

// 기억 확인 · 정정의 순수 규칙 (B3). 정책 보류: Slack 원문에서 온 후보의 확인(a) · 글이 지워진 항목의 확인(c). 범위 변경(b)은 DB 함수가 거절한다(tests/db/memory-writes.scenarios.ts).

const row = (overrides: Partial<MemoryItem> = {}): MemoryItem => ({
  id: "aaaaaaaa-0000-4000-8000-000000000001",
  kind: "fact",
  scope_kind: "context",
  context_id: "cccccccc-0000-4000-8000-000000000001",
  action_id: null,
  person_id: null,
  agent_adapter: null,
  subject: "launch day",
  statement: "출시는 목요일인 듯",
  value: { day: "thu" },
  origin: "inferred",
  source_ref: { source_id: "bbbbbbbb-0000-4000-8000-000000000001", quote: "목요일" },
  observed_at: "2026-10-10T01:00:00.000Z",
  valid_from: "2026-10-01T00:00:00.000Z",
  valid_until: null,
  superseded_by: null,
  superseded_at: null,
  revoked_at: null,
  confidence: 0.6,
  source_purged: false,
  version: 3,
  created_at: "2026-10-10T01:00:00.000Z",
  updated_at: "2026-10-10T01:00:00.000Z",
  ...overrides,
});

describe("낡은 요청 (isStale)", () => {
  it("version이 다르거나 이미 정정 · 잊은 항목이면 낡았다", () => {
    expect(isStale(row(), 3)).toBe(false);
    expect(isStale(row(), 2)).toBe(true);
    expect(isStale(row({ superseded_at: "2026-10-10T02:00:00Z" }), 3)).toBe(true);
    expect(isStale(row({ revoked_at: "2026-10-10T02:00:00Z" }), 3)).toBe(true);
  });
});

describe("확인 (planConfirm)", () => {
  it("version이 맞는 추정 후보는 확인된다", () => {
    expect(planConfirm(row(), 3, false)).toEqual({ ok: true });
  });

  it("낡은 요청은 conflict — 정책 거절보다 먼저 (다시 읽으면 상태가 바뀌어 있다)", () => {
    expect(planConfirm(row(), 2, false)).toEqual({ ok: false, reason: "conflict" });
    expect(planConfirm(row({ superseded_at: "2026-10-10T02:00:00Z" }), 3, true)).toEqual({ ok: false, reason: "conflict" });
    expect(planConfirm(row({ revoked_at: "2026-10-10T02:00:00Z" }), 3, false)).toEqual({ ok: false, reason: "conflict" });
  });

  it("정책 보류 (c): 추정이 아닌 항목 · 글이 지워진 항목은 확인할 수 없다", () => {
    expect(planConfirm(row({ origin: "explicit", confidence: null }), 3, false)).toEqual({ ok: false, reason: "unavailable" });
    expect(planConfirm(row({ origin: "observed", confidence: null }), 3, false)).toEqual({ ok: false, reason: "unavailable" });
    expect(planConfirm(row({ origin: "observed", confidence: null, statement: "", source_purged: true }), 3, false)).toEqual({ ok: false, reason: "unavailable" });
  });

  it("정책 보류 (a): Slack 원문에서 온 후보는 확인할 수 없다", () => {
    expect(planConfirm(row(), 3, true)).toEqual({ ok: false, reason: "unavailable" });
  });
});

describe("정정 (planEdit)", () => {
  const request = (overrides: Record<string, unknown> = {}) => ({ expected_version: 3, statement: "출시는 금요일", ...overrides }) as Parameters<typeof planEdit>[1];

  it("요청에 없는 값(value · valid_from · valid_until)은 옛 행에서 이어받고, 있으면 바꾸고 null이면 비운다", () => {
    const old = row({ origin: "explicit", confidence: null, valid_until: "2026-12-31T00:00:00.000Z" });
    expect(planEdit(old, request(), false)).toEqual({
      ok: true,
      write: { statement: "출시는 금요일", value: { day: "thu" }, valid_from: "2026-10-01T00:00:00.000Z", valid_until: "2026-12-31T00:00:00.000Z" },
    });
    expect(planEdit(old, request({ value: { day: "fri" }, valid_from: null, valid_until: "2026-11-01T00:00:00Z" }), false)).toEqual({
      ok: true,
      write: { statement: "출시는 금요일", value: { day: "fri" }, valid_from: null, valid_until: "2026-11-01T00:00:00Z" },
    });
  });

  it("낡은 요청은 conflict, 합친 유효 구간이 거꾸로면 invalid (옛 행에서 이어받은 값과 합쳐 본다)", () => {
    expect(planEdit(row(), request({ expected_version: 1 }), false)).toEqual({ ok: false, reason: "conflict" });
    expect(planEdit(row({ revoked_at: "2026-10-10T02:00:00Z" }), request(), false)).toEqual({ ok: false, reason: "conflict" });
    expect(planEdit(row(), request({ valid_until: "2026-09-01T00:00:00Z" }), false)).toEqual({ ok: false, reason: "invalid" });
    expect(planEdit(row(), request({ valid_from: "2026-12-01T00:00:00Z", valid_until: "2026-11-01T00:00:00Z" }), false)).toEqual({ ok: false, reason: "invalid" });
  });

  it("정책 보류 (a): Slack에서 온 후보 · observed는 글자 그대로 정정하면 확인의 우회라 거절하고, 새 글이면 옛 값을 잇지 않는다", () => {
    for (const statement of ["출시는 목요일인 듯", "  출시는   목요일인 듯  ", "ＡＢＣ" /* 다른 글 */]) {
      const plan = planEdit(row(), request({ statement }), true);
      expect(plan.ok, statement).toBe(statement === "ＡＢＣ");
    }
    expect(planEdit(row(), request({ statement: "출시는 이번 주 목요일" }), true)).toEqual({
      ok: true,
      write: { statement: "출시는 이번 주 목요일", value: {}, valid_from: null, valid_until: null },
    });
    expect(planEdit(row(), request({ statement: "출시는 이번 주 목요일", value: { day: "thu" }, valid_from: "2026-10-05T00:00:00Z" }), true)).toEqual({
      ok: true,
      write: { statement: "출시는 이번 주 목요일", value: { day: "thu" }, valid_from: "2026-10-05T00:00:00Z", valid_until: null },
    });
    const observed = row({ origin: "observed", confidence: null });
    expect(planEdit(observed, request({ statement: "출시는 목요일인 듯" }), true)).toEqual({ ok: false, reason: "unavailable" });
  });

  it("Slack에서 온 explicit(이미 확인한 것)은 글자 그대로여도 고칠 수 있다 · Slack이 아닌 후보는 이어받는다", () => {
    const explicit = row({ origin: "explicit", confidence: null });
    expect(planEdit(explicit, request({ statement: "출시는 목요일인 듯" }), false).ok).toBe(true);
    expect(planEdit(row(), request({ statement: "출시는 목요일인 듯" }), false)).toMatchObject({ ok: true, write: { value: { day: "thu" } } });
  });
});

describe("같은 글 (sameStatement)", () => {
  it("NFKC · 소문자 · 공백 하나로 접어 견준다", () => {
    expect(sameStatement("Launch is Thursday", " launch   IS\tthursday ")).toBe(true);
    expect(sameStatement("ＬＡＵＮＣＨ", "launch")).toBe(true);
    expect(sameStatement("출시는 목요일", "출시는 금요일")).toBe(false);
    expect(sameStatement("", "x")).toBe(false);
  });
});
