import { afterEach, describe, expect, it, vi } from "vitest";

import type { WorkContext } from "./contract";
import { apiErrorV2Schema, workContextResponseSchema } from "./contract";
import { handleCreateWorkContext, handleUpdateWorkContext } from "./contexts";

const USER = { user: { id: "11111111-0000-4000-8000-000000000001" } };
const ID = "cccccccc-0000-4000-8000-000000000001";
const context: WorkContext = {
  id: ID,
  name: "Shape",
  kind: "project",
  status: "active",
  icon: "rocket",
  version: 1,
  context_version: 1,
  last_activity_at: "2026-10-13T00:00:00Z",
  created_at: "2026-10-13T00:00:00Z",
  updated_at: "2026-10-13T00:00:00Z",
};
const request = (body: unknown) => new Request("https://api.example.test/api/v2/contexts", { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });
const createDeps = (overrides: Partial<Parameters<typeof handleCreateWorkContext>[1]> = {}) => ({
  enabled: vi.fn(() => true),
  authenticate: vi.fn(async () => USER),
  create: vi.fn(async () => context),
  ...overrides,
});
const updateDeps = (overrides: Partial<Parameters<typeof handleUpdateWorkContext>[2]> = {}) => ({
  enabled: vi.fn(() => true),
  authenticate: vi.fn(async () => USER),
  update: vi.fn(async () => ({ status: "ok" as const, context })),
  ...overrides,
});

afterEach(() => vi.restoreAllMocks());

describe("POST /api/v2/contexts", () => {
  it("오류 이름과 코드만 구조화 로그에 남기고 500을 반환한다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = createDeps({ create: async () => { throw Object.assign(new Error("private detail"), { code: "XX000" }); } });
    expect((await handleCreateWorkContext(request({ name: "Shape", kind: "project" }), d)).status).toBe(500);
    expect(log).toHaveBeenCalledWith(JSON.stringify({ event: "context_create_failed", error: "Error", code: "XX000" }));
    expect(log.mock.calls.flat().join(" ")).not.toContain("private detail");
  });

  it("gate off는 인증 · 쓰기 없이 404", async () => {
    const d = createDeps({ enabled: () => false });
    expect((await handleCreateWorkContext(request({ name: "Shape", kind: "project" }), d)).status).toBe(404);
    expect(d.authenticate).not.toHaveBeenCalled();
    expect(d.create).not.toHaveBeenCalled();
  });

  it("인증되지 않으면 401, 본문 오류는 400이고 쓰기 0", async () => {
    const unauthenticated = createDeps({ authenticate: async () => null });
    expect((await handleCreateWorkContext(request({ name: "Shape", kind: "project" }), unauthenticated)).status).toBe(401);
    const d = createDeps();
    for (const body of [{ name: "Shape" }, { name: "Shape", kind: "project", icon: "star" }, { name: " ", kind: "project" }, { name: "Shape", kind: "project", user_id: "22222222-0000-4000-8000-000000000002" }]) {
      const response = await handleCreateWorkContext(request(body), d);
      expect(response.status).toBe(400);
      expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("invalid_request");
    }
    expect(d.create).not.toHaveBeenCalled();
  });

  it("optional icon을 저장소에 넘기고 응답 context를 반환한다", async () => {
    const d = createDeps();
    const response = await handleCreateWorkContext(request({ name: "Shape", kind: "project", icon: "rocket" }), d);
    expect(response.status).toBe(200);
    expect(workContextResponseSchema.parse(await response.json())).toEqual({ context });
    expect(d.create).toHaveBeenCalledWith(USER, { name: "Shape", kind: "project", icon: "rocket" });
  });
});

describe("PATCH /api/v2/contexts/{id}", () => {
  it("저장소가 유효한 상태 없이 context를 반환하면 오류로 기록한다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = updateDeps({ update: async () => ({ status: "ok", context: null } as never) });
    expect((await handleUpdateWorkContext(request({ expected_version: 1, name: "Shape" }), ID, d)).status).toBe(500);
    expect(log).toHaveBeenCalledWith(JSON.stringify({ event: "context_update_failed", error: "ZodError" }));
  });

  it("wrong version은 409, 없는 맥락은 404", async () => {
    const conflict = updateDeps({ update: async () => ({ status: "conflict" as const }) });
    const missing = updateDeps({ update: async () => ({ status: "not_found" as const }) });
    const call = (d: Parameters<typeof handleUpdateWorkContext>[2]) => handleUpdateWorkContext(request({ expected_version: 1, name: "Shape 2" }), ID, d);
    expect((await call(conflict)).status).toBe(409);
    expect(apiErrorV2Schema.parse(await (await call(conflict)).json()).error.code).toBe("conflict");
    expect((await call(missing)).status).toBe(404);
  });

  it("id와 expected_version 필수 필드를 검증하고 200 context를 반환한다", async () => {
    const d = updateDeps();
    expect((await handleUpdateWorkContext(request({ expected_version: 1, name: "x" }), "bad-id", d)).status).toBe(404);
    for (const body of [{ name: "Shape" }, { expected_version: 1 }, { expected_version: 0, name: "Shape" }, { expected_version: 1, icon: "star" }]) {
      expect((await handleUpdateWorkContext(request(body), ID, d)).status).toBe(400);
    }
    expect(d.update).not.toHaveBeenCalled();
    const response = await handleUpdateWorkContext(request({ expected_version: 1, icon: "rocket" }), ID, d);
    expect(response.status).toBe(200);
    expect(workContextResponseSchema.parse(await response.json())).toEqual({ context });
    expect(d.update).toHaveBeenCalledWith(USER, ID, 1, { icon: "rocket" });
  });
});
