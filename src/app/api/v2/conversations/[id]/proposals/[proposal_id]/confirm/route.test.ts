import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), confirmProposal: vi.fn(), loadMessage: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/conversation/store", () => ({ confirmProposal: mocks.confirmProposal, loadMessage: mocks.loadMessage }));

import { POST } from "./route";

// 삭제 · 병합 확인 카드의 Delete · Merge 버튼 route (OA D4c-2). 처리 규칙은 src/lib/api/conversations.test.ts, 쓰기는 tests/db/issue-organize.scenarios.ts

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const PROPOSAL = "fafafafa-0000-4000-8000-000000000007";
const ACTION = "f0b0c918-acd0-b623-d33f-14699a728393";
const call = (body: string | undefined = "{}") =>
  POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/proposals/${PROPOSAL}/confirm`, { method: "POST", body }), { params: Promise.resolve({ id: CONV, proposal_id: PROPOSAL }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.confirmProposal.mockResolvedValue({ status: "already", op: "delete", actionIds: [ACTION], eventId: null });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/proposals/{proposal_id}/confirm (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 확인 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.confirmProposal).not.toHaveBeenCalled();
  });

  it("켜져 있으면 경로의 대화 · 제안 id로 이 사용자의 확인을 부른다 (에이전트가 만든 해시 모양 이슈 id도 받는다)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "already", op: "delete", action_ids: [ACTION], event: null });
    expect(mocks.confirmProposal).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, CONV, PROPOSAL);
    expect(mocks.loadMessage).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401 (확인 0), 잘못된 본문은 400", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    mocks.auth.mockResolvedValue({ user: { id: USER } });
    expect((await call('{"note": 1}')).status).toBe(400);
    expect(mocks.confirmProposal).not.toHaveBeenCalled();
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
