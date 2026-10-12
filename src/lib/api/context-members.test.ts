import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import type { ContextMemberChange, ContextMemberOutcome, ContextMemberWritten } from "@/lib/context/member-writes";

import { handleChangeContextMember, handleMoveContextMember } from "./context-members";
import { apiErrorV2Schema, contextMemberMoveResponseSchema, contextMembershipResponseSchema, type ContextMember } from "./contract";

// POST /api/v2/contexts/{id}/members (+ /move) 처리 (S3b). 쓰기를 가짜로 두고 호출 수로 "gate 꺼짐 · 인증 거부 · 잘못된 요청에서는 쓰기 0"을 증명한다.
// 규칙(조건부 쓰기 · 실제 변화 · 승격 · 뺀 표시)은 DB 시나리오(tests/db/context-members.scenarios.ts)가 본다. 여기서는 JSON 계약(요청 검증 · 응답 모양 · 오류 코드)을 본다.

type User = { user: { id: string } };
const USER: User = { user: { id: "11111111-0000-4000-8000-000000000001" } };
const CTX = "cccccccc-0000-4000-8000-000000000001";
const FROM = "cccccccc-0000-4000-8000-000000000002";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";

const member = (over: Partial<ContextMember> = {}): ContextMember => ({
  id: "bbbbbbbb-0000-4000-8000-000000000001",
  context_id: CTX,
  member_kind: "action",
  action_id: ACTION,
  source_id: null,
  person_id: null,
  origin: "user",
  confidence: null,
  removed_at: null,
  created_at: "2026-10-11T01:00:00.000Z",
  updated_at: "2026-10-11T01:00:00.000Z",
  ...over,
});
const written = (over: Partial<ContextMemberWritten> & { member?: ContextMember } = {}): ContextMemberWritten => ({ member: member(), contextVersion: 5, changed: true, ...over });

function makeDeps(outcome: ContextMemberOutcome | (() => Promise<ContextMemberOutcome>)) {
  const change = vi.fn<(user: User, change: ContextMemberChange) => Promise<ContextMemberOutcome>>(async () => (typeof outcome === "function" ? outcome() : outcome));
  return {
    change,
    deps: { enabled: vi.fn(() => true), authenticate: vi.fn<(request: Request) => Promise<User | null>>(async () => USER), change },
  };
}

const post = (body: unknown) => new Request("https://api.example.dev/api/v2/contexts/x/members", { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });
const add = { op: "add", member_kind: "action", member_id: ACTION, expected_context_version: 4 };
const move = { member_kind: "action", member_id: ACTION, from_context_id: FROM, expected_context_version: 4, expected_from_context_version: 2 };

afterEach(() => vi.restoreAllMocks());

describe("POST /api/v2/contexts/{id}/members (넣기 · 빼기)", () => {
  it("gate 꺼짐이면 404: 인증 · 쓰기를 부르지 않는다", async () => {
    const { deps, change } = makeDeps({ status: "ok", added: written(), removed: null });
    deps.enabled.mockReturnValue(false);
    const response = await handleChangeContextMember(post(add), CTX, deps);
    expect(response.status).toBe(404);
    expect(apiErrorV2Schema.parse(await response.json()).error).toMatchObject({ code: "not_found", message: "없는 경로입니다." });
    expect(deps.authenticate).not.toHaveBeenCalled();
    expect(change).not.toHaveBeenCalled();
  });

  it("인증하지 못하면 401, 잘못된 범위 id는 404, 잘못된 본문은 400이고 모두 쓰기 0", async () => {
    const { deps, change } = makeDeps({ status: "ok", added: written(), removed: null });
    deps.authenticate.mockResolvedValueOnce(null);
    expect((await handleChangeContextMember(post(add), CTX, deps)).status).toBe(401);
    expect((await handleChangeContextMember(post(add), "not-a-uuid", deps)).status).toBe(404);
    expect((await handleChangeContextMember(post("{not json"), CTX, deps)).status).toBe(400);
    const bad: unknown[] = [
      {},
      { op: "add", member_kind: "action", member_id: ACTION }, // 조건(expected_context_version) 없음
      { ...add, expected_context_version: 0 },
      { ...add, expected_context_version: 1.5 },
      { ...add, expected_context_version: "4" },
      { ...add, op: "move" },
      { ...add, member_id: "x" },
      { ...add, member_kind: "source" }, // S3b는 할 일만
      { ...add, member_kind: "person" },
      { ...add, origin: "auto" }, // origin은 요청이 정하지 않는다 (언제나 user)
      { ...add, confidence: 0.5 },
    ];
    for (const body of bad) {
      const response = await handleChangeContextMember(post(body), CTX, deps);
      expect(response.status, JSON.stringify(body)).toBe(400);
      expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("invalid_request");
    }
    expect(change).not.toHaveBeenCalled();
  });

  it("넣기는 경로의 범위 + 요청이 본 version으로, 빼기는 remove로 쓴다 (사용자 · 할 일 id 그대로). 200은 { member, context_version, change }", async () => {
    const { deps, change } = makeDeps({ status: "ok", added: written({ contextVersion: 5 }), removed: null });
    const response = await handleChangeContextMember(post(add), CTX, deps);
    expect(response.status).toBe(200);
    const body = contextMembershipResponseSchema.parse(await response.json());
    expect(body).toEqual({ member: member(), context_version: 5, change: { added: [{ context_id: CTX, context_version: 5 }], removed: [] } });
    expect(change).toHaveBeenCalledWith(USER, { actionId: ACTION, add: { contextId: CTX, expectedVersion: 4 } });

    const removed = member({ removed_at: "2026-10-11T02:00:00.000Z" });
    const removal = makeDeps({ status: "ok", added: null, removed: written({ member: removed, contextVersion: 6 }) });
    const removeResponse = await handleChangeContextMember(post({ ...add, op: "remove" }), CTX, removal.deps);
    expect(removal.change).toHaveBeenCalledWith(USER, { actionId: ACTION, remove: { contextId: CTX, expectedVersion: 4 } });
    expect(contextMembershipResponseSchema.parse(await removeResponse.json())).toEqual({
      member: removed,
      context_version: 6,
      change: { added: [], removed: [{ context_id: CTX, context_version: 6 }] },
    });
  });

  it("바뀐 멤버가 없으면(이미 그 상태 · 승격 · 후보 빼기) change가 비어 있다: 되돌릴 것이 없다", async () => {
    const { deps } = makeDeps({ status: "ok", added: written({ changed: false }), removed: null });
    const body = contextMembershipResponseSchema.parse(await (await handleChangeContextMember(post(add), CTX, deps)).json());
    expect(body.change).toEqual({ added: [], removed: [] });
  });

  it("version이 다르면 409 conflict (쓰기 0은 DB가 보장), 남의 · 없는 · 보관된 범위와 남의 · 없는 할 일은 404", async () => {
    const conflict = await handleChangeContextMember(post(add), CTX, makeDeps({ status: "conflict" }).deps);
    expect(conflict.status).toBe(409);
    expect(apiErrorV2Schema.parse(await conflict.json()).error).toMatchObject({ code: "conflict", message: "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요." });
    const noContext = await handleChangeContextMember(post(add), CTX, makeDeps({ status: "context_not_found" }).deps);
    expect(noContext.status).toBe(404);
    expect(apiErrorV2Schema.parse(await noContext.json()).error).toMatchObject({ code: "not_found", message: "범위가 없습니다." });
    const noAction = await handleChangeContextMember(post(add), CTX, makeDeps({ status: "action_not_found" }).deps);
    expect(noAction.status).toBe(404);
    expect(apiErrorV2Schema.parse(await noAction.json()).error).toMatchObject({ code: "not_found", message: "할 일이 없습니다." });
  });

  it("예상 못 한 오류는 500 internal_error이고 로그에는 오류 이름과 DB 코드만 남는다 (id · 본문 없음)", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = makeDeps(async () => {
      throw Object.assign(new Error("boom: " + ACTION), { code: "40P01" });
    });
    const response = await handleChangeContextMember(post(add), CTX, failing.deps);
    expect(response.status).toBe(500);
    expect(apiErrorV2Schema.parse(await response.json()).error.code).toBe("internal_error");
    const logged = spy.mock.calls.map((call) => String(call[0])).join("\n");
    expect(logged).toContain("40P01");
    expect(logged).not.toContain(ACTION);
    expect(logged).not.toContain(CTX);
  });
});

describe("POST /api/v2/contexts/{to}/members/move (옮기기 · Undo)", () => {
  const moved = (): ContextMemberOutcome => ({
    status: "ok",
    added: written({ contextVersion: 5 }),
    removed: written({ member: member({ context_id: FROM, removed_at: "2026-10-11T02:00:00.000Z" }), contextVersion: 3 }),
  });

  it("gate 꺼짐 404 · 인증 거부 401 · 잘못된 id 404 · 잘못된 본문 400 · 같은 범위 400: 모두 쓰기 0", async () => {
    const { deps, change } = makeDeps(moved());
    deps.enabled.mockReturnValueOnce(false);
    expect((await handleMoveContextMember(post(move), CTX, deps)).status).toBe(404);
    deps.authenticate.mockResolvedValueOnce(null);
    expect((await handleMoveContextMember(post(move), CTX, deps)).status).toBe(401);
    expect((await handleMoveContextMember(post(move), "nope", deps)).status).toBe(404);
    const bad: unknown[] = [
      {},
      { member_kind: "action", member_id: ACTION, from_context_id: FROM },
      { ...move, expected_from_context_version: undefined },
      { ...move, expected_context_version: undefined },
      { ...move, expected_context_version: 0 },
      { ...move, from_context_id: "x" },
      { ...move, member_kind: "source" },
      { ...move, op: "add" },
    ];
    for (const body of bad) expect((await handleMoveContextMember(post(body), CTX, deps)).status, JSON.stringify(body)).toBe(400);
    const same = await handleMoveContextMember(post({ ...move, from_context_id: CTX.toUpperCase() }), CTX, deps);
    expect(same.status).toBe(400);
    expect(apiErrorV2Schema.parse(await same.json()).error.code).toBe("invalid_request");
    expect(deps.authenticate).toHaveBeenCalledTimes(bad.length + 3); // 본문 검증은 인증 뒤
    expect(change).not.toHaveBeenCalled();
  });

  it("경로의 범위가 도착이다: add는 도착 범위 + expected_context_version, remove는 from + expected_from_context_version으로 한 번에 쓴다. 200은 두 행 · 두 version · change", async () => {
    const { deps, change } = makeDeps(moved());
    const response = await handleMoveContextMember(post(move), CTX, deps);
    expect(response.status).toBe(200);
    expect(change).toHaveBeenCalledTimes(1);
    expect(change).toHaveBeenCalledWith(USER, { actionId: ACTION, add: { contextId: CTX, expectedVersion: 4 }, remove: { contextId: FROM, expectedVersion: 2 } });
    const body = contextMemberMoveResponseSchema.parse(await response.json());
    expect(body).toMatchObject({ context_version: 5, from_context_version: 3 });
    expect(body.member).toMatchObject({ context_id: CTX, removed_at: null });
    expect(body.from_member).toMatchObject({ context_id: FROM });
    expect(body.from_member.removed_at).not.toBeNull();
    expect(body.change).toEqual({ added: [{ context_id: CTX, context_version: 5 }], removed: [{ context_id: FROM, context_version: 3 }] });
  });

  it("실제 변화만 change에 든다: 도착 범위가 이미 멤버였으면 added가 비어 있다 (Undo는 from 넣기 하나)", async () => {
    const outcome: ContextMemberOutcome = { status: "ok", added: written({ changed: false }), removed: written({ member: member({ context_id: FROM, removed_at: "2026-10-11T02:00:00.000Z" }), contextVersion: 3 }) };
    const body = contextMemberMoveResponseSchema.parse(await (await handleMoveContextMember(post(move), CTX, makeDeps(outcome).deps)).json());
    expect(body.change).toEqual({ added: [], removed: [{ context_id: FROM, context_version: 3 }] });
  });

  it("409 conflict · 404 not_found를 그대로 옮긴다", async () => {
    expect((await handleMoveContextMember(post(move), CTX, makeDeps({ status: "conflict" }).deps)).status).toBe(409);
    expect((await handleMoveContextMember(post(move), CTX, makeDeps({ status: "context_not_found" }).deps)).status).toBe(404);
    expect((await handleMoveContextMember(post(move), CTX, makeDeps({ status: "action_not_found" }).deps)).status).toBe(404);
  });
});

describe("권한 경계 (I04 · I14 · D13)", () => {
  it("멤버십 handler · 저장소 · route는 실행 · 진실 판정 · Action 쓰기 코드를 가져오지 않는다 (멤버십은 권한이 아니다)", () => {
    const root = path.resolve(__dirname, "../../..");
    const files = [
      "src/lib/api/context-members.ts",
      "src/lib/context/member-writes.ts",
      "src/app/api/v2/contexts/[id]/members/route.ts",
      "src/app/api/v2/contexts/[id]/members/move/route.ts",
    ];
    for (const file of files) {
      const code = readFileSync(path.join(root, file), "utf8")
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .replace(/(^|[^:])\/\/.*$/gm, "$1");
      expect(code, file).not.toMatch(/@\/lib\/(execution|truth|actions|pipeline|sources|ai)\b|from ["'][^"']*\/execution|begin_call|resolve\(/);
    }
  });
});
