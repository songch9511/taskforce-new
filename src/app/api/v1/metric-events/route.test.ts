import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), adminInsert: vi.fn(), userInsert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST } from "./route";

// 앱이 알리는 지표 (OA 외부 세션 PR1): app_opened는 예전 그대로 사용자 권한으로, external_sessions_shown은 구간 값만 받아 서버 권한으로 남긴다
const USER = "11111111-0000-4000-8000-000000000001";
const post = (body: unknown) => POST(new Request("https://api.example.dev/api/v1/metric-events", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
const shown = { type: "external_sessions_shown", props: { rows_bucket: "2-5", held_bucket: "1-2" } };

beforeEach(() => {
  mocks.userInsert.mockResolvedValue({ error: null });
  mocks.adminInsert.mockResolvedValue({ error: null });
  mocks.auth.mockResolvedValue({ user: { id: USER }, supabase: { from: (table: string) => ({ insert: (row: unknown) => mocks.userInsert(table, row) }) } });
  mocks.admin.mockReturnValue({ from: (table: string) => ({ insert: (row: unknown) => mocks.adminInsert(table, row) }) });
});
afterEach(() => vi.clearAllMocks());

describe("POST /api/v1/metric-events", () => {
  it("로그인하지 않았으면 401 (저장 0)", async () => {
    mocks.auth.mockResolvedValue(null);
    expect((await post(shown)).status).toBe(401);
    expect(mocks.adminInsert).not.toHaveBeenCalled();
    expect(mocks.userInsert).not.toHaveBeenCalled();
  });

  it("app_opened: 예전 모양 그대로 사용자 권한으로 남긴다 (서버 권한 0)", async () => {
    expect((await post({ type: "app_opened" })).status).toBe(204);
    expect(mocks.userInsert).toHaveBeenCalledExactlyOnceWith("metric_events", { type: "app_opened", action_id: null });
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("external_sessions_shown: 인증된 사용자 id와 구간 값만으로 서버 권한 insert", async () => {
    expect((await post(shown)).status).toBe(204);
    expect(mocks.adminInsert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type: "external_sessions_shown", props: shown.props });
    expect(mocks.userInsert).not.toHaveBeenCalled();
  });

  it("같은 날 두 번째(23505)는 조용히 204", async () => {
    mocks.adminInsert.mockResolvedValue({ error: { code: "23505" } });
    expect((await post(shown)).status).toBe(204);
  });

  it("그 밖의 저장 오류는 500", async () => {
    mocks.adminInsert.mockResolvedValue({ error: { code: "XX000" } });
    expect((await post(shown)).status).toBe(500);
  });

  it.each([
    { type: "external_sessions_shown" },
    { type: "external_sessions_shown", props: { rows_bucket: "12", held_bucket: "0" } },
    { type: "external_sessions_shown", props: { rows_bucket: "1", held_bucket: "0", user_id: "x" } },
    { type: "session_attached" },
    { type: "agent_message_sent" },
  ])("잘못된 본문 · 앱이 보낼 수 없는 종류는 400 (저장 0): %j", async (body) => {
    expect((await post(body)).status).toBe(400);
    expect(mocks.adminInsert).not.toHaveBeenCalled();
    expect(mocks.userInsert).not.toHaveBeenCalled();
  });
});
