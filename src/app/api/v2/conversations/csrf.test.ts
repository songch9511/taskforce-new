import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createCookieClient: vi.fn(),
  createSupabaseClient: vi.fn(),
  admin: vi.fn(),
  readConversationTarget: vi.fn(),
  createAgentConversation: vi.fn(),
  confirmProposal: vi.fn(),
  dismissProposal: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: mocks.createAgentConversation }));
vi.mock("@/lib/conversation/store", async (original) => ({ ...(await original<typeof import("@/lib/conversation/store")>()), confirmProposal: mocks.confirmProposal, dismissProposal: mocks.dismissProposal }));

import { GET as readDelivery } from "./[id]/delivery/route";
import { POST as deliver } from "./[id]/deliver/route";
import { POST as postMessage } from "./[id]/messages/route";
import { POST as confirmProposal } from "./[id]/proposals/[proposal_id]/confirm/route";
import { POST as dismissProposal } from "./[id]/proposals/[proposal_id]/dismiss/route";
import { POST as setReferent } from "./[id]/messages/[message_id]/referent/route";
import { POST as stop } from "./[id]/stop/route";
import { POST as createConversation } from "./route";

// 인증 거부 · 쿠키 CSRF (OA D1d, R2): 진짜 authenticateRequest로 부른다. 쿠키로 인증하는 쓰기는 같은 출처만, Bearer는 쿠키 CSRF 검사 대상이 아니다.
// 거절되면 쓰기도 DB 클라이언트도 부르지 않는다. GET(전달 읽기)은 CSRF 대상이 아니다.
const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const PROPOSAL = "fafafafa-0000-4000-8000-000000000007";
const params = { id: CONV, message_id: MSG };

const ROUTES: [string, (request: Request) => Promise<Response>, unknown][] = [
  ["POST conversations (agent)", (request) => createConversation(request), { target: { kind: "agent", connection_id: CONN } }],
  ["POST messages", (request) => postMessage(request, { params: Promise.resolve(params) }), { client_message_id: "c1c1c1c1-0000-4000-8000-000000000001", text: "안녕" }],
  ["POST deliver", (request) => deliver(request, { params: Promise.resolve(params) }), {}],
  ["POST referent", (request) => setReferent(request, { params: Promise.resolve(params) }), { action_id: ACTION }],
  ["POST stop", (request) => stop(request, { params: Promise.resolve(params) }), {}],
];
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];

const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  mocks.readConversationTarget.mockResolvedValue(null);
  mocks.createAgentConversation.mockResolvedValue({ status: "not_found" });
  mocks.confirmProposal.mockResolvedValue({ status: "not_found" });
  mocks.dismissProposal.mockResolvedValue("not_found");
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe.each(ROUTES)("%s: 쿠키 CSRF · 인증", (name, call, payload) => {
  const request = (headers: Record<string, string>) =>
    new Request("https://api.example.test/api/v2/x", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(payload) });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) expect((await call(request(headers))).status, `${name} ${JSON.stringify(headers)}`).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.readConversationTarget).not.toHaveBeenCalled();
    expect(mocks.createAgentConversation).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다 (handler가 돈다)", async () => {
    const response = await call(request({ "sec-fetch-site": "same-origin" }));
    expect(response.status).not.toBe(401);
    expect(mocks.readConversationTarget.mock.calls.length + mocks.createAgentConversation.mock.calls.length).toBeGreaterThan(0);
  });

  it("Bearer는 쿠키 CSRF 검사 대상이 아니다: 다른 사이트 표시가 있어도 통과한다 (쿠키 클라이언트는 쓰지 않는다)", async () => {
    const response = await call(request({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }));
    expect(response.status).not.toBe(401);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
    expect(mocks.createSupabaseClient).toHaveBeenCalledTimes(1);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(mocks.readConversationTarget).not.toHaveBeenCalled();
    expect(mocks.createAgentConversation).not.toHaveBeenCalled();
  });
});

// 삭제 · 병합 확인 카드의 버튼 (OA D4c-2): 쿠키로 인증하는 쓰기라 같은 출처만, Bearer는 CSRF 대상이 아니다. 거절되면 확인 · 취소 · DB 클라이언트를 부르지 않는다.
describe.each([
  ["POST proposals/confirm", (request: Request) => confirmProposal(request, { params: Promise.resolve({ id: CONV, proposal_id: PROPOSAL }) }), mocks.confirmProposal],
  ["POST proposals/dismiss", (request: Request) => dismissProposal(request, { params: Promise.resolve({ id: CONV, proposal_id: PROPOSAL }) }), mocks.dismissProposal],
] as const)("%s: 쿠키 CSRF · 인증", (name, call, write) => {
  const request = (headers: Record<string, string>) =>
    new Request("https://api.example.test/api/v2/x", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: "{}" });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) expect((await call(request(headers))).status, `${name} ${JSON.stringify(headers)}`).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(write).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다 (handler가 돈다)", async () => {
    const response = await call(request({ "sec-fetch-site": "same-origin" }));
    expect(response.status).not.toBe(401);
    expect(write).toHaveBeenCalledTimes(1);
  });

  it("Bearer는 쿠키 CSRF 검사 대상이 아니다: 다른 사이트 표시가 있어도 통과한다 (쿠키 클라이언트는 쓰지 않는다)", async () => {
    const response = await call(request({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }));
    expect(response.status).not.toBe(401);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
    expect(write).toHaveBeenCalledTimes(1);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(write).not.toHaveBeenCalled();
  });
});

describe("GET delivery: CSRF 대상이 아니다 (읽기)", () => {
  it("다른 사이트 표시가 있어도 인증만 되면 통과하고, 로그인하지 않으면 401이다", async () => {
    const read = (headers: Record<string, string>) => readDelivery(new Request(`https://api.example.test/api/v2/conversations/${CONV}/delivery`, { headers }), { params: Promise.resolve({ id: CONV }) });
    expect((await read({ "sec-fetch-site": "cross-site" })).status).not.toBe(401);
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await read({})).status).toBe(401);
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
