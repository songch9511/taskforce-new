import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), admin: vi.fn(), resolvePathConflict: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/agents/path-leases", () => ({ resolvePathConflict: mocks.resolvePathConflict }));

import { POST } from "./route";

// 진짜 authenticateRequest · 진짜 route · 진짜 gate 조합(REVIEW_V2_ENABLED ∧ 켜진 adapter)으로 부른다. 해소 SQL만 대역이다.
const LEASE = "e0000000-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const ctx = (id = LEASE) => ({ params: Promise.resolve({ id }) });
const SAME_ORIGIN = { "sec-fetch-site": "same-origin" };
const BODY = { keep: "later", conflict_version: 2 };
const FLAGS = ["REVIEW_V2_ENABLED", "CONVERSATIONS_V2_ENABLED", "AGENT_ADAPTER_CODEX_ENABLED", "AGENT_ADAPTER_CLAUDE_CODE_ENABLED"] as const;
const open = (extra: Record<string, string> = {}) => {
  for (const [key, value] of Object.entries({ REVIEW_V2_ENABLED: "true", CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true", ...extra })) vi.stubEnv(key, value);
};
const req = (headers: Record<string, string> = SAME_ORIGIN, body: unknown = BODY) =>
  new Request(`https://api.example.test/api/v2/path-conflicts/${LEASE}/resolve`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
const notFoundBody = { error: { code: "not_found", message: "없는 경로입니다." } };
let getClaims: ReturnType<typeof vi.fn>;

beforeEach(() => {
  for (const flag of FLAGS) delete process.env[flag];
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  mocks.resolvePathConflict.mockResolvedValue({ status: "resolved" });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  for (const flag of FLAGS) delete process.env[flag];
});

const expectClosed = async (response: Response) => {
  expect(response.status).toBe(404);
  expect(await response.json()).toEqual(notFoundBody);
  expect(mocks.createCookieClient).not.toHaveBeenCalled();
  expect(getClaims).not.toHaveBeenCalled();
  expect(mocks.admin).not.toHaveBeenCalled();
  expect(mocks.resolvePathConflict).not.toHaveBeenCalled();
};

describe("POST /api/v2/path-conflicts/{id}/resolve: gate", () => {
  it("모든 플래그가 꺼져 있으면 404: 인증 · DB 클라이언트 · 해소 0", async () => {
    await expectClosed(await POST(req(), ctx()));
  });

  it("REVIEW_V2만 켜지면(켜진 adapter 없음) 404 — Review가 충돌을 보이지 않는 조건과 같다", async () => {
    vi.stubEnv("REVIEW_V2_ENABLED", "true");
    await expectClosed(await POST(req(), ctx()));
  });

  it("REVIEW_V2 + 대화 v2만(adapter 플래그 없음)이어도 404", async () => {
    vi.stubEnv("REVIEW_V2_ENABLED", "true");
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    await expectClosed(await POST(req(), ctx()));
  });

  it("대화 v2 + adapter만 켜지고 REVIEW_V2가 꺼졌으면 404", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    await expectClosed(await POST(req(), ctx()));
  });

  it("REVIEW_V2 + adapter만 켜지고 대화 v2가 꺼졌으면 404", async () => {
    vi.stubEnv("REVIEW_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    await expectClosed(await POST(req(), ctx()));
  });

  it.each(["", "false", "TRUE", "True", "1", " true", "true\n"])("플래그 값 %j는 켜짐이 아니다 (정확히 \"true\"만)", async (value) => {
    open({ REVIEW_V2_ENABLED: value });
    await expectClosed(await POST(req(), ctx()));
  });

  it.each([["agent:codex만", { AGENT_ADAPTER_CODEX_ENABLED: "true" }], ["claude-code만", { AGENT_ADAPTER_CODEX_ENABLED: "", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }], ["둘 다", { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }]])(
    "REVIEW_V2 ∧ 대화 v2 ∧ adapter 하나라도 → 열린다 (%s)",
    async (_name, extra) => {
      open(extra);
      const response = await POST(req(), ctx());
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ status: "resolved" });
      expect(mocks.resolvePathConflict).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, leaseId: LEASE, keep: "later", conflictVersion: 2 });
    },
  );
});

describe("POST /api/v2/path-conflicts/{id}/resolve: 인증 · CSRF", () => {
  it("로그인하지 않은 요청은 401이고 해소를 부르지 않는다", async () => {
    open();
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await POST(req(), ctx())).status).toBe(401);
    expect(mocks.resolvePathConflict).not.toHaveBeenCalled();
  });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 해소 0 · DB 클라이언트 0)", async () => {
    open();
    for (const headers of [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }] as Record<string, string>[]) {
      expect((await POST(req(headers), ctx())).status, JSON.stringify(headers)).toBe(401);
    }
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.resolvePathConflict).not.toHaveBeenCalled();
  });

  it("사용자는 검증된 클레임의 sub다 (본문 · 경로에서 오지 않는다)", async () => {
    open();
    await POST(req(SAME_ORIGIN, { ...BODY }), ctx());
    expect(mocks.resolvePathConflict.mock.calls[0][1]).toMatchObject({ userId: USER });
    expect(getClaims).toHaveBeenCalled();
  });
});

describe("POST /api/v2/path-conflicts/{id}/resolve: 결과", () => {
  it("잘못된 id는 404, 본문이 틀리면 400 — 해소 0", async () => {
    open();
    expect((await POST(req(), ctx("not-a-uuid"))).status).toBe(404);
    for (const body of [{}, { keep: "holder" }, { keep: "holder", conflict_version: 0 }, { keep: "holder", conflict_version: 1, extra: 1 }]) {
      expect((await POST(req(SAME_ORIGIN, body), ctx())).status, JSON.stringify(body)).toBe(400);
    }
    expect(mocks.resolvePathConflict).not.toHaveBeenCalled();
  });

  it("stale → 409 conflict, not_found → 404, SQL 오류 → 500 (오류 본문에 값 없음)", async () => {
    open();
    mocks.resolvePathConflict.mockResolvedValueOnce({ status: "stale" });
    const stale = await POST(req(), ctx());
    expect([stale.status, (await stale.json()).error.code]).toEqual([409, "conflict"]);
    mocks.resolvePathConflict.mockResolvedValueOnce({ status: "not_found" });
    expect((await POST(req(), ctx())).status).toBe(404);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.resolvePathConflict.mockRejectedValueOnce(new Error(`db down for ${LEASE} /w/proj/secret.mdx`));
    const failed = await POST(req(), ctx());
    expect(failed.status).toBe(500);
    expect(JSON.stringify(await failed.json())).not.toContain(LEASE);
    expect(String(log.mock.calls[0][0])).not.toMatch(/w\/proj|secret|e0000000/);
    log.mockRestore();
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
