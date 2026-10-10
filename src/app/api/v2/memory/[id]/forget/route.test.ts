import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { forgetMemoryItem } from "@/lib/context/memory-writes";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/context/memory-writes", () => ({
  forgetMemoryItem: vi.fn(async () => ({ status: "not_found" })),
}));

// 기억 잊기 (B3). route는 얇다: gate · 인증 · 본문 검증은 lib/api/memory.test.ts, 규칙은 tests/db/memory-writes.scenarios.ts가 본다.
// 여기서는 gate 꺼짐(기본)이 DB 클라이언트도 만들지 않는다는 것과 켜졌을 때 경로의 id · 사용자 · 본문이 그대로 쓰기에 간다는 것만 본다.
const ID = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const call = (body: unknown, id = ID) =>
  POST(new Request(`https://api.example.dev/api/v2/memory/${id}/forget`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v2/memory/{id}/forget (route)", () => {
  it("gate 꺼짐(기본)이면 404, DB 클라이언트도 만들지 않는다", async () => {
    expect((await call({ expected_version: 1 })).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(forgetMemoryItem).not.toHaveBeenCalled();
  });

  it("MEMORY_ENABLED가 정확히 true일 때만 켜진다 (TRUE · 1 · 공백은 꺼짐)", async () => {
    for (const value of ["TRUE", "1", " true", "false"]) {
      vi.stubEnv("MEMORY_ENABLED", value);
      expect((await call({ expected_version: 1 })).status, value).toBe(404);
    }
    expect(forgetMemoryItem).not.toHaveBeenCalled();
  });

  it("켜져 있으면 인증한 사용자 · 경로의 id · 검증한 본문으로 쓴다 (없는 기억은 404)", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    const response = await call({ expected_version: 1 });
    expect(response.status).toBe(404);
    expect(forgetMemoryItem).toHaveBeenCalledWith({ admin: true }, USER, ID, 1);
    expect((await call({})).status).toBe(400);
    expect(forgetMemoryItem).toHaveBeenCalledTimes(1);
  });
});
