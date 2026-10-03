import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { createUserAction, nowList } from "./service";

vi.mock("server-only", () => ({}));

// 직접 추가 (POST /api/v1/actions → createUserAction): 원문 구절을 골랐는지가 user_created 이벤트의 source_id로 남는다.
// 지표 4는 이 source_id가 있는 직접 추가만 추출이 놓친 신호로 센다 (lib/metrics/compute.ts missed, A42).
// write_action이 이벤트의 source_id를 그대로 저장하는 것은 tests/db/user-created-actions.test.ts가 본다.

const USER = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const SOURCE = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e";

/** write_action에 넘긴 값을 기록하고, 응답용 요약 읽기에는 빈 행을 돌려주는 가짜 service role 클라이언트 */
function fakeAdmin() {
  const writes: Record<string, unknown>[] = [];
  const admin = {
    rpc: (fn: string, params: Record<string, unknown>) => {
      if (fn === "write_action") writes.push(params);
      return { throwOnError: async () => ({ data: true }) };
    },
    from: () => {
      const q = { select: () => q, eq: () => q, single: () => q, throwOnError: async () => ({ data: {} }) };
      return q;
    },
  } as unknown as SupabaseClient;
  return { admin, writes };
}

type EventParam = { type: string; actor: string; source_id: string | null; after: { source_id: string | null } };

describe("createUserAction: 직접 추가의 원문 표시", () => {
  it("원문 구절을 고르면 user_created 이벤트 · 근거에 원문이 붙는다", async () => {
    const { admin, writes } = fakeAdmin();
    await createUserAction(admin, USER, { title: "견적서 보내기", dueDate: null, source: { id: SOURCE, quote: "금요일까지 견적서 보내드릴게요" }, embedding: null });

    const events = writes[0].p_events as EventParam[];
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "user_created", actor: "user", source_id: SOURCE, after: { source_id: SOURCE } });
    expect(writes[0].p_evidence).toEqual([{ source_id: SOURCE, quote: "금요일까지 견적서 보내드릴게요", role: "created" }]);
  });

  it("구절 없이 추가하면 이벤트에 원문이 없다 (일반 입력)", async () => {
    const { admin, writes } = fakeAdmin();
    await createUserAction(admin, USER, { title: "장보기", dueDate: "2026-10-03", source: null, embedding: null });

    const events = writes[0].p_events as EventParam[];
    expect(events[0]).toMatchObject({ type: "user_created", source_id: null, after: { source_id: null } });
    expect(writes[0].p_evidence).toEqual([]);
  });
});

// 지금 할 일의 바뀜 점 (U1): 이벤트는 사용자 권한으로 목록의 할 일 것만 읽는다. id가 많으면 100개씩 나누고(요청 주소 길이),
// 한 번에 1000행까지 오므로 끝까지 이어 읽는다 (빠진 이벤트로 본 것 · 바뀐 것을 놓치지 않게).
describe("nowList: 바뀜 점 이벤트 읽기", () => {
  const actionId = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const open = Array.from({ length: 150 }, (_, i) => ({
    id: actionId(i),
    title: `할 일 ${i}`,
    owner: "me",
    status: "open",
    due_date: null,
    counterpart: null,
    needs_confirmation: false,
    confirm_reasons: [],
    started_at: null,
    last_activity_at: "2026-10-02T09:00:00.000Z",
  }));

  it("150개면 100 · 50개씩 두 번, 1000행이 찬 쪽은 다음 쪽까지 읽어 마지막 쪽의 본 것까지 반영한다", async () => {
    const reads: { ids: string[]; from: number; to: number }[] = [];
    // 0번 할 일: AI 변경 1000건(첫 쪽을 채움) 뒤 두 번째 쪽에 user_seen → 바뀜 아님. 120번 할 일: AI 변경 → 바뀜
    const first = Array.from({ length: 1000 }, (_, i) => ({ action_id: actionId(0), type: "merged", actor: "ai", created_at: new Date(Date.UTC(2026, 9, 1, 0, 0, i)).toISOString() }));
    const second = [{ action_id: actionId(0), type: "user_seen", actor: "user", created_at: "2026-10-02T00:00:00.000Z" }];
    const changed = [{ action_id: actionId(120), type: "due_changed", actor: "ai", created_at: "2026-10-02T00:00:00.000Z" }];
    const client = {
      from: (table: string) => {
        let ids: string[] = [];
        const q = {
          select: () => q,
          eq: () => q,
          in: (_column: string, values: string[]) => {
            ids = values;
            return q;
          },
          order: () => q,
          throwOnError: async () => ({ data: table === "actions" ? open : [] }),
          range: async (from: number, to: number) => {
            reads.push({ ids, from, to });
            if (ids.includes(actionId(0))) return { data: from === 0 ? first : second, error: null };
            return { data: ids.includes(actionId(120)) ? changed : [], error: null };
          },
        };
        return q;
      },
    } as unknown as SupabaseClient;

    const ranked = await nowList(client, new Date("2026-10-03T03:00:00.000Z"));
    // 두 묶음은 함께 읽는다 (순서는 상관없다)
    expect(reads.map((r) => [r.ids.length, r.from, r.to]).sort()).toEqual([
      [100, 0, 999],
      [100, 1000, 1999],
      [50, 0, 999],
    ]);
    expect(new Set(reads.flatMap((r) => r.ids))).toEqual(new Set(open.map((a) => a.id)));
    expect(ranked.now.filter((a) => a.changed).map((a) => a.id)).toEqual([actionId(120)]);
    expect(ranked.now).toHaveLength(150);
  });

  it("열린 할 일이 없으면 이벤트를 읽지 않는다", async () => {
    const tables: string[] = [];
    const client = {
      from: (table: string) => {
        tables.push(table);
        const q = { select: () => q, eq: () => q, throwOnError: async () => ({ data: [] }) };
        return q;
      },
    } as unknown as SupabaseClient;
    expect(await nowList(client)).toEqual({ now: [], confirmations: [] });
    expect(tables).toEqual(["actions"]);
  });
});
