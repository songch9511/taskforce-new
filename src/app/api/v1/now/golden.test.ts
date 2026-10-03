import { readFileSync } from "node:fs";
import path from "node:path";

import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { authenticateRequest } from "@/lib/api/auth";

import { GET } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/env", () => ({ weeklyCheckEnabled: () => true }));

// GET /api/v1/now 회귀 기준 (U1 "now 회귀 0" ①, .omc/plans/u1-shell-prs.md): 고정 입력의 응답에서 새 필드(항목의 changed,
// section_limits)를 뺀 JSON이 0a71b2c(U1 전) 응답과 같아야 한다. now.golden.json은 0a71b2c 코드로 만든 응답이고 고치지 않는다.
// nowList · rankNow · 주간 질문 · 실패 원문을 실제 코드로 돌리고, 사용자 권한(RLS) 클라이언트만 가짜다.

const NOW = new Date("2026-10-03T03:00:00.000Z"); // 한국 시간 10월 3일(토) 정오

const row = (id: string, over: Record<string, unknown>) => ({
  id,
  title: `할 일 ${id.slice(0, 1)}`,
  owner: "me",
  status: "open",
  due_date: null,
  counterpart: null,
  needs_confirmation: false,
  confirm_reasons: [],
  started_at: null,
  last_activity_at: "2026-10-02T09:00:00.000Z",
  ...over,
});

/** 열린 Action (actions 표를 status open으로 읽은 결과). 랭킹 규칙마다 하나씩, 동점 · 제외 사례 포함 */
const OPEN_ACTIONS = [
  row("a0000000-0000-4000-8000-000000000001", { due_date: "2026-09-30", counterpart: "김대표", started_at: "2026-09-29T01:00:00.000Z", last_activity_at: "2026-10-01T01:00:00.000Z" }),
  row("b0000000-0000-4000-8000-000000000002", { due_date: "2026-10-03" }),
  row("c0000000-0000-4000-8000-000000000003", { due_date: "2026-10-05", last_activity_at: "2026-09-20T01:00:00.000Z" }),
  row("d0000000-0000-4000-8000-000000000004", { last_activity_at: "2026-09-10T01:00:00.000Z" }),
  row("e0000000-0000-4000-8000-000000000005", { due_date: "2026-10-30", last_activity_at: "2026-10-03T01:00:00.000Z" }),
  // 점수 같음(0): 기한 없음끼리 → 받은 순서
  row("f0000000-0000-4000-8000-000000000006", { last_activity_at: "2026-10-02T10:00:00.000Z" }),
  row("90000000-0000-4000-8000-000000000007", { last_activity_at: "2026-10-02T10:00:00.000Z" }),
  // 확인 요청: 오래된 것부터
  row("10000000-0000-4000-8000-000000000008", { owner: "unknown", needs_confirmation: true, confirm_reasons: ["담당 확인"], last_activity_at: "2026-10-01T00:00:00.000Z" }),
  row("20000000-0000-4000-8000-000000000009", { needs_confirmation: true, confirm_reasons: ["기한 확인"], due_date: "2026-10-04", last_activity_at: "2026-09-28T00:00:00.000Z" }),
  // 다른 사람 일은 어디에도 없다
  row("30000000-0000-4000-8000-00000000000a", { owner: "other", counterpart: "박팀장" }),
  row("40000000-0000-4000-8000-00000000000b", { owner: "other", needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION"] }),
  // 담당 미정이지만 확인 요청이 아님 → 지금 할 일
  row("50000000-0000-4000-8000-00000000000c", { owner: "unknown", due_date: "2026-10-06", counterpart: "최이사" }),
];

type Query = { table: string; select: string; calls: { method: string; args: unknown[] }[] };
type Resolver = (query: Query) => { data: unknown; count?: number | null; error?: unknown };

/** 쿼리 사슬을 기록하고, 끝(throwOnError · range)에서 resolver가 고른 결과를 돌려주는 가짜 사용자 권한 클라이언트 */
function fakeClient(resolve: Resolver) {
  const queries: Query[] = [];
  const client = {
    from: (table: string) => {
      const query: Query = { table, select: "", calls: [] };
      queries.push(query);
      const chain: Record<string, unknown> = {};
      for (const method of ["eq", "neq", "gte", "in", "order", "limit", "maybeSingle"]) {
        chain[method] = (...args: unknown[]) => {
          query.calls.push({ method, args });
          return chain;
        };
      }
      chain.select = (columns: string) => {
        query.select = columns;
        return chain;
      };
      chain.throwOnError = async () => {
        const result = resolve(query);
        if (result.error) throw result.error;
        return result;
      };
      chain.range = async (from: number, to: number) => {
        query.calls.push({ method: "range", args: [from, to] });
        return { error: null, ...resolve(query) };
      };
      return chain;
    },
  } as unknown as SupabaseClient;
  return { client, queries };
}

/** 0a71b2c 응답을 만든 고정 입력: 열린 Action · 첫 원문(3주 전) · 주간 답 없음 · 실패 원문 2건 */
const baseResolver: Resolver = ({ table, select }) => {
  if (table === "actions") return { data: OPEN_ACTIONS };
  if (table === "weekly_checks") return { data: [] };
  if (table === "sources" && select === "created_at") return { data: { created_at: "2026-09-10T00:00:00.000Z" } };
  if (table === "sources") return { data: [{ processed_at: "2026-10-03T01:00:00.000Z", processing_error_code: "ai_timeout" }], count: 2 };
  return { data: [] };
};

const GOLDEN = JSON.parse(readFileSync(path.join(import.meta.dirname, "now.golden.json"), "utf8")) as unknown;

/** U1이 더한 필드를 뺀다 (항목의 changed, 응답의 section_limits). 나머지 키 · 값 · 순서는 그대로 */
function withoutU1Fields(body: Record<string, unknown>) {
  const without = (value: unknown, key: string) => Object.fromEntries(Object.entries(value as Record<string, unknown>).filter(([k]) => k !== key));
  const items = (list: unknown) => (list as unknown[]).map((item) => without(item, "changed"));
  return { ...without(body, "section_limits"), now: items(body.now), confirmations: items(body.confirmations) };
}

const getNow = async (client: SupabaseClient) => {
  vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "u1", email: null, name: "나" }, supabase: client });
  return GET(new Request("https://api.example.dev/api/v1/now", { headers: { Authorization: "Bearer t" } }));
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("GET /api/v1/now 회귀 기준 (0a71b2c)", () => {
  it("새 필드를 뺀 응답이 기준 JSON과 같다: 순서 · 점수 · 이유 · 확인 요청 · 주간 질문 · 실패 원문", async () => {
    const { client } = fakeClient(baseResolver);
    const response = await getNow(client);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(JSON.stringify(withoutU1Fields(body), null, 2)).toBe(JSON.stringify(GOLDEN, null, 2));
  });
});
