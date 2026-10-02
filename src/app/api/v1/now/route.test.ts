import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { authenticateRequest } from "@/lib/api/auth";
import { nowResponseSchema } from "@/lib/api/contract";

import { GET } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/actions/service", () => ({ nowList: vi.fn(async () => ({ now: [], confirmations: [] })) }));
vi.mock("@/lib/env", () => ({ weeklyCheckEnabled: () => false }));

// GET /api/v1/now의 failed_sources (W4): 목록이 비었을 때 앱이 "All caught up" 대신 처리에 실패한 원문을 보인다.
// 사용자 권한(RLS) 클라이언트로 자기 원문만 세고, 원문 글은 읽지 않는다.

type Query = { table: string; select: string; options: unknown; filters: string[] };

/** sources 조회 하나를 기록하고 준비한 결과를 돌려주는 가짜 사용자 클라이언트 */
function fakeClient(result: () => { data: unknown; count: number | null }) {
  const queries: Query[] = [];
  const client = {
    from: (table: string) => {
      const query: Query = { table, select: "", options: undefined, filters: [] };
      queries.push(query);
      const q = {
        select: (columns: string, options?: unknown) => {
          query.select = columns;
          query.options = options;
          return q;
        },
        eq: (column: string, value: string) => {
          query.filters.push(`eq ${column} ${value}`);
          return q;
        },
        neq: (column: string, value: string) => {
          query.filters.push(`neq ${column} ${value}`);
          return q;
        },
        gte: (column: string, value: string) => {
          query.filters.push(`gte ${column} ${value}`);
          return q;
        },
        order: (column: string, options: unknown) => {
          query.filters.push(`order ${column} ${JSON.stringify(options)}`);
          return q;
        },
        limit: (n: number) => {
          query.filters.push(`limit ${n}`);
          return q;
        },
        throwOnError: async () => result(),
      };
      return q;
    },
  } as unknown as SupabaseClient;
  return { client, queries };
}

const get = () => GET(new Request("https://api.example.dev/api/v1/now", { headers: { Authorization: "Bearer t" } }));

const NOW = new Date("2026-10-02T12:00:00.000Z");

beforeEach(() => {
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("GET /api/v1/now failed_sources", () => {
  it("실패 원문 수 · 마지막 실패 시각 · 까닭을 돌려준다. 글은 읽지 않고, 실패한 지 하루 안의 글 원문 실패만 최근 순으로 하나 본다", async () => {
    const { client, queries } = fakeClient(() => ({ data: [{ processed_at: "2026-10-02T03:00:00.000Z", processing_error_code: "ai_quota" }], count: 3 }));
    vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1" }, supabase: client } as never);

    const response = await get();
    expect(response.status).toBe(200);
    const body = nowResponseSchema.parse(await response.json());
    expect(body.failed_sources).toEqual({ count: 3, latest_at: "2026-10-02T03:00:00.000Z", reason: "ai_quota" });
    expect(queries).toEqual([
      {
        table: "sources",
        select: "processed_at, processing_error_code",
        options: { count: "exact" },
        filters: [
          "eq processing_status failed",
          // 할 일 DB 항목의 실패는 다음 버전이 대신해 다시 처리되지 않고, 하루가 지난 실패는 세지 않는다 (사라지지 않는 실패).
          // 들어온 시각이 아니라 실패 시각으로 거른다: 들어온 지 하루가 지나야 닫히는 expired도 닫힌 뒤 하루 동안 보인다
          "neq kind task",
          "gte processed_at 2026-10-01T12:00:00.000Z",
          'order processed_at {"ascending":false,"nullsFirst":false}',
          "limit 1",
        ],
      },
    ]);
  });

  it("창을 지나 멈춰 닫은 원문(들어온 지 하루가 넘음)도 닫은 시각이 실패 시각이라 까닭 expired로 보인다", async () => {
    const { client } = fakeClient(() => ({ data: [{ processed_at: "2026-10-02T11:37:00.000Z", processing_error_code: "expired" }], count: 1 }));
    vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1" }, supabase: client } as never);
    expect(nowResponseSchema.parse(await (await get()).json()).failed_sources).toEqual({ count: 1, latest_at: "2026-10-02T11:37:00.000Z", reason: "expired" });
  });

  it("실패가 없으면 0 · null. 까닭을 기록하기 전의 실패는 까닭 null", async () => {
    const empty = fakeClient(() => ({ data: [], count: 0 }));
    vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1" }, supabase: empty.client } as never);
    expect(nowResponseSchema.parse(await (await get()).json()).failed_sources).toEqual({ count: 0, latest_at: null, reason: null });

    const old = fakeClient(() => ({ data: [{ processed_at: "2026-09-29T03:00:00.000Z", processing_error_code: null }], count: 2 }));
    vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1" }, supabase: old.client } as never);
    expect(nowResponseSchema.parse(await (await get()).json()).failed_sources).toEqual({ count: 2, latest_at: "2026-09-29T03:00:00.000Z", reason: null });
  });

  it("실패 원문을 못 읽어도(예: 마이그레이션 전) 목록은 그대로 200, failed_sources는 0", async () => {
    const { client } = fakeClient(() => {
      throw new Error('column sources.processing_error_code does not exist');
    });
    vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1" }, supabase: client } as never);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await get();
    expect(response.status).toBe(200);
    expect(nowResponseSchema.parse(await response.json()).failed_sources).toEqual({ count: 0, latest_at: null, reason: null });
    expect(log).toHaveBeenCalled();
    log.mockRestore();
  });

  it("인증이 없으면 401", async () => {
    vi.mocked(authenticateRequest).mockResolvedValue(null);
    expect((await get()).status).toBe(401);
  });
});
