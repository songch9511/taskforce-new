import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import type { Claim } from "@/lib/pipeline/resolve";
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

describe("SupabaseActionStore.append: 사용자의 확정 약속이 붙으면 판정 확인 이유를 푼다 (E3 · E4)", () => {
  const CLAIM = (id: string, field: string, value: string) => ({
    id,
    field,
    value,
    occurred_at: "2026-10-06T01:30:00Z",
    speaker_role: "counterpart",
    certainty: "tentative",
    directness: "first_hand",
    audience: "shared",
    origin: "source",
    channel: "email",
  });

  /** 저장된 Action 행과 Claim을 돌려주고, write_action에 넘긴 인자를 모으는 가짜 service role 클라이언트 */
  function appendAdmin(storedReasons: string[]) {
    const writes: Record<string, unknown>[] = [];
    const rows: Record<string, unknown> = {
      actions: { title: "견적서 정리", confirm_reasons: storedReasons, needs_confirmation: true, version: 3, status: "open", started_at: null },
      claims: [CLAIM("c1", "scope", "견적서 정리"), CLAIM("c2", "owner", "me"), CLAIM("c3", "status", "open")],
    };
    const admin = {
      from: (table: string) => {
        const q = {
          select: () => q,
          eq: () => q,
          returns: () => q,
          maybeSingle: () => q,
          throwOnError: async () => ({ data: rows[table] }),
        };
        return q;
      },
      rpc: (_fn: string, params: Record<string, unknown>) => ({
        throwOnError: async () => {
          writes.push(params);
          return { data: true };
        },
      }),
    } as unknown as SupabaseClient;
    return { admin, writes };
  }

  const firmClaims = (): Claim[] =>
    (["scope", "owner", "status"] as const).map((field, i) => ({
      id: `n${i}`,
      field,
      value: field === "owner" ? "me" : field === "status" ? "open" : "견적서 정리",
      occurredAt: new Date("2026-10-06T03:40:00Z"),
      speakerRole: "me",
      certainty: "firm",
      directness: "first_hand",
      audience: "shared",
      channel: "email",
    }));
  const evidence = { sourceId: "s2", quote: "네, 목요일까지 드리겠습니다", role: "duplicate" as const };
  const written = (writes: Record<string, unknown>[]) => writes[0].p_action as { confirm_reasons: string[]; needs_confirmation: boolean };

  it("clearJudgeReasons면 판정 확인만 빼고 병합 확인 같은 다른 이유는 남긴다. 내용 · 담당 · 상태 확인은 Claim에서 다시 계산한다", async () => {
    const { admin, writes } = appendAdmin(["판정 확인: NOT_MY_ACTION", "병합 확인 (55%)", "내용 확인", "담당 확인", "상태 확인"]);
    await new SupabaseActionStore(admin, USER).append("a1", { claims: firmClaims(), evidence, clearJudgeReasons: true });
    expect(writes).toHaveLength(1);
    expect(written(writes).confirm_reasons).toEqual(["병합 확인 (55%)"]);
    expect(written(writes).needs_confirmation).toBe(true);
    // Claim은 지우지 않고 더한다
    expect(writes[0].p_claims as unknown[]).toHaveLength(3);
  });

  it("풀린 확인 요청은 merged 이벤트에 전후(needs_confirmation · confirm_reasons)를 싣는다. 판정 확인을 안 풀면 계산되는 이유만 풀리고 확인은 남는다", async () => {
    const { admin, writes } = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    await new SupabaseActionStore(admin, USER).append("a1", { claims: firmClaims(), evidence, clearJudgeReasons: true });
    const events = writes[0].p_events as { type: string; before: unknown; after: unknown; actor: string }[];
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: "merged",
      actor: "ai",
      // 앞의 이유에는 Claim에서 계산되는 확인(추정 발언뿐이던 내용 · 담당 · 상태)도 들어 있다
      before: { needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION", "내용 확인", "담당 확인", "상태 확인"] },
      after: { needs_confirmation: false, confirm_reasons: [] },
    });
    const kept = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    await new SupabaseActionStore(kept.admin, USER).append("a1", { claims: firmClaims(), evidence });
    expect((kept.writes[0].p_events as { after: unknown }[])[0].after).toEqual({ needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION"] });
  });

  it("기한이 바뀌는 붙임이면 별도 merged를 더하지 않고 그 due_changed 이벤트에 전후를 얹는다", async () => {
    const { admin, writes } = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    const due: Claim = { ...firmClaims()[0], id: "n9", field: "due", value: "2026-10-09" };
    await new SupabaseActionStore(admin, USER).append("a1", { claims: [...firmClaims(), due], evidence, clearJudgeReasons: true });
    const events = writes[0].p_events as { type: string; before: Record<string, unknown>; after: Record<string, unknown> }[];
    expect(events.map((e) => e.type)).toEqual(["due_changed"]);
    expect(events[0].before).toMatchObject({ due: null, needs_confirmation: true });
    expect(events[0].after).toMatchObject({ due: "2026-10-09", needs_confirmation: false, confirm_reasons: [] });
  });

  it("판정 확인 하나뿐이었으면 확인 요청이 없어진다", async () => {
    const { admin, writes } = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    await new SupabaseActionStore(admin, USER).append("a1", { claims: firmClaims(), evidence, clearJudgeReasons: true });
    expect(written(writes)).toMatchObject({ confirm_reasons: [], needs_confirmation: false });
  });

  it("같은 처리에서 만든 확인 요청이 풀리면 확인 요청 알림 대상에서 뺀다. 아직 확인이 남으면 그대로 둔다", async () => {
    const solved = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    const store = new SupabaseActionStore(solved.admin, USER);
    store.needsConfirmation.add("a1");
    await store.append("a1", { claims: firmClaims(), evidence, clearJudgeReasons: true });
    expect(store.needsConfirmation.has("a1")).toBe(false);

    const remaining = appendAdmin(["판정 확인: NOT_MY_ACTION", "병합 확인 (55%)"]);
    const other = new SupabaseActionStore(remaining.admin, USER);
    other.needsConfirmation.add("a1");
    await other.append("a1", { claims: firmClaims(), evidence, clearJudgeReasons: true });
    expect(other.needsConfirmation.has("a1")).toBe(true);
  });

  it("clearJudgeReasons가 없으면 판정 확인을 그대로 둔다", async () => {
    const { admin, writes } = appendAdmin(["판정 확인: NOT_MY_ACTION"]);
    await new SupabaseActionStore(admin, USER).append("a1", { claims: firmClaims(), evidence });
    expect(written(writes).confirm_reasons).toEqual(["판정 확인: NOT_MY_ACTION"]);
  });
});
