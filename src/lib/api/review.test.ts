import { afterEach, describe, expect, it, vi } from "vitest";

import {
  apiErrorV2Schema,
  returnSummaryClearResponseSchema,
  returnSummaryResponseSchema,
  reviewResponseSchema,
  suggestionResponseSchema,
  type ReturnSummaryResponse,
  type ReviewResponse,
  type Suggestion,
} from "./contract";
import { handleClearReturnSummary, handleDismissSuggestion, handleGetReturnSummary, handleGetReview, handleSnoozeSuggestion } from "./review";

// /api/v2/review · return-summary · suggestions 처리 (C3). 인증 · gate · 읽기/쓰기를 가짜로 두고 호출 수로 증명한다:
// gate 꺼짐에서는 인증도 DB도 부르지 않고(404), 인증 거부에서는 읽기도 쓰기도 부르지 않는다.

type User = { user: { id: string } };
const USER: User = { user: { id: "11111111-1111-4111-8111-111111111111" } };
const ID = "a5555555-5555-4555-8555-555555555555";
const NOW = new Date("2026-10-12T09:00:00Z");
const json = (body: unknown, method = "POST") => new Request("http://localhost/api/v2/x", { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const get = () => new Request("http://localhost/api/v2/x");

const review: ReviewResponse = {
  generated_at: NOW.toISOString(), complete: true, empty: true, sources: { decisions: "ok", suggestions: "ok" }, decisions: [], suggestions: [],
  suggestion_batch: { state: "ready", local_day: "2026-10-12", size: 3 },
};
const summary: ReturnSummaryResponse = {
  generated_at: NOW.toISOString(), since: null, baseline: "never_cleared", cursor: null, complete: true, empty: true, sources: { changes: "ok", decisions: "ok" }, items: [],
};
const suggestion: Suggestion = {
  id: ID, kind: "due_window", action_id: "a6666666-6666-4666-8666-666666666666", run_id: null, urgent: true, state: "snoozed", version: 2,
  snooze_until: "2026-10-13T00:00:00.000Z", offered_on: null, created_at: "2026-10-12T00:00:00.000Z", shown_at: null,
};

afterEach(() => vi.restoreAllMocks());

describe.each([
  ["GET review", (deps: object) => handleGetReview(get(), deps as never)],
  ["GET return-summary", (deps: object) => handleGetReturnSummary(get(), deps as never)],
])("%s", (_name, run) => {
  it("gate가 꺼져 있으면 404이고 인증도 읽기도 부르지 않는다", async () => {
    const authenticate = vi.fn();
    const load = vi.fn();
    const response = await run({ enabled: () => false, authenticate, load });
    expect(response.status).toBe(404);
    expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("not_found");
    expect(authenticate).not.toHaveBeenCalled();
    expect(load).not.toHaveBeenCalled();
  });

  it("인증하지 못하면 401이고 읽기를 부르지 않는다", async () => {
    const load = vi.fn();
    const response = await run({ enabled: () => true, authenticate: async () => null, load });
    expect(response.status).toBe(401);
    expect(load).not.toHaveBeenCalled();
  });

  it("읽기에 실패하면 500이고 오류 본문에 어떤 값도 담지 않는다 (오류 이름만 로그)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await run({ enabled: () => true, authenticate: async () => USER, load: async () => { throw new Error("select * from sources where text = '비밀 원문'"); } });
    expect(response.status).toBe(500);
    const text = await response.text();
    expect(text).not.toContain("비밀 원문");
    expect(JSON.stringify(log.mock.calls)).not.toContain("비밀 원문");
  });
});

describe("GET 성공", () => {
  it("200 + no-store + 계약 모양. 시계는 주입한 now", async () => {
    const load = vi.fn(async (user: User, now: Date) => (void user, void now, review));
    const response = await handleGetReview(get(), { enabled: () => true, authenticate: async () => USER, load, now: () => NOW });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(reviewResponseSchema.parse(await response.json())).toEqual(review);
    expect(load).toHaveBeenCalledWith(USER, NOW);

    const other = await handleGetReturnSummary(get(), { enabled: () => true, authenticate: async () => USER, load: async () => summary, now: () => NOW });
    expect(other.headers.get("cache-control")).toBe("no-store");
    expect(returnSummaryResponseSchema.parse(await other.json())).toEqual(summary);
  });
});

describe("POST return-summary/clear", () => {
  const cursor = "c1.AAAA";
  const deps = (clear: ReturnType<typeof vi.fn>) => ({ enabled: () => true, authenticate: async () => USER, clear }) as never;

  it("gate 꺼짐 404 · 인증 거부 401 · 본문 검증 400: 어느 경우에도 Clear를 부르지 않는다", async () => {
    const clear = vi.fn();
    expect((await handleClearReturnSummary(json({ cursor }), { enabled: () => false, authenticate: vi.fn(), clear } as never)).status).toBe(404);
    expect((await handleClearReturnSummary(json({ cursor }), { enabled: () => true, authenticate: async () => null, clear } as never)).status).toBe(401);
    for (const body of [{}, { cursor: "" }, { cursor: 1 }, { cursor, extra: 1 }, { cursor: "x".repeat(401) }]) {
      expect((await handleClearReturnSummary(json(body), deps(clear))).status, JSON.stringify(body)).toBe(400);
    }
    expect((await handleClearReturnSummary(new Request("http://localhost/x", { method: "POST", body: "{not json" }), deps(clear))).status).toBe(400);
    expect(clear).not.toHaveBeenCalled();
  });

  it("cleared → 200 { cleared_through, applied }: 재시도(applied false)도 성공이다", async () => {
    for (const applied of [true, false]) {
      const clear = vi.fn(async () => ({ status: "cleared" as const, applied, clearedThrough: "2026-10-12T00:00:00.000123Z" }));
      const response = await handleClearReturnSummary(json({ cursor }), deps(clear));
      expect(response.status).toBe(200);
      expect(returnSummaryClearResponseSchema.parse(await response.json())).toEqual({ cleared_through: "2026-10-12T00:00:00.000123Z", applied });
      expect(clear).toHaveBeenCalledWith(USER, cursor);
    }
  });

  it("stale → 409 conflict (읽음 처리하지 않았다), invalid → 400. 어느 쪽도 본문에 커서를 담지 않는다", async () => {
    const stale = await handleClearReturnSummary(json({ cursor }), deps(vi.fn(async () => ({ status: "stale" as const }))));
    expect(stale.status).toBe(409);
    expect(apiErrorV2Schema.parse(await stale.clone().json()).error.code).toBe("conflict");
    expect(await stale.text()).not.toContain(cursor);
    const invalid = await handleClearReturnSummary(json({ cursor }), deps(vi.fn(async () => ({ status: "invalid" as const }))));
    expect(invalid.status).toBe(400);
    expect(apiErrorV2Schema.parse(await invalid.json()).error.code).toBe("invalid_request");
  });

  it("쓰기 중 예외는 500이다 (자동 재시도 없음: 한 번만 부른다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const clear = vi.fn(async () => { throw new Error("boom"); });
    expect((await handleClearReturnSummary(json({ cursor }), deps(clear))).status).toBe(500);
    expect(clear).toHaveBeenCalledTimes(1);
  });
});

describe("POST suggestions/{id}/snooze · dismiss", () => {
  const until = new Date(NOW.getTime() + 3 * 3_600_000).toISOString();
  const snoozeDeps = (snooze: ReturnType<typeof vi.fn>) => ({ enabled: () => true, authenticate: async () => USER, snooze, maxDays: 366, now: () => NOW }) as never;
  const dismissDeps = (dismiss: ReturnType<typeof vi.fn>) => ({ enabled: () => true, authenticate: async () => USER, dismiss, now: () => NOW }) as never;

  it("gate 꺼짐 404 · 인증 거부 401 · id 모양 404 · 본문 400: 쓰기를 부르지 않는다", async () => {
    const snooze = vi.fn();
    const dismiss = vi.fn();
    expect((await handleSnoozeSuggestion(json({}), ID, { enabled: () => false, authenticate: vi.fn(), snooze, maxDays: 366 } as never)).status).toBe(404);
    expect((await handleDismissSuggestion(json({}), ID, { enabled: () => false, authenticate: vi.fn(), dismiss } as never)).status).toBe(404);
    expect((await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: until }), ID, { enabled: () => true, authenticate: async () => null, snooze, maxDays: 366 } as never)).status).toBe(401);
    expect((await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: until }), "not-a-uuid", snoozeDeps(snooze))).status).toBe(404);
    expect((await handleDismissSuggestion(json({ expected_version: 1, scope: "this" }), "../x", dismissDeps(dismiss))).status).toBe(404);
    for (const body of [{}, { expected_version: 0, snooze_until: until }, { expected_version: 1 }, { expected_version: 1, snooze_until: "내일" }, { expected_version: 1, snooze_until: until, x: 1 }]) {
      expect((await handleSnoozeSuggestion(json(body), ID, snoozeDeps(snooze))).status, JSON.stringify(body)).toBe(400);
    }
    for (const body of [{}, { expected_version: 1 }, { expected_version: 1, scope: "forever" }, { scope: "this" }, { expected_version: 1, scope: "this", x: 1 }]) {
      expect((await handleDismissSuggestion(json(body), ID, dismissDeps(dismiss))).status, JSON.stringify(body)).toBe(400);
    }
    expect(snooze).not.toHaveBeenCalled();
    expect(dismiss).not.toHaveBeenCalled();
  });

  it("snooze 시점은 사용자가 고른 미래여야 한다: 지금 · 과거 · 366일 넘게 먼 시점은 400 (서버는 시점을 정하지 않는다)", async () => {
    const snooze = vi.fn();
    for (const when of [NOW.toISOString(), new Date(NOW.getTime() - 1000).toISOString(), new Date(NOW.getTime() + 367 * 86_400_000).toISOString()]) {
      expect((await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: when }), ID, snoozeDeps(snooze))).status, when).toBe(400);
    }
    expect(snooze).not.toHaveBeenCalled();
    const edge = new Date(NOW.getTime() + 366 * 86_400_000).toISOString();
    snooze.mockResolvedValueOnce({ status: "ok", suggestion });
    expect((await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: edge }), ID, snoozeDeps(snooze))).status).toBe(200);
  });

  it("ok → 200 { suggestion } · not_found 404 · conflict 409 · invalid 400", async () => {
    const snooze = vi.fn()
      .mockResolvedValueOnce({ status: "ok", suggestion })
      .mockResolvedValueOnce({ status: "not_found" })
      .mockResolvedValueOnce({ status: "conflict" })
      .mockResolvedValueOnce({ status: "invalid" });
    const statuses: number[] = [];
    for (let i = 0; i < 4; i++) {
      const response = await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: until }), ID, snoozeDeps(snooze));
      statuses.push(response.status);
      if (response.status === 200) expect(suggestionResponseSchema.parse(await response.json())).toEqual({ suggestion });
      else expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe({ 404: "not_found", 409: "conflict", 400: "invalid_request" }[response.status]);
    }
    expect(statuses).toEqual([200, 404, 409, 400]);
    expect(snooze).toHaveBeenNthCalledWith(1, USER, ID, 1, new Date(until), NOW);

    const dismiss = vi.fn().mockResolvedValueOnce({ status: "ok", suggestion: { ...suggestion, state: "dismissed" } }).mockResolvedValueOnce({ status: "conflict" });
    expect((await handleDismissSuggestion(json({ expected_version: 3, scope: "topic" }), ID, dismissDeps(dismiss))).status).toBe(200);
    expect((await handleDismissSuggestion(json({ expected_version: 3, scope: "topic" }), ID, dismissDeps(dismiss))).status).toBe(409);
    expect(dismiss).toHaveBeenNthCalledWith(1, USER, ID, 3, "topic", NOW);
  });

  it("쓰기 중 예외는 500이고 자동 재시도하지 않는다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const snooze = vi.fn(async () => { throw new Error("boom"); });
    expect((await handleSnoozeSuggestion(json({ expected_version: 1, snooze_until: until }), ID, snoozeDeps(snooze))).status).toBe(500);
    expect(snooze).toHaveBeenCalledTimes(1);
  });
});
