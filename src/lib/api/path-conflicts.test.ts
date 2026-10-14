import { afterEach, describe, expect, it, vi } from "vitest";

import { handleResolvePathConflict, type ResolvePathConflictDeps } from "./path-conflicts";

// POST /api/v2/path-conflicts/{lease_id}/resolve 처리 (OA D4b-s, 계약 3.3): 의존성을 인자로 받는 handler만 본다. 진짜 인증 · 쿠키 CSRF · gate 조합은 route 시험이 본다.

const USER = { user: { id: "11111111-0000-4000-8000-000000000001" } };
const LEASE = "e0000000-0000-4000-8000-000000000001";
const BODY = { keep: "holder", conflict_version: 3 };

afterEach(() => vi.restoreAllMocks());

function deps(over: Partial<ResolvePathConflictDeps<typeof USER>> = {}) {
  const resolve = vi.fn(async () => ({ status: "resolved" as const }));
  const enabled = vi.fn(() => true);
  const authenticate = vi.fn(async () => USER);
  return { resolve, enabled, authenticate, deps: { enabled, authenticate, resolve, ...over } satisfies ResolvePathConflictDeps<typeof USER> };
}
const post = (body: unknown, lease = LEASE, d: ResolvePathConflictDeps<typeof USER>) =>
  handleResolvePathConflict(new Request(`https://api.example.test/api/v2/path-conflicts/${lease}/resolve`, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) }), lease, d);
const notFound = { error: { code: "not_found", message: "없는 경로입니다." } };

describe("handleResolvePathConflict", () => {
  it("gate가 꺼져 있으면 404: 인증 · 해소를 부르지 않는다", async () => {
    const t = deps({ enabled: () => false });
    const response = await post(BODY, LEASE, t.deps);
    expect([response.status, await response.json()]).toEqual([404, notFound]);
    expect(t.authenticate).not.toHaveBeenCalled();
    expect(t.resolve).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401이고 해소를 부르지 않는다", async () => {
    const t = deps({ authenticate: async () => null });
    expect((await post(BODY, LEASE, t.deps)).status).toBe(401);
    expect(t.resolve).not.toHaveBeenCalled();
  });

  it.each(["not-a-uuid", "", "e0000000-0000-4000-8000-00000000000", "e0000000-0000-4000-8000-0000000000012", "'; drop table x; --"])("lease id가 UUID 모양이 아니면(%j) 404이고 해소를 부르지 않는다", async (bad) => {
    const t = deps();
    expect((await post(BODY, bad, t.deps)).status).toBe(404);
    expect(t.resolve).not.toHaveBeenCalled();
  });

  it.each([
    ["본문 없음", ""],
    ["JSON이 아님", "{not json"],
    ["keep 없음", { conflict_version: 1 }],
    ["conflict_version 없음", { keep: "holder" }],
    ["keep이 둘 밖의 값", { keep: "both", conflict_version: 1 }],
    ["conflict_version 0", { keep: "holder", conflict_version: 0 }],
    ["conflict_version 음수", { keep: "holder", conflict_version: -2 }],
    ["conflict_version 소수", { keep: "later", conflict_version: 1.5 }],
    ["conflict_version 글자", { keep: "later", conflict_version: "1" }],
    ["conflict_version DB 범위 밖", { keep: "later", conflict_version: 2_147_483_648 }],
    ["모르는 키", { keep: "holder", conflict_version: 1, user_id: "x" }],
  ])("본문이 틀리면(%s) 400 invalid_request이고 해소를 부르지 않는다", async (_name, body) => {
    const t = deps();
    const response = await post(body, LEASE, t.deps);
    expect(response.status).toBe(400);
    expect((await response.json()).error.code).toBe("invalid_request");
    expect(t.resolve).not.toHaveBeenCalled();
  });

  it.each(["holder", "later"] as const)("resolved → 200 { status: resolved } (no-store), 인증된 사용자와 본문의 keep · version으로만 해소한다 (%s)", async (keep) => {
    const t = deps();
    const response = await post({ keep, conflict_version: 7 }, LEASE, t.deps);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "resolved" });
    expect(t.resolve).toHaveBeenCalledExactlyOnceWith(USER, { leaseId: LEASE, keep, conflictVersion: 7 });
  });

  it("stale(옛 version이거나 이미 해소됨) → 409 conflict. 응답에 값이 없다", async () => {
    const t = deps({ resolve: async () => ({ status: "stale" }) });
    const response = await post(BODY, LEASE, t.deps);
    expect(response.status).toBe(409);
    const body = await response.json();
    expect(body.error.code).toBe("conflict");
    expect(JSON.stringify(body)).not.toContain(LEASE);
  });

  it("not_found(없는 lease · 남의 lease) → 404", async () => {
    const t = deps({ resolve: async () => ({ status: "not_found" }) });
    const response = await post(BODY, LEASE, t.deps);
    expect(response.status).toBe(404);
    expect((await response.json()).error.code).toBe("not_found");
  });

  it("해소가 던지면 500 internal_error이고 로그에는 오류 이름만 남는다 (lease id · 경로 · 본문 · 메시지 0)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const t = deps({
      resolve: async () => {
        throw Object.assign(new Error(`failed for ${LEASE} at /w/proj/pricing.mdx`), { name: "PostgrestError" });
      },
    });
    const response = await post(BODY, LEASE, t.deps);
    expect(response.status).toBe(500);
    expect((await response.json()).error.code).toBe("internal_error");
    expect(log).toHaveBeenCalledTimes(1);
    const logged = String(log.mock.calls[0][0]);
    expect(JSON.parse(logged)).toEqual({ event: "path_conflict_resolve_failed", error: "PostgrestError" });
    for (const text of [LEASE, "/w/proj", "pricing", "holder"]) expect(logged).not.toContain(text);
  });
});
