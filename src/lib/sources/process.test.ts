import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { LlmError } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import { mergeJudged } from "@/lib/pipeline/merge";
import { runPipeline, type JudgedCandidate, type PipelineResult } from "@/lib/pipeline/run";

import { failureSummary, processSource, replaceJudgeLogs } from "./process";

vi.mock("server-only", () => ({}));
// processSource의 다시 처리 흐름만 본다: 추출 · 병합 · 저장소 · 알림은 가짜로
vi.mock("@/lib/consent/store", () => ({ consentCheck: () => async () => true }));
vi.mock("@/lib/pipeline/run", () => ({ runPipeline: vi.fn() }));
vi.mock("@/lib/pipeline/merge", () => ({ mergeJudged: vi.fn(async () => []) }));
vi.mock("@/lib/pipeline/backfill-embeddings", () => ({ backfillEmbeddings: vi.fn(async () => undefined) }));
vi.mock("@/lib/notify/service", () => ({ notifyConfirmations: vi.fn(async () => undefined) }));
vi.mock("@/lib/actions/db-store", () => ({
  SupabaseActionStore: class {
    readonly needsConfirmation = new Set<string>();
  },
  SupabaseTaskLinks: class {},
}));

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

describe("failureSummary: 실패 기록 (다시 처리할지 가른다)", () => {
  it("동의 철회는 다시 하지 않고, 모델 호출 실패 등은 다시 해 볼 수 있다", () => {
    const now = new Date("2026-09-29T12:00:00.000Z");
    expect(failureSummary(new ConsentRequiredError(), 1, now)).toEqual({ attempt: 1, retryable: false, failed_at: now.toISOString() });
    expect(failureSummary(new LlmError("빈 응답 (finish_reason: length)", undefined, true), 2, now)).toEqual({
      attempt: 2,
      retryable: true,
      failed_at: now.toISOString(),
    });
    // 모델 호출이 다시 물어도 안 된 마지막 오류(LlmError.retryable false)도 cron은 나중에 다시 해 본다
    expect(failureSummary(new LlmError("응답 시간 초과 (90초)"), 1, now)).toMatchObject({ attempt: 1, retryable: true });
    // 마지막 시도였으면 더 하지 않는다 (cron이 후보에서 뺀다)
    expect(failureSummary(new LlmError("응답 시간 초과 (90초)"), 3, now)).toMatchObject({ attempt: 3, retryable: false });
  });
});

describe("processSource: 다시 처리 (재처리 cron)", () => {
  const judged = (quote: string) =>
    ({
      candidate: { quote },
      judge: { decision: "auto", reasons: [], signals: {}, model: "jev", promptVersion: "judge-v5" },
    }) as unknown as JudgedCandidate;
  const input = { text: "원문", kind: "message" as const, occurredAt: new Date("2026-09-29T00:00:00.000Z"), identity: { name: "나", aliases: [], emails: [] } };
  const deps = { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() };

  /** 부른 쿼리를 기록하고, 이 원문의 근거(evidence) 구절을 돌려주는 가짜 service role 클라이언트 */
  function recordingAdmin(evidenceQuotes: string[]) {
    const queries: string[][] = [];
    const updates: Record<string, unknown>[] = [];
    let current: string[] = [];
    let table = "";
    const builder: object = new Proxy(
      {},
      {
        get: (_target, method) =>
          method === "throwOnError"
            ? async () => ({ data: table === "evidence" ? evidenceQuotes.map((quote) => ({ quote })) : null })
            : (...args: unknown[]) => {
                if (method === "update") updates.push(args[0] as Record<string, unknown>);
                current.push(String(method));
                return builder;
              },
      },
    );
    const admin = {
      from: (name: string) => {
        table = name;
        current = [name];
        queries.push(current);
        return builder;
      },
    } as unknown as SupabaseClient;
    return { admin, queries, updates };
  }

  it("이 원문에서 이미 근거로 쓰인 구절과 겹치는 후보는 빼고 병합하고, 뺀 수와 시도 번호를 남긴다", async () => {
    vi.mocked(runPipeline).mockResolvedValue({
      judged: [judged("금요일까지 견적서 정리해서 드릴게요"), judged("다음 주에 미팅 잡을게요")],
      summary: { extracted: 2 },
    } as unknown as PipelineResult);
    const { admin, updates } = recordingAdmin(["네, 금요일까지 견적서 정리해서 드릴게요."]);

    const result = await processSource(admin, { id: "s1", userId: "u1", attempt: 2, retry: true }, input, deps);

    expect(result.ok).toBe(true);
    expect(vi.mocked(mergeJudged).mock.calls[0][1]).toEqual([judged("다음 주에 미팅 잡을게요")]);
    expect(updates.at(-1)).toMatchObject({
      processing_status: "done",
      processing_summary: { extracted: 2, attempt: 2, merge: { already_applied: 1 } },
    });
  });

  it("처음 처리는 근거를 보지 않고 모든 후보를 병합한다", async () => {
    vi.mocked(mergeJudged).mockClear();
    vi.mocked(runPipeline).mockResolvedValue({ judged: [judged("금요일까지 견적서 정리해서 드릴게요")], summary: { extracted: 1 } } as unknown as PipelineResult);
    const { admin, queries, updates } = recordingAdmin(["금요일까지 견적서 정리해서 드릴게요"]);

    await processSource(admin, { id: "s1", userId: "u1" }, input, deps);

    expect(queries.map((q) => q[0])).not.toContain("evidence");
    expect(vi.mocked(mergeJudged).mock.calls[0][1]).toHaveLength(1);
    const done = updates.at(-1) as { processing_summary: { attempt: number; merge: Record<string, number> } };
    expect(done.processing_summary.attempt).toBe(1);
    expect(done.processing_summary.merge).not.toHaveProperty("already_applied");
  });
});
