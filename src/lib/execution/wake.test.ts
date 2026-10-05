vi.mock("./store", () => ({ supabaseExecutionStore: () => ({ loadRun: async () => ({ user_id: "u1" }) }) }));
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({})) }));
vi.mock("@/lib/connectors/store", () => ({ loadIdentity: vi.fn() }));
vi.mock("./executor", () => ({ advance: vi.fn() }));

import { advance } from "./executor";
import { ADVANCE_PATH, advanceAndWake, wakeOrigin, wakeRun } from "./wake";

beforeEach(() => {
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("wakeOrigin", () => {
  it("정해 둔 곳으로만 보낸다: EXECUTION_WAKE_ORIGIN → 운영 배포의 VERCEL_PROJECT_PRODUCTION_URL → 개발 서버 localhost → 없음", () => {
    expect(wakeOrigin({ EXECUTION_WAKE_ORIGIN: "https://taskforce.example.com/anything", VERCEL_ENV: "production", VERCEL_PROJECT_PRODUCTION_URL: "x.vercel.app" })).toBe(
      "https://taskforce.example.com",
    );
    expect(wakeOrigin({ VERCEL_ENV: "production", VERCEL_PROJECT_PRODUCTION_URL: "taskforce.example.com" })).toBe("https://taskforce.example.com");
    // 미리보기 배포는 운영 주소로 깨우지 않는다
    expect(wakeOrigin({ VERCEL_ENV: "preview", VERCEL_PROJECT_PRODUCTION_URL: "taskforce.example.com" })).toBeNull();
    expect(wakeOrigin({ NODE_ENV: "development" })).toBe("http://localhost:3000");
    expect(wakeOrigin({ NODE_ENV: "development", PORT: "3100" })).toBe("http://localhost:3100");
    expect(wakeOrigin({ NODE_ENV: "production" })).toBeNull();
    expect(wakeOrigin({ EXECUTION_WAKE_ORIGIN: "javascript:alert(1)" })).toBeNull();
    // 비밀값을 평문으로 보내지 않는다: http는 localhost만
    expect(wakeOrigin({ EXECUTION_WAKE_ORIGIN: "http://taskforce.example.com" })).toBeNull();
    expect(wakeOrigin({ EXECUTION_WAKE_ORIGIN: "http://127.0.0.1:3000" })).toBe("http://127.0.0.1:3000");
  });
});

describe("wakeRun", () => {
  it("CRON_SECRET을 실어 자기 호출을 보내고 202면 true", async () => {
    const fetch = vi.fn(async () => new Response(JSON.stringify({ accepted: true }), { status: 202 }));
    expect(await wakeRun("r1", { origin: "https://taskforce.example.com", secret: "s3cret", fetch })).toBe(true);
    const [url, init] = fetch.mock.calls[0] as unknown as [URL, RequestInit];
    expect(String(url)).toBe(`https://taskforce.example.com${ADVANCE_PATH}`);
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({ authorization: "Bearer s3cret" });
    expect(JSON.parse(String(init.body))).toEqual({ run_id: "r1" });
  });

  it("주소나 비밀값이 없으면 보내지 않고, 실패 · 202가 아니면 false (던지지 않는다, sweep이 이어 간다)", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 404 }));
    expect(await wakeRun("r1", { origin: null, secret: "s", fetch })).toBe(false);
    expect(await wakeRun("r1", { origin: "https://t.example.com", secret: "", fetch })).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
    expect(await wakeRun("r1", { origin: "https://t.example.com", secret: "s", fetch })).toBe(false);
    const broken = vi.fn(async () => {
      throw new TypeError("fetch failed");
    });
    expect(await wakeRun("r1", { origin: "https://t.example.com", secret: "s", fetch: broken })).toBe(false);
  });
});

describe("advanceAndWake", () => {
  beforeEach(() => {
    vi.stubEnv("OPENROUTER_API_KEY", "k");
    vi.stubEnv("LLM_MODEL", "m");
    vi.stubEnv("CRON_SECRET", "s3cret");
    vi.stubEnv("EXECUTION_WAKE_ORIGIN", "https://taskforce.example.com");
  });

  it("단계 하나를 돌고 다음 단계를 붙였을 때만 깨운다. 함수 호출마다 lease 소유자가 다르다", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 202 }));
    vi.stubGlobal("fetch", fetch);
    vi.mocked(advance).mockResolvedValueOnce({ status: "completed", step: "s1", next: true });
    await advanceAndWake("r1");
    expect(fetch).toHaveBeenCalledTimes(1);
    vi.mocked(advance).mockResolvedValueOnce({ status: "held", step: "s2", gate: "insufficient_credit" });
    await advanceAndWake("r1");
    vi.mocked(advance).mockResolvedValueOnce({ status: "completed", step: "s3", next: false });
    await advanceAndWake("r1");
    expect(fetch).toHaveBeenCalledTimes(1);
    const owners = vi.mocked(advance).mock.calls.map(([deps]) => deps.owner);
    expect(new Set(owners).size).toBe(3);
    vi.unstubAllGlobals();
  });

  it("실패는 로그만 남기고 던지지 않는다 (run은 DB에 남아 sweep이 이어 간다)", async () => {
    vi.mocked(advance).mockRejectedValueOnce(new Error("connection reset"));
    expect(await advanceAndWake("r1")).toBeNull();
    expect(console.error).toHaveBeenCalledWith(expect.stringContaining("execution_advance_failed"));
  });
});
