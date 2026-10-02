import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";

import { DeadlineExceededError } from "@/lib/ai/deadline";
import { embed } from "@/lib/ai/embed";
import { decide } from "@/lib/ai/jev";
import { completeJson, LlmError } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { ActionStore } from "@/lib/pipeline/merge";
import { mergeJudged } from "@/lib/pipeline/merge";
import { runPipeline, type JudgedCandidate, type PipelineResult } from "@/lib/pipeline/run";
import { notifyConfirmations } from "@/lib/notify/service";

import { backfillEmbeddings } from "@/lib/pipeline/backfill-embeddings";
import { extractMissing, type MissingResult } from "@/lib/pipeline/missing";

import {
  AFTER_EXTRACT_MS,
  failureSummary,
  MERGE_MIN_MS,
  MERGE_NO_TIME_MESSAGE,
  processDepsFromEnv,
  processSource,
  recordSourceFailed,
  replaceJudgeLogs,
  reportMissing,
  sourceFailureCode,
  USER_LOCK_TIMEOUT_MESSAGE,
  withUserLock,
} from "./process";

// 누락 신고가 새 Action과 같이 남길 이벤트(createEvents)를 보려고, 만든 저장소의 옵션을 모은다
const { storeOptions } = vi.hoisted(() => ({ storeOptions: [] as unknown[] }));
vi.mock("@/lib/actions/db-store", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/actions/db-store")>();
  class RecordingStore extends original.SupabaseActionStore {
    constructor(...args: ConstructorParameters<typeof original.SupabaseActionStore>) {
      super(...args);
      if (args[2]) storeOptions.push(args[2]);
    }
  }
  return { ...original, SupabaseActionStore: RecordingStore };
});
vi.mock("server-only", () => ({}));
// processSource: 동의는 있고, 추출 · 병합은 준비한 결과를 돌려주며, 알림은 부른 인자만 남긴다
vi.mock("@/lib/consent/store", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/consent/store")>()), consentCheck: () => async () => true }));
vi.mock("@/lib/pipeline/run", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/run")>()), runPipeline: vi.fn() }));
vi.mock("@/lib/pipeline/merge", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/merge")>()), mergeJudged: vi.fn() }));
vi.mock("@/lib/pipeline/backfill-embeddings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/pipeline/backfill-embeddings")>()),
  backfillEmbeddings: vi.fn(async () => 0),
}));
vi.mock("@/lib/notify/service", () => ({ notifyConfirmations: vi.fn(async () => 0) }));
vi.mock("@/lib/pipeline/missing", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/missing")>()), extractMissing: vi.fn() }));

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

// 실패한 원문은 앱에 보이고(GET /api/v1/now failed_sources, 앱의 RLS 읽기) 까닭 코드가 남는다 (W4, sources.processing_error_code).
describe("sourceFailureCode: 처리 실패의 까닭 코드", () => {
  const request = { system: "s", user: "u", schemaName: "t", schema: z.object({ ok: z.boolean() }) };
  const timeout = () => {
    throw new DOMException("signal timed out", "TimeoutError");
  };
  const respond = (status: number, body: unknown = {}) => async () => new Response(JSON.stringify(body), { status });
  /** 실제 AI 호출 함수가 이 응답에 던지는 오류 (오류 문구가 바뀌면 분류가 깨지는 것을 여기서 잡는다) */
  const thrown = async (call: () => Promise<unknown>) => call().then(() => expect.fail("오류가 나야 한다"), (error: unknown) => error);
  const llm = (fetch: () => Promise<Response>) => thrown(() => completeJson({ apiKey: "k", model: "m", overrunReasoning: null, fetch: fetch as typeof globalThis.fetch }, request));
  const jev = (fetch: () => Promise<Response>) => thrown(() => decide({ apiKey: "k", model: "j", fetch: fetch as typeof globalThis.fetch }, { state: {}, questions: {} }));
  const emb = (fetch: () => Promise<Response>) => thrown(() => embed({ apiKey: "k", model: "e", fetch: fetch as typeof globalThis.fetch }, ["x"]));

  it("AI 공급자가 한도 · 잔액으로 거절하면(402 · 403) ai_quota: LLM · Jev · 임베딩 모두", async () => {
    for (const status of [402, 403]) {
      expect(sourceFailureCode(await llm(respond(status)))).toBe("ai_quota");
      expect(sourceFailureCode(await jev(respond(status)))).toBe("ai_quota");
      expect(sourceFailureCode(await emb(respond(status)))).toBe("ai_quota");
    }
  });

  it("그 밖의 공급자 오류 응답(429 · 500 · 추론 옵션을 받는 공급자 없음 404)은 internal", async () => {
    expect(sourceFailureCode(await llm(respond(500)))).toBe("internal");
    expect(sourceFailureCode(await llm(respond(404, { error: { message: "No endpoints found that can handle the requested parameters." } })))).toBe("internal");
    expect(sourceFailureCode(await jev(respond(429)))).toBe("internal");
    expect(sourceFailureCode(await emb(respond(503)))).toBe("internal");
  });

  it("응답 시간 초과는 ai_timeout (배경 처리: LLM은 다시 물은 뒤, Jev는 한 번 다시 물은 뒤, 임베딩은 바로)", async () => {
    expect(sourceFailureCode(await llm(async () => timeout()))).toBe("ai_timeout");
    expect(sourceFailureCode(await jev(async () => timeout()))).toBe("ai_timeout");
    expect(sourceFailureCode(await emb(async () => timeout()))).toBe("ai_timeout");
    expect(sourceFailureCode(new LlmError("응답 시간 초과 (90초)"))).toBe("ai_timeout");
    expect(sourceFailureCode(new DeadlineExceededError("llm", "응답 시간 초과 (26초)"))).toBe("ai_timeout");
  });

  it("응답 형식이 깨지면 ai_output (빈 응답 · JSON 아님 · 스키마와 다름 · 답 없는 질문 · 임베딩 개수)", async () => {
    const chat = (content: string | null) => respond(200, { model: "m", choices: [{ finish_reason: "stop", message: { content } }] });
    expect(sourceFailureCode(await llm(chat(null)))).toBe("ai_output");
    expect(sourceFailureCode(await llm(chat("not json")))).toBe("ai_output");
    expect(sourceFailureCode(await llm(chat('{"ok":"yes"}')))).toBe("ai_output");
    expect(sourceFailureCode(await llm(respond(200, { unexpected: true })))).toBe("ai_output");
    expect(sourceFailureCode(await thrown(() => decide({ apiKey: "k", model: "j", fetch: respond(200, { model: "j", answers: {} }) as typeof fetch }, { state: {}, questions: { q: { type: "noul", instructions: "?" } } })))).toBe("ai_output");
    expect(sourceFailureCode(await emb(respond(200, { data: [] })))).toBe("ai_output");
  });

  it("동의 철회는 consent, 그 밖(DB 오류 · 병합 대기 마감)은 internal", () => {
    expect(sourceFailureCode(new ConsentRequiredError())).toBe("consent");
    expect(sourceFailureCode(new Error("connection refused"))).toBe("internal");
    expect(sourceFailureCode(new DeadlineExceededError("lock", USER_LOCK_TIMEOUT_MESSAGE))).toBe("internal");
    expect(sourceFailureCode("문자열")).toBe("internal");
  });
});

describe("processSource: 실패 기록 (W4)", () => {
  const input = { text: "금요일까지 견적서 보낼게요", kind: "message" as const, occurredAt: new Date("2026-10-02T00:00:00.000Z"), identity: { name: "나", aliases: [], emails: [] } };
  const deps = { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() };

  /** 표마다 준비한 응답을 돌려주고, 바꾼 값 · 넣은 행을 기록하는 가짜 service role 클라이언트 */
  function failingAdmin(responses: Record<string, unknown> = {}) {
    const updates: Record<string, unknown>[] = [];
    const inserts: { table: string; rows: unknown }[] = [];
    let table = "";
    const builder: object = new Proxy(
      {},
      {
        get: (_target, method) =>
          // 실패 기록은 결과를 기다리기만 한다(throwOnError 없이 await): then이 없어야 바로 끝난다
          method === "then"
            ? undefined
            : method === "throwOnError"
              ? async () => ({ data: responses[table] ?? null })
              : (...args: unknown[]) => {
                  if (method === "update" && table === "sources") updates.push(args[0] as Record<string, unknown>);
                  if (method === "insert") inserts.push({ table, rows: args[0] });
                  return builder;
                },
      },
    );
    const admin = {
      from: (name: string) => {
        table = name;
        return builder;
      },
    } as unknown as SupabaseClient;
    return { admin, updates, inserts };
  }

  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });
  afterEach(() => vi.mocked(console.error).mockRestore());

  it("다시 해 볼 만한 실패는 까닭 코드만 남기고, 닫힌 실패로 세지 않는다", async () => {
    vi.mocked(runPipeline).mockRejectedValueOnce(new LlmError("OpenRouter 요청 실패 (402)", "{}"));
    const { admin, updates, inserts } = failingAdmin();

    expect(await processSource(admin, { id: "s1", userId: "u1" }, input, deps)).toEqual({ ok: false, needsConfirmation: [] });
    expect(updates.at(-1)).toMatchObject({ processing_status: "failed", processing_error_code: "ai_quota", processing_summary: { attempt: 1, retryable: true } });
    expect(inserts.filter((i) => i.table === "metric_events")).toEqual([]);
  });

  it("마지막 시도의 실패는 닫힌 실패로 source_failed 한 줄을 남긴다. 서비스는 원문을 가져온 연결의 것, 원문 글은 넣지 않는다", async () => {
    vi.mocked(runPipeline).mockRejectedValueOnce(new LlmError("응답 시간 초과 (90초)", undefined, true, true, "timeout"));
    const { admin, updates, inserts } = failingAdmin({ sources: { connection_id: "c1" }, connections: { provider: "notion" } });

    await processSource(admin, { id: "s1", userId: "u1", attempt: 3, retry: true }, input, deps);
    expect(updates.at(-1)).toMatchObject({ processing_error_code: "ai_timeout", processing_summary: { attempt: 3, retryable: false } });
    expect(inserts.filter((i) => i.table === "metric_events")).toEqual([{ table: "metric_events", rows: { user_id: "u1", type: "source_failed", provider: "notion" } }]);
  });

  it("동의 철회는 consent로 닫고(source_failed) 부르는 쪽에 오류를 넘긴다. 직접 넣은 원문은 서비스 없이", async () => {
    vi.mocked(runPipeline).mockRejectedValueOnce(new ConsentRequiredError());
    const { admin, updates, inserts } = failingAdmin({ sources: { connection_id: null } });

    await expect(processSource(admin, { id: "s1", userId: "u1" }, input, deps)).rejects.toBeInstanceOf(ConsentRequiredError);
    expect(updates.at(-1)).toMatchObject({ processing_error_code: "consent", processing_summary: { retryable: false } });
    expect(inserts.filter((i) => i.table === "metric_events")).toEqual([{ table: "metric_events", rows: { user_id: "u1", type: "source_failed", provider: null } }]);
  });

  it("처리를 마치면 까닭 코드를 지운다 (다시 처리해 성공한 원문)", async () => {
    vi.mocked(runPipeline).mockResolvedValueOnce({ judged: [], droppedQuotedHistory: [], summary: {} } as unknown as PipelineResult);
    vi.mocked(mergeJudged).mockResolvedValueOnce([]);
    const { admin, updates } = failingAdmin();

    await processSource(admin, { id: "s1", userId: "u1", attempt: 2, retry: true }, input, deps);
    expect(updates.at(-1)).toMatchObject({ processing_status: "done", processing_error: null, processing_error_code: null });
  });

  it("source_failed 기록이 실패해도 처리 결과는 그대로다. 로그에는 원문 id와 오류만 남는다", async () => {
    const admin = {
      from: () => {
        throw new Error("metric_events_type_check");
      },
    } as unknown as SupabaseClient;
    await expect(recordSourceFailed(admin, { id: "s1", userId: "u1" })).resolves.toBeUndefined();
    expect(console.error).toHaveBeenCalledWith("원문 실패 지표 기록 실패 (s1):", "metric_events_type_check");
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
    const inserts: { table: string; rows: unknown }[] = [];
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
                if (method === "insert") inserts.push({ table, rows: args[0] });
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
    return { admin, queries, updates, inserts };
  }

  beforeEach(() => {
    vi.mocked(mergeJudged).mockReset();
    vi.mocked(mergeJudged).mockResolvedValue([]);
  });

  it("이 원문에서 이미 근거로 쓰인 구절과 겹치는 후보는 빼고 병합하고, 뺀 수와 시도 번호를 남긴다", async () => {
    vi.mocked(runPipeline).mockResolvedValue({
      judged: [judged("금요일까지 견적서 정리해서 드릴게요"), judged("다음 주에 미팅 잡을게요")],
      droppedQuotedHistory: [],
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

  it("연결 메일의 인용된 옛 메일 속이라 버린 후보는 판정 기록에 이유만 남기고, 이유별 개수는 처리 요약에 들어간다", async () => {
    const dropped = { title: "옛 약속", quote: "네, 수정 시안은 목요일까지 드리겠습니다." };
    vi.mocked(runPipeline).mockResolvedValue({
      judged: [judged("감사합니다")],
      droppedQuotedHistory: [dropped],
      summary: { extracted: 3, dropped: 2, droppedByReason: { quoteNotFound: 1, quotedHistory: 1 }, promptVersions: { extract: "extract-v5", judge: "judge-v5" } },
    } as unknown as PipelineResult);
    const { admin, inserts, updates } = recordingAdmin([]);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await processSource(admin, { id: "s1", userId: "u1" }, { ...input, kind: "email", fromConnector: true }, deps);

    const rows = inserts.find((i) => i.table === "judge_logs")!.rows as { decision: string; jev_answers: Record<string, unknown>; candidate: unknown; model_version: string }[];
    expect(rows).toHaveLength(2);
    expect(rows[1]).toMatchObject({ decision: "reject", candidate: dropped, jev_answers: { dropped: "QUOTED_HISTORY" }, model_version: "verify@extract-v5" });
    expect(updates.at(-1)).toMatchObject({ processing_summary: { droppedByReason: { quoteNotFound: 1, quotedHistory: 1 } } });
    // 서버 로그에는 개수와 원문 id만 (후보 글은 찍지 않는다)
    const logged = log.mock.calls.flat().join(" ");
    expect(logged).toContain("1건 버림");
    expect(logged).not.toContain("목요일");
    log.mockRestore();
  });

  it("처음 처리는 근거를 보지 않고 모든 후보를 병합한다", async () => {
    vi.mocked(runPipeline).mockResolvedValue({ judged: [judged("금요일까지 견적서 정리해서 드릴게요")], droppedQuotedHistory: [], summary: { extracted: 1 } } as unknown as PipelineResult);
    const { admin, queries, updates } = recordingAdmin(["금요일까지 견적서 정리해서 드릴게요"]);

    await processSource(admin, { id: "s1", userId: "u1" }, input, deps);

    expect(queries.map((q) => q[0])).not.toContain("evidence");
    expect(vi.mocked(mergeJudged).mock.calls[0][1]).toHaveLength(1);
    const done = updates.at(-1) as { processing_summary: { attempt: number; merge: Record<string, number> } };
    expect(done.processing_summary.attempt).toBe(1);
    expect(done.processing_summary.merge).not.toHaveProperty("already_applied");
  });
});

// 연결 전 시각의 원문을 한꺼번에 가져올 때(Gmail 첫 14일 · 다시 연결 뒤 이어 가져오기)는 원문마다 알림이 가지 않게 한다 (원칙 3).
describe("processSource: 확인 요청 알림", () => {
  /** sources 상태 바꾸기 · judge_logs 지우기를 받아 주는 가짜 service role 클라이언트 */
  function fakeProcessAdmin() {
    const statuses: unknown[] = [];
    const chain = () => {
      const q = { eq: () => q, throwOnError: async () => ({ data: null }) };
      return q;
    };
    const admin = {
      from: (table: string) => ({
        update: (values: { processing_status?: string }) => {
          if (table === "sources") statuses.push(values.processing_status);
          return chain();
        },
        delete: () => chain(),
        insert: () => chain(),
      }),
    } as unknown as SupabaseClient;
    return { admin, statuses };
  }

  const input = {
    text: "제목: Signed contract\n\nSure, I'll send it by Monday.",
    kind: "email" as const,
    occurredAt: new Date("2026-10-05T16:45:00.000Z"),
    identity: { name: "Alex", aliases: [], emails: ["me@company.dev"] },
  };
  const deps = { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() };

  beforeEach(() => {
    vi.mocked(notifyConfirmations).mockClear();
    vi.mocked(runPipeline).mockResolvedValue({ judged: [], droppedCount: 0, droppedQuotedHistory: [], summary: {} } as unknown as PipelineResult);
    // 병합이 확인 요청이 필요한 Action 하나를 만든다
    vi.mocked(mergeJudged).mockImplementation(async (store: ActionStore) => {
      (store as unknown as { needsConfirmation: Set<string> }).needsConfirmation.add("action-1");
      return [{ relation: "new", actionId: "action-1" }] as never;
    });
  });

  it("notify: false면 확인 요청은 만들되 알림은 보내지 않는다", async () => {
    const { admin, statuses } = fakeProcessAdmin();
    const result = await processSource(admin, { id: "s1", userId: "u1", notify: false }, input, deps);
    expect(result).toEqual({ ok: true, needsConfirmation: ["action-1"] });
    expect(statuses).toEqual(["processing", "done"]);
    expect(notifyConfirmations).not.toHaveBeenCalled();
  });

  it("notify를 주지 않거나 true면 알린다", async () => {
    const { admin } = fakeProcessAdmin();
    await processSource(admin, { id: "s1", userId: "u1" }, input, deps);
    expect(notifyConfirmations).toHaveBeenLastCalledWith(admin, "u1", ["action-1"]);
    await processSource(admin, { id: "s2", userId: "u1", notify: true }, input, deps);
    expect(notifyConfirmations).toHaveBeenCalledTimes(2);
  });
});

describe("processDepsFromEnv: 사용자가 기다리는 처리와 배경 처리", () => {
  const request = { system: "s", user: "u", schemaName: "t", schema: z.object({ ok: z.boolean() }) };

  /** 환경변수와 OpenRouter를 가짜로 둔다. 보낸 요청의 주소와 본문을 남긴다 */
  function fakeOpenRouter() {
    vi.stubEnv("OPENROUTER_API_KEY", "k");
    vi.stubEnv("LLM_MODEL", "m");
    vi.stubEnv("JEV_MODEL", "j");
    vi.stubEnv("LLM_OVERRUN_REASONING_EFFORT", "");
    const sent: { url: string; body: Record<string, unknown> }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      sent.push({ url, body: JSON.parse(init.body as string) });
      return new Response(JSON.stringify({ model: "m", choices: [{ message: { content: '{"ok":true}' } }], answers: {} }));
    });
    return sent;
  }

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("마감이 없으면(원문 처리 · 동기화 · 재처리 cron) 추출은 지금처럼 추론량을 제한하지 않는다", async () => {
    const sent = fakeOpenRouter();
    const result = await processDepsFromEnv().complete(request);
    expect(sent[0].body.reasoning).toBeUndefined();
    expect(result.reasoningLimited).toBeUndefined();
  });

  it("마감을 주면(빠진 할 일 신고) 추출은 첫 호출부터 추론량을 제한한다", async () => {
    const sent = fakeOpenRouter();
    const result = await processDepsFromEnv(Date.now() + 55_000).complete(request);
    expect(sent[0].body.reasoning).toEqual({ effort: "high", exclude: true });
    expect(result.reasoningLimited).toBe(true);
  });

  it("추출은 뒤의 판정 · 병합에 시간을 남긴다: 남은 시간이 그만큼뿐이면 추출은 부르지 않고, 판정은 마감까지 부른다", async () => {
    const sent = fakeOpenRouter();
    const deps = processDepsFromEnv(Date.now() + AFTER_EXTRACT_MS + 1_000);
    await expect(deps.complete(request)).rejects.toThrow(/남은 시간 없음/);
    expect(sent).toHaveLength(0);
    await deps.decide({ state: {}, questions: {} });
    expect(sent.map((s) => s.url)).toEqual(["https://openrouter.ai/api/alpha/decisions"]);
  });
});

describe("withUserLock: 같은 사용자의 병합은 한 번에 하나씩", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("마감을 주면 앞선 병합을 마감 전 MERGE_MIN_MS까지만 기다리고, 넘기면 차례가 나중에 와도 병합하지 않는다", async () => {
    let finishFirst!: () => void;
    const first = withUserLock("lock-u1", () => new Promise<void>((resolve) => (finishFirst = resolve)));
    const late = vi.fn(async () => "merged");
    const error = await withUserLock("lock-u1", late, Date.now() + MERGE_MIN_MS + 20).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DeadlineExceededError);
    expect(error).toMatchObject({ stage: "lock", message: expect.stringContaining(USER_LOCK_TIMEOUT_MESSAGE) });

    finishFirst();
    await first;
    // 대기열은 그대로 이어진다: 다음 병합은 바로 돌고, 마감을 넘긴 병합은 끝내 부르지 않는다
    await expect(withUserLock("lock-u1", async () => "next", Date.now() + MERGE_MIN_MS + 1_000)).resolves.toBe("next");
    expect(late).not.toHaveBeenCalled();
  });

  it("차례가 와도 마감까지 MERGE_MIN_MS가 남지 않았으면 병합을 시작하지 않는다", async () => {
    const clock = { now: 1_000_000 };
    vi.spyOn(Date, "now").mockImplementation(() => clock.now);
    let finishFirst!: () => void;
    const first = withUserLock("lock-u4", () => new Promise<void>((resolve) => (finishFirst = resolve)));
    const late = vi.fn(async () => "merged");
    // 기다리기 타이머는 60초 뒤라 울리지 않는다. 앞선 병합이 끝났을 때 가짜 시계로는 마감까지 4초만 남았다
    const report = withUserLock("lock-u4", late, clock.now + MERGE_MIN_MS + 60_000);
    await vi.waitFor(() => expect(finishFirst).toBeTypeOf("function"));
    clock.now += 61_000;
    finishFirst();
    await first;
    await expect(report).rejects.toThrow(USER_LOCK_TIMEOUT_MESSAGE);
    expect(late).not.toHaveBeenCalled();
  });

  it("기다리지 않았는데 마감까지 MERGE_MIN_MS가 남지 않았으면 lock이 아니라 merge 단계로 멈춘다 (앞 단계가 느렸다)", async () => {
    const task = vi.fn(async () => "merged");
    const error = await withUserLock("lock-u5", task, Date.now() + MERGE_MIN_MS - 1_000).catch((e: unknown) => e);
    expect(error).toMatchObject({ stage: "merge", message: expect.stringContaining(MERGE_NO_TIME_MESSAGE) });
    expect(task).not.toHaveBeenCalled();
  });

  it("차례가 마감 안에 오면 병합하고, 시작한 병합은 마감을 넘겨도 끊지 않는다", async () => {
    const slow = () => new Promise<string>((resolve) => setTimeout(() => resolve("done"), 30));
    await expect(withUserLock("lock-u2", slow, Date.now() + MERGE_MIN_MS + 10)).resolves.toBe("done");
  });

  it("마감이 없으면(배경 처리) 앞선 병합이 끝날 때까지 기다린다", async () => {
    const order: string[] = [];
    const first = withUserLock("lock-u3", async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      order.push("first");
    });
    await withUserLock("lock-u3", async () => order.push("second"));
    await first;
    expect(order).toEqual(["first", "second"]);
  });
});

describe("reportMissing: 사용자가 기다리는 누락 신고", () => {
  const input = {
    text: "나: 금요일까지 견적서 정리해서 드릴게요.",
    kind: "meeting" as const,
    occurredAt: new Date("2026-09-28T01:00:00.000Z"),
    identity: { name: "나", aliases: [], emails: [] },
    quote: "금요일까지 견적서 정리해서 드릴게요",
  };
  const deps = { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() };

  /** 근거 · 판정 기록은 비었고, 속도 제한은 남았고, 만든 Action 요약을 돌려주는 가짜 service role 클라이언트 */
  function reportAdmin() {
    let table = "";
    const builder: object = new Proxy(
      {},
      {
        get: (_target, method) =>
          method === "throwOnError" ? async () => ({ data: table === "actions" ? { id: "action-1", title: "견적서 전달" } : [] }) : () => builder,
      },
    );
    return {
      from: (name: string) => {
        table = name;
        return builder;
      },
      rpc: () => ({ throwOnError: async () => ({ data: null }) }),
    } as unknown as SupabaseClient;
  }

  beforeEach(() => {
    vi.mocked(backfillEmbeddings).mockClear();
    vi.mocked(mergeJudged).mockReset();
    vi.mocked(mergeJudged).mockResolvedValue([{ relation: "new", actionId: "action-1" }] as never);
    vi.mocked(extractMissing).mockResolvedValue({
      judged: { candidate: { quote: input.quote }, judge: { decision: "auto" } },
      summary: { reasoningLimited: true },
    } as unknown as MissingResult);
    storeOptions.length = 0;
  });

  it("임베딩 채우기를 하지 않고 병합한다 (신고에 필요한 임베딩 · 매칭 시간을 쓰지 않게)", async () => {
    const result = await reportMissing(reportAdmin(), { id: "s1", userId: "report-u1", processingStatus: "done" }, input, Date.now() + 52_000, deps);
    expect(result).toMatchObject({ status: "created", action: { id: "action-1" }, stage: "not_extracted" });
    expect(mergeJudged).toHaveBeenCalledTimes(1);
    expect(backfillEmbeddings).not.toHaveBeenCalled();
  });

  it("추론량을 제한해 뽑은 신고면 user_reported_missing 이벤트에 reasoning_limited를 남긴다 (제품 원칙 6)", async () => {
    await reportMissing(reportAdmin(), { id: "s1", userId: "report-u3", processingStatus: "done" }, input, Date.now() + 52_000, deps);
    expect(storeOptions).toEqual([
      {
        createEvents: [
          {
            type: "user_reported_missing",
            before: null,
            after: { stage: "not_extracted", source_id: "s1", reasoning_limited: true },
            rule: null,
            actor: "user",
          },
        ],
      },
    ]);
  });

  it("같은 사용자의 다른 병합이 마감까지 끝나지 않으면 병합하지 않고 마감 오류를 낸다", async () => {
    let finishOther!: () => void;
    const other = withUserLock("report-u2", () => new Promise<void>((resolve) => (finishOther = resolve)));
    const report = reportMissing(reportAdmin(), { id: "s1", userId: "report-u2", processingStatus: "done" }, input, Date.now() + MERGE_MIN_MS + 30, deps);
    await expect(report).rejects.toBeInstanceOf(DeadlineExceededError);
    finishOther();
    await other;
    expect(mergeJudged).not.toHaveBeenCalled();
  });
});
