import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { z } from "zod";

import type { GenerationLookup } from "@/lib/ai/generation";
import { LlmError, type JsonCompletion, type JsonCompletionRequest, type LlmAttempt } from "@/lib/ai/llm";
import { PLAN_PROMPT_VERSION } from "@/lib/ai/prompts/plan";
import { DRAFT_PROMPT_VERSION } from "@/lib/ai/prompts/draft";
import { handleCreateRun, handleCredits, handleStopRun } from "@/lib/api/runs";
import type { Draft } from "@/lib/execution/draft";
import { advance, type AdvanceResult, type ExecutorDeps } from "@/lib/execution/executor";
import { DRAFT_ESTIMATE_CREDITS, LEASE_SECONDS, MAX_STEPS, RATE_VERSION } from "@/lib/execution/limits";
import type { NextStep } from "@/lib/execution/plan";
import { sweep } from "@/lib/execution/sweep";
import { RunActionNotFoundError } from "@/lib/execution/types";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { pgliteExecutionStore } from "../execution/pglite-store";
import { createLocalSupabase } from "./local-supabase";

// 실행기(U2 PR6) × 운영 마이그레이션 (PGlite). 가짜 LLM으로 계획 → 초안 → 계획을 끝까지 돌리고 DB에 남는 것을 본다:
// 산출물 · 원가(시도마다) · 원장(예약 · 정산 · 해제) · run 결과 · 실행 이벤트, 함수가 중간에 죽은 뒤 이어 가기(A18),
// 차단 스위치를 끄면 세 입구(route의 after() · 자기 호출 · sweep) 모두 calling 0(기준 9), 미확정 원가 보류(A46), Slack 원문 제외.
// 동시 commit 경합은 tests/pg가 본다 (PGlite는 연결이 하나다).

// 테스트 시계 (tests/execution/driver.ts와 같은 판): 운영의 db_now()는 now()뿐이다
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;
const NOW = new Date("2026-10-02T00:00:00Z");
const MODEL = "z-ai/glm-5.3-flash";

let db: PGlite;
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows;
const count = async (sql: string, params: unknown[] = []) => (await one<{ n: number }>(`select count(*)::int as n from (${sql}) x`, params)).n;
const setClock = (at: Date) => db.query("select set_config('app.now', $1, false)", [at.toISOString()]);
const advanceClock = (seconds: number) => db.query("select set_config('app.now', (public.db_now() + make_interval(secs => $1))::text, false)", [seconds]);

let generation = 0;
/** llm.ts LlmAttempt 한 건. cost를 주지 않으면 비용을 모르는 시도 */
const attempt = (cost?: number): LlmAttempt => ({
  generationId: `gen-test-${++generation}`,
  model: MODEL,
  usage: { prompt_tokens: 1000, completion_tokens: 300, ...(cost === undefined ? {} : { cost }) },
});

const DRAFT: Draft = { title: "Re: 견적 문의", to: ["박서준 <seojun@example.com>"], body: "박서준님, 견적 회신드립니다. 금액: [금액]" };

/** 가짜 LLM: 계획 · 초안 답을 차례로 준다. 받은 프롬프트를 모두 남긴다 (Slack 글자가 없는지 본다) */
class FakeLlm {
  plans: NextStep[] = [];
  drafts: Draft[] = [];
  prompts: string[] = [];
  cost: number | undefined = 0.0007;
  /** 다음 호출 하나를 대신한다 (오류 · 멈춤 · 여러 시도) */
  overrides: ((request: JsonCompletionRequest<z.ZodType>) => Promise<JsonCompletion<unknown>>)[] = [];

  complete = (async (request: JsonCompletionRequest<z.ZodType>) => {
    this.prompts.push(`${request.system}\n${request.user}`);
    const override = this.overrides.shift();
    if (override) return override(request);
    const data = request.schemaName === "next_step" ? { reason: "남은 조각", step: this.plans.shift() ?? { kind: "done" } } : (this.drafts.shift() ?? DRAFT);
    return { data: request.schema.parse(data), model: MODEL, attempts: [attempt(this.cost)] };
  }) as CompleteJson;
}

let llm: FakeLlm;
const store = () => pgliteExecutionStore(db);
const deps = (owner = "fn-1"): ExecutorDeps => ({ store: store(), complete: llm.complete, owner, now: () => NOW });

/** 함수 호출을 이어서: 단계를 끝내고 다음 단계를 붙였으면(자기 호출) 다음 호출 */
async function drive(runId: string, owner = "fn-1"): Promise<AdvanceResult[]> {
  const results: AdvanceResult[] = [];
  for (let i = 0; i < 10; i++) {
    const result = await advance(deps(`${owner}-${i}`), runId);
    results.push(result);
    if (!(result.status === "completed" && result.next)) break;
  }
  return results;
}

async function newUser({ credits = 100, consent = true, actor = true }: { credits?: number; consent?: boolean; actor?: boolean } = {}) {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.profiles (user_id, ai_consent_at) values ($1, $2)", [userId, consent ? NOW.toISOString() : null]);
  if (actor) await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  if (credits) await db.query("select public.grant_credits($1, $2, $3)", [userId, credits, randomUUID()]);
  return userId;
}

type SourceSeed = { text: string; quote: string; provider?: "slack" | "gmail" | "notion"; externalId?: string; externalUrl?: string };

/** 열린 Action과 근거 원문. provider를 주면 그 서비스의 연결에서 온 원문 (sources에는 provider가 없고 연결 행이 갖는다) */
async function newAction(userId: string, sources: SourceSeed[] = [{ text: "박서준: 견적서 금요일까지 회신 부탁드려요.", quote: "견적서 금요일까지 회신 부탁드려요" }]) {
  const actionId = (await one<{ id: string }>("insert into public.actions (user_id, title, counterpart) values ($1, '견적 회신', '박서준') returning id", [userId])).id;
  for (const s of sources) {
    const connectionId = s.provider
      ? (await one<{ id: string }>("insert into public.connections (user_id, provider, external_account_id) values ($1, $2, $3) returning id", [userId, s.provider, randomUUID()])).id
      : null;
    const sourceId = (
      await one<{ id: string }>(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_url)
         values ($1, 'message', $2, '2026-10-01T01:00:00Z', $3, $4, $5) returning id`,
        [userId, s.text, connectionId, s.externalId ?? (s.provider ? randomUUID() : null), s.externalUrl ?? null],
      )
    ).id;
    await db.query("insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, $4, 'created')", [userId, actionId, sourceId, s.quote]);
  }
  return actionId;
}

const startRun = async (userId: string, actionId: string, budget: number | null = null) =>
  (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '견적 회신 메일 초안 써 줘', $3) as id", [userId, actionId, budget])).id;

const runState = (runId: string) =>
  one<{ state: string; hold_reason: string | null; outcome: string | null }>("select state, hold_reason, outcome from public.execution_runs where id = $1", [runId]);
const steps = (runId: string) =>
  rows<{ seq: number; kind: string; state: string; attempt: number; receipt: Record<string, unknown> | null; estimate_credits: number }>(
    "select seq, kind, state, attempt, receipt, estimate_credits from public.execution_steps where run_id = $1 order by seq",
    [runId],
  );
const ledger = (userId: string) =>
  rows<{ kind: string; credits: number }>("select kind, credits from public.credit_ledger where user_id = $1 and kind <> 'grant' order by id", [userId]);
const account = (userId: string) => one<{ granted: number; reserved: number; settled: number }>("select granted, reserved, settled from public.credit_accounts where user_id = $1", [userId]);
const usage = (runId: string) =>
  rows<{ kind: string; cost_status: string; billable: boolean; cost_usd: string | null }>(
    `select s.kind, u.cost_status, u.billable, u.cost_usd::text from public.execution_usage u join public.execution_steps s on s.id = u.step_id
     where u.run_id = $1 order by u.id`,
    [runId],
  );
const calling = () => count("select 1 from public.execution_steps where state = 'calling'");
const setControl = (scope: string, key: string, blocked: boolean) =>
  db.query("update public.execution_controls set blocked = $3 where scope = $1 and key = $2", [scope, key, blocked]);

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
}, 60_000);

beforeEach(async () => {
  llm = new FakeLlm();
  // 테스트마다 run이 없는 상태로 (sweep은 모든 run을 본다). Action을 지우면 run · 단계 · 원장 · 원가 · 산출물이 함께 지워진다
  await db.exec("truncate public.actions, public.execution_policies restart identity cascade");
  await setClock(NOW);
  // 처음 상태는 전체 스위치가 막혀 있다 (운영 켜기 순서의 마지막 단계). 여기서는 연 상태에서 시작한다
  await db.query("update public.execution_controls set blocked = (scope = 'mode' and key <> 'manual')");
  vi.spyOn(console, "info").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("한도가 마이그레이션과 같다", () => {
  it("begin_call의 lease는 LEASE_SECONDS(실행 한도 + 여유)이고, 지금 요율은 RATE_VERSION이다", async () => {
    const user = await newUser();
    const runId = await startRun(user, await newAction(user));
    const step = await one<{ id: string; version: number }>("select id, version from public.execution_steps where run_id = $1", [runId]);
    await db.query("select public.prepare_step($1, $2)", [step.id, step.version]);
    expect((await one<{ g: { gate: string } }>("select public.begin_call($1, 'fn-lease', $2) as g", [step.id, step.version + 1])).g.gate).toBe("ok");
    const lease = await one<{ s: number }>("select extract(epoch from lease_expires_at - public.db_now())::int as s from public.execution_steps where id = $1", [step.id]);
    expect(lease.s).toBe(LEASE_SECONDS);
    expect((await one<{ version: string }>("select version from public.credit_rates where active")).version).toBe(RATE_VERSION);
  });
});

describe("계획 → 초안 → 계획 (내장 초안 한 건)", () => {
  it("산출물 1 · 원가는 시도마다 · 원장은 예약 → 정산 → 해제, run은 draft_ready. 함수 호출 한 번에 단계 하나", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "박서준님께 견적 회신 메일, 금액은 비워 둠" }, { kind: "done" }];

    const results = await drive(runId);
    expect(results.map((r) => r.status)).toEqual(["completed", "completed", "completed"]);
    expect(results.map((r) => (r.status === "completed" ? r.next : null))).toEqual([true, true, false]);

    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
    const s = await steps(runId);
    expect(s.map((x) => [x.seq, x.kind, x.state, x.estimate_credits])).toEqual([
      [1, "plan", "called", 0],
      [2, "draft", "called", DRAFT_ESTIMATE_CREDITS],
      [3, "plan", "called", 0],
    ]);
    expect(s[0].receipt).toEqual({ decision: "draft", model: MODEL, prompt_version: PLAN_PROMPT_VERSION });
    expect(s[1].receipt).toEqual({ to: DRAFT.to, model: MODEL, prompt_version: DRAFT_PROMPT_VERSION });
    expect(s[2].receipt).toMatchObject({ decision: "done" });
    // 초안 단계의 brief는 begin_call이 돌려준 인자다
    expect((await one<{ brief: string }>("select args->>'brief' as brief from public.execution_steps where run_id = $1 and seq = 2", [runId])).brief).toBe(
      "박서준님께 견적 회신 메일, 금액은 비워 둠",
    );

    const artifacts = await rows("select title, body, model, prompt_version, kind from public.execution_artifacts where run_id = $1", [runId]);
    expect(artifacts).toEqual([{ title: DRAFT.title, body: DRAFT.body, model: MODEL, prompt_version: DRAFT_PROMPT_VERSION, kind: "draft" }]);

    // 계획 단계는 플랫폼 원가(청구 안 함), 초안만 청구 대상
    expect(await usage(runId)).toEqual([
      { kind: "plan", cost_status: "confirmed", billable: false, cost_usd: "0.0007" },
      { kind: "draft", cost_status: "confirmed", billable: true, cost_usd: "0.0007" },
      { kind: "plan", cost_status: "confirmed", billable: false, cost_usd: "0.0007" },
    ]);
    // 정산 = ceil($0.0007 / $0.001) = 1, 남은 19 해제
    expect(await ledger(user)).toEqual([
      { kind: "reserve", credits: DRAFT_ESTIMATE_CREDITS },
      { kind: "settle", credits: 1 },
      { kind: "release", credits: DRAFT_ESTIMATE_CREDITS - 1 },
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 1 });

    // 두 번째 계획은 앞선 초안을 history로 받는다 (제목은 산출물에서)
    expect(llm.prompts[2]).toContain('"history":[{"kind":"draft","status":"called","brief":"박서준님께 견적 회신 메일, 금액은 비워 둠","title":"Re: 견적 문의"}]');
    // 모든 쓰기는 실행 이벤트를 남긴다 (상태가 바뀔 때만)
    const events = await rows<{ type: string; to_state: string }>("select type, to_state from public.execution_events where run_id = $1 and step_id is null order by id", [runId]);
    expect(events).toEqual([
      { type: "run", to_state: "queued" },
      { type: "run", to_state: "running" },
      { type: "run", to_state: "done" },
    ]);

    // 끝난 run은 더 깨워도 아무것도 하지 않는다
    expect(await advance(deps("fn-late"), runId)).toEqual({ status: "closed" });
  });

  it("원가는 다시 물은 시도까지 모두 더해 정산한다 (형식 오류로 다시 물은 시도 포함)", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "done" }]; // 두 번째 계획
    llm.overrides = [
      async (request) => ({ data: request.schema.parse({ reason: "r", step: { kind: "draft", brief: "회신" } }), model: MODEL, attempts: [attempt(0.0006)] }),
      // 초안: 첫 시도 형식 오류($0.0004) → 다시 물어 성공($0.0019)
      async (request) => ({ data: request.schema.parse(DRAFT), model: MODEL, attempts: [attempt(0.0004), attempt(0.0019)] }),
    ];
    await drive(runId);
    expect((await usage(runId)).filter((u) => u.kind === "draft")).toEqual([
      { kind: "draft", cost_status: "confirmed", billable: true, cost_usd: "0.0004" },
      { kind: "draft", cost_status: "confirmed", billable: true, cost_usd: "0.0019" },
    ]);
    // ceil(0.0023 / 0.001) = 3
    expect((await ledger(user)).find((l) => l.kind === "settle")).toEqual({ kind: "settle", credits: 3 });
  });

  it("계획 · 초안을 둘씩 하면 단계 상한(4)에서 멈춘다: 마지막 초안 뒤에는 계획을 붙이지 않고 draft_ready", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "제안서" }, { kind: "draft", brief: "후속 메일" }];
    await drive(runId);
    expect((await steps(runId)).map((s) => s.kind)).toEqual(["plan", "draft", "plan", "draft"]);
    expect(MAX_STEPS).toBe(4);
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [runId])).toBe(2);
  });

  it("A39: 보내기만 남았으면(needs_connection) 초안 단계 0 · 청구 0으로 끝내고, 앞서 만든 초안은 그대로 둔다", async () => {
    const user = await newUser({ credits: 100 });
    const only = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "needs_connection", capability: "send_email" }];
    await drive(only);
    expect(await runState(only)).toEqual({ state: "done", hold_reason: null, outcome: "needs_connection" });
    expect((await steps(only)).map((s) => [s.kind, s.receipt?.decision, s.receipt?.capability])).toEqual([["plan", "needs_connection", "send_email"]]);
    expect(await ledger(user)).toEqual([]);

    const after = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "needs_connection", capability: "send_email" }];
    await drive(after);
    expect(await runState(after)).toEqual({ state: "done", hold_reason: null, outcome: "needs_connection" });
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [after])).toBe(1);
  });

  it("물을 것이 있으면(ask_user) needs_input으로 끝내고 질문은 계획 단계 receipt에 둔다. 아무것도 없이 done이면 결과 없이 닫는다", async () => {
    const user = await newUser();
    const ask = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "ask_user", question: "견적 금액이 얼마인가요?" }];
    await drive(ask);
    expect(await runState(ask)).toEqual({ state: "done", hold_reason: null, outcome: "needs_input" });
    expect((await steps(ask))[0].receipt).toMatchObject({ decision: "ask_user", question: "견적 금액이 얼마인가요?" });

    const done = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "done" }];
    await drive(done);
    expect(await runState(done)).toEqual({ state: "done", hold_reason: null, outcome: null });
  });
});

describe("자료: Slack · 출처 모를 원문은 모델에 보내지 않는다", () => {
  it("연결이 Slack인 원문(링크 없음, provider는 연결 행에서) · 연결이 지워진 연동 원문은 근거째 빼고, 직접 넣은 원문은 넣는다", async () => {
    const user = await newUser();
    const actionId = await newAction(user, [
      { text: "박서준: 견적서 금요일까지 회신 부탁드려요.", quote: "견적서 금요일까지 회신 부탁드려요" },
      { text: "slack-secret-7731 내부 채널 이야기", quote: "slack-secret-7731", provider: "slack" },
      { text: "orphan-text-4410 연결이 지워진 원문", quote: "orphan-text-4410", provider: "gmail" },
      { text: "gmail-ok-5520 메일 원문", quote: "gmail-ok-5520", provider: "gmail" },
    ]);
    // 연결 행이 다른 길로 지워진 연동 원문: connection_id는 비고 external_id만 남는다 (Slack일 수 있다)
    await db.query(
      "delete from public.connections where id = (select s.connection_id from public.sources s where s.raw_text like 'orphan-text-4410%' and s.user_id = $1)",
      [user],
    );
    const runId = await startRun(user, actionId);
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    await drive(runId);
    const sent = llm.prompts.join("\n");
    expect(sent).toContain("견적서 금요일까지 회신 부탁드려요");
    expect(sent).toContain("gmail-ok-5520");
    expect(sent).not.toContain("slack-secret-7731");
    expect(sent).not.toContain("orphan-text-4410");
  });
});

describe("함수가 중간에 죽음 (A18)", () => {
  it("모델 호출 중 죽으면 lease 만료 뒤 sweep이 다시 준비하고 새 함수가 이어 간다. 산출물은 1건, 늦게 온 옛 응답은 원가만 남는다", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    await advance(deps("fn-a"), runId); // 계획

    // 초안을 부르는 함수가 응답을 받기 전에 죽는다 (응답은 나중에 온다)
    let respond!: () => void;
    const late = new Promise<void>((resolve) => (respond = resolve));
    const lateAttempt = attempt(0.0005);
    llm.overrides = [
      async (request) => {
        await late;
        return { data: request.schema.parse({ ...DRAFT, title: "늦은 초안" }), model: MODEL, attempts: [lateAttempt] };
      },
    ];
    const dead = advance(deps("fn-dead"), runId);
    await vi.waitFor(async () => expect(await calling()).toBe(1));

    // lease가 살아 있는 동안 sweep · 다른 함수는 건드리지 않는다
    const woken: string[] = [];
    const sweepDeps = { store: store(), lookupGeneration: async (): Promise<GenerationLookup> => ({ status: "pending" }), wake: async (id: string) => (woken.push(id), true), now: () => NOW };
    expect((await sweep(sweepDeps)).expired).toBe(0);
    expect(woken).toEqual([]);
    expect(await advance(deps("fn-b"), runId)).toMatchObject({ status: "busy" });

    await advanceClock(LEASE_SECONDS + 1);
    expect((await sweep(sweepDeps)).expired).toBe(1);
    expect(woken).toEqual([runId]);
    expect((await steps(runId))[1]).toMatchObject({ state: "prepared", attempt: 1 });
    await drive(runId, "fn-new");
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });

    respond();
    expect(await dead).toMatchObject({ status: "lost" });
    expect(await rows("select title from public.execution_artifacts where run_id = $1", [runId])).toEqual([{ title: DRAFT.title }]);
    // 예약 · 정산은 한 번. 늦은 응답은 플랫폼 원가(청구 안 함)로만 남는다
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["reserve", "settle", "release"]);
    expect(await one("select billable, cost_status from public.execution_usage where generation_id = $1", [lateAttempt.generationId])).toEqual({ billable: false, cost_status: "confirmed" });
  });

  it("응답 없음 · 공급자 5xx는 다시 준비하고(원가를 먼저 남긴다), 다시 준비가 2번을 넘으면 실패 · 예약 해제", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps(), runId); // 계획
    const failing = () => async () => {
      throw Object.assign(new LlmError("OpenRouter 요청 실패 (503)"), { attempts: [attempt(0.0001)] });
    };
    llm.overrides = [failing(), failing(), failing()];
    expect(await advance(deps("fn-1"), runId)).toMatchObject({ status: "retry" });
    expect((await steps(runId))[1]).toMatchObject({ state: "prepared", attempt: 1 });
    expect(await advance(deps("fn-2"), runId)).toMatchObject({ status: "retry" });
    expect(await advance(deps("fn-3"), runId)).toMatchObject({ status: "retry" }); // 세 번째: SQL이 한도를 넘겨 실패로 끝낸다
    expect((await steps(runId))[1]).toMatchObject({ state: "failed", receipt: { error: "retries_exhausted" } });
    expect(await runState(runId)).toMatchObject({ state: "failed" });
    // 실패한 시도의 원가는 모두 남고(플랫폼 원가), 예약은 해제된다
    expect((await usage(runId)).filter((u) => u.kind === "draft").map((u) => u.billable)).toEqual([false, false, false]);
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["reserve", "release"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
  });

  it("공급자의 확정적 거절(400 등) · 처리 도중 동의 철회는 다시 하지 않고 실패로 끝낸다 (receipt에 까닭). 키 · 잔액 문제(401 · 402)는 다시 준비", async () => {
    const user = await newUser({ credits: 100 });
    const quota = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps(), quota);
    llm.overrides = [
      async () => {
        throw Object.assign(new LlmError("OpenRouter 요청 실패 (402)"), { attempts: [] });
      },
      async () => {
        throw Object.assign(new LlmError("OpenRouter 요청 실패 (400)"), { attempts: [] });
      },
    ];
    expect(await advance(deps(), quota)).toMatchObject({ status: "retry" }); // 운영 설정 문제: 사용자 run을 바로 실패로 두지 않는다
    expect(await advance(deps(), quota)).toMatchObject({ status: "failed", reason: "rejected" });
    expect(await runState(quota)).toMatchObject({ state: "failed" });

    const consent = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps(), consent);
    await db.query("update public.profiles set ai_consent_at = null where user_id = $1", [user]);
    const before = llm.prompts.length;
    expect(await advance(deps(), consent)).toMatchObject({ status: "failed", reason: "consent" });
    expect(llm.prompts.length).toBe(before); // 모델을 부르지 않았다
    expect((await steps(consent))[1]).toMatchObject({ state: "failed", receipt: { error: "consent" } });
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
  });
});

describe("이어 가기 · 후속 계획", () => {
  it("계획 단계가 다음 단계를 붙인 뒤 끝내지 못하고 죽으면, 다시 부를 때 모델을 부르지 않고 끝낸 뒤 이어 간다. 첫 시도의 원가는 남는다", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    const broken = { ...store(), completeInternalStep: async () => Promise.reject(new Error("connection reset")) };
    await expect(advance({ ...deps("fn-dead"), store: broken }, runId)).rejects.toThrow("connection reset");
    expect((await steps(runId)).map((s) => [s.kind, s.state])).toEqual([
      ["plan", "calling"],
      ["draft", "pending"],
    ]);
    // 받은 계획 시도의 원가는 단계가 calling에 남아도 남는다 (플랫폼 원가)
    expect(await usage(runId)).toEqual([{ kind: "plan", cost_status: "confirmed", billable: false, cost_usd: "0.0007" }]);

    await advanceClock(LEASE_SECONDS + 1);
    const woken: string[] = [];
    await sweep({ store: store(), lookupGeneration: async () => ({ status: "pending" }), wake: async (id) => (woken.push(id), true), now: () => NOW });
    expect(woken).toEqual([runId]);
    const results = await drive(runId, "fn-new");
    expect(results[0]).toEqual({ status: "completed", step: expect.any(String), next: true });
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
    // 계획 모델 호출은 첫 시도와 후속 계획 둘뿐 (다시 부른 계획 단계는 모델을 부르지 않았다)
    expect(llm.prompts.filter((p) => p.includes("실행 계획 담당"))).toHaveLength(2);
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [runId])).toBe(1);
  });

  it("후속 계획(초안 뒤)이 실패하면 다시 하지 않고 이미 만든 초안으로 끝낸다: run은 done · draft_ready, 청구는 초안 한 번", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps("fn-1"), runId); // 계획
    await advance(deps("fn-2"), runId); // 초안
    llm.overrides = [
      async () => {
        throw Object.assign(new LlmError("OpenRouter 요청 실패 (503)"), { attempts: [attempt(0.0002)] });
      },
    ];
    expect(await advance(deps("fn-3"), runId)).toMatchObject({ status: "completed", next: false });
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
    expect((await steps(runId))[2]).toMatchObject({ kind: "plan", state: "called", receipt: { decision: "done", error: "unavailable" } });
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["reserve", "settle", "release"]);
    expect((await usage(runId)).at(-1)).toEqual({ kind: "plan", cost_status: "confirmed", billable: false, cost_usd: "0.0002" });
  });
});

describe("크레딧", () => {
  it("잔액이 모자라면 계획은 하고 초안은 부르지 않는다(hold credit). 지급 뒤 sweep이 깨워 이어 간다", async () => {
    const user = await newUser({ credits: 0 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    const results = await drive(runId);
    expect(results.map((r) => r.status)).toEqual(["completed", "held"]);
    expect(results[1]).toMatchObject({ gate: "insufficient_credit" });
    expect(await runState(runId)).toEqual({ state: "running", hold_reason: "credit", outcome: null });
    expect((await steps(runId))[1].state).toBe("prepared");

    await db.query("select public.grant_credits($1, 50, $2)", [user, randomUUID()]);
    const woken: string[] = [];
    await sweep({ store: store(), lookupGeneration: async () => ({ status: "pending" }), wake: async (id) => (woken.push(id), true), now: () => NOW });
    expect(woken).toEqual([runId]);
    await drive(runId);
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
  });

  it("A46: 초안 원가가 미확정이면 정산하지 않고 예약을 둔다. sweep의 generation 조회가 비용을 찾으면 그때 정산 · 해제", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    llm.cost = undefined; // 응답에 비용이 없다
    await drive(runId);
    expect(await runState(runId)).toMatchObject({ state: "done", outcome: "draft_ready" });
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["reserve"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: DRAFT_ESTIMATE_CREDITS, settled: 0 });

    const lookups: string[] = [];
    const lookupGeneration = async (id: string): Promise<GenerationLookup> => {
      lookups.push(id);
      return {
        status: "found",
        generation: { id, model: MODEL, costUsd: 0.0012, provider: "fireworks", promptTokens: 1000, completionTokens: 300, reasoningTokens: null, cancelled: false, createdAt: NOW.toISOString() },
      };
    };
    const result = await sweep({ store: store(), lookupGeneration, wake: async () => true, now: () => new Date() });
    expect(lookups).toHaveLength(3); // 계획 둘 + 초안 하나, 행마다
    expect(result.reconciled).toBe(3);
    // ceil(0.0012 / 0.001) = 2
    expect(await ledger(user)).toEqual([
      { kind: "reserve", credits: DRAFT_ESTIMATE_CREDITS },
      { kind: "settle", credits: 2 },
      { kind: "release", credits: DRAFT_ESTIMATE_CREDITS - 2 },
    ]);
    // 다시 돌아도 같다
    expect((await sweep({ store: store(), lookupGeneration, wake: async () => true, now: () => new Date() })).reconciled).toBe(0);
  });

  it("운영자만 풀 수 있는 오래된 hold가 쌓여도 지급으로 풀릴 새 run(credit)은 깨울 목록에 든다 (막힌 run은 새것부터)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    for (let i = 0; i < 25; i++) {
      const runId = await startRun(user, actionId);
      await db.query("update public.execution_runs set hold_reason = 'actor', created_at = $2 where id = $1", [runId, new Date(NOW.getTime() - (100 - i) * 60_000).toISOString()]);
    }
    const credit = await startRun(user, actionId);
    await db.query("update public.execution_runs set hold_reason = 'credit' where id = $1", [credit]);
    const free = await startRun(user, actionId);
    const wakeable = await store().wakeableRuns(20);
    expect(wakeable).toHaveLength(20);
    expect(wakeable[0]).toEqual({ id: free, held: false });
    expect(wakeable[1]).toEqual({ id: credit, held: true });
  });

  it("run 예산: 예산이 초안 추정치보다 작으면 초안을 부르지 않는다 (그래서 POST /runs는 그런 예산을 400으로 받지 않는다, contract.ts)", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user), DRAFT_ESTIMATE_CREDITS - 1);
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await drive(runId);
    expect(await runState(runId)).toEqual({ state: "running", hold_reason: "credit", outcome: null });
  });
});

describe("차단 스위치 (기준 9): 세 입구 모두 calling 0", () => {
  it("공급자 스위치를 끄면 route의 after() · 자기 호출 · sweep 어느 입구로도 부르지 않는다. 다시 켜면 sweep이 이어 간다", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    await setControl("provider", "taskforce", true);
    const ctx = { id: user };
    const scheduled: Promise<AdvanceResult>[] = [];

    // ① route: POST /api/v1/runs → 응답 뒤 첫 단계
    const response = await handleCreateRun(
      new Request("https://api.example.test/api/v1/runs", {
        method: "POST",
        body: JSON.stringify({ action_id: actionId, goal: "draft", request: "견적 회신 메일 초안 써 줘" }),
      }),
      routeDeps(ctx, (runId) => scheduled.push(advance(deps("fn-route"), runId))),
    );
    expect(response.status).toBe(202);
    const runId = ((await response.json()) as { run: { id: string } }).run.id;
    expect(await Promise.all(scheduled)).toEqual([expect.objectContaining({ status: "held", gate: "blocked" })]);
    expect(await calling()).toBe(0);

    // ② 자기 호출 (POST /api/cron/execution-advance가 부르는 것과 같은 advance)
    expect(await advance(deps("fn-wake"), runId)).toMatchObject({ status: "held", gate: "blocked" });
    expect(await calling()).toBe(0);

    // ③ sweep → 깨우기 → advance
    const viaSweep: AdvanceResult[] = [];
    const sweepDeps = {
      store: store(),
      lookupGeneration: async (): Promise<GenerationLookup> => ({ status: "pending" }),
      wake: async (id: string) => (viaSweep.push(await advance(deps("fn-sweep"), id)), true),
      now: () => NOW,
    };
    await sweep(sweepDeps);
    expect(viaSweep).toEqual([expect.objectContaining({ status: "held", gate: "blocked" })]);
    expect(await calling()).toBe(0);
    expect(llm.prompts).toEqual([]);
    expect(await runState(runId)).toEqual({ state: "running", hold_reason: "blocked", outcome: null });

    // 다시 켜면 이어 간다
    await setControl("provider", "taskforce", false);
    llm.plans = [{ kind: "done" }];
    viaSweep.length = 0;
    await sweep(sweepDeps);
    expect(viaSweep).toEqual([expect.objectContaining({ status: "completed" })]);
    expect((await runState(runId)).state).toBe("done");
  });

  it("전체 스위치가 막혀 있으면 route는 새 run을 받지 않고(404), 있던 run은 sweep으로도 부르지 않는다", async () => {
    const user = await newUser();
    const runId = await startRun(user, await newAction(user));
    await setControl("global", "*", true);
    const response = await handleCreateRun(
      new Request("https://api.example.test/api/v1/runs", { method: "POST", body: JSON.stringify({ action_id: await newAction(user), goal: "draft", request: "초안" }) }),
      routeDeps({ id: user }, () => {
        throw new Error("부르면 안 된다");
      }),
    );
    expect(response.status).toBe(404);
    // sweep은 전체가 막혀 있으면 깨우지도 않는다 (begin_call이 어차피 막는다)
    const viaSweep: AdvanceResult[] = [];
    const result = await sweep({ store: store(), lookupGeneration: async () => ({ status: "pending" }), wake: async (id) => (viaSweep.push(await advance(deps(), id)), true), now: () => NOW });
    expect(result).toMatchObject({ blocked: true, woken: 0 });
    expect(viaSweep).toEqual([]);
    // 자기 호출이 와도 begin_call이 막는다
    expect(await advance(deps(), runId)).toMatchObject({ status: "held", gate: "blocked" });
    expect(await calling()).toBe(0);
    expect(await runState(runId)).toMatchObject({ hold_reason: "blocked" });
  });

  it("실행 주체 허용 목록 밖이면 route는 404, 이미 있던 run은 begin_call이 막는다 (hold actor)", async () => {
    const user = await newUser({ actor: false });
    const runId = await startRun(user, await newAction(user));
    const response = await handleCreateRun(
      new Request("https://api.example.test/api/v1/runs", { method: "POST", body: JSON.stringify({ action_id: await newAction(user), goal: "draft", request: "초안" }) }),
      routeDeps({ id: user }, () => {}),
    );
    expect(response.status).toBe(404);
    expect(await advance(deps(), runId)).toMatchObject({ status: "held", gate: "actor" });
    expect(await calling()).toBe(0);
  });
});

describe("멈추기", () => {
  it("초안을 부르는 중에 멈추면 그 초안은 받아 남기고 다음 단계는 없다. 예약은 정산 · 해제된다. 다시 멈춰도 같은 200", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps(), runId);
    const stop = () =>
      handleStopRun(new Request(`https://api.example.test/api/v1/runs/${runId}/stop`, { method: "POST" }), runId, {
        ...gateDeps({ id: user }),
        stopRun: async (u, id) => (await one<{ s: string | null }>("select public.stop_run($1, $2) as s", [u.id, id])).s,
        loadRun: async (u, id) => (await one("select id, state from public.execution_runs where id = $1 and user_id = $2", [id, u.id])) as never,
      });
    llm.overrides = [
      async (request) => {
        expect((await stop()).status).toBe(200); // 부르는 중에 멈춤
        return { data: request.schema.parse(DRAFT), model: MODEL, attempts: [attempt(0.0007)] };
      },
    ];
    expect(await advance(deps(), runId)).toMatchObject({ status: "completed" });
    expect(await runState(runId)).toMatchObject({ state: "stopped" });
    expect((await steps(runId)).map((s) => [s.kind, s.state])).toEqual([
      ["plan", "called"],
      ["draft", "called"],
    ]);
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [runId])).toBe(1);
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["reserve", "settle", "release"]);
    expect(await advance(deps(), runId)).toEqual({ status: "closed" });
    const again = await stop();
    expect(again.status).toBe(200);
    expect(((await again.json()) as { run: { state: string } }).run.state).toBe("stopped");

    // 남의 run은 없는 것처럼
    const other = await newUser();
    const foreign = await handleStopRun(new Request(`https://api.example.test/api/v1/runs/${runId}/stop`, { method: "POST" }), runId, {
      ...gateDeps({ id: other }),
      stopRun: async (u, id) => (await one<{ s: string | null }>("select public.stop_run($1, $2) as s", [u.id, id])).s,
      loadRun: async () => null,
    });
    expect(foreign.status).toBe(404);
  });
});

describe("route 처리 × DB", () => {
  it("run_create 횟수 제한(10분에 10번)은 DB 함수가 센다: 11번째는 429", async () => {
    const user = await newUser();
    const create = async () =>
      handleCreateRun(
        new Request("https://api.example.test/api/v1/runs", { method: "POST", body: JSON.stringify({ action_id: await newAction(user), goal: "draft", request: "초안" }) }),
        routeDeps({ id: user }, () => {}),
      );
    for (let i = 0; i < 10; i++) expect((await create()).status).toBe(202);
    const limited = await create();
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("Retry-After"))).toBeGreaterThan(0);
  });

  it("남의 · 열리지 않은 Action이면 404 (create_run도 같은 확인)", async () => {
    const user = await newUser();
    const other = await newUser();
    const foreign = await newAction(other);
    const response = await handleCreateRun(
      new Request("https://api.example.test/api/v1/runs", { method: "POST", body: JSON.stringify({ action_id: foreign, goal: "draft", request: "초안" }) }),
      routeDeps({ id: user }, () => {}),
    );
    expect(response.status).toBe(404);
    await expect(routeDeps({ id: user }, () => {}).createRun({ id: user }, { action_id: foreign, goal: "draft", request: "초안" })).rejects.toBeInstanceOf(
      RunActionNotFoundError,
    );
  });

  it("GET /credits: 계정 행의 합계 (가용 = 지급 - 예약 - 사용)와 지금 요율", async () => {
    const user = await newUser({ credits: 100 });
    const runId = await startRun(user, await newAction(user));
    llm.plans = [{ kind: "draft", brief: "회신" }];
    await advance(deps(), runId);
    llm.overrides = [
      async () => {
        const response = await handleCredits(new Request("https://api.example.test/api/v1/credits"), { ...gateDeps({ id: user }), credits: (u) => credits(u.id) });
        expect(await response.json()).toEqual({ available: 100 - DRAFT_ESTIMATE_CREDITS, reserved: DRAFT_ESTIMATE_CREDITS, rate_version: RATE_VERSION });
        throw Object.assign(new LlmError("OpenRouter 요청 실패 (400)"), { attempts: [] });
      },
    ];
    await advance(deps(), runId);
    expect(await credits(user)).toEqual({ available: 100, reserved: 0, rate_version: RATE_VERSION });
  });
});

describe("receipt (U2 PR7): 초안 목적만 완료, Action은 그대로", () => {
  const actionRow = (actionId: string) =>
    one<Record<string, unknown>>(
      "select title, owner, due_date, status, needs_confirmation, confirm_reasons, resolution, last_activity_at::text, version from public.actions where id = $1",
      [actionId],
    );
  const receipts = (actionId: string) =>
    Promise.all([
      count("select 1 from public.sources s join public.evidence e on e.source_id = s.id where e.action_id = $1 and s.kind = 'execution'", [actionId]),
      rows<{ value: string; origin: string; field: string }>("select value, origin, field from public.claims where action_id = $1 order by created_at", [actionId]),
      count("select 1 from public.evidence where action_id = $1 and role = 'executed'", [actionId]),
      count("select 1 from public.action_events where action_id = $1 and type = 'artifact_created' and actor = 'agent'", [actionId]),
    ]);

  it("초안 단계를 끝낼 때마다 receipt(원문 execution · Claim origin execution · 근거 executed · 이벤트 agent)가 붙고, Action 상태 · 값은 그대로다. 다음 초안 자료에 receipt는 들어가지 않는다", async () => {
    const user = await newUser({ credits: 100 });
    const actionId = await newAction(user);
    const before = await actionRow(actionId);
    const runId = await startRun(user, actionId);
    llm.plans = [{ kind: "draft", brief: "제안서" }, { kind: "draft", brief: "후속 메일" }];
    llm.drafts = [DRAFT, { ...DRAFT, title: "후속: 견적 일정" }];
    await drive(runId);
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });

    const artifacts = (await rows<{ id: string }>("select id from public.execution_artifacts where run_id = $1 order by created_at", [runId])).map((a) => a.id);
    const [sources, claims, executed, events] = await receipts(actionId);
    expect(sources).toBe(2);
    expect(claims).toEqual(artifacts.map((id) => ({ value: id, origin: "execution", field: "artifact" })));
    expect([executed, events]).toEqual([2, 2]);
    expect(await count("select 1 from public.claims where action_id = $1 and origin = 'user'", [actionId])).toBe(0);
    // 초안 ≠ 완료: 상태 · 값 · 확인 · 활동 시각 그대로, 버전만 receipt마다 하나씩
    expect(await actionRow(actionId)).toEqual({ ...before, version: (before.version as number) + 2 });
    // 두 번째 초안(4번째 모델 호출)은 앞선 receipt를 원문으로 받지 않는다 (근거 원문은 받는다)
    expect(llm.prompts[3]).toContain("견적서 금요일까지 회신 부탁드려요");
    expect(llm.prompts[3]).not.toContain("초안 저장");
  });

  it("실행기가 receipt를 쓰지 못하고 끝나도 단계 · run은 끝낸 그대로이고, sweep 보조 안전망이 한 번만 이어 쓴다", async () => {
    const user = await newUser({ credits: 100 });
    const actionId = await newAction(user);
    const runId = await startRun(user, actionId);
    llm.plans = [{ kind: "draft", brief: "회신" }, { kind: "done" }];
    const dying = (): ExecutorDeps => ({
      ...deps(),
      store: {
        ...store(),
        writeReceipt: async () => {
          throw new Error("function killed");
        },
      },
    });
    for (let i = 0; i < 5; i++) {
      const result = await advance(dying(), runId);
      if (!(result.status === "completed" && result.next)) break;
    }
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });
    expect((await receipts(actionId))[0]).toBe(0);

    const sweepDeps = { store: store(), lookupGeneration: async (): Promise<GenerationLookup> => ({ status: "pending" }), wake: async () => true, now: () => NOW };
    expect(await sweep(sweepDeps)).toMatchObject({ receipts: 1, receipt_failed: 0, errors: 0 });
    expect(await sweep(sweepDeps)).toMatchObject({ receipts: 0, receipt_failed: 0, errors: 0 });
    const [sources, claims, executed, events] = await receipts(actionId);
    expect([sources, claims.length, executed, events]).toEqual([1, 1, 1, 1]);
    expect((await one<{ status: string }>("select status from public.actions where id = $1", [actionId])).status).toBe("open");
  });
});

describe("외부 효과 없음", () => {
  it("외부 단계(kind external)는 begin_call도 부르지 않는다 (발송은 U6a)", async () => {
    const user = await newUser();
    const runId = await startRun(user, await newAction(user));
    await db.query("insert into public.execution_tools (provider, tool, effect_class) values ('fake', 'send', 'external') on conflict do nothing");
    await db.query("insert into public.execution_controls (scope, key) values ('provider', 'fake') on conflict do nothing");
    await db.query(
      "update public.execution_steps set state = 'called', version = version + 1, policy_version = 1 where run_id = $1 and seq = 1",
      [runId],
    );
    await db.query("select public.append_step($1, 2, $2::jsonb)", [runId, JSON.stringify({ kind: "external", provider: "fake", tool: "send", purpose: "send" })]);
    expect(await advance(deps(), runId)).toMatchObject({ status: "busy" });
    expect(await advance(deps(), runId)).toMatchObject({ status: "busy" });
    expect(await count("select 1 from public.execution_intents i join public.execution_steps s on s.id = i.step_id where s.run_id = $1 and s.kind = 'external'", [runId])).toBe(0);
  });
});

// ─── route 처리에 넘기는 DB 연산 (운영 route가 store.ts로 하는 것과 같은 SQL) ───

type Ctx = { id: string };

function gateDeps(ctx: Ctx) {
  return {
    enabled: () => true,
    authenticate: async () => ctx,
    isActor: async (u: Ctx) => (await count("select 1 from public.execution_actors where user_id = $1", [u.id])) > 0,
  };
}

function routeDeps(ctx: Ctx, schedule: (runId: string) => void) {
  return {
    ...gateDeps(ctx),
    globallyBlocked: async () => {
      const row = await one<{ blocked: boolean } | undefined>("select blocked from public.execution_controls where scope = 'global' and key = '*'");
      return !row || row.blocked;
    },
    hasConsent: async (u: Ctx) => (await count("select 1 from public.profiles where user_id = $1 and ai_consent_at is not null", [u.id])) > 0,
    actionOpen: async (u: Ctx, actionId: string) => (await count("select 1 from public.actions where id = $1 and user_id = $2 and status = 'open'", [actionId, u.id])) > 0,
    rateLimit: async (u: Ctx) => {
      const at = (await one<{ at: Date | null }>("select public.take_rate_limit($1, 'run_create', 10, 600) as at", [u.id])).at;
      return at ? new Date(at) : null;
    },
    createRun: async (u: Ctx, run: { action_id: string; goal: "draft"; request: string; budget_credits?: number }) => {
      try {
        return (await one<{ id: string }>("select public.create_run($1, $2, $3, $4, $5) as id", [u.id, run.action_id, run.goal, run.request, run.budget_credits ?? null])).id;
      } catch (error) {
        if ((error as { code?: string }).code === "P0002") throw new RunActionNotFoundError();
        throw error;
      }
    },
    loadRun: async (u: Ctx, runId: string) =>
      (await one("select id, action_id, goal, state, hold_reason, outcome, budget_credits, created_at::text from public.execution_runs where id = $1 and user_id = $2", [
        runId,
        u.id,
      ])) as never,
    schedule,
    now: () => NOW,
  };
}

async function credits(userId: string) {
  const a = await account(userId);
  const rate = await one<{ version: string }>("select version from public.credit_rates where active");
  return { available: a ? a.granted - a.reserved - a.settled : 0, reserved: a?.reserved ?? 0, rate_version: rate?.version ?? null };
}
