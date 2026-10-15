import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { changeContextMembership } from "@/lib/context/member-writes";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/context/member-writes", () => ({ changeContextMembership: vi.fn(async () => ({ status: "context_not_found" })) }));

// 범위 멤버십 넣기 · 빼기 (S3b). route는 얇다: gate · 인증 · 본문 검증은 lib/api/context-members.test.ts, 규칙은 tests/db/context-members.scenarios.ts가 본다.
// 여기서는 gate 꺼짐(기본)이 DB 클라이언트도 만들지 않는다는 것과 켜졌을 때 경로의 id · 사용자 · 본문(version 조건 포함)이 그대로 쓰기에 간다는 것만 본다.
const CONTEXT = "cccccccc-0000-4000-8000-000000000001";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const body = { op: "add", member_kind: "action", member_id: ACTION, expected_context_version: 3 };
const call = (payload: unknown, id = CONTEXT) =>
  POST(new Request(`https://api.example.dev/api/v2/contexts/${id}/members`, { method: "POST", body: JSON.stringify(payload) }), { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v2/contexts/{id}/members (route)", () => {
  it("gate 꺼짐(기본)이면 404, DB 클라이언트도 만들지 않는다", async () => {
    expect((await call(body)).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(changeContextMembership).not.toHaveBeenCalled();
  });

  it("MEMORY_ENABLED가 정확히 true일 때만 켜진다 (TRUE · 1 · 공백은 꺼짐)", async () => {
    for (const value of ["TRUE", "1", " true", "false"]) {
      vi.stubEnv("MEMORY_ENABLED", value);
      expect((await call(body)).status, value).toBe(404);
    }
    expect(changeContextMembership).not.toHaveBeenCalled();
  });

  it("켜져 있으면 인증한 사용자 · 경로의 범위 id · 검증한 본문(version 조건 포함)으로 쓴다 (없는 범위는 404). 빼기는 remove로", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    expect((await call(body)).status).toBe(404);
    expect(changeContextMembership).toHaveBeenCalledWith({ admin: true }, USER, { actionId: ACTION, add: { contextId: CONTEXT, expectedVersion: 3 } });
    expect((await call({ ...body, op: "remove" })).status).toBe(404);
    expect(changeContextMembership).toHaveBeenLastCalledWith({ admin: true }, USER, { actionId: ACTION, remove: { contextId: CONTEXT, expectedVersion: 3 } });
    expect((await call({ op: "add", member_kind: "action", member_id: ACTION })).status).toBe(400); // 조건 없는 요청은 받지 않는다
    expect(changeContextMembership).toHaveBeenCalledTimes(2);
  });

  // 검토 P2-3: 일괄 말로 이동과 겹쳐 교착의 피해자가 되어도 500이 아니라 다시 보내면 되는 409 busy_retry다 (쓰기는 롤백됐다)
  it("잠금 경합(55P03) · 직렬화 실패(40001) · 교착(40P01)은 500이 아니라 409 busy_retry. 그 밖의 DB 오류는 500", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    for (const code of ["40P01", "55P03", "40001"]) {
      vi.mocked(changeContextMembership).mockRejectedValueOnce(Object.assign(new Error("db"), { code }));
      const response = await call(body);
      expect(response.status, code).toBe(409);
      expect((await response.json()).error.code, code).toBe("busy_retry");
    }
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.mocked(changeContextMembership).mockRejectedValueOnce(Object.assign(new Error("db"), { code: "XX000" }));
    expect((await call(body)).status).toBe(500);
  });
});
