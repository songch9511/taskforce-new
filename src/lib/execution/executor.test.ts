import { AiBudgetError } from "@/lib/ai/budget-error";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError } from "@/lib/ai/deadline";
import { LlmError, type LlmAttempt } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { advance, definitiveFailure } from "./executor";
import { ExecutionInputError } from "./material";
import type { ExecutionStore, StepRow } from "./types";

// 실행기의 순서 · 오류 처리 (가짜 store). 실제 SQL 함수와의 흐름은 tests/db/execution-executor.test.ts가 본다.

const REQUEST = "비밀-요청-글 견적 회신 메일 초안 써 줘";
const RUN = { id: "r1", user_id: "u1", action_id: "a1", state: "running" as const, request: REQUEST };
const DRAFT_STEP: StepRow = { id: "s2", run_id: "r1", seq: 2, kind: "draft", state: "prepared", version: 3 };
const ATTEMPTS: LlmAttempt[] = [{ generationId: "gen-1", model: "m", usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.0001 } }];

function fakeStore(overrides: Partial<ExecutionStore> = {}) {
  const order: string[] = [];
  const track =
    <R>(name: string, value: R) =>
    async () => (order.push(name), value);
  const store = {
    loadRun: vi.fn(async () => RUN),
    nextOpenStep: vi.fn(async () => DRAFT_STEP),
    hasStepAfter: vi.fn(async () => false),
    draftHistory: vi.fn(async () => []),
    loadMaterial: vi.fn(async () => ({
      action: { title: "견적 회신", status: "open" as const, owner: "me" as const, due_date: null, counterpart: null },
      sources: [],
      evidence: [],
    })),
    holdsLease: vi.fn(async () => true),
    hasConsent: vi.fn(async () => true),
    userName: vi.fn(async () => "김도윤"),
    prepareStep: vi.fn(track("prepareStep", true)),
    beginCall: vi.fn(async () => (order.push("beginCall"), { gate: "ok", args: { brief: "회신" } })),
    appendStep: vi.fn(track("appendStep", "s3")),
    completeInternalStep: vi.fn(track("completeInternalStep", true)),
    recordUsage: vi.fn(track("recordUsage", 1)),
    settleFailed: vi.fn(track("settleFailed", true)),
    markUnknown: vi.fn(track("markUnknown", true)),
    finishRun: vi.fn(track("finishRun", true)),
    globallyBlocked: vi.fn(),
    sweepExpire: vi.fn(),
    unconfirmedUsage: vi.fn(),
    reconcileUsage: vi.fn(),
    openEndedCreditRuns: vi.fn(),
    releaseRunCredits: vi.fn(),
    wakeableRuns: vi.fn(),
    // receipt 쓰기 (receipt.ts): 끝낸 초안 단계 · Action을 읽고 write_execution_receipt
    receiptTarget: vi.fn(async (stepId: string) => ({
      stepId,
      runId: "r1",
      userId: "u1",
      actionId: "a1",
      artifact: { id: "art-1", title: "Re: 견적", createdAt: new Date("2026-10-02T00:00:00Z") },
    })),
    loadAction: vi.fn(async () => ({ version: 1, title: "견적 회신", confirmReasons: [], claims: [] })),
    writeReceipt: vi.fn(track("writeReceipt", "written" as const)),
    missingReceipts: vi.fn(),
    ...overrides,
  } satisfies ExecutionStore;
  return { store, order };
}

const draftReply = (async (request) => ({
  data: request.schema.parse({ title: "Re: 견적", to: [], body: "본문" }),
  model: "m",
  attempts: ATTEMPTS,
})) as CompleteJson;

const failWith = (error: Error) => (async () => {
  throw error;
}) as CompleteJson;

let info: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  info = vi.spyOn(console, "info").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

describe("advance", () => {
  it("prepared 단계: begin_call → 효과 → 다음 단계를 먼저 붙이고 → complete_internal_step", async () => {
    const { store, order } = fakeStore();
    const result = await advance({ store, complete: draftReply, owner: "fn-1" }, "r1");
    expect(result).toEqual({ status: "completed", step: "s2", next: true });
    // 초안 단계를 끝낸 뒤 receipt를 붙인다 (receipt.ts, Action은 바꾸지 않는다)
    expect(order).toEqual(["beginCall", "appendStep", "completeInternalStep", "writeReceipt"]);
    expect(store.writeReceipt).toHaveBeenCalledWith("s2", 1, expect.objectContaining({ source: expect.objectContaining({ raw_text: "초안 저장: Re: 견적" }) }));
    expect(store.beginCall).toHaveBeenCalledWith("s2", "fn-1", 3);
    expect(store.appendStep).toHaveBeenCalledWith("r1", 3, { kind: "plan", provider: "taskforce", tool: "plan", purpose: "plan", estimate_credits: 0 });
    expect(store.completeInternalStep).toHaveBeenCalledWith(
      "s2",
      "fn-1",
      { to: [], model: "m", prompt_version: "draft-v1" },
      ATTEMPTS,
      { title: "Re: 견적", body: "본문", model: "m", prompt_version: "draft-v1" },
      null,
    );
  });

  it("pending 단계는 준비(prepare_step)한 뒤 바뀐 버전으로 begin_call. 준비를 다른 함수가 먼저 했으면 부르지 않는다", async () => {
    const pending = { ...DRAFT_STEP, state: "pending" as const, version: 0 };
    const { store } = fakeStore({ nextOpenStep: vi.fn(async () => pending) });
    await advance({ store, complete: draftReply, owner: "fn-1" }, "r1");
    expect(store.prepareStep).toHaveBeenCalledWith("s2", 0);
    expect(store.beginCall).toHaveBeenCalledWith("s2", "fn-1", 1);

    const raced = fakeStore({ nextOpenStep: vi.fn(async () => pending), prepareStep: vi.fn(async () => false) });
    expect(await advance({ store: raced.store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "busy", step: "s2" });
    expect(raced.store.beginCall).not.toHaveBeenCalled();
  });

  it("begin_call이 막으면 모델을 부르지 않고 held (단계는 그대로)", async () => {
    const complete = vi.fn(draftReply);
    const { store } = fakeStore({ beginCall: vi.fn(async () => ({ gate: "insufficient_credit" })) });
    expect(await advance({ store, complete: complete as CompleteJson, owner: "fn-1" }, "r1")).toEqual({ status: "held", step: "s2", gate: "insufficient_credit" });
    expect(complete).not.toHaveBeenCalled();
    expect(store.completeInternalStep).not.toHaveBeenCalled();
  });

  it("끝난 run · 남은 단계 없음 · 부르는 중인 단계", async () => {
    expect(await advance({ store: fakeStore({ loadRun: vi.fn(async () => ({ ...RUN, state: "stopped" as const })) }).store, complete: draftReply, owner: "f" }, "r1")).toEqual({
      status: "closed",
    });
    const empty = fakeStore({ nextOpenStep: vi.fn(async () => null) });
    expect(await advance({ store: empty.store, complete: draftReply, owner: "f" }, "r1")).toEqual({ status: "finished" });
    expect(empty.store.finishRun).toHaveBeenCalledWith("r1");
    const busy = fakeStore({ nextOpenStep: vi.fn(async () => ({ ...DRAFT_STEP, state: "calling" as const })) });
    expect(await advance({ store: busy.store, complete: draftReply, owner: "f" }, "r1")).toEqual({ status: "busy", step: "s2" });
    expect(busy.store.beginCall).not.toHaveBeenCalled();
  });

  it("응답을 못 받으면 원가를 먼저 남기고(record_usage) 다시 준비한다(mark_unknown)", async () => {
    const error = Object.assign(new LlmError("응답 시간 초과 (90초)", undefined, true, true, "timeout"), { attempts: ATTEMPTS });
    const { store, order } = fakeStore();
    expect(await advance({ store, complete: failWith(error), owner: "fn-1" }, "r1")).toEqual({ status: "retry", step: "s2" });
    expect(order).toEqual(["beginCall", "recordUsage", "markUnknown"]);
    expect(store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
    expect(store.markUnknown).toHaveBeenCalledWith("s2", "fn-1");
  });

  it("확정적 거절이면 원가를 먼저 남기고 실패로 끝낸다 (settle_step failed)", async () => {
    const error = Object.assign(new LlmError("OpenRouter 요청 실패 (400)"), { attempts: ATTEMPTS });
    const { store, order } = fakeStore();
    expect(await advance({ store, complete: failWith(error), owner: "fn-1" }, "r1")).toEqual({ status: "failed", step: "s2", reason: "rejected" });
    expect(order).toEqual(["beginCall", "recordUsage", "settleFailed"]);
    expect(store.settleFailed).toHaveBeenCalledWith("s2", "fn-1", { error: "rejected" });
  });

  it("동의를 철회했으면 모델을 부르지 않고 실패(consent)", async () => {
    const complete = vi.fn(draftReply);
    const { store } = fakeStore({ hasConsent: vi.fn(async () => false) });
    expect(await advance({ store, complete: complete as CompleteJson, owner: "fn-1" }, "r1")).toEqual({ status: "failed", step: "s2", reason: "consent" });
    expect(complete).not.toHaveBeenCalled();
  });

  it("결과 쓰기가 DB 오류면 다시 쓴다. 다시 쓴 쪽이 false면(앞 쓰기가 commit했거나 lease를 잃음) generation id가 있는 시도만 다시 남긴다", async () => {
    const withTimeout: LlmAttempt[] = [{ generationId: null, model: "m" }, ...ATTEMPTS];
    const reply = (async (request) => ({ data: request.schema.parse({ title: "t", to: [], body: "b" }), model: "m", attempts: withTimeout })) as CompleteJson;
    const completeInternalStep = vi.fn().mockRejectedValueOnce(new Error("fetch failed")).mockResolvedValueOnce(false);
    const { store } = fakeStore({ completeInternalStep });
    expect(await advance({ store, complete: reply, owner: "fn-1" }, "r1")).toEqual({ status: "completed", step: "s2", next: true });
    expect(completeInternalStep).toHaveBeenCalledTimes(2);
    expect(store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
    // 앞 쓰기가 commit했을 수 있으니 receipt도 붙인다 (다시 불러도 한 번, 끝내지 않은 단계면 receipt.ts가 쓰지 않는다)
    expect(store.writeReceipt).toHaveBeenCalledTimes(1);
  });

  it("receipt: 계획 단계 · lease를 잃은 초안에는 붙이지 않고, 쓰지 못해도 단계는 끝낸 것으로 둔다 (단계 id와 까닭만 로그, sweep이 이어 쓴다)", async () => {
    const plan: StepRow = { ...DRAFT_STEP, id: "s1", seq: 1, kind: "plan" };
    const planned = fakeStore({ nextOpenStep: vi.fn(async () => plan) });
    await advance({ store: planned.store, complete: (async (request) => ({ data: request.schema.parse({ reason: "r", step: { kind: "done" } }), model: "m", attempts: ATTEMPTS })) as CompleteJson, owner: "fn-1" }, "r1");
    expect(planned.store.writeReceipt).not.toHaveBeenCalled();

    const lostDraft = fakeStore({ completeInternalStep: vi.fn(async () => false) });
    expect(await advance({ store: lostDraft.store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "lost", step: "s2" });
    expect(lostDraft.store.writeReceipt).not.toHaveBeenCalled();

    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const dbError = Object.assign(new Error("deadlock detected"), { code: "40P01" });
    for (const failing of [fakeStore({ writeReceipt: vi.fn().mockRejectedValue(dbError) }), fakeStore({ receiptTarget: vi.fn(async () => null) })]) {
      expect(await advance({ store: failing.store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "completed", step: "s2", next: true });
      expect(failing.store.settleFailed).not.toHaveBeenCalled();
      expect(failing.store.markUnknown).not.toHaveBeenCalled();
    }
    expect(error.mock.calls.map((c) => JSON.parse(String(c[0])))).toEqual([
      { event: "execution_receipt_failed", run: "r1", step: "s2", reason: "Error", code: "40P01" },
      { event: "execution_receipt_failed", run: "r1", step: "s2", reason: "not_found" },
    ]);
    // 완료 로그에 receipt 결과가 숫자 · 상태로만 남는다
    const completed = info.mock.calls.map((c: unknown[]) => JSON.parse(String(c[0]))).filter((l: { status?: string; kind?: string }) => l.status === "completed" && l.kind === "draft");
    expect(completed.map((l: { receipt?: string }) => l.receipt)).toEqual(["failed", "failed"]);
  });

  it("결과 쓰기 · 다음 단계 붙이기가 계속 실패하면 받은 시도의 원가를 남기고 오류를 낸다 (단계는 calling에 남고 lease 만료 뒤 다시 준비된다)", async () => {
    const completeInternalStep = vi.fn().mockRejectedValue(new Error("fetch failed"));
    const failing = fakeStore({ completeInternalStep });
    await expect(advance({ store: failing.store, complete: draftReply, owner: "fn-1" }, "r1")).rejects.toThrow("fetch failed");
    expect(completeInternalStep).toHaveBeenCalledTimes(3);
    expect(failing.store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
    expect(failing.store.markUnknown).not.toHaveBeenCalled();

    const appendStep = vi.fn().mockRejectedValue(new Error("connection reset"));
    const noAppend = fakeStore({ appendStep });
    await expect(advance({ store: noAppend.store, complete: draftReply, owner: "fn-1" }, "r1")).rejects.toThrow("connection reset");
    expect(appendStep).toHaveBeenCalledTimes(3);
    expect(noAppend.store.completeInternalStep).not.toHaveBeenCalled();
    expect(noAppend.store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
  });

  it("다음 단계 붙이기가 null이면(run이 멈춤 · 앞 시도가 붙임) 실제로 다음 단계가 있을 때만 깨운다", async () => {
    const stopped = fakeStore({ appendStep: vi.fn(async () => null), hasStepAfter: vi.fn(async () => false) });
    expect(await advance({ store: stopped.store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "completed", step: "s2", next: false });
    const already = fakeStore({ appendStep: vi.fn(async () => null), hasStepAfter: vi.fn(async () => true) });
    expect(await advance({ store: already.store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "completed", step: "s2", next: true });
  });

  it("lease를 잃은 함수는 다음 단계를 붙이지 않는다 (원가만 남긴다)", async () => {
    const { store } = fakeStore({ holdsLease: vi.fn(async () => false) });
    expect(await advance({ store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "lost", step: "s2" });
    expect(store.appendStep).not.toHaveBeenCalled();
    expect(store.completeInternalStep).not.toHaveBeenCalled();
    expect(store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
  });

  it("후속 계획(초안 뒤 계획 단계)이 실패하면 다시 하지 않고 이미 만든 초안으로 끝낸다 (draft_ready)", async () => {
    const followUp: StepRow = { ...DRAFT_STEP, id: "s3", seq: 3, kind: "plan" };
    for (const error of [new LlmError("OpenRouter 요청 실패 (400)"), new LlmError("OpenRouter 요청 실패 (503)"), new ConsentRequiredError()]) {
      const { store } = fakeStore({ nextOpenStep: vi.fn(async () => followUp), draftHistory: vi.fn(async () => [{ state: "called" as const, brief: "b", title: "t" }]) });
      expect(await advance({ store, complete: failWith(Object.assign(error, { attempts: ATTEMPTS })), owner: "fn-1" }, "r1")).toEqual({
        status: "completed",
        step: "s3",
        next: false,
      });
      expect(store.recordUsage).toHaveBeenCalledWith("s3", ATTEMPTS);
      expect(store.completeInternalStep).toHaveBeenCalledWith("s3", "fn-1", expect.objectContaining({ decision: "done" }), [], null, "draft_ready");
      expect(store.settleFailed).not.toHaveBeenCalled();
      expect(store.markUnknown).not.toHaveBeenCalled();
    }
  });

  it("다시 부른 계획 단계는 앞 시도가 붙인 단계가 있으면 모델을 부르지 않고 끝낸 뒤 깨운다", async () => {
    const complete = vi.fn(draftReply);
    const plan: StepRow = { ...DRAFT_STEP, id: "s1", seq: 1, kind: "plan" };
    const { store } = fakeStore({ nextOpenStep: vi.fn(async () => plan), hasStepAfter: vi.fn(async () => true) });
    expect(await advance({ store, complete: complete as CompleteJson, owner: "fn-1" }, "r1")).toEqual({ status: "completed", step: "s1", next: true });
    expect(complete).not.toHaveBeenCalled();
    expect(store.appendStep).not.toHaveBeenCalled();
    expect(store.completeInternalStep).toHaveBeenCalledWith("s1", "fn-1", expect.objectContaining({ decision: "draft" }), [], null, null);
  });

  it("원가 기록이 실패해도 단계는 내보낸다 (lease를 붙잡지 않는다)", async () => {
    const error = Object.assign(new LlmError("응답 시간 초과 (90초)", undefined, true, true, "timeout"), { attempts: ATTEMPTS });
    const { store } = fakeStore({ recordUsage: vi.fn().mockRejectedValue(new Error("connection reset")) });
    expect(await advance({ store, complete: failWith(error), owner: "fn-1" }, "r1")).toEqual({ status: "retry", step: "s2" });
    expect(store.markUnknown).toHaveBeenCalledWith("s2", "fn-1");
  });

  it("lease를 잃었으면(첫 쓰기가 false) 결과를 버리고 원가만 플랫폼 원가로 남긴다", async () => {
    const { store } = fakeStore({ completeInternalStep: vi.fn(async () => false) });
    expect(await advance({ store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "lost", step: "s2" });
    expect(store.recordUsage).toHaveBeenCalledWith("s2", ATTEMPTS);
  });

  it("외부 단계는 준비 · begin_call도 하지 않는다", async () => {
    const { store } = fakeStore({ nextOpenStep: vi.fn(async () => ({ ...DRAFT_STEP, kind: "external" as const, state: "pending" as const })) });
    expect(await advance({ store, complete: draftReply, owner: "fn-1" }, "r1")).toEqual({ status: "busy", step: "s2" });
    expect(store.prepareStep).not.toHaveBeenCalled();
    expect(store.beginCall).not.toHaveBeenCalled();
  });

  it("로그에는 id · 상태만 남긴다 (요청 글 없음)", async () => {
    await advance({ store: fakeStore().store, complete: draftReply, owner: "fn-1" }, "r1");
    await advance({ store: fakeStore().store, complete: failWith(new LlmError("OpenRouter 요청 실패 (500)")), owner: "fn-1" }, "r1");
    const lines = info.mock.calls.map((c: unknown[]) => String(c[0]));
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) expect(line).not.toContain("비밀-요청-글");
  });
});

describe("definitiveFailure", () => {
  it.each([
    [new ConsentRequiredError(), "consent"],
    [new ExecutionInputError("action_missing"), "action_missing"],
    [new LlmError("OpenRouter 요청 실패 (400)"), "rejected"],
    [new LlmError("OpenRouter 요청 실패 (413)"), "rejected"],
    [new LlmError("OpenRouter 요청 실패 (401)"), null],
    [new LlmError("OpenRouter 요청 실패 (402)"), null],
    [new LlmError("OpenRouter 요청 실패 (403)"), null],
    [new LlmError("OpenRouter 요청 실패 (404)", undefined, false, false, "unsupported_parameters"), "rejected"],
    [new LlmError("OpenRouter 요청 실패 (408)"), null],
    [new LlmError("OpenRouter 요청 실패 (429)"), null],
    [new LlmError("OpenRouter 요청 실패 (503)"), null],
    [new LlmError("응답이 스키마와 맞지 않습니다", undefined, true), null],
    [new LlmError("응답 시간 초과 (90초)", undefined, true, true, "timeout"), null],
    [new DeadlineExceededError("llm", "남은 시간 없음"), null],
    [new Error("fetch failed"), null],
  ])("%s → %s", (error, expected) => {
    expect(definitiveFailure(error)).toBe(expected);
  });
});

it("exhaustion is terminal while infrastructure errors remain retryable", () => {
  expect(definitiveFailure(new AiBudgetError("ai_budget_exhausted"))).toBe("ai_budget_exhausted");
  expect(definitiveFailure(new AiBudgetError("ai_price_bound_unavailable"))).toBe("ai_pricing_unavailable");
  expect(definitiveFailure(new AiBudgetError("ai_provider_bound_breached"))).toBe("ai_provider_bound_violation");
  expect(definitiveFailure(new AiBudgetError("ai_budget_unavailable"))).toBeNull();
});

it("exhausted draft settles terminal failure without scheduling an unknown retry", async () => {
  const { store } = fakeStore();
  const result = await advance({ store, complete: failWith(new AiBudgetError("ai_budget_exhausted")), owner: "worker" }, "r1");
  expect(result).toEqual({ status: "failed", step: "s2", reason: "ai_budget_exhausted" });
  expect(store.settleFailed).toHaveBeenCalledWith("s2", "worker", { error: "ai_budget_exhausted" });
  expect(store.markUnknown).not.toHaveBeenCalled();
});
