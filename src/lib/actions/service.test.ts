import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { createUserAction } from "./service";

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
