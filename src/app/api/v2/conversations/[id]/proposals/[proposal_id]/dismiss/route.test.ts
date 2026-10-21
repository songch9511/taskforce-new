import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), dismissProposal: vi.fn(), loadMessage: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/conversation/store", () => ({ dismissProposal: mocks.dismissProposal, loadMessage: mocks.loadMessage }));

import { POST } from "./route";

// 삭제 · 병합 확인 카드의 Cancel 버튼 route (OA D4c-2)

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const PROPOSAL = "fafafafa-0000-4000-8000-000000000007";
const call = (body: string | undefined = "{}") =>
  POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/proposals/${PROPOSAL}/dismiss`, { method: "POST", body }), { params: Promise.resolve({ id: CONV, proposal_id: PROPOSAL }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.dismissProposal.mockResolvedValue("dismissed");
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/proposals/{proposal_id}/dismiss (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 취소 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.dismissProposal).not.toHaveBeenCalled();
  });

  it("켜져 있으면 경로의 대화 · 제안 id로 이 사용자의 취소를 부른다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "dismissed" });
    expect(mocks.dismissProposal).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, CONV, PROPOSAL);
  });

  it("이미 확인한 카드의 취소는 409 not_open, 로그인하지 않았으면 401", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.dismissProposal.mockResolvedValue("not_open");
    const response = await call();
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: { code: "not_open" } });
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
