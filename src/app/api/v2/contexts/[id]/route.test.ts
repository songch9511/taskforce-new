import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { updateContext } from "@/lib/context/store";
import { createAdminClient } from "@/lib/supabase/admin";

import { PATCH } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/context/store", () => ({ updateContext: vi.fn(async () => ({ status: "not_found" })) }));

const ID = "cccccccc-0000-4000-8000-000000000001";
const call = (body: unknown, id = ID) => PATCH(new Request(`https://api.example.test/api/v2/contexts/${id}`, { method: "PATCH", body: JSON.stringify(body) }), { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("PATCH /api/v2/contexts/{id} (route)", () => {
  it("gate off는 404이며 admin client를 만들지 않는다", async () => {
    expect((await call({ expected_version: 1, icon: "rocket" })).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(updateContext).not.toHaveBeenCalled();
  });

  it("gate on은 optimistic version과 필드를 저장소에 전달한다", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    expect((await call({ expected_version: 3, icon: "rocket" })).status).toBe(404); // mock SQL 함수가 없는 범위로 답함
    expect(updateContext).toHaveBeenCalledWith({ admin: true }, "11111111-0000-4000-8000-000000000001", ID, 3, { icon: "rocket" });
  });
});
