import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { RunActionNotFoundError } from "@/lib/execution/types";

import { CONSENT_REQUIRED_MESSAGE } from "./consent";
import { createRunResponseSchema, creditsResponseSchema, stopRunResponseSchema, type RunSummary } from "./contract";
import { EXECUTION_UNAVAILABLE_MESSAGE, handleCreateRun, handleCredits, handleStopRun, type CreateRunDeps } from "./runs";

type User = { id: string };
const USER: User = { id: "u1" };
const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const RUN_ID = "22222222-2222-4222-8222-222222222222";
const REQUEST_TEXT = "비밀-요청-글 견적 회신 메일 초안 써 줘";
const RUN: RunSummary = {
  id: RUN_ID,
  action_id: ACTION_ID,
  goal: "draft",
  state: "queued",
  hold_reason: null,
  outcome: null,
  budget_credits: null,
  created_at: "2026-10-02T00:00:00.000Z",
};

function createDeps(overrides: Partial<CreateRunDeps<User>> = {}) {
  return {
    enabled: vi.fn(() => true),
    authenticate: vi.fn(async () => USER as User | null),
    isActor: vi.fn(async () => true),
    globallyBlocked: vi.fn(async () => false),
    hasConsent: vi.fn(async () => true),
    actionOpen: vi.fn(async () => true),
    rateLimit: vi.fn(async () => null as Date | null),
    createRun: vi.fn(async () => RUN_ID),
    loadRun: vi.fn(async () => RUN as RunSummary | null),
    schedule: vi.fn(),
    now: () => new Date("2026-10-02T00:00:00Z"),
    ...overrides,
  } satisfies CreateRunDeps<User>;
}

const post = (body: unknown = { action_id: ACTION_ID, goal: "draft", request: REQUEST_TEXT }) =>
  new Request("https://api.example.test/api/v1/runs", { method: "POST", body: JSON.stringify(body) });

beforeEach(() => vi.spyOn(console, "error").mockImplementation(() => {}));
afterEach(() => vi.restoreAllMocks());

describe("POST /api/v1/runs", () => {
  it("run을 만들고 202 { run }, 첫 단계는 응답 뒤(schedule)", async () => {
    const deps = createDeps();
    const response = await handleCreateRun(post({ action_id: ACTION_ID, goal: "draft", request: `  ${REQUEST_TEXT}  `, budget_credits: 50 }), deps);
    expect(response.status).toBe(202);
    expect(createRunResponseSchema.parse(await response.json())).toEqual({ run: RUN });
    expect(deps.createRun).toHaveBeenCalledWith(USER, { action_id: ACTION_ID, goal: "draft", request: REQUEST_TEXT, budget_credits: 50 });
    expect(deps.schedule).toHaveBeenCalledWith(RUN_ID);
  });

  it("기능 플래그가 꺼져 있으면 로그인보다 먼저 404 (존재를 드러내지 않는다)", async () => {
    const deps = createDeps({ enabled: vi.fn(() => false) });
    const response = await handleCreateRun(post(), deps);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: { code: "not_found", message: EXECUTION_UNAVAILABLE_MESSAGE } });
    expect(deps.authenticate).not.toHaveBeenCalled();
    expect(deps.createRun).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401, 실행 주체 허용 목록 밖이면 404", async () => {
    expect((await handleCreateRun(post(), createDeps({ authenticate: vi.fn(async () => null) }))).status).toBe(401);
    const outside = createDeps({ isActor: vi.fn(async () => false) });
    const response = await handleCreateRun(post(), outside);
    expect(response.status).toBe(404);
    expect(outside.createRun).not.toHaveBeenCalled();
    expect(outside.rateLimit).not.toHaveBeenCalled();
  });

  it("차단 스위치가 전체를 막고 있으면 404 (막힌 채 기다릴 run을 만들지 않는다)", async () => {
    const deps = createDeps({ globallyBlocked: vi.fn(async () => true) });
    expect((await handleCreateRun(post(), deps)).status).toBe(404);
    expect(deps.createRun).not.toHaveBeenCalled();
  });

  it("외부 AI 처리 동의 전이면 409 (기존 consentRequired)", async () => {
    const deps = createDeps({ hasConsent: vi.fn(async () => false) });
    const response = await handleCreateRun(post(), deps);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: { code: "conflict", message: CONSENT_REQUIRED_MESSAGE } });
    expect(deps.rateLimit).not.toHaveBeenCalled();
  });

  it("열린 내 Action이 아니면 404이고 횟수에 세지 않는다. create_run이 다시 거절해도 404", async () => {
    const closed = createDeps({ actionOpen: vi.fn(async () => false) });
    expect((await handleCreateRun(post(), closed)).status).toBe(404);
    expect(closed.rateLimit).not.toHaveBeenCalled();
    const raced = createDeps({
      createRun: vi.fn(async () => {
        throw new RunActionNotFoundError();
      }),
    });
    expect((await handleCreateRun(post(), raced)).status).toBe(404);
    expect(raced.schedule).not.toHaveBeenCalled();
  });

  it("횟수 한도에 차면 429와 Retry-After, run을 만들지 않는다", async () => {
    const deps = createDeps({ rateLimit: vi.fn(async () => new Date("2026-10-02T00:05:00Z")) });
    const response = await handleCreateRun(post(), deps);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("300");
    expect(deps.createRun).not.toHaveBeenCalled();
  });

  it("본문 검증: goal은 draft만, request 1–2000자, budget_credits는 초안 예약 이상의 정수", async () => {
    for (const body of [
      { action_id: ACTION_ID, goal: "send", request: "보내 줘" },
      { action_id: ACTION_ID, goal: "draft", request: "   " },
      { action_id: ACTION_ID, goal: "draft", request: "가".repeat(2001) },
      { action_id: ACTION_ID, goal: "draft", request: "초안", budget_credits: 0 },
      // 초안 한 건의 예약(20)보다 작은 예산은 초안을 한 번도 부르지 못한다
      { action_id: ACTION_ID, goal: "draft", request: "초안", budget_credits: 19 },
      { action_id: "not-a-uuid", goal: "draft", request: "초안" },
    ]) {
      expect((await handleCreateRun(post(body), createDeps())).status).toBe(400);
    }
  });

  it("저장하지 못하면 500, 로그에 요청 글을 남기지 않는다", async () => {
    const deps = createDeps({
      createRun: vi.fn(async () => {
        throw new Error("connection reset");
      }),
    });
    expect((await handleCreateRun(post(), deps)).status).toBe(500);
    for (const call of vi.mocked(console.error).mock.calls) expect(call.join(" ")).not.toContain("비밀-요청-글");
  });
});

describe("POST /api/v1/runs/:id/stop", () => {
  const stopDeps = (overrides: Partial<Parameters<typeof handleStopRun<User>>[2]> = {}) => ({
    enabled: () => true,
    authenticate: async () => USER as User | null,
    isActor: async () => true,
    stopRun: vi.fn(async () => "stopped" as string | null),
    loadRun: vi.fn(async () => ({ ...RUN, state: "stopped" as const }) as RunSummary | null),
    ...overrides,
  });
  const stop = (id = RUN_ID) => new Request(`https://api.example.test/api/v1/runs/${id}/stop`, { method: "POST" });

  it("멈추고 200 { run }. 이미 끝난 run은 그 상태 그대로 200", async () => {
    const deps = stopDeps();
    const response = await handleStopRun(stop(), RUN_ID, deps);
    expect(response.status).toBe(200);
    expect(stopRunResponseSchema.parse(await response.json()).run.state).toBe("stopped");
    expect(deps.stopRun).toHaveBeenCalledWith(USER, RUN_ID);

    const done = stopDeps({ stopRun: vi.fn(async () => "done"), loadRun: vi.fn(async () => ({ ...RUN, state: "done" as const, outcome: "draft_ready" as const })) });
    const again = await handleStopRun(stop(), RUN_ID, done);
    expect(again.status).toBe(200);
    expect(((await again.json()) as { run: RunSummary }).run.state).toBe("done");
  });

  it("없거나 남의 run · UUID가 아니면 404, 플래그 꺼짐 · 허용 목록 밖도 404", async () => {
    expect((await handleStopRun(stop(), RUN_ID, stopDeps({ stopRun: vi.fn(async () => null) }))).status).toBe(404);
    const bad = stopDeps();
    expect((await handleStopRun(stop("x"), "x", bad)).status).toBe(404);
    expect(bad.stopRun).not.toHaveBeenCalled();
    expect((await handleStopRun(stop(), RUN_ID, stopDeps({ enabled: () => false }))).status).toBe(404);
    expect((await handleStopRun(stop(), RUN_ID, stopDeps({ isActor: async () => false }))).status).toBe(404);
  });
});

describe("GET /api/v1/credits", () => {
  it("서버 합계를 돌려준다. 플래그 꺼짐 · 허용 목록 밖은 404, 로그인 전 401", async () => {
    const credits = vi.fn(async () => ({ available: 80, reserved: 20, rate_version: "c3-v1" }));
    const base = { enabled: () => true, authenticate: async () => USER as User | null, isActor: async () => true, credits };
    const request = new Request("https://api.example.test/api/v1/credits");
    const response = await handleCredits(request, base);
    expect(response.status).toBe(200);
    expect(creditsResponseSchema.parse(await response.json())).toEqual({ available: 80, reserved: 20, rate_version: "c3-v1" });
    expect((await handleCredits(request, { ...base, enabled: () => false })).status).toBe(404);
    expect((await handleCredits(request, { ...base, isActor: async () => false })).status).toBe(404);
    expect((await handleCredits(request, { ...base, authenticate: async () => null })).status).toBe(401);
  });
});
