import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import { SupabaseActionStore } from "./db-store";

vi.mock("server-only", () => ({}));

// 매칭이 읽는 쿼리(shortlist · unembedded): Slack 연결을 끊어 지운 인용 자리 표시를 인용으로 쓰지 않는다.
// 쿼리 자체(user_id 범위 · match_open_actions)는 tests/db에서 본다.

const USER = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const KEPT = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e";
const REMOVED = "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f";

type Row = Record<string, unknown>;

/** 표마다 정해 둔 행을 돌려주는 가짜 service role 클라이언트 (필터는 흉내 내지 않는다) */
function fakeAdmin(tables: Record<string, Row[]>, matches: { id: string; similarity: number }[] = []) {
  return {
    from: (table: string) => {
      const q = {
        select: () => q,
        eq: () => q,
        in: () => q,
        is: () => q,
        order: () => q,
        limit: () => q,
        throwOnError: async () => ({ data: tables[table] ?? [] }),
      };
      return q;
    },
    rpc: () => ({ throwOnError: async () => ({ data: matches }) }),
  } as unknown as SupabaseClient;
}

const action = (id: string, title: string): Row => ({ id, title, counterpart: "민지", due_date: null, owner: "me" });

describe("SupabaseActionStore.shortlist: 매칭 판정에 넘기는 최근 인용", () => {
  it("Slack 연결을 끊어 지운 자리 표시는 건너뛰고 남은 인용 중 가장 최근 것을 쓴다. 인용이 자리 표시뿐이면 null", async () => {
    const admin = fakeAdmin(
      {
        actions: [action(KEPT, "견적서 보내기"), action(REMOVED, "계약서 검토")],
        // created_at 순서 (쿼리가 order("created_at")로 읽는다)
        evidence: [
          { action_id: KEPT, quote: SLACK_DISCONNECTED_QUOTE, created_at: "2026-09-19T01:00:00Z" },
          { action_id: KEPT, quote: "금요일까지 견적서 보내드릴게요", created_at: "2026-09-20T01:00:00Z" },
          { action_id: REMOVED, quote: SLACK_DISCONNECTED_QUOTE, created_at: "2026-09-21T01:00:00Z" },
          { action_id: KEPT, quote: SLACK_DISCONNECTED_QUOTE, created_at: "2026-09-22T01:00:00Z" },
        ],
      },
      [
        { id: KEPT, similarity: 0.9 },
        { id: REMOVED, similarity: 0.8 },
      ],
    );

    const shortlist = await new SupabaseActionStore(admin, USER).shortlist([1, 0, 0]);

    expect(shortlist.map((a) => [a.id, a.latestQuote])).toEqual([
      [KEPT, "금요일까지 견적서 보내드릴게요"],
      [REMOVED, null],
    ]);
  });
});

describe("SupabaseActionStore.unembedded: 임베딩을 채울 때 쓰는 인용", () => {
  it("만든 근거가 Slack 연결을 끊어 지운 자리 표시면 인용 없이(제목만) 채운다", async () => {
    const admin = fakeAdmin({
      actions: [
        { id: KEPT, title: "견적서 보내기" },
        { id: REMOVED, title: "계약서 검토" },
      ],
      evidence: [
        { action_id: KEPT, quote: "금요일까지 견적서 보내드릴게요" },
        { action_id: REMOVED, quote: SLACK_DISCONNECTED_QUOTE },
      ],
    });

    expect(await new SupabaseActionStore(admin, USER).unembedded(20)).toEqual([
      { id: KEPT, title: "견적서 보내기", quote: "금요일까지 견적서 보내드릴게요" },
      { id: REMOVED, title: "계약서 검토", quote: null },
    ]);
  });
});
