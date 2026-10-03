import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiErrorSchema } from "@/lib/api/contract";

const mocks = vi.hoisted(() => ({ getVerifiedClaims: vi.fn(), createCookieClient: vi.fn(), createBearerClient: vi.fn(), createAdminClient: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.createAdminClient }));
vi.mock("@supabase/supabase-js", async (importOriginal) => ({ ...(await importOriginal<object>()), createClient: mocks.createBearerClient }));

import { POST } from "./route";

// POST /api/v1/actions/:id/seen (U1 바뀜 점): 실제 인증(authenticateRequest: Bearer · 쿠키 + CSRF) → 사용자 권한(RLS)으로 Action · 이벤트 읽기
// → 지금 바뀜이면 service role로 user_seen 한 줄. 바뀜 판정 자체는 lib/actions/changed.test.ts, 제약 · 권한은 tests/db/action-seen.test.ts.

const ALICE = "00000000-0000-4000-8000-00000000000a";
const BOB = "00000000-0000-4000-8000-00000000000b";
const ACTION = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";
const NOW = new Date("2026-10-03T03:00:00.000Z");

type ActionRow = { id: string; user_id: string; status: string; owner: string };
type EventRow = { user_id: string; action_id: string; type: string; actor: string; created_at: string };

let actions: ActionRow[];
let events: EventRow[];
let inserts: Record<string, unknown>[];
let insertError: Error | null;

/** 로그인한 사용자 권한의 가짜 클라이언트: 자기 행만 보인다 (RLS owner_select). 읽기만 한다 */
function rlsClient(userId: string) {
  return {
    from(table: string) {
      const filters: { method: string; args: unknown[] }[] = [];
      const chain: Record<string, unknown> = {};
      for (const method of ["select", "eq", "in", "order", "maybeSingle"]) {
        chain[method] = (...args: unknown[]) => {
          filters.push({ method, args });
          return chain;
        };
      }
      const arg = (method: string, index: number) => filters.find((f) => f.method === method)?.args[index];
      chain.throwOnError = async () => {
        if (table !== "actions") throw new Error(`예상하지 않은 읽기: ${table}`);
        const row = actions.find((a) => a.user_id === userId && a.id === arg("eq", 1));
        return { data: row ? { status: row.status, owner: row.owner } : null };
      };
      chain.range = async (from: number, to: number) => {
        if (table !== "action_events") throw new Error(`예상하지 않은 읽기: ${table}`);
        const ids = arg("in", 1) as string[];
        const rows = events
          .filter((e) => e.user_id === userId && ids.includes(e.action_id))
          .sort((a, b) => a.created_at.localeCompare(b.created_at))
          .map(({ action_id, type, actor, created_at }) => ({ action_id, type, actor, created_at }));
        return { data: rows.slice(from, to + 1), error: null };
      };
      return chain;
    },
  } as unknown as SupabaseClient;
}

/** service role 가짜: action_events에 넣기만 한다 (created_at은 DB 기본값 now()) */
function adminClient() {
  return {
    from(table: string) {
      return {
        insert(row: Record<string, unknown>) {
          return {
            throwOnError: async () => {
              if (insertError) throw insertError;
              inserts.push({ table, ...row });
              events.push({ ...(row as Omit<EventRow, "created_at">), created_at: new Date().toISOString() });
              return { data: null };
            },
          };
        },
      };
    },
  } as unknown as SupabaseClient;
}

const event = (type: string, actor: string, created_at: string, user_id = ALICE): EventRow => ({ user_id, action_id: ACTION, type, actor, created_at });

function seen(headers: Record<string, string> = { authorization: "Bearer app-token" }, id = ACTION) {
  return POST(new Request(`https://api.example.test/api/v1/actions/${id}/seen`, { method: "POST", headers }), { params: Promise.resolve({ id }) });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  actions = [{ id: ACTION, user_id: ALICE, status: "open", owner: "me" }];
  events = [event("created", "ai", "2026-10-01T01:00:00+00:00"), event("due_changed", "ai", "2026-10-02T01:00:00.123456+00:00")];
  inserts = [];
  insertError = null;
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: ALICE } }, error: null });
  mocks.createBearerClient.mockImplementation(() => rlsClient(ALICE));
  mocks.createCookieClient.mockImplementation(async () => rlsClient(ALICE));
  mocks.createAdminClient.mockImplementation(adminClient);
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("POST /api/v1/actions/:id/seen", () => {
  it("바뀐 할 일이면 user_seen(actor user) 한 줄을 남기고 204, 본문 없음", async () => {
    const response = await seen();
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(inserts).toEqual([{ table: "action_events", user_id: ALICE, action_id: ACTION, type: "user_seen", actor: "user" }]);
  });

  it("다시 보내도 한 줄뿐이다 (본 뒤에는 바뀜이 아니다). 그 뒤 AI가 다시 바꾸면 한 줄 더", async () => {
    expect((await seen()).status).toBe(204);
    expect((await seen()).status).toBe(204);
    expect((await seen()).status).toBe(204);
    expect(inserts).toHaveLength(1);

    vi.setSystemTime(new Date("2026-10-03T04:00:00.000Z"));
    events.push(event("merged", "ai", "2026-10-03T03:30:00+00:00"));
    expect((await seen()).status).toBe(204);
    expect((await seen()).status).toBe(204);
    expect(inserts).toHaveLength(2);
  });

  it("바뀌지 않았으면 쓰지 않고 204: AI가 만들기만 함 · 사용자가 직접 고치기만 함 · 바뀐 뒤 사용자가 고침", async () => {
    for (const list of [
      [event("created", "ai", "2026-10-01T01:00:00+00:00")],
      [event("user_created", "user", "2026-10-01T01:00:00+00:00"), event("user_edited", "user", "2026-10-02T01:00:00+00:00")],
      [...events, event("user_confirmed", "user", "2026-10-02T02:00:00+00:00")],
    ]) {
      events = list;
      const response = await seen();
      expect(response.status).toBe(204);
    }
    expect(inserts).toEqual([]);
  });

  it("지금 할 일 목록에 없는 할 일(끝냄 · 취소 · 다른 사람 일)은 바뀌었어도 쓰지 않고 204", async () => {
    for (const over of [{ status: "done" }, { status: "dropped" }, { owner: "other" }]) {
      actions = [{ id: ACTION, user_id: ALICE, status: "open", owner: "me", ...over }];
      expect((await seen()).status).toBe(204);
    }
    expect(inserts).toEqual([]);
  });

  it("없거나 남의 할 일이면 404 (사용자 권한으로 읽어 보이지 않는다). 남의 이벤트로 바뀜을 판정하지 않는다", async () => {
    actions = [{ id: ACTION, user_id: BOB, status: "open", owner: "me" }];
    events = events.map((e) => ({ ...e, user_id: BOB }));
    const response = await seen();
    expect(response.status).toBe(404);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("not_found");

    actions = [];
    expect((await seen()).status).toBe(404);
    expect((await seen(undefined, "not-a-uuid")).status).toBe(404);
    expect(inserts).toEqual([]);
  });

  it("로그인하지 않았거나 토큰이 틀리면 401", async () => {
    mocks.getVerifiedClaims.mockResolvedValue({ data: null, error: new Error("invalid JWT") });
    const response = await seen();
    expect(response.status).toBe(401);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("unauthorized");
    expect(inserts).toEqual([]);
  });

  it("쿠키로 다른 사이트에서 온 요청은 401 (CSRF). 같은 출처의 쿠키 요청은 받는다", async () => {
    expect((await seen({ "sec-fetch-site": "cross-site" })).status).toBe(401);
    expect((await seen({ origin: "https://evil.example" })).status).toBe(401);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
    expect(inserts).toEqual([]);

    expect((await seen({ "sec-fetch-site": "same-origin" })).status).toBe(204);
    expect(mocks.createCookieClient).toHaveBeenCalledOnce();
    expect(inserts).toHaveLength(1);
  });

  it("쓰기가 실패하면(예: 마이그레이션 20261025000000 전, 제약에 막힘) 500", async () => {
    insertError = new Error('new row for relation "action_events" violates check constraint "action_events_type_check"');
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await seen();
    expect(response.status).toBe(500);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("internal_error");
    log.mockRestore();
  });
});
