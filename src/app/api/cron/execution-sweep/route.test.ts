import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ sweep: vi.fn(), wakeRun: vi.fn(), supabaseExecutionStore: vi.fn(() => ({ store: true })) }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({ supabaseExecutionStore: mocks.supabaseExecutionStore }));
vi.mock("@/lib/execution/sweep", () => ({ sweep: mocks.sweep }));
vi.mock("@/lib/execution/wake", () => ({ wakeRun: mocks.wakeRun }));

import { GET } from "./route";

const RESULT = { expired: 1, reconciled: 0, released: 0, woken: 2, wake_failed: 0, errors: 0 };
const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.test/api/cron/execution-sweep", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("EXECUTION_ENABLED", "true");
  mocks.sweep.mockResolvedValue(RESULT);
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
  });

  it("기능 플래그가 꺼져 있으면(기본) 아무것도 하지 않고 정상 종료", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "");
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ enabled: false });
    expect(mocks.sweep).not.toHaveBeenCalled();
    expect(mocks.supabaseExecutionStore).not.toHaveBeenCalled();
  });

  it("켜져 있으면 sweep 결과(숫자만)를 돌려주고 로그 한 줄", async () => {
    const response = await cron();
    expect(await response.json()).toEqual({ enabled: true, ...RESULT });
    expect(console.info).toHaveBeenCalledWith(JSON.stringify({ event: "execution_sweep", ...RESULT }));
    // 깨우기는 자기 호출(wakeRun)로 맡긴다
    const [{ wake }] = mocks.sweep.mock.calls[0] as [{ wake: (id: string) => Promise<boolean> }];
    await wake("r1");
    expect(mocks.wakeRun).toHaveBeenCalledWith("r1");
  });

  it("실패한 단계가 있으면 오류 로그로 남긴다 (응답은 200, 다음 분에 다시 돈다)", async () => {
    mocks.sweep.mockResolvedValueOnce({ ...RESULT, errors: 1 });
    expect((await cron()).status).toBe(200);
    expect(console.error).toHaveBeenCalledWith(JSON.stringify({ event: "execution_sweep", ...RESULT, errors: 1 }));
  });
});
