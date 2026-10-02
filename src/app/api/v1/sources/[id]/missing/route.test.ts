import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError, INTERACTIVE_MAX_DURATION_S, RESPONSE_MARGIN_MS } from "@/lib/ai/deadline";
import { processDepsFromEnv, reportMissing } from "@/lib/sources/process";

import { maxDuration, POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true), loadProfile: vi.fn(async () => null) }));
vi.mock("@/lib/sources/process", () => ({
  processDepsFromEnv: vi.fn(() => ({ deps: "missing" })),
  reportMissing: vi.fn(async () => ({ status: "created", action: { id: "action-1" }, stage: "not_extracted" })),
}));

const SOURCE_ID = "11111111-1111-4111-8111-111111111111";
const QUOTE = "금요일까지 견적서 정리해서 드릴게요";

// 인증된 사용자의 원문 한 건 (사용자 권한으로 읽은 것). 종류는 테스트가 바꾼다
const row = vi.hoisted(() => ({
  id: "11111111-1111-4111-8111-111111111111",
  kind: "meeting",
  raw_text: "나: 금요일까지 견적서 정리해서 드릴게요.",
  occurred_at: "2026-09-28T01:00:00.000Z",
  participants: null,
  processing_status: "done",
  raw_text_purged_at: null,
  raw_text_purge_reason: null,
}));
vi.mock("@/lib/api/auth", () => {
  const query = { select: () => query, eq: () => query, maybeSingle: async () => ({ data: row, error: null }) };
  return {
    authenticateRequest: vi.fn(async () => ({ user: { id: "u1", name: "나", email: null }, supabase: { from: () => query } })),
  };
});

const report = () =>
  POST(new Request(`https://api.example.dev/api/v1/sources/${SOURCE_ID}/missing`, { method: "POST", body: JSON.stringify({ quote: QUOTE }) }), {
    params: Promise.resolve({ id: SOURCE_ID }),
  });

beforeEach(() => {
  vi.clearAllMocks();
  row.kind = "meeting";
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /api/v1/sources/:id/missing", () => {
  it("실행 한도는 사용자가 기다리는 요청의 한도와 같다 (앱도 그만큼 기다린다)", () => {
    expect(maxDuration).toBe(INTERACTIVE_MAX_DURATION_S);
  });

  it("실행 receipt · 할 일 DB 항목은 원문이 아니라 신고할 수 없다 (모델을 부르지 않는다)", async () => {
    for (const kind of ["execution", "task"]) {
      row.kind = kind;
      const response = await report();
      expect(response.status, kind).toBe(400);
      expect(((await response.json()) as { error: { code: string } }).error.code).toBe("invalid_request");
    }
    expect(reportMissing).not.toHaveBeenCalled();
  });

  it("요청을 받자마자 정한 마감과 그 마감으로 만든 deps로 신고를 처리한다", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const response = await report();
    expect(response.status).toBe(200);
    const deadline = 1_000_000 + INTERACTIVE_MAX_DURATION_S * 1000 - RESPONSE_MARGIN_MS;
    expect(processDepsFromEnv).toHaveBeenCalledWith(deadline);
    const [admin, source, input, sentDeadline, deps] = vi.mocked(reportMissing).mock.calls[0];
    expect(admin).toEqual({ admin: true });
    expect(source).toEqual({ id: SOURCE_ID, userId: "u1", processingStatus: "done" });
    expect(input.quote).toBe(QUOTE);
    expect(sentDeadline).toBe(deadline);
    expect(deps).toEqual({ deps: "missing" });
  });

  it("마감 안에 끝내지 못하면 500과 함께 셀 수 있는 deadline_exceeded 한 줄을 남긴다 (구절은 남기지 않는다)", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(reportMissing).mockImplementationOnce(async () => {
      now.mockReturnValue(1_000_000 + 45_000);
      throw new DeadlineExceededError("lock", "병합 대기 시간 초과");
    });
    const response = await report();
    expect(response.status).toBe(500);
    const marker = log.mock.calls.find(([line]) => typeof line === "string" && line.includes("deadline_exceeded"));
    expect(JSON.parse(marker![0] as string)).toEqual({ event: "deadline_exceeded", route: "missing", stage: "lock", elapsed_ms: 45_000 });
    expect(JSON.stringify(log.mock.calls)).not.toContain(QUOTE);
  });
});
