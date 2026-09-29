import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { replaceJudgeLogs } from "./process";

vi.mock("server-only", () => ({}));

// 판정 기록(judge_logs)은 원문의 마지막 처리 결과다: 다시 처리하면(scripts/reprocess-sources.ts) 쌓지 않고 바꾼다.
// 빠진 할 일 신고의 놓친 단계 분류(classifyMiss)와 /lab이 이 기록을 읽는다.

/** judge_logs 지우기 조건과 넣은 행을 기록하는 가짜 service role 클라이언트 */
function fakeAdmin() {
  const calls: string[] = [];
  const inserted: unknown[] = [];
  const admin = {
    from: (table: string) => ({
      delete: () => {
        const q = {
          eq: (column: string, value: string) => {
            calls.push(`delete ${table} ${column}=${value}`);
            return q;
          },
          throwOnError: async () => ({ data: null }),
        };
        return q;
      },
      insert: (rows: unknown[]) => {
        calls.push(`insert ${table} ${rows.length}`);
        inserted.push(...rows);
        return { throwOnError: async () => ({ data: null }) };
      },
    }),
  } as unknown as SupabaseClient;
  return { admin, calls, inserted };
}

const source = { id: "s1", userId: "u1" };
const row = (quote: string) => ({
  user_id: "u1",
  source_id: "s1",
  candidate: { quote },
  jev_answers: {},
  decision: "auto" as const,
  model_version: "jev@judge-v5",
});

describe("replaceJudgeLogs", () => {
  it("이 원문의 전 기록을 지우고 이번 결과만 넣는다", async () => {
    const { admin, calls, inserted } = fakeAdmin();
    await replaceJudgeLogs(admin, source, [row("금요일까지 보낼게요")]);
    expect(calls).toEqual(["delete judge_logs user_id=u1", "delete judge_logs source_id=s1", "insert judge_logs 1"]);
    expect(inserted).toEqual([row("금요일까지 보낼게요")]);
  });

  it("이번에 후보가 없으면 전 기록만 지운다 (옛 판정으로 놓친 단계를 가르지 않게)", async () => {
    const { admin, calls } = fakeAdmin();
    await replaceJudgeLogs(admin, source, []);
    expect(calls).toEqual(["delete judge_logs user_id=u1", "delete judge_logs source_id=s1"]);
  });
});
