import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), admin: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/review/review", () => ({ loadReview: vi.fn(), loadReviewDecisions: vi.fn() }));
vi.mock("@/lib/review/return-summary", () => ({ loadReturnSummary: vi.fn(), clearReturnSummary: vi.fn(), initializeReturnSummaryBaseline: vi.fn() }));
vi.mock("@/lib/review/suggestions", () => ({ snoozeSuggestion: vi.fn(), dismissSuggestion: vi.fn() }));
vi.mock("@/lib/agents/path-leases", () => ({ resolvePathConflict: vi.fn() }));

import * as pathLeases from "@/lib/agents/path-leases";
import * as returnSummary from "@/lib/review/return-summary";
import * as review from "@/lib/review/review";
import * as suggestions from "@/lib/review/suggestions";

import { POST as resolveConflict } from "../path-conflicts/[id]/resolve/route";
import { POST as baseline } from "../return-summary/baseline/route";
import { POST as clear } from "../return-summary/clear/route";
import { GET as getSummary } from "../return-summary/route";
import { POST as dismiss } from "../suggestions/[id]/dismiss/route";
import { POST as snooze } from "../suggestions/[id]/snooze/route";

import { GET as getReviewDecisions } from "./decisions/route";
import { GET as getReview } from "./route";

// 두 gate의 조합 (R1): RETURN_SUMMARY_ENABLED는 복귀 요약 세 경로(GET return-summary · POST clear · POST baseline)만 연다.
// Review GET · 결정만 읽는 GET review/decisions(R-dec, 쓰기 0) · 제안 snooze · dismiss(제안 생산 · 노출 포함)는 REVIEW_V2_ENABLED 뒤에 그대로 있다. REVIEW_V2_ENABLED는 이 일곱 경로 전부를 연다(상위 집합).
// 복귀 요약 경로는 둘 중 하나라도 정확히 "true"이면 열린다. 꺼짐의 의미(404, 인증 · DB · 서비스 0, 새 쓰기 0)와 인증 · 쿠키 CSRF는 그대로다. 진짜 authenticateRequest와 진짜 route로 부른다.
const ID = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const ctx = { params: Promise.resolve({ id: ID }) };
const SAME_ORIGIN = { "sec-fetch-site": "same-origin" };

type Call = (request: Request) => Promise<Response>;
type Route = { name: string; method: "GET" | "POST"; call: Call; body?: unknown; service: () => ReturnType<typeof vi.fn>; summary: boolean };
const ROUTES: Route[] = [
  { name: "GET return-summary", method: "GET", call: (r) => getSummary(r), service: () => vi.mocked(returnSummary.loadReturnSummary) as never, summary: true },
  { name: "POST return-summary/clear", method: "POST", call: (r) => clear(r), body: { cursor: "c1.AAAA" }, service: () => vi.mocked(returnSummary.clearReturnSummary) as never, summary: true },
  { name: "POST return-summary/baseline", method: "POST", call: (r) => baseline(r), body: { init_token: "i1.AAAA" }, service: () => vi.mocked(returnSummary.initializeReturnSummaryBaseline) as never, summary: true },
  { name: "GET review", method: "GET", call: (r) => getReview(r), service: () => vi.mocked(review.loadReview) as never, summary: false },
  { name: "GET review/decisions", method: "GET", call: (r) => getReviewDecisions(r), service: () => vi.mocked(review.loadReviewDecisions) as never, summary: false },
  {
    name: "POST suggestions/snooze",
    method: "POST",
    call: (r) => snooze(r, ctx),
    body: { expected_version: 1, snooze_until: new Date(Date.now() + 2 * 86_400_000).toISOString() },
    service: () => vi.mocked(suggestions.snoozeSuggestion) as never,
    summary: false,
  },
  { name: "POST suggestions/dismiss", method: "POST", call: (r) => dismiss(r, ctx), body: { expected_version: 1, scope: "this" }, service: () => vi.mocked(suggestions.dismissSuggestion) as never, summary: false },
];
const allServices = () =>
  [review.loadReview, review.loadReviewDecisions, returnSummary.loadReturnSummary, returnSummary.clearReturnSummary, returnSummary.initializeReturnSummaryBaseline, suggestions.snoozeSuggestion, suggestions.dismissSuggestion].map(
    (fn) => vi.mocked(fn) as unknown as ReturnType<typeof vi.fn>,
  );

const COMBOS: { name: string; env: Record<string, string>; reviewOn: boolean; summaryOn: boolean }[] = [
  { name: "off/off", env: {}, reviewOn: false, summaryOn: false },
  { name: "REVIEW_V2만", env: { REVIEW_V2_ENABLED: "true" }, reviewOn: true, summaryOn: false },
  { name: "RETURN_SUMMARY만", env: { RETURN_SUMMARY_ENABLED: "true" }, reviewOn: false, summaryOn: true },
  { name: "on/on", env: { REVIEW_V2_ENABLED: "true", RETURN_SUMMARY_ENABLED: "true" }, reviewOn: true, summaryOn: true },
];

let getClaims: ReturnType<typeof vi.fn>;
const setEnv = (env: Record<string, string>) => {
  delete process.env.REVIEW_V2_ENABLED;
  delete process.env.RETURN_SUMMARY_ENABLED;
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
};

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  vi.mocked(review.loadReview).mockResolvedValue({ ok: "review" } as never);
  vi.mocked(review.loadReviewDecisions).mockResolvedValue({ ok: "decisions" } as never);
  vi.mocked(returnSummary.loadReturnSummary).mockResolvedValue({ ok: "summary" } as never);
  vi.mocked(returnSummary.clearReturnSummary).mockResolvedValue({ status: "stale" });
  vi.mocked(returnSummary.initializeReturnSummaryBaseline).mockResolvedValue({ status: "stale" });
  vi.mocked(suggestions.snoozeSuggestion).mockResolvedValue({ status: "not_found" });
  vi.mocked(suggestions.dismissSuggestion).mockResolvedValue({ status: "not_found" });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  delete process.env.REVIEW_V2_ENABLED;
  delete process.env.RETURN_SUMMARY_ENABLED;
});

// headers를 주면 그것만 쓴다 (교차 출처 시험). 안 주면 쓰기는 같은 출처로 보낸다
const req = (route: Route, headers?: Record<string, string>) =>
  new Request("https://api.example.test/api/v2/x", {
    method: route.method,
    headers: { "content-type": "application/json", ...(headers ?? (route.method === "POST" ? SAME_ORIGIN : {})) },
    body: route.method === "GET" ? undefined : JSON.stringify(route.body),
  });
const notFoundBody = { error: { code: "not_found", message: "없는 경로입니다." } };

describe.each(COMBOS)("두 gate 조합: $name", ({ env, reviewOn, summaryOn }) => {
  describe.each(ROUTES)("$name", (route) => {
    const open = route.summary ? reviewOn || summaryOn : reviewOn;

    if (open) {
      it("열린다: 인증을 거쳐 서비스까지 간다 (사용자는 검증된 클레임의 sub)", async () => {
        setEnv(env);
        const response = await route.call(req(route));
        // 서비스가 부른 대로 200/409/404(제안 없음)이 나오지만 "gate 404"의 본문은 아니다
        expect(await response.clone().json().catch(() => null)).not.toEqual(notFoundBody);
        const called = allServices().filter((service) => service.mock.calls.length > 0);
        expect(called).toHaveLength(1);
        expect(called[0]).toBe(route.service());
        expect(JSON.stringify(called[0].mock.calls[0])).toContain(USER);
      });
    } else {
      it("닫힌다: 404, 인증 · DB 클라이언트 · 서비스를 부르지 않는다 (새 쓰기 0)", async () => {
        setEnv(env);
        const response = await route.call(req(route));
        expect(response.status).toBe(404);
        expect(await response.json()).toEqual(notFoundBody);
        expect(mocks.createCookieClient).not.toHaveBeenCalled();
        expect(getClaims).not.toHaveBeenCalled();
        expect(mocks.admin).not.toHaveBeenCalled();
        for (const service of allServices()) expect(service).not.toHaveBeenCalled();
      });
    }
  });
});

describe("RETURN_SUMMARY_ENABLED만 켠 경우의 인증 · CSRF는 그대로다 (복귀 요약 쓰기 둘)", () => {
  const writes = ROUTES.filter((route) => route.summary && route.method === "POST");

  it.each(writes)("$name: 로그인하지 않은 요청은 401이고 서비스를 부르지 않는다", async (route) => {
    setEnv({ RETURN_SUMMARY_ENABLED: "true" });
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await route.call(req(route))).status).toBe(401);
    for (const service of allServices()) expect(service).not.toHaveBeenCalled();
  });

  it.each(writes)("$name: 다른 사이트에서 온 쿠키 쓰기는 401 (쓰기 0 · DB 클라이언트 0)", async (route) => {
    setEnv({ RETURN_SUMMARY_ENABLED: "true" });
    for (const headers of [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }] as Record<string, string>[]) {
      expect((await route.call(req(route, headers))).status, JSON.stringify(headers)).toBe(401);
    }
    expect(mocks.admin).not.toHaveBeenCalled();
    for (const service of allServices()) expect(service).not.toHaveBeenCalled();
  });
});

describe("gate 값은 정확히 \"true\"만 켠다", () => {
  const summaryRoutes = ROUTES.filter((route) => route.summary);
  it.each(["", "false", "TRUE", "True", "1", " true", "true\n", "yes"])("RETURN_SUMMARY_ENABLED=%j이면 복귀 요약 세 경로 모두 404이고 아무것도 부르지 않는다", async (value) => {
    setEnv({ RETURN_SUMMARY_ENABLED: value });
    for (const route of summaryRoutes) {
      const response = await route.call(req(route));
      expect(response.status, route.name).toBe(404);
      expect(await response.json(), route.name).toEqual(notFoundBody);
    }
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    for (const service of allServices()) expect(service).not.toHaveBeenCalled();
  });

  it("RETURN_SUMMARY_ENABLED=true여도 REVIEW_V2_ENABLED가 아니면 Review · 제안 경로는 닫혀 있다 (제안 생산 · 노출 · snooze · dismiss 0)", async () => {
    setEnv({ RETURN_SUMMARY_ENABLED: "true" });
    for (const route of ROUTES.filter((r) => !r.summary)) {
      const response = await route.call(req(route));
      expect(response.status, route.name).toBe(404);
      expect(await response.json(), route.name).toEqual(notFoundBody);
    }
    expect(vi.mocked(review.loadReview)).not.toHaveBeenCalled();
    expect(vi.mocked(suggestions.snoozeSuggestion)).not.toHaveBeenCalled();
    expect(vi.mocked(suggestions.dismissSuggestion)).not.toHaveBeenCalled();
  });
});

describe("경로 충돌 해소 route (D4b-s)의 gate 조합: REVIEW_V2_ENABLED ∧ CONVERSATIONS_V2_ENABLED ∧ adapter 플래그 하나 이상", () => {
  const FLAGS = ["REVIEW_V2_ENABLED", "CONVERSATIONS_V2_ENABLED", "AGENT_ADAPTER_CODEX_ENABLED", "AGENT_ADAPTER_CLAUDE_CODE_ENABLED"] as const;
  const combos = Array.from({ length: 16 }, (_, n) => {
    const on = FLAGS.map((_flag, i) => Boolean(n & (1 << i)));
    return { name: FLAGS.map((flag, i) => `${flag.replace("_ENABLED", "")}=${on[i] ? "on" : "off"}`).join(" "), on, open: on[0] && on[1] && (on[2] || on[3]) };
  });
  const call = () =>
    resolveConflict(
      new Request("https://api.example.test/api/v2/x", { method: "POST", headers: { "content-type": "application/json", ...SAME_ORIGIN }, body: JSON.stringify({ keep: "holder", conflict_version: 1 }) }),
      ctx,
    );

  beforeEach(() => {
    for (const flag of FLAGS) delete process.env[flag];
    vi.mocked(pathLeases.resolvePathConflict).mockResolvedValue({ status: "resolved" });
  });

  it.each(combos)("$name → $open", async ({ on, open }) => {
    FLAGS.forEach((flag, i) => on[i] && vi.stubEnv(flag, "true"));
    const response = await call();
    if (open) {
      expect(response.status).toBe(200);
      expect(vi.mocked(pathLeases.resolvePathConflict)).toHaveBeenCalledTimes(1);
      expect(JSON.stringify(vi.mocked(pathLeases.resolvePathConflict).mock.calls[0][1])).toContain(USER);
    } else {
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual(notFoundBody);
      expect(mocks.createCookieClient).not.toHaveBeenCalled();
      expect(getClaims).not.toHaveBeenCalled();
      expect(mocks.admin).not.toHaveBeenCalled();
      expect(vi.mocked(pathLeases.resolvePathConflict)).not.toHaveBeenCalled();
    }
    // 다른 Review 서비스는 이 route가 부르지 않는다
    for (const service of allServices()) expect(service).not.toHaveBeenCalled();
  });

  it("RETURN_SUMMARY_ENABLED는 이 route를 열지 못한다 (복귀 요약 세 경로만)", async () => {
    vi.stubEnv("RETURN_SUMMARY_ENABLED", "true");
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    expect((await call()).status).toBe(404);
    expect(vi.mocked(pathLeases.resolvePathConflict)).not.toHaveBeenCalled();
  });
});

describe("결정만 읽기 GET review/decisions (R-dec)의 gate는 REVIEW_V2_ENABLED 하나다", () => {
  const decisionsRoute = ROUTES.find((route) => route.name === "GET review/decisions")!;

  it.each(["", "false", "TRUE", "True", "1", " true", "true\n", "yes"])("REVIEW_V2_ENABLED=%j이면 404이고 인증 · DB 클라이언트 · 서비스를 부르지 않는다", async (value) => {
    setEnv({ REVIEW_V2_ENABLED: value });
    const response = await decisionsRoute.call(req(decisionsRoute));
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual(notFoundBody);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
    expect(getClaims).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    for (const service of allServices()) expect(service).not.toHaveBeenCalled();
  });

  it("RETURN_SUMMARY_ENABLED만 켜도 열리지 않는다: 404이고 결정 읽기 서비스를 부르지 않는다 (복귀 요약 세 경로만 연다)", async () => {
    setEnv({ RETURN_SUMMARY_ENABLED: "true" });
    const response = await decisionsRoute.call(req(decisionsRoute));
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual(notFoundBody);
    expect(vi.mocked(review.loadReviewDecisions)).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("에이전트 입력 gate는 이 route의 404 조건이 아니다: 대화 v2 · adapter 플래그가 모두 꺼져 있어도 REVIEW_V2_ENABLED만으로 열린다 (C3 결정은 보여야 한다)", async () => {
    setEnv({ REVIEW_V2_ENABLED: "true" });
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "false");
    const response = await decisionsRoute.call(req(decisionsRoute));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: "decisions" });
    expect(vi.mocked(review.loadReviewDecisions)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(review.loadReview)).not.toHaveBeenCalled();
  });

  it("열린 route는 admin 클라이언트와 검증된 사용자 id로 결정만 읽는다: 인자는 (admin, 사용자, 지금) 셋이고 제안 생산 옵션(coordinatorEnabled)이 없다", async () => {
    setEnv({ REVIEW_V2_ENABLED: "true", COORDINATOR_ENABLED: "true" } as Record<string, string>);
    await decisionsRoute.call(req(decisionsRoute));
    const call = vi.mocked(review.loadReviewDecisions).mock.calls[0];
    expect(call).toHaveLength(3);
    expect(call[0]).toEqual({ admin: true });
    expect(call[1]).toBe(USER);
    expect(call[2]).toBeInstanceOf(Date);
    vi.unstubAllEnvs();
  });
});
