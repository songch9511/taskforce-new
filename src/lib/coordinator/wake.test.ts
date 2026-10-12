import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createAdminClient: vi.fn(() => ({ admin: true })),
  coordinatorPass: vi.fn(),
  supabaseCoordinatorStore: vi.fn(() => ({ store: true })),
  supabaseCoordinatorReads: vi.fn(() => ({ reads: true })),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.createAdminClient }));
vi.mock("./store", () => ({ supabaseCoordinatorStore: mocks.supabaseCoordinatorStore }));
vi.mock("./reads", () => ({ supabaseCoordinatorReads: mocks.supabaseCoordinatorReads }));
vi.mock("./sweep", () => ({ coordinatorPass: mocks.coordinatorPass }));
vi.mock("@/lib/execution/wake", () => ({ wakeOrigin: (env: Record<string, string | undefined>) => env.EXECUTION_WAKE_ORIGIN ?? null }));

import { advanceCoordinator, COORDINATOR_ADVANCE_PATH, wakeCoordinator } from "./wake";

const ON = { COORDINATOR_ENABLED: "true", CRON_SECRET: "s3cret", EXECUTION_WAKE_ORIGIN: "https://taskforce.example.test" };

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "info").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

describe("깨우기 wakeCoordinator: 기본 off → 네트워크 호출 0", () => {
  it("플래그가 꺼져 있거나(기본) 정확히 true가 아니면 주소 · 비밀값이 있어도 부르지 않는다", async () => {
    const fetchMock = vi.fn();
    for (const flag of [undefined, "", "false", "1", "TRUE", " true "]) {
      expect(await wakeCoordinator({ env: { ...ON, COORDINATOR_ENABLED: flag }, fetch: fetchMock as never })).toBe(false);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("켜져 있어도 주소나 비밀값을 모르면 부르지 않는다 (sweep이 이어 간다). 요청 헤더로 주소를 만들지 않는다", async () => {
    const fetchMock = vi.fn();
    expect(await wakeCoordinator({ env: { ...ON, EXECUTION_WAKE_ORIGIN: undefined }, fetch: fetchMock as never })).toBe(false);
    expect(await wakeCoordinator({ env: { ...ON, CRON_SECRET: "" }, fetch: fetchMock as never })).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("정해 둔 주소의 route에 CRON_SECRET을 실어 POST하고 202면 true", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 202 }));
    expect(await wakeCoordinator({ env: ON, fetch: fetchMock as never })).toBe(true);
    const [url, init] = fetchMock.mock.calls[0] as unknown as [URL, RequestInit];
    expect(url.toString()).toBe(`https://taskforce.example.test${COORDINATOR_ADVANCE_PATH}`);
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>).authorization).toBe("Bearer s3cret");
    expect(init.body).toBe("{}");
  });

  it("실패해도 던지지 않는다: 202가 아닌 응답 · 네트워크 오류 · 시간 초과는 false (1분 sweep이 다시 깨운다). 로그에 비밀값 · 본문이 없다", async () => {
    expect(await wakeCoordinator({ env: ON, fetch: (async () => new Response(null, { status: 500 })) as never })).toBe(false);
    expect(await wakeCoordinator({ env: ON, fetch: (async () => { throw new TypeError("fetch failed"); }) as never })).toBe(false);
    expect(await wakeCoordinator({ env: ON, fetch: (async () => { throw new DOMException("timeout", "TimeoutError"); }) as never })).toBe(false);
    const logs = vi.mocked(console.error).mock.calls.flat().join("\n");
    expect(logs).not.toContain("s3cret");
    expect(logs).toContain("coordinator_wake_failed");
  });

  it("같은 깨우기를 연달아 여러 번 보내도(중복) 매번 독립이다: 부른 쪽은 상태를 들고 있지 않는다", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 202 }));
    const results = await Promise.all([wakeCoordinator({ env: ON, fetch: fetchMock as never }), wakeCoordinator({ env: ON, fetch: fetchMock as never })]);
    expect(results).toEqual([true, true]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("advanceCoordinator: 한 번 돌고 더 남았으면 깨운다", () => {
  const pass = (more: boolean, errors = 0) => ({ timers: 0, recovered: 0, errors, run: { claimed: 1, finished: 1, already_finished: 0, lost_claim: 0, failed: 0, results: {}, more } });

  it("플래그가 꺼져 있으면 아무것도 하지 않는다: DB 클라이언트도 만들지 않는다 (집기 · 처리 · 모델 0)", async () => {
    expect(await advanceCoordinator({ env: { ...ON, COORDINATOR_ENABLED: "false" } })).toBeNull();
    expect(mocks.createAdminClient).not.toHaveBeenCalled();
    expect(mocks.coordinatorPass).not.toHaveBeenCalled();
  });

  it("한 번 돌고, 더 남았으면(more) 자기 호출로 깨운다. 다 처리했으면 깨우지 않는다. 모델 포트는 주지 않는다 (운영 배선)", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 202 }));
    mocks.coordinatorPass.mockResolvedValueOnce(pass(true)).mockResolvedValueOnce(pass(false));
    expect(await advanceCoordinator({ env: ON, fetch: fetchMock as never })).toMatchObject({ run: { more: true } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(await advanceCoordinator({ env: ON, fetch: fetchMock as never })).toMatchObject({ run: { more: false } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const deps = mocks.coordinatorPass.mock.calls[0][0];
    expect(deps.ports).toBeUndefined();
    expect(deps.consumer).toMatch(/^fn-/);
  });

  it("처리 중 예외는 던지지 않고 null (사건은 DB에 남아 sweep이 이어 간다). 단계 실패 수는 오류 로그로", async () => {
    mocks.coordinatorPass.mockRejectedValueOnce(new Error("DB 끊김"));
    expect(await advanceCoordinator({ env: ON })).toBeNull();
    mocks.coordinatorPass.mockResolvedValueOnce(pass(false, 2));
    await advanceCoordinator({ env: ON });
    expect(vi.mocked(console.error).mock.calls.flat().join("\n")).toContain("coordinator_pass");
  });
});
