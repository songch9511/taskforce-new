import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { MemoryWriteOutcome } from "@/lib/context/memory-edit";

import { apiErrorV2Schema, memoryItemResponseSchema, type MemoryItem } from "./contract";
import { handleConfirmMemory, handleEditMemory, handleForgetMemory, handleMoveMemory } from "./memory";

// POST/PATCH /api/v2/memory/{id}… 처리 (B3). 쓰기를 가짜로 두고 호출 수로 "gate 꺼짐 · 인증 거부 · 잘못된 요청에서는 쓰기 0"을 증명한다.
// 규칙(Slack 보류 · 같은 사실 · version)은 순수 모듈 src/lib/context/memory-edit.test.ts와 DB 시나리오(tests/db/memory-writes.scenarios.ts)가 본다.

type User = { user: { id: string } };
const USER: User = { user: { id: "11111111-0000-4000-8000-000000000001" } };
const ID = "aaaaaaaa-0000-4000-8000-000000000001";
const CONTEXT = "cccccccc-0000-4000-8000-000000000001";

const item: MemoryItem = {
  id: ID,
  kind: "fact",
  scope_kind: "global",
  context_id: null,
  action_id: null,
  person_id: null,
  agent_adapter: null,
  subject: "launch day",
  statement: "출시는 목요일",
  value: {},
  origin: "explicit",
  source_ref: null,
  observed_at: "2026-10-10T01:00:00.000Z",
  valid_from: null,
  valid_until: null,
  superseded_by: null,
  superseded_at: null,
  revoked_at: null,
  confidence: null,
  source_purged: false,
  version: 1,
  created_at: "2026-10-10T01:00:00.000Z",
  updated_at: "2026-10-10T01:00:00.000Z",
};

const ok = (overrides: Partial<MemoryItem> = {}): MemoryWriteOutcome => ({ status: "ok", item: { ...item, ...overrides } });

function makeDeps(outcome: MemoryWriteOutcome | (() => Promise<MemoryWriteOutcome>) = ok()) {
  const write = vi.fn<(user: User, id: string, body: unknown) => Promise<MemoryWriteOutcome>>(async () => (typeof outcome === "function" ? outcome() : outcome));
  return {
    write,
    deps: {
      enabled: vi.fn(() => true),
      authenticate: vi.fn<(request: Request) => Promise<User | null>>(async () => USER),
      confirm: write,
      edit: write,
      forget: write,
      move: write,
    },
  };
}

type Case = {
  name: string;
  call: (request: Request, id: string, deps: ReturnType<typeof makeDeps>["deps"]) => Promise<Response>;
  method: string;
  body: unknown;
  unavailable: "confirm_unavailable" | "scope_unavailable" | null;
  badBodies: unknown[];
};

const CASES: Case[] = [
  {
    name: "confirm",
    call: (request, id, deps) => handleConfirmMemory(request, id, deps),
    method: "POST",
    body: { expected_version: 1 },
    unavailable: "confirm_unavailable",
    badBodies: [{}, { expected_version: 0 }, { expected_version: 1.5 }, { expected_version: "1" }, { expected_version: 1, statement: "x" }, { expected_version: 1, origin: "explicit" }],
  },
  {
    name: "edit",
    call: (request, id, deps) => handleEditMemory(request, id, deps),
    method: "PATCH",
    body: { expected_version: 1, statement: "출시는 금요일" },
    unavailable: "confirm_unavailable",
    badBodies: [
      {},
      { expected_version: 1 },
      { expected_version: 1, statement: "   " },
      { expected_version: 1, statement: "x".repeat(1001) },
      { expected_version: 1, statement: "x", scope_kind: "global" },
      { expected_version: 1, statement: "x", origin: "inferred" },
      { expected_version: 1, statement: "x", value: null }, // 비우려면 {} (value는 nullable이 아니다, valid_from · valid_until만 null)
      { expected_version: 1, statement: "x", value: "{}" },
      { expected_version: 1, statement: "x", valid_from: "2026-10-10T00:00:00Z", valid_until: "2026-10-01T00:00:00Z" },
    ],
  },
  {
    name: "forget",
    call: (request, id, deps) => handleForgetMemory(request, id, deps),
    method: "POST",
    body: { expected_version: 1 },
    unavailable: null,
    badBodies: [{}, { expected_version: -1 }, { expected_version: 1, revoked_at: "2026-10-10T00:00:00Z" }],
  },
  {
    name: "scope",
    call: (request, id, deps) => handleMoveMemory(request, id, deps),
    method: "POST",
    body: { expected_version: 1, scope_kind: "context", context_id: CONTEXT },
    unavailable: "scope_unavailable",
    badBodies: [
      {},
      { expected_version: 1 },
      { expected_version: 1, scope_kind: "team", context_id: null },
      { expected_version: 1, scope_kind: "context" }, // 범위 종류가 context면 대상이 필요하다
      { expected_version: 1, scope_kind: "context", context_id: null },
      { expected_version: 1, scope_kind: "global", context_id: CONTEXT }, // 전체는 대상이 없다
      { expected_version: 1, scope_kind: "context", context_id: "not-a-uuid" },
      { expected_version: 1, scope_kind: "global", user_id: ID },
      { expected_version: 1, scope_kind: "agent", context_id: null },
    ],
  },
];

const req = (method: string, body: unknown) => new Request("https://api.example.dev/api/v2/memory/x", { method, body: typeof body === "string" ? body : JSON.stringify(body) });

let errors: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
});
afterEach(() => {
  errors.mockRestore();
});

describe.each(CASES)("기억 쓰기 route 처리: $name", (c) => {
  it("gate MEMORY_ENABLED가 꺼져 있으면 404: 인증 · 쓰기를 부르지 않는다", async () => {
    const { deps, write } = makeDeps();
    deps.enabled = vi.fn(() => false);
    const response = await c.call(req(c.method, c.body), ID, deps);
    expect(response.status).toBe(404);
    expect(deps.authenticate).not.toHaveBeenCalled();
    expect(write).not.toHaveBeenCalled();
  });

  it("인증 거부 401 · 잘못된 기억 id 404 · 잘못된 본문 400: 쓰기 0", async () => {
    const unauth = makeDeps();
    unauth.deps.authenticate = vi.fn(async () => null);
    expect((await c.call(req(c.method, c.body), ID, unauth.deps)).status).toBe(401);
    expect(unauth.write).not.toHaveBeenCalled();

    const { deps, write } = makeDeps();
    expect((await c.call(req(c.method, c.body), "not-a-uuid", deps)).status).toBe(404);
    expect((await c.call(req(c.method, "{not json"), ID, deps)).status).toBe(400);
    for (const bad of c.badBodies) {
      const response = await c.call(req(c.method, bad), ID, deps);
      expect(response.status, JSON.stringify(bad)).toBe(400);
      expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("invalid_request");
    }
    expect(write).not.toHaveBeenCalled();
  });

  it("성공은 200 { item } (스키마를 지킨다). 쓰기에는 인증한 사용자 · 경로의 id · 검증한 본문만 간다", async () => {
    const { deps, write } = makeDeps();
    const response = await c.call(req(c.method, c.body), ID, deps);
    expect(response.status).toBe(200);
    expect(memoryItemResponseSchema.parse(await response.json()).item.id).toBe(ID);
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith(USER, ID, expect.objectContaining({ expected_version: 1 }));
  });

  it("없거나 남의 기억 404 · version 충돌 · 이미 정정 · 잊음 409 conflict (이유 코드와 구별된다)", async () => {
    const missing = makeDeps({ status: "not_found" });
    const notFound = await c.call(req(c.method, c.body), ID, missing.deps);
    expect(notFound.status).toBe(404);
    expect(apiErrorV2Schema.parse(await notFound.json()).error.code).toBe("not_found");

    const stale = makeDeps({ status: "conflict" });
    const conflict = await c.call(req(c.method, c.body), ID, stale.deps);
    expect(conflict.status).toBe(409);
    expect(apiErrorV2Schema.parse(await conflict.json()).error.code).toBe("conflict");
  });

  it("정책 보류의 거절은 409 이유 코드다 (앱은 그 동작을 감춘다). 잊기는 정책 거절이 없다", async () => {
    const { deps } = makeDeps({ status: "unavailable" });
    const response = await c.call(req(c.method, c.body), ID, deps);
    expect(response.status).toBe(409);
    const body = apiErrorV2Schema.parse(await response.json());
    expect(body.error.code).toBe(c.unavailable ?? "conflict");
  });

  it("예기치 못한 오류는 500이고, 요청 글 · 기억 글은 로그에 남지 않는다 (동작 · 오류 이름 · DB 코드만)", async () => {
    const secret = "비밀 회의 내용: 계약 금액 3억";
    const body = c.name === "edit" ? { expected_version: 1, statement: secret } : c.body;
    const { deps } = makeDeps(async () => {
      throw Object.assign(new Error(`failed near ${secret}`), { code: "23514" });
    });
    const response = await c.call(req(c.method, body), ID, deps);
    expect(response.status).toBe(500);
    expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("internal_error");
    const logged = errors.mock.calls.map((call: unknown[]) => String(call[0])).join("\n");
    expect(logged).toContain("memory_write_failed");
    expect(logged).toContain("23514");
    expect(logged).not.toContain(secret);
  });
});

describe("정정 route 처리의 고유 규칙", () => {
  it("valid_from이 valid_until보다 늦어지는 병합(옛 행에서 이어받은 값과 요청의 값)은 400이다", async () => {
    const { deps } = makeDeps({ status: "invalid" });
    const response = await handleEditMemory(req("PATCH", { expected_version: 1, statement: "x", valid_until: "2026-10-01T00:00:00Z" }), ID, deps);
    expect(response.status).toBe(400);
    expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("invalid_request");
  });

  it("글은 앞뒤 공백을 걷어 쓰기에 넘긴다", async () => {
    const { deps, write } = makeDeps();
    await handleEditMemory(req("PATCH", { expected_version: 2, statement: "  출시는 금요일  ", value: { day: "fri" }, valid_until: null }), ID, deps);
    expect(write).toHaveBeenCalledWith(USER, ID, { expected_version: 2, statement: "출시는 금요일", value: { day: "fri" }, valid_until: null });
  });
});

describe("정정 비우기 계약", () => {
  it("value를 비우려면 {}를 보낸다(그대로 쓰기에 간다). 생략한 키는 쓰기 입력에 없다(상속은 규칙에서). valid_from · valid_until만 null로 비운다", async () => {
    const { deps, write } = makeDeps();
    await handleEditMemory(req("PATCH", { expected_version: 2, statement: "x", value: {}, valid_from: null }), ID, deps);
    await handleEditMemory(req("PATCH", { expected_version: 2, statement: "x" }), ID, deps);
    expect(write.mock.calls.map((call) => call[2])).toEqual([{ expected_version: 2, statement: "x", value: {}, valid_from: null }, { expected_version: 2, statement: "x" }]);
  });
});

describe("범위 옮기기 route 처리의 고유 규칙", () => {
  it("전체로 옮길 때 context_id는 비워도(null) 생략해도 같다", async () => {
    const { deps, write } = makeDeps();
    await handleMoveMemory(req("POST", { expected_version: 1, scope_kind: "global", context_id: null }), ID, deps);
    await handleMoveMemory(req("POST", { expected_version: 1, scope_kind: "global" }), ID, deps);
    expect(write.mock.calls.map((call) => call[2])).toEqual([
      { expected_version: 1, scope_kind: "global", context_id: null },
      { expected_version: 1, scope_kind: "global", context_id: null },
    ]);
  });
});
