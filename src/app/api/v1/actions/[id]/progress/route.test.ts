import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { StoredRow } from "@/lib/actions/db-store";
import type { ClaimRow } from "@/lib/actions/rows";
import { authenticateRequest } from "@/lib/api/auth";
import { actionResponseSchema, apiErrorSchema } from "@/lib/api/contract";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));

// POST /api/v1/actions/:id/progress: 인증 → 본문 → 서비스(setActionProgress) → DB 함수 set_action_progress에 넘기는 값.
// DB 함수 자체는 tests/db/action-progress.test.ts에서 본다.

const ACTION = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";
const STARTED = "2026-09-28T01:00:00.000Z";

const statusClaim = (value: "open" | "done"): ClaimRow => ({
  id: "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d",
  field: "status",
  value,
  occurred_at: "2026-09-27T01:00:00.000Z",
  speaker_role: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  origin: "user",
  channel: "note",
});

const stored = (over: Partial<StoredRow> = {}): StoredRow => ({
  title: "견적서 보내기",
  confirm_reasons: [],
  needs_confirmation: false,
  version: 3,
  status: "open",
  started_at: null,
  ...over,
});

type Rpc = { fn: string; params: Record<string, unknown> };

/** actions 행 하나와 그 Claim만 읽고, rpc 호출을 기록하는 가짜 service role 클라이언트 */
function fakeAdmin(row: StoredRow | null, claims: ClaimRow[], rpcResult: () => { data: unknown; error: unknown } = () => ({ data: true, error: null })) {
  const rpcs: Rpc[] = [];
  const admin = {
    from: (table: string) => {
      let single = false;
      const q = {
        select: () => q,
        eq: () => q,
        returns: () => q,
        maybeSingle: () => q,
        single: () => {
          single = true;
          return q;
        },
        throwOnError: async () => {
          if (table === "claims") return { data: claims };
          if (!single) return { data: row };
          // 응답용 요약 (쓰기 결과를 흉내 내지 않는다: 넘긴 값은 rpcs로 본다)
          return {
            data: {
              id: ACTION,
              title: row!.title,
              owner: "me",
              status: row!.status,
              due_date: null,
              counterpart: null,
              needs_confirmation: false,
              confirm_reasons: [],
              started_at: row!.started_at,
              last_activity_at: STARTED,
            },
          };
        },
      };
      return q;
    },
    rpc: (fn: string, params: Record<string, unknown>) => {
      rpcs.push({ fn, params });
      return {
        throwOnError: async () => {
          const result = rpcResult();
          if (result.error) throw result.error;
          return result;
        },
      };
    },
  } as unknown as SupabaseClient;
  vi.mocked(createAdminClient).mockReturnValue(admin as ReturnType<typeof createAdminClient>);
  return rpcs;
}

function call(body: unknown, id = ACTION) {
  const request = new Request(`http://localhost/api/v1/actions/${id}/progress`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  return POST(request, { params: Promise.resolve({ id }) });
}

beforeEach(() => {
  vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1", email: null, name: "나" }, supabase: {} as SupabaseClient });
});

describe("POST /api/v1/actions/:id/progress", () => {
  it("로그인하지 않았으면 401", async () => {
    vi.mocked(authenticateRequest).mockResolvedValue(null);
    const response = await call({ state: "to_do" });
    expect(response.status).toBe(401);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("unauthorized");
  });

  it("본문이 잘못됐으면 400 (모르는 상태 · 빈 본문 · JSON 아님)", async () => {
    const rpcs = fakeAdmin(stored(), []);
    for (const body of [{ state: "doing" }, {}, "not json"]) {
      const response = await call(body);
      expect(response.status).toBe(400);
      expect(apiErrorSchema.parse(await response.json()).error.code).toBe("invalid_request");
    }
    expect(rpcs).toEqual([]);
  });

  it("id가 uuid가 아니거나, 없거나 남의 것이거나, 취소된 Action이면 404", async () => {
    fakeAdmin(null, []);
    expect((await call({ state: "to_do" }, "not-a-uuid")).status).toBe(404);
    expect((await call({ state: "to_do" })).status).toBe(404);
    const rpcs = fakeAdmin(stored({ status: "dropped" }), []);
    const response = await call({ state: "in_progress" });
    expect(response.status).toBe(404);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("not_found");
    expect(rpcs).toEqual([]);
  });

  it("이미 그 상태면 쓰지 않고 그대로 돌려준다", async () => {
    for (const [row, state] of [
      [stored(), "to_do"],
      [stored({ started_at: STARTED }), "in_progress"],
      [stored({ status: "done" }), "done"],
    ] as const) {
      const rpcs = fakeAdmin(row, []);
      const response = await call({ state });
      expect(response.status).toBe(200);
      expect(actionResponseSchema.parse(await response.json()).action.id).toBe(ACTION);
      expect(rpcs).toEqual([]);
    }
  });

  it("할 일 → 진행 중: 상태는 그대로 두고 착수만 (버전 확인)", async () => {
    const rpcs = fakeAdmin(stored(), []);
    const response = await call({ state: "in_progress" });
    expect(response.status).toBe(200);
    actionResponseSchema.parse(await response.json());
    expect(rpcs).toHaveLength(1);
    expect(rpcs[0]).toEqual({
      fn: "set_action_progress",
      params: { p_user_id: "u1", p_action_id: ACTION, p_expected_version: 3, p_action: null, p_claims: [], p_evidence: [], p_events: [], p_started: true },
    });
  });

  it("진행 중 → 할 일: 착수만 되돌린다", async () => {
    const rpcs = fakeAdmin(stored({ started_at: STARTED }), []);
    expect((await call({ state: "to_do" })).status).toBe(200);
    expect(rpcs[0].params).toMatchObject({ p_action: null, p_events: [], p_started: false });
  });

  it("완료 → 할 일: PATCH status open과 같은 사용자 Claim · user_edited로 다시 열고, 같은 트랜잭션에서 착수를 되돌린다", async () => {
    const rpcs = fakeAdmin(stored({ status: "done", started_at: STARTED }), [statusClaim("done")]);
    expect((await call({ state: "to_do" })).status).toBe(200);
    const { params } = rpcs[0];
    expect(params).toMatchObject({ p_expected_version: 3, p_started: false, p_evidence: [], p_action: { status: "open" } });
    expect(params.p_claims).toEqual([expect.objectContaining({ field: "status", value: "open", origin: "user", source_id: null, user_id: "u1", action_id: ACTION })]);
    expect(params.p_events).toEqual([{ type: "user_edited", before: { status: "done" }, after: { status: "open" }, rule: "user", actor: "user", source_id: null }]);
  });

  it("완료 → 진행 중: 다시 열고 착수한다. 완료 전에 착수했었으면 다시 열기만 (처음 착수 시각을 지킨다)", async () => {
    let rpcs = fakeAdmin(stored({ status: "done" }), [statusClaim("done")]);
    expect((await call({ state: "in_progress" })).status).toBe(200);
    expect(rpcs[0].params).toMatchObject({ p_action: { status: "open" }, p_started: true });

    rpcs = fakeAdmin(stored({ status: "done", started_at: STARTED }), [statusClaim("done")]);
    expect((await call({ state: "in_progress" })).status).toBe(200);
    expect(rpcs[0].params).toMatchObject({ p_action: { status: "open" }, p_started: null });
  });

  it("진행 중 → 완료: PATCH status done과 같은 user_edited, 착수 시각은 그대로", async () => {
    const rpcs = fakeAdmin(stored({ started_at: STARTED }), [statusClaim("open")]);
    expect((await call({ state: "done" })).status).toBe(200);
    expect(rpcs[0].params).toMatchObject({
      p_action: { status: "done" },
      p_events: [{ type: "user_edited", before: { status: "open" }, after: { status: "done" }, rule: "user", actor: "user", source_id: null }],
      p_started: null,
    });
  });

  it("동시 수정이 계속 겹치면 세 번 다시 해 보고 409", async () => {
    const rpcs = fakeAdmin(stored(), [], () => ({ data: false, error: null }));
    const response = await call({ state: "in_progress" });
    expect(response.status).toBe(409);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("conflict");
    expect(rpcs).toHaveLength(3);
  });

  it("그 사이 없어졌으면(DB 함수의 P0002) 404", async () => {
    fakeAdmin(stored(), [], () => ({ data: null, error: Object.assign(new Error("open action not found"), { code: "P0002" }) }));
    expect((await call({ state: "in_progress" })).status).toBe(404);
  });
});
