import { reconcileAiSpend } from "@/lib/ai/budget";
vi.mock("@/lib/ai/budget", () => ({ reconcileAiSpend: vi.fn() }));
import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// OA D1d: 대기 메시지 만료(conversation_expire_agent_messages)도 이 admin의 rpc로 돈다
const mocks = vi.hoisted(() => {
  const rpc = vi.fn();
  return { sweep: vi.fn(), wakeRun: vi.fn(), supabaseExecutionStore: vi.fn(() => ({ store: true })), rpc, admin: { admin: true, rpc } };
});

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => mocks.admin) }));
vi.mock("@/lib/execution/store", () => ({ supabaseExecutionStore: mocks.supabaseExecutionStore }));
vi.mock("@/lib/execution/sweep", () => ({ sweep: mocks.sweep }));
vi.mock("@/lib/execution/wake", () => ({ wakeRun: mocks.wakeRun }));

import { GET } from "./route";

const AI_SPEND = { attempted: 3, settled: 1, deferred: 2, errors: 0 };
const RESULT = { expired: 1, reconciled: 0, released: 0, woken: 2, wake_failed: 0, errors: 0 };
const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.test/api/cron/execution-sweep", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("EXECUTION_ENABLED", "true");
  mocks.sweep.mockResolvedValue(RESULT);
  vi.mocked(reconcileAiSpend).mockResolvedValue(AI_SPEND);
  mocks.rpc.mockReturnValue({ throwOnError: async () => ({ data: 0, error: null }) });
  vi.spyOn(console, "info").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("GET /api/cron/execution-sweep", () => {
  it("vercel.json에 1분마다 등록돼 있다", () => {
    const vercel = JSON.parse(readFileSync(path.resolve(__dirname, "../../../../../vercel.json"), "utf8")) as { crons: { path: string; schedule: string }[] };
    expect(vercel.crons).toContainEqual({ path: "/api/cron/execution-sweep", schedule: "* * * * *" });
  });

  it("CRON_SECRET이 맞지 않으면 401", async () => {
    expect((await cron("Bearer wrong!")).status).toBe(401);
    expect(mocks.sweep).not.toHaveBeenCalled();
    expect(reconcileAiSpend).not.toHaveBeenCalled();
  });

  it("실행 플래그가 꺼져도 공통 원가를 확인하고 실행 sweep은 생략", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "");
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ enabled: false });
    expect(mocks.sweep).not.toHaveBeenCalled();
    expect(mocks.supabaseExecutionStore).not.toHaveBeenCalled();
    expect(reconcileAiSpend).toHaveBeenCalledWith(mocks.admin);
  });

  it("켜져 있으면 sweep 결과(숫자만)를 돌려주고 로그 한 줄", async () => {
    const response = await cron();
    expect(await response.json()).toEqual({ enabled: true, ...RESULT });
    expect(console.info).toHaveBeenCalledWith(JSON.stringify({ event: "execution_sweep", ...RESULT, ai_spend: AI_SPEND }));
    // 깨우기는 자기 호출(wakeRun)로 맡긴다
    const [{ wake }] = mocks.sweep.mock.calls[0] as [{ wake: (id: string) => Promise<boolean> }];
    await wake("r1");
    expect(mocks.wakeRun).toHaveBeenCalledWith("r1");
  });

  it("실패한 단계가 있으면 오류 로그로 남긴다 (응답은 200, 다음 분에 다시 돈다)", async () => {
    mocks.sweep.mockResolvedValueOnce({ ...RESULT, errors: 1 });
    expect((await cron()).status).toBe(200);
    expect(console.error).toHaveBeenCalledWith(JSON.stringify({ event: "execution_sweep", ...RESULT, errors: 1, ai_spend: AI_SPEND }));
  });
});


it.each([true, false])("logs budget errors when execution enabled=%s and retains scheduled retry HTTP 200", async (enabled) => {
  vi.stubEnv("EXECUTION_ENABLED", String(enabled));
  const aiSpend = { attempted: 3, settled: 0, deferred: 1, errors: 2 };
  vi.mocked(reconcileAiSpend).mockResolvedValueOnce(aiSpend);
  const response = await cron();
  expect(response.status).toBe(200);
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify(enabled
    ? { event: "execution_sweep", ...RESULT, ai_spend: aiSpend }
    : { event: "execution_sweep", enabled: false, ai_spend: aiSpend }));
});


it("keeps startup infrastructure failures observable and HTTP 500 for retry", async () => {
  const aiSpend = { attempted: 0, settled: 0, deferred: 0, errors: 1 };
  vi.mocked(reconcileAiSpend).mockResolvedValueOnce(aiSpend);
  expect((await cron()).status).toBe(500);
  expect(mocks.sweep).not.toHaveBeenCalled();
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "execution_sweep", ai_spend: aiSpend }));
});


// ─── OA D1d: 대기 메시지 만료 (계약 2.13 · OD-18) ───
const expiryCalls = () => mocks.rpc.mock.calls.filter(([name]) => name === "conversation_expire_agent_messages");
const expiring = (...counts: number[]) => {
  let call = 0;
  mocks.rpc.mockImplementation(() => ({ throwOnError: async () => ({ data: counts[Math.min(call++, counts.length - 1)], error: null }) }));
};

describe("대기 메시지 만료 (conversation_expire_agent_messages)", () => {
  it("실행 플래그가 꺼져 있어도 돈다 (조기 반환 앞): 대기 메시지가 24시간 뒤에도 자동 전달 대상으로 남지 않는다", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "");
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ enabled: false });
    expect(expiryCalls()).toHaveLength(1);
    expect(mocks.sweep).not.toHaveBeenCalled();
  });

  it("켜져 있어도 한 번 돌고, 기존 sweep과 응답 본문은 그대로다. 로그는 숫자만", async () => {
    expiring(7);
    const response = await cron();
    expect(await response.json()).toEqual({ enabled: true, ...RESULT });
    expect(expiryCalls()).toHaveLength(1);
    expect(expiryCalls()[0][1]).toEqual({ p_now: expect.stringMatching(/^\d{4}-\d\d-\d\dT/) });
    expect(console.info).toHaveBeenCalledWith(JSON.stringify({ event: "agent_message_expiry", expired: 7, rounds: 1 }));
  });

  it("2,500행이면 1,000 · 1,000 · 500으로 세 번 돈다 (한 번의 cron에서 최대 10회)", async () => {
    expiring(1000, 1000, 500);
    await cron();
    expect(expiryCalls()).toHaveLength(3);
    mocks.rpc.mockClear();
    expiring(1000);
    await cron();
    expect(expiryCalls()).toHaveLength(10);
  });

  it("실패해도 응답 본문 · 상태 코드는 그대로이고 기존 sweep도 이어 돈다 (로그에는 이벤트 이름 · 오류 이름만)", async () => {
    mocks.rpc.mockImplementation(() => ({ throwOnError: async () => { throw Object.assign(new Error("secret"), { name: "PostgrestError" }); } }));
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ enabled: true, ...RESULT });
    expect(mocks.sweep).toHaveBeenCalledTimes(1);
    expect(console.error).toHaveBeenCalledWith(JSON.stringify({ event: "agent_message_expiry_failed", error: "PostgrestError" }));
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("secret");
  });

  it("인증 실패(401)에서는 돌지 않는다", async () => {
    expect((await cron("Bearer wrong!")).status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
