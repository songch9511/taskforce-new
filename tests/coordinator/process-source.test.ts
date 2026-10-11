import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { AiBudgetError } from "@/lib/ai/budget-error";
import { LlmError } from "@/lib/ai/llm";
import { runPipeline } from "@/lib/pipeline/run";
import { mergeJudged } from "@/lib/pipeline/merge";
import { mergeTask } from "@/lib/pipeline/merge-task";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/ai/budget", () => ({ budgetFetch: () => fetch }));
vi.mock("@/lib/consent/store", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/consent/store")>()), consentCheck: () => async () => true }));
vi.mock("@/lib/pipeline/run", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/run")>()), runPipeline: vi.fn() }));
vi.mock("@/lib/pipeline/merge", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/merge")>()), mergeJudged: vi.fn() }));
vi.mock("@/lib/pipeline/merge-task", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/merge-task")>()), mergeTask: vi.fn() }));
vi.mock("@/lib/pipeline/backfill-embeddings", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/pipeline/backfill-embeddings")>()), backfillEmbeddings: vi.fn(async () => 0) }));
vi.mock("@/lib/notify/service", () => ({ notifyConfirmations: vi.fn(async () => 0) }));

import { processSource, processTaskSource } from "@/lib/sources/process";

import { adminOf, createCoordinatorDb, seed, setClock } from "./support";

// 정직한 적재 (실제 processSource · processTaskSource × 실제 DB 트리거, PGlite). process.ts는 한 글자도 바꾸지 않았다 — 사건은 done 쓰기와 같은 트랜잭션에서 DB 트리거가 쌓는다.
//  성공 → 사건 1건 / 실패 · 예산 대기 → 사건 0건 (실패가 성공 사건이 되지 않는다) / 재시도 · 재처리 → 늘지 않는다 / 적재 실패 → processSource의 성공 · 실패 의미가 그대로다.
// 추출 · 병합은 준비한 결과를 돌려주는 가짜다 (모델 · 공급자를 부르지 않는다).

let db: PGlite;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  s = seed(db);
}, 60_000);
afterAll(() => db.close());
beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "log").mockImplementation(() => {});
});

const PIPELINE_RESULT = { judged: [], droppedQuotedHistory: [], summary: { promptVersions: { extract: "x-v1" }, extracted: 0 } };
const INPUT = { text: "회의 원문", kind: "meeting", occurredAt: "2026-10-12T00:00:00Z", identity: { names: ["김"], emails: [] } } as never;
const events = (userId: string) => s.q(`select type, dedup_key, refs, processed_at from public.inbox_events where user_id = $1 order by seq`, [userId]);

async function pendingSource() {
  const user = await s.user();
  return { user, source: await s.source(user) };
}

describe("[현재 실제] processSource × 사건 적재", () => {
  it("성공(done): 같은 트랜잭션에서 사건 1건 — refs는 원문 id와 종류뿐 (원문 글 없음). processSource의 반환 · 상태는 예전과 같다", async () => {
    const { user, source } = await pendingSource();
    vi.mocked(runPipeline).mockResolvedValue(PIPELINE_RESULT as never);
    vi.mocked(mergeJudged).mockResolvedValue([]);
    const result = await processSource(adminOf(db), { id: source, userId: user, notify: false }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
    expect(result).toEqual({ ok: true, needsConfirmation: [] });
    expect(await s.one(`select processing_status from public.sources where id = $1`, [source])).toEqual({ processing_status: "done" });
    const rows = await events(user);
    expect(rows).toEqual([{ type: "source_processed", dedup_key: `source:${source}`, refs: { source_id: source, kind: "meeting" }, processed_at: null }]);
    expect(JSON.stringify(rows)).not.toContain("회의 원문");
  });

  it("실패(failed)한 처리는 성공 사건이 되지 않는다. 예산 대기(pending)도 아니다. 재시도해서 done이 되면 그때 한 건", async () => {
    const { user, source } = await pendingSource();
    vi.mocked(runPipeline).mockRejectedValueOnce(new LlmError("추출 요청 실패 (500)"));
    const failed = await processSource(adminOf(db), { id: source, userId: user, notify: false }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
    expect(failed).toEqual({ ok: false, needsConfirmation: [] });
    expect((await s.one(`select processing_status from public.sources where id = $1`, [source])).processing_status).toBe("failed");
    expect(await events(user)).toEqual([]);

    vi.mocked(runPipeline).mockRejectedValueOnce(new AiBudgetError("ai_user_daily_budget_exhausted"));
    await processSource(adminOf(db), { id: source, userId: user, notify: false, attempt: 2, retry: true }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
    expect((await s.one(`select processing_status from public.sources where id = $1`, [source])).processing_status).toBe("pending");
    expect(await events(user)).toEqual([]);

    vi.mocked(runPipeline).mockResolvedValue(PIPELINE_RESULT as never);
    vi.mocked(mergeJudged).mockResolvedValue([]);
    await processSource(adminOf(db), { id: source, userId: user, notify: false, attempt: 3, retry: true }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
    expect((await s.one(`select processing_status from public.sources where id = $1`, [source])).processing_status).toBe("done");
    expect(await events(user)).toHaveLength(1);
  });

  it("같은 원문을 다시 처리해도(재처리 스크립트 · 응답 유실 뒤 재시도) 사건은 늘지 않는다", async () => {
    const { user, source } = await pendingSource();
    vi.mocked(runPipeline).mockResolvedValue(PIPELINE_RESULT as never);
    vi.mocked(mergeJudged).mockResolvedValue([]);
    for (let attempt = 1; attempt <= 3; attempt++) {
      await processSource(adminOf(db), { id: source, userId: user, notify: false, attempt, retry: attempt > 1 }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
    }
    expect(await events(user)).toHaveLength(1);
  });

  it("적재가 실패해도(여기서는 제약으로 강제) processSource의 성공 · 실패 의미는 바뀌지 않는다: 성공은 그대로 성공(done)이고 사건만 없다. 회수가 메운다", async () => {
    const { user, source } = await pendingSource();
    vi.mocked(runPipeline).mockResolvedValue(PIPELINE_RESULT as never);
    vi.mocked(mergeJudged).mockResolvedValue([]);
    await db.query("alter table public.inbox_events add constraint force_fail check (false) not valid");
    try {
      const result = await processSource(adminOf(db), { id: source, userId: user, notify: false }, INPUT, { complete: vi.fn(), decide: vi.fn(), embed: vi.fn() } as never);
      expect(result).toEqual({ ok: true, needsConfirmation: [] });
    } finally {
      await db.query("alter table public.inbox_events drop constraint force_fail");
    }
    expect((await s.one(`select processing_status, processing_error from public.sources where id = $1`, [source])).processing_status).toBe("done");
    expect(await events(user)).toEqual([]);
    // processSource는 JS 시각으로 processed_at을 쓴다: 회수의 기간 기준(DB 시계)을 지금으로 맞춘다
    await setClock(db, new Date());
    expect((await s.one(`select public.coordinator_recover_missing(7200, 100) as n`)).n).toBe(1);
    expect(await events(user)).toHaveLength(1);
  });

  it("구조화된 할 일(processTaskSource)도 같다: done이면 한 건, 실패면 0건", async () => {
    const user = await s.user();
    const connection = await s.connection(user);
    const ok = await s.source(user, { kind: "task", externalId: "task-1", version: "v1", connection });
    const bad = await s.source(user, { kind: "task", externalId: "task-2", version: "v1", connection });
    const task = { identity: { names: [], emails: [] }, edit: { occurredAt: "2026-10-12T00:00:00Z", editedByUser: false } } as never;
    vi.mocked(mergeTask).mockResolvedValueOnce({ relation: "new", changes: [] } as never);
    expect((await processTaskSource(adminOf(db), { id: ok, userId: user, connectionId: connection }, task, { embed: vi.fn(), decide: vi.fn() } as never)).ok).toBe(true);
    vi.mocked(mergeTask).mockRejectedValueOnce(new Error("병합 실패"));
    expect((await processTaskSource(adminOf(db), { id: bad, userId: user, connectionId: connection }, task, { embed: vi.fn(), decide: vi.fn() } as never)).ok).toBe(false);
    const rows = await events(user);
    expect(rows.map((r) => (r.refs as { source_id: string }).source_id)).toEqual([ok]);
  });
});
