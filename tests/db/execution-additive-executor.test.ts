import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { advance, type AdvanceResult } from "@/lib/execution/executor";
import { sweep } from "@/lib/execution/sweep";
import { EXECUTABLE_GOALS, EXECUTABLE_STEP_KINDS } from "@/lib/execution/types";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { pgliteExecutionStore } from "../execution/pglite-store";
import { NEW_GOALS, NEW_STEP_KINDS } from "./execution-additive-contract.scenarios";
import { createLocalSupabase } from "./local-supabase";

// 0.2.0 C1(20261109000000_execution_additive_contract): DB가 새 goal · 단계 종류를 받아도 실행기는 실행하지 않는다 (fail closed).
// 실행기(src/lib/execution/executor.ts)를 운영 마이그레이션(PGlite) 위에서 그대로 돌린다. 실행에 필요한 조건은 모두 갖춘 세계다(실행 주체 · 동의 · 크레딧 · 스위치 열림 ·
// 도구 목록 허용): 그래서 0번의 모델 호출은 조건이 막아서가 아니라 실행기가 새 값을 실행하지 않아서다 (대조군: 같은 세계의 draft run은 모델을 부른다).
// 새 값을 쓰는 코드는 이 묶음에 없다: 행은 서버가 DB에 직접 넣은 것이다. 외부 호출(메일 · 에이전트 · 공급자)은 실행기에 길이 없고, 모델 호출 0 · 네트워크 호출 0으로 본다.

let db: PGlite;
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const store = () => pgliteExecutionStore(db);

let modelCalls: string[];
/** 모델 호출을 세는 가짜 LLM. 계획은 초안을, 초안은 본문을 준다 */
const complete = (async (request) => {
  modelCalls.push(request.schemaName ?? "?");
  const data = request.schemaName === "next_step" ? { reason: "r", step: { kind: "draft", brief: "회신" } } : { title: "Re: 견적", to: [], body: "본문" };
  return {
    data: request.schema.parse(data),
    model: "m",
    attempts: [{ generationId: `gen-${randomUUID()}`, model: "m", usage: { prompt_tokens: 100, completion_tokens: 30, cost: 0.0005 } }],
  };
}) as CompleteJson;
const deps = (owner = "fn-1") => ({ store: store(), complete, owner });

/** 실행 조건을 모두 갖춘 사용자 */
async function readyUser() {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.profiles (user_id, ai_consent_at) values ($1, now())", [userId]);
  await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  await db.query("select public.grant_credits($1, 500, $2)", [userId, randomUUID()]);
  return userId;
}
const action = async (userId: string) => (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, '견적 회신') returning id", [userId])).id;

type RawStep = { seq: number; kind: string; state?: "pending" | "prepared" | "called"; provider?: string; tool?: string; effect?: "internal" | "external" };
/**
 * 서버가 DB에 직접 넣은 run(새 값은 create_run · append_step이 막는다). 단계의 공급자 · 도구는 기본이 내장 초안 도구(taskforce.draft, 내부 효과)다:
 * 도구 목록이 허용하는 가장 나쁜 경우 — 실행기가 종류를 보지 않으면 begin_call을 지나 초안(모델 호출)으로 새는 조합이다
 */
async function rawRun(userId: string, goal: string, steps: RawStep[]) {
  await db.query("insert into public.execution_policies (user_id) values ($1) on conflict (user_id) do nothing", [userId]);
  const run = (
    await one<{ id: string }>(
      `insert into public.execution_runs (user_id, action_id, policy_id, goal, request)
       select $1, $2, p.id, $3, '요청 글' from public.execution_policies p where p.user_id = $1 returning id`,
      [userId, await action(userId), goal],
    )
  ).id;
  const ids: string[] = [];
  for (const s of steps) {
    const state = s.state ?? "pending";
    ids.push(
      (
        await one<{ id: string }>(
          `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose, state, policy_version, estimate_credits, intent_key)
           values ($1, $2, $3, $4, $5, $6, $7, $4, $8, $9, $10, $11) returning id`,
          [
            userId, run, s.seq, s.kind, s.provider ?? "taskforce", s.tool ?? "draft", s.effect ?? "internal", state,
            state === "pending" ? null : 1, s.kind === "draft" || s.tool === "draft" ? 20 : 0, state === "pending" ? null : `raw-${randomUUID()}`,
          ],
        )
      ).id,
    );
  }
  return { run, steps: ids };
}

const SNAPSHOT_TABLES = [
  "execution_policies", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "execution_artifacts",
  "execution_usage", "credit_accounts", "credit_ledger", "actions",
];
async function snapshot() {
  const out: Record<string, unknown[]> = {};
  for (const table of SNAPSHOT_TABLES) out[table] = (await db.query<{ row: unknown }>(`select to_jsonb(t) as row from public.${table} t order by to_jsonb(t)::text`)).rows;
  return out;
}

let fetchSpy: ReturnType<typeof vi.spyOn>;
beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);
beforeEach(async () => {
  modelCalls = [];
  await db.exec("truncate public.actions, public.execution_policies restart identity cascade");
  // 처음 상태는 전체 스위치가 막혀 있다. 여기서는 연 상태에서 시작한다 (Manual만)
  await db.query("update public.execution_controls set blocked = (scope = 'mode' and key <> 'manual')");
  vi.spyOn(console, "info").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
  fetchSpy = vi.spyOn(globalThis, "fetch");
});
afterEach(() => vi.restoreAllMocks());

describe("대조군: 같은 세계에서 draft run은 실행된다 (그래서 아래의 0은 실행기의 판단이다)", () => {
  it("draft run은 모델을 부르고 단계를 끝낸다", async () => {
    const user = await readyUser();
    const { run, steps } = await rawRun(user, "draft", [{ seq: 1, kind: "plan", tool: "plan" }]);
    expect(await advance(deps(), run)).toMatchObject({ status: "completed", next: true });
    expect(modelCalls).toEqual(["next_step"]);
    expect((await one<{ state: string }>("select state from public.execution_steps where id = $1", [steps[0]])).state).toBe("called");
  });

  it("실행기가 아는 값은 draft goal · plan · draft 단계뿐이다", () => {
    expect([...EXECUTABLE_GOALS]).toEqual(["draft"]);
    expect([...EXECUTABLE_STEP_KINDS]).toEqual(["plan", "draft"]);
  });
});

describe("새 goal의 run: 단계가 어떤 상태든 실행기는 아무것도 하지 않는다", () => {
  it.each(NEW_GOALS)("goal %s (계획 단계 pending · prepared): advance는 unsupported, 모델 · 네트워크 호출 0, DB 변화 0 (준비 · begin_call · 예약 · intent · 이벤트 · run 닫기 없음)", async (goal) => {
    const user = await readyUser();
    const pending = await rawRun(user, goal, [{ seq: 1, kind: "plan", tool: "plan" }]);
    const prepared = await rawRun(user, goal, [{ seq: 1, kind: "plan", tool: "plan", state: "prepared" }]);
    // 단계가 하나도 없는 run도 (남은 단계가 없다고 run을 done으로 닫지 않는다)
    const empty = await rawRun(user, goal, []);
    const before = await snapshot();
    for (const { run } of [pending, prepared, empty]) {
      expect(await advance(deps(), run)).toEqual({ status: "unsupported", reason: "goal", step: null });
    }
    expect(await snapshot()).toEqual(before);
    expect(modelCalls).toEqual([]);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(await one("select count(*)::int as n from public.execution_intents")).toEqual({ n: 0 });
    expect((await db.query("select state, hold_reason, outcome from public.execution_runs where goal = $1", [goal])).rows).toEqual(
      Array(3).fill({ state: "queued", hold_reason: null, outcome: null }),
    );
  });

  it("route의 after() · 자기 호출 · sweep 세 입구 모두: sweep은 새 goal의 run을 깨우지 않고, 낡은 자기 호출이 와도 advance가 멈춘다. draft run은 그대로 깨운다", async () => {
    const user = await readyUser();
    const normal = await rawRun(user, "draft", [{ seq: 1, kind: "plan", tool: "plan" }]);
    const others = await Promise.all(NEW_GOALS.map((goal) => rawRun(user, goal, [{ seq: 1, kind: "plan", tool: "plan" }])));
    const before = await snapshot();

    expect(await store().wakeableRuns(20)).toEqual([{ id: normal.run, held: false }]);
    const woken: string[] = [];
    const result = await sweep({ store: store(), lookupGeneration: async () => ({ status: "pending" }), wake: async (id) => (woken.push(id), true), now: () => new Date("2026-10-02T00:00:00Z") });
    expect(woken).toEqual([normal.run]);
    expect(result).toMatchObject({ woken: 1, errors: 0 });
    expect(await snapshot()).toEqual(before); // sweep은 깨우기만 한다(단계를 돌리지 않는다)

    // 이미 날아온 자기 호출: 새 goal은 멈추고, draft는 돈다
    for (const { run } of others) expect(await advance(deps(), run)).toMatchObject({ status: "unsupported" });
    expect(modelCalls).toEqual([]);
    expect(await advance(deps(), normal.run)).toMatchObject({ status: "completed" });
    expect(modelCalls).toEqual(["next_step"]);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("새 goal의 run이 앞자리를 차지하지 못한다: 오래된 새 goal run이 많아도(깨우기 한도 20 초과) 새 draft run은 깨운다", async () => {
    const user = await readyUser();
    for (let i = 0; i < 25; i++) await rawRun(user, NEW_GOALS[i % NEW_GOALS.length], [{ seq: 1, kind: "plan", tool: "plan" }]);
    const normal = await rawRun(user, "draft", [{ seq: 1, kind: "plan", tool: "plan" }]);
    expect((await store().wakeableRuns(20)).map((r) => r.id)).toEqual([normal.run]);
  });
});

describe("새 단계 종류: draft run 안에서도 준비 · begin_call 없이 멈춘다 (plan이 아니면 초안으로 보는 갈래로 새지 않는다)", () => {
  /** 종류마다 (도구 목록이 허용하는 가장 나쁜 조합, 실제로 쓰일 조합) */
  const REALISTIC: Record<string, { provider: string; tool: string; effect: "internal" | "external" }> = {
    agent_dispatch: { provider: "agent:claude-code", tool: "dispatch", effect: "external" },
    agent_message: { provider: "agent:claude-code", tool: "message", effect: "external" },
    agent_cancel: { provider: "agent:claude-code", tool: "cancel", effect: "external" },
    review: { provider: "taskforce", tool: "review", effect: "internal" },
    check: { provider: "taskforce", tool: "check", effect: "internal" },
    send: { provider: "gmail", tool: "send", effect: "external" },
    observe: { provider: "gmail", tool: "observe", effect: "internal" },
  };

  it.each(NEW_STEP_KINDS)("%s (pending · prepared, 내장 초안 도구로 적었을 때와 실제 도구로 적었을 때, 첫 단계일 때와 계획 뒤일 때): unsupported, 모델 호출 0, DB 변화 0", async (kind) => {
    const user = await readyUser();
    const variants: RawStep[][] = [];
    for (const state of ["pending", "prepared"] as const) {
      variants.push([{ seq: 1, kind, state }]); // 내장 초안 도구(internal)로 적은 새 종류가 첫 단계
      variants.push([{ seq: 1, kind: "plan", tool: "plan", state: "called" }, { seq: 2, kind, state }]);
      variants.push([{ seq: 1, kind: "plan", tool: "plan", state: "called" }, { seq: 2, kind, state, ...REALISTIC[kind] }]);
    }
    const runs = [];
    for (const steps of variants) runs.push(await rawRun(user, "draft", steps));
    const before = await snapshot();
    for (const [i, { run, steps }] of runs.entries()) {
      const stuck = variants[i].length; // 막힌 단계는 마지막 단계다
      expect(await advance(deps(), run), `variant ${i}`).toEqual({ status: "unsupported", reason: "kind", step: steps[stuck - 1] });
    }
    expect(await snapshot()).toEqual(before);
    expect(modelCalls).toEqual([]);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(await one("select count(*)::int as n from public.execution_intents")).toEqual({ n: 0 });
    expect(await one("select count(*)::int as n from public.credit_ledger where kind <> 'grant'")).toEqual({ n: 0 });
  });

  it("지금 실행하는 plan · draft 단계와 external(부르지 않고 그대로 둔다)의 동작은 그대로다", async () => {
    const user = await readyUser();
    const external = await rawRun(user, "draft", [
      { seq: 1, kind: "plan", tool: "plan", state: "called" },
      { seq: 2, kind: "external", provider: "gmail", tool: "send", effect: "external" },
    ]);
    const before = await snapshot();
    const result: AdvanceResult = await advance(deps(), external.run);
    expect(result).toEqual({ status: "busy", step: external.steps[1] });
    expect(await snapshot()).toEqual(before);
    expect(modelCalls).toEqual([]);

    const draft = await rawRun(user, "draft", [
      { seq: 1, kind: "plan", tool: "plan", state: "called" },
      { seq: 2, kind: "draft", state: "pending" },
    ]);
    expect(await advance(deps(), draft.run)).toMatchObject({ status: "completed" });
    expect(modelCalls).toEqual(["draft"]);
  });
});
