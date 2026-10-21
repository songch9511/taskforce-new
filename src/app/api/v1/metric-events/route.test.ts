import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), userInsert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST } from "./route";

// v1 metric-events는 동결이다 (contract-v1-freeze.test.ts): app_opened만, 사용자 권한으로. 외부 세션 지표(external_sessions_shown)는 v2 route가 받는다 (v2/external-sessions/shown)
const USER = "11111111-0000-4000-8000-000000000001";
const post = (body: unknown) => POST(new Request("https://api.example.dev/api/v1/metric-events", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

beforeEach(() => {
  mocks.userInsert.mockResolvedValue({ error: null });
  mocks.auth.mockResolvedValue({ user: { id: USER }, supabase: { from: (table: string) => ({ insert: (row: unknown) => mocks.userInsert(table, row) }) } });
});
afterEach(() => vi.clearAllMocks());

describe("POST /api/v1/metric-events", () => {
  it("로그인하지 않았으면 401 (저장 0)", async () => {
    mocks.auth.mockResolvedValue(null);
    expect((await post({ type: "app_opened" })).status).toBe(401);
    expect(mocks.userInsert).not.toHaveBeenCalled();
  });

  it("app_opened는 예전 모양 그대로 사용자 권한으로 남긴다 (서버 권한 0)", async () => {
    expect((await post({ type: "app_opened" })).status).toBe(204);
    expect(mocks.userInsert).toHaveBeenCalledExactlyOnceWith("metric_events", { type: "app_opened", action_id: null });
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each([
    { type: "external_sessions_shown", props: { rows_bucket: "2-5", held_bucket: "0" } },
    { type: "session_attached" },
    { type: "agent_message_sent" },
  ])("앱이 보낼 수 없는 종류는 400 (저장 0, 새 지표도 v1로 받지 않는다): %j", async (body) => {
    expect((await post(body)).status).toBe(400);
    expect(mocks.userInsert).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});
