import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createContext } from "@/lib/context/store";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/context/store", () => ({ createContext: vi.fn(async () => ({
  id: "cccccccc-0000-4000-8000-000000000001", name: "Shape", kind: "project", status: "active", icon: "rocket", version: 1,
  context_version: 1, last_activity_at: "2026-10-13T00:00:00Z", created_at: "2026-10-13T00:00:00Z", updated_at: "2026-10-13T00:00:00Z",
})) }));

const call = (body: unknown) => POST(new Request("https://api.example.test/api/v2/contexts", { method: "POST", body: JSON.stringify(body) }));

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v2/contexts (route)", () => {
  it("MEMORY_ENABLED off는 404이며 admin client를 만들지 않는다", async () => {
    expect((await call({ name: "Shape", kind: "project" })).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(createContext).not.toHaveBeenCalled();
  });

  it("켜지면 요청자와 제한된 입력으로 저장소 함수를 부른다", async () => {
    vi.stubEnv("MEMORY_ENABLED", "true");
    const response = await call({ name: "Shape", kind: "project", icon: "rocket" });
    expect(response.status).toBe(200);
    expect(createContext).toHaveBeenCalledWith({ admin: true }, "11111111-0000-4000-8000-000000000001", { name: "Shape", kind: "project", icon: "rocket" });
  });
});
