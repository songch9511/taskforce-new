import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { changeContextMembership } from "@/lib/context/member-writes";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/context/member-writes", () => ({ changeContextMembership: vi.fn(async () => ({ status: "conflict" })) }));

// 범위 멤버십 옮기기 (S3b). gate 꺼짐(기본)은 DB 클라이언트도 만들지 않고, 켜졌을 때 도착(경로) · 출발(본문) 범위와 두 version 조건이 한 번의 쓰기로 간다.
const TO = "cccccccc-0000-4000-8000-000000000001";
const FROM = "cccccccc-0000-4000-8000-000000000002";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const body = { member_kind: "action", member_id: ACTION, from_context_id: FROM, expected_context_version: 3, expected_from_context_version: 7 };
const call = (payload: unknown, id = TO) =>
  POST(new Request(`https://api.example.dev/api/v2/contexts/${id}/members/move`, { method: "POST", body: JSON.stringify(payload) }), { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v2/contexts/{to}/members/move (route)", () => {
  it("gate 꺼짐(기본)이면 404, DB 클라이언트도 만들지 않는다", async () => {
    expect((await call(body)).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(changeContextMembership).not.toHaveBeenCalled();
  });

  it("켜져 있으면 한 번의 쓰기로 도착 범위(경로) + 출발 범위(본문)와 두 version 조건을 보낸다 (낡은 version은 409)", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    const response = await call(body);
    expect(response.status).toBe(409);
    expect(changeContextMembership).toHaveBeenCalledTimes(1);
    expect(changeContextMembership).toHaveBeenCalledWith({ admin: true }, USER, {
      actionId: ACTION,
      add: { contextId: TO, expectedVersion: 3 },
      remove: { contextId: FROM, expectedVersion: 7 },
    });
    expect((await call({ ...body, from_context_id: TO })).status).toBe(400); // 같은 범위
    expect((await call({ member_kind: "action", member_id: ACTION, from_context_id: FROM })).status).toBe(400); // 조건 없음
    expect(changeContextMembership).toHaveBeenCalledTimes(1);
  });

  it("교착(40P01) · 잠금 경합(55P03) · 직렬화 실패(40001)는 500이 아니라 409 busy_retry (검토 P2-3: 일괄 말로 이동과 겹친 피해자)", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    for (const code of ["40P01", "55P03", "40001"]) {
      vi.mocked(changeContextMembership).mockRejectedValueOnce(Object.assign(new Error("db"), { code }));
      const response = await call(body);
      expect(response.status, code).toBe(409);
      expect((await response.json()).error.code, code).toBe("busy_retry");
    }
  });
});
