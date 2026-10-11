import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), admin: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/context/member-writes", () => ({ changeContextMembership: vi.fn() }));

import * as memberWrites from "@/lib/context/member-writes";

import { POST as changeMember } from "./[id]/members/route";
import { POST as moveMember } from "./[id]/members/move/route";

// 인증 거부 · 쿠키 CSRF (S3b): 진짜 authenticateRequest로 부른다. 쿠키로 인증하는 쓰기 요청은 같은 출처에서 온 것만 받고, Bearer는 쿠키 CSRF 검사 대상이 아니다.
// 거절되면 쓰기도 DB 클라이언트도 부르지 않는다.
const CONTEXT = "cccccccc-0000-4000-8000-000000000001";
const FROM = "cccccccc-0000-4000-8000-000000000002";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";

const ROUTES: [string, (request: Request) => Promise<Response>, unknown][] = [
  ["POST members", (request) => changeMember(request, { params: Promise.resolve({ id: CONTEXT }) }), { op: "add", member_kind: "action", member_id: ACTION, expected_context_version: 1 }],
  [
    "POST members/move",
    (request) => moveMember(request, { params: Promise.resolve({ id: CONTEXT }) }),
    { member_kind: "action", member_id: ACTION, from_context_id: FROM, expected_context_version: 1, expected_from_context_version: 1 },
  ],
];

const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];

beforeEach(() => {
  vi.stubEnv("MEMORY_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  const getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  vi.mocked(memberWrites.changeContextMembership).mockResolvedValue({ status: "context_not_found" });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe.each(ROUTES)("%s: 쿠키 CSRF · 인증", (_name, call, body) => {
  const request = (headers: Record<string, string>) =>
    new Request("https://api.example.test/api/v2/x", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) {
      expect((await call(request(headers))).status, JSON.stringify(headers)).toBe(401);
    }
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(memberWrites.changeContextMembership).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다", async () => {
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(404); // 가짜 쓰기가 없는 범위로 답했다 (인증 통과의 증거)
    expect(memberWrites.changeContextMembership).toHaveBeenCalledTimes(1);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(memberWrites.changeContextMembership).not.toHaveBeenCalled();
  });
});
