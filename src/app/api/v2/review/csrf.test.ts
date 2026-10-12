import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), admin: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/review/review", () => ({ loadReview: vi.fn() }));
vi.mock("@/lib/review/return-summary", () => ({ loadReturnSummary: vi.fn(), clearReturnSummary: vi.fn(), initializeReturnSummaryBaseline: vi.fn() }));
vi.mock("@/lib/review/suggestions", () => ({ snoozeSuggestion: vi.fn(), dismissSuggestion: vi.fn() }));

import * as returnSummary from "@/lib/review/return-summary";
import * as review from "@/lib/review/review";
import * as suggestions from "@/lib/review/suggestions";

import { POST as baseline } from "../return-summary/baseline/route";
import { POST as clear } from "../return-summary/clear/route";
import { GET as getSummary } from "../return-summary/route";
import { POST as dismiss } from "../suggestions/[id]/dismiss/route";
import { POST as snooze } from "../suggestions/[id]/snooze/route";

import { GET as getReview } from "./route";

// 인증 · gate · 쿠키 CSRF (C3): 진짜 authenticateRequest로 부른다. gate가 꺼져 있으면 인증도 DB 클라이언트도 부르지 않고(404, 새 쓰기 0),
// 쿠키로 인증하는 쓰기(POST)는 같은 출처에서 온 것만 받는다. 읽기(GET)는 CSRF 대상이 아니다. Bearer는 쿠키 CSRF 검사 대상이 아니다.
const ID = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const ctx = { params: Promise.resolve({ id: ID }) };

type Call = (request: Request) => Promise<Response>;
const WRITES: [string, Call, unknown][] = [
  ["POST return-summary/clear", (r) => clear(r), { cursor: "c1.AAAA" }],
  ["POST return-summary/baseline", (r) => baseline(r), { init_token: "i1.AAAA" }],
  ["POST suggestions/snooze", (r) => snooze(r, ctx), { expected_version: 1, snooze_until: new Date(Date.now() + 2 * 86_400_000).toISOString() }],
  ["POST suggestions/dismiss", (r) => dismiss(r, ctx), { expected_version: 1, scope: "this" }],
];
const READS: [string, Call][] = [
  ["GET review", (r) => getReview(r)],
  ["GET return-summary", (r) => getSummary(r)],
];

const services = () =>
  [
    vi.mocked(review.loadReview),
    vi.mocked(returnSummary.loadReturnSummary),
    vi.mocked(returnSummary.clearReturnSummary),
    vi.mocked(returnSummary.initializeReturnSummaryBaseline),
    vi.mocked(suggestions.snoozeSuggestion),
    vi.mocked(suggestions.dismissSuggestion),
  ] as unknown as ReturnType<typeof vi.fn>[];

const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
let getClaims: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.stubEnv("REVIEW_V2_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  vi.mocked(review.loadReview).mockResolvedValue({ ok: "review" } as never);
  vi.mocked(returnSummary.loadReturnSummary).mockResolvedValue({ ok: "summary" } as never);
  vi.mocked(returnSummary.clearReturnSummary).mockResolvedValue({ status: "stale" });
  vi.mocked(returnSummary.initializeReturnSummaryBaseline).mockResolvedValue({ status: "stale" });
  vi.mocked(suggestions.snoozeSuggestion).mockResolvedValue({ status: "not_found" });
  vi.mocked(suggestions.dismissSuggestion).mockResolvedValue({ status: "not_found" });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

const req = (method: string, body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://api.example.test/api/v2/x", { method, headers: { "content-type": "application/json", ...headers }, body: method === "GET" ? undefined : JSON.stringify(body) });

describe.each([...WRITES.map(([name, call, body]) => [name, call, "POST", body] as const), ...READS.map(([name, call]) => [name, call, "GET", undefined] as const)])(
  "%s: gate",
  (_name, call, method, body) => {
    it.each(["", "false", "TRUE", "1", " true"])("REVIEW_V2_ENABLED=%j이면 404이고 인증 · DB 클라이언트 · 서비스를 부르지 않는다 (새 쓰기 0)", async (value) => {
      vi.stubEnv("REVIEW_V2_ENABLED", value);
      const response = await call(req(method, body, { "sec-fetch-site": "same-origin" }));
      expect(response.status).toBe(404);
      expect(mocks.createCookieClient).not.toHaveBeenCalled();
      expect(getClaims).not.toHaveBeenCalled();
      expect(mocks.admin).not.toHaveBeenCalled();
      for (const service of services()) expect(service).not.toHaveBeenCalled();
    });

    it("env에 아예 없어도 꺼짐이다", async () => {
      vi.unstubAllEnvs();
      delete process.env.REVIEW_V2_ENABLED;
      expect((await call(req(method, body))).status).toBe(404);
      expect(mocks.admin).not.toHaveBeenCalled();
    });

    it("로그인하지 않은 요청은 401이고 서비스를 부르지 않는다", async () => {
      mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
      expect((await call(req(method, body, { "sec-fetch-site": "same-origin" }))).status).toBe(401);
      for (const service of services()) expect(service).not.toHaveBeenCalled();
    });
  },
);

describe.each(WRITES)("%s: 쿠키 CSRF", (_name, call, body) => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) {
      expect((await call(req("POST", body, headers))).status, JSON.stringify(headers)).toBe(401);
    }
    expect(mocks.admin).not.toHaveBeenCalled();
    for (const service of services()) expect(service).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과해 서비스까지 간다 (사용자는 검증된 클레임의 sub)", async () => {
    const response = await call(req("POST", body, { "sec-fetch-site": "same-origin" }));
    expect([404, 409]).toContain(response.status);
    expect(services().filter((service) => service.mock.calls.length > 0)).toHaveLength(1);
    const called = services().find((service) => service.mock.calls.length > 0)!;
    expect(JSON.stringify(called.mock.calls[0])).toContain(USER);
    // 본문이 가리킨 id · 커서가 아니라 인증된 사용자로 admin을 좁힌다: 사용자 id는 본문에서 오지 않는다
    expect(mocks.admin).toHaveBeenCalled();
  });
});

describe.each(READS)("%s", (_name, call) => {
  it("GET은 CSRF 검사 대상이 아니다 (다른 사이트에서 온 쿠키 GET도 통과). 복귀 요약 GET은 읽기만 하지만 Review GET은 멱등 쓰기(제안 생산 · 노출 표시: 그날의 비긴급 묶음 소비)를 한다 — D-4", async () => {
    const response = await call(req("GET", undefined, { "sec-fetch-site": "cross-site" }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});
