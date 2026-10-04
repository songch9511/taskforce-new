import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { createLocalSupabase } from "./local-supabase";

// 실행 코어(20261021000000_execution_core)의 운영 쪽 모양: 처음 상태(닫힌 쪽), run · 단계 만들기, 끝내기 · 멈추기, 실행 이벤트,
// 연결 끊기, run_create 횟수 제한. 상태 전이의 계약(A29)은 tests/execution/a29.test.ts가 같은 마이그레이션으로 시험한다.
// 여기서는 시계를 바꾸지 않는다 (운영의 db_now() = now()).

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const gate = async (step: string, owner = "fn-1") => {
  const { version } = await one<{ version: number }>("select version from public.execution_steps where id = $1", [step]);
  return (await one<{ g: Record<string, unknown> }>("select public.begin_call($1, $2, $3) as g", [step, owner, version])).g;
};

let actionCount = 0;
async function newAction(userId: string, status = "open") {
  actionCount += 1;
  return (await one<{ id: string }>("insert into public.actions (user_id, title, status) values ($1, $2, $3) returning id", [userId, `할 일 ${actionCount}`, status])).id;
}

/** create_run → 첫 단계(계획)를 prepared까지. run · 단계 id */
async function preparedRun(userId: string) {
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '초안 써 줘') as id", [userId, await newAction(userId)])).id;
  const stepId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
  expect((await one<{ ok: boolean }>("select public.prepare_step($1, 0) as ok", [stepId])).ok).toBe(true);
  return { runId, stepId };
}

const setGlobal = (blocked: boolean) => db.query("update public.execution_controls set blocked = $1 where scope = 'global'", [blocked]);

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("처음 상태: 닫힌 쪽", () => {
  it("전체 스위치가 막혀 있고, 풀어도 Manual만, 공급자는 내장(taskforce)만, 도구는 내장 계획 · 초안만이다", async () => {
    const controls = await db.query("select scope, key, blocked from public.execution_controls order by scope, key");
    expect(controls.rows).toEqual([
      { scope: "global", key: "*", blocked: true },
      { scope: "mode", key: "auto", blocked: true },
      { scope: "mode", key: "full", blocked: true },
      { scope: "mode", key: "manual", blocked: false },
      { scope: "provider", key: "taskforce", blocked: false },
    ]);
    const tools = await db.query("select provider, tool, effect_class from public.execution_tools order by tool");
    expect(tools.rows).toEqual([
      { provider: "taskforce", tool: "draft", effect_class: "internal" },
      { provider: "taskforce", tool: "plan", effect_class: "internal" },
    ]);
    expect((await one<{ n: number }>("select count(*)::int as n from public.execution_actors")).n).toBe(0);
    expect((await one<{ n: number }>("select count(*)::int as n from public.execution_recipient_allowlist")).n).toBe(0);
  });

  it("실행 주체가 없으면 actor, 운영자를 넣어도 전체가 막혀 있으면 blocked, 풀면 Manual 사용자의 내장 계획만 부른다", async () => {
    const { runId, stepId } = await preparedRun(ALICE);
    expect(await gate(stepId)).toEqual({ gate: "actor" });
    await db.query("insert into public.execution_actors (user_id) values ($1)", [ALICE]);
    expect(await gate(stepId)).toEqual({ gate: "blocked" });
    await setGlobal(false);
    try {
      const ok = await gate(stepId);
      expect(ok).toMatchObject({ gate: "ok", provider: "taskforce", tool: "plan", recipients: [], connection: null });
      expect(typeof ok.marker).toBe("string");
      expect(await one("select state, hold_reason from public.execution_runs where id = $1", [runId])).toEqual({ state: "running", hold_reason: null });

      // Auto · Full 사용자는 "Manual만" 상태에서 막힌다
      await db.query("insert into public.execution_actors (user_id) values ($1)", [BOB]);
      await db.query("insert into public.execution_policies (user_id, mode) values ($1, 'auto')", [BOB]);
      const bob = await preparedRun(BOB);
      expect(await gate(bob.stepId)).toEqual({ gate: "blocked" });
    } finally {
      await setGlobal(true);
    }
  });
});

describe("run · 단계 만들기", () => {
  it("create_run: 본인의 열린 Action에만 만들고, 정책이 없으면 Manual로 만들고, 첫 단계는 계획(내부 효과)이다", async () => {
    await expect(db.query("select public.create_run($1, $2, 'draft', 'x')", [BOB, await newAction(ALICE)])).rejects.toThrow(/open action not found/);
    await expect(db.query("select public.create_run($1, $2, 'draft', 'x')", [ALICE, await newAction(ALICE, "done")])).rejects.toThrow(/open action not found/);
    await expect(db.query("select public.create_run($1, $2, 'send', 'x')", [ALICE, await newAction(ALICE)])).rejects.toThrow(/check constraint/);

    const user = "00000000-0000-0000-0000-00000000000c";
    await db.query("insert into auth.users (id, email) values ($1, 'carol@example.com')", [user]);
    const first = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '초안 써 줘', 50) as id", [user, await newAction(user)])).id;
    const second = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '다시') as id", [user, await newAction(user)])).id;
    expect(await one("select mode, version from public.execution_policies where user_id = $1", [user])).toEqual({ mode: "manual", version: 1 });
    const runs = await db.query<{ policy_id: string; state: string; budget_credits: number | null }>(
      "select policy_id, state, budget_credits from public.execution_runs where id in ($1, $2) order by budget_credits nulls last",
      [first, second],
    );
    expect(runs.rows.map((r) => [r.state, r.budget_credits])).toEqual([
      ["queued", 50],
      ["queued", null],
    ]);
    expect(runs.rows[0].policy_id).toBe(runs.rows[1].policy_id);
    expect(await one("select seq, kind, provider, tool, effect_class, state, recipients from public.execution_steps where run_id = $1", [first])).toEqual({
      seq: 1,
      kind: "plan",
      provider: "taskforce",
      tool: "plan",
      effect_class: "internal",
      state: "pending",
      recipients: [],
    });
  });

  it("prepare_step: 내부 효과는 승인이 필요 없고, intent key는 단계마다 하나다", async () => {
    const { stepId } = await preparedRun(ALICE);
    expect(await one("select state, needs_approval, intent_key from public.execution_steps where id = $1", [stepId])).toEqual({
      state: "prepared",
      needs_approval: false,
      intent_key: `internal|${stepId}`,
    });
  });

  it("append_step: 끝나지 않은 run에 기대한 순번(마지막 + 1)일 때만 붙이고, 효과 종류는 도구 목록이 정하고, 회차는 늘 1이다", async () => {
    const { runId } = await preparedRun(ALICE);
    const append = async (seq: number, step: object) =>
      (await one<{ id: string | null }>("select public.append_step($1, $2, $3::jsonb) as id", [runId, seq, JSON.stringify(step)])).id;
    // 모델 · planner는 회차를 늘리지 못한다: 넘겨도 1
    const draft = { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft", body: "제안서 초안", estimate_credits: 30, occurrence: 5 };

    const id = await append(2, draft);
    expect(id).toEqual(expect.any(String));
    expect(await one("select seq, effect_class, body, estimate_credits, occurrence, user_id from public.execution_steps where id = $1", [id])).toEqual({
      seq: 2,
      effect_class: "internal",
      body: "제안서 초안",
      estimate_credits: 30,
      occurrence: 1,
      user_id: ALICE,
    });
    expect(await append(2, draft)).toBeNull(); // 다른 함수가 먼저 붙였다
    expect(await append(4, draft)).toBeNull(); // 건너뛴 순번

    // 목록 밖 도구를 내부라고 적어도 external로 들어간다 (begin_call이 막는다)
    const unknown = await append(3, { kind: "external", provider: "gmail", tool: "send", purpose: "send", effect_class: "internal" });
    expect((await one<{ effect_class: string }>("select effect_class from public.execution_steps where id = $1", [unknown])).effect_class).toBe("external");

    // 수신자 출처는 정한 값(user · source · tool_output · model)만, 주소는 비어 있지 않아야 한다
    for (const recipients of [[{ address: "a@example.com", origin: "admin" }], [{ address: " ", origin: "user" }], [{ origin: "model" }], ["a@example.com"]]) {
      await expect(append(4, { kind: "external", provider: "gmail", tool: "send", purpose: "send", recipients })).rejects.toThrow(/check constraint/);
    }

    expect(await one<{ s: string }>("select public.stop_run($1, $2) as s", [ALICE, runId])).toEqual({ s: "stopped" });
    expect(await append(4, draft)).toBeNull(); // 멈춘 run에는 붙이지 않는다
  });

  it("approval_hash: 공급자 · 효과 종류가 바뀌어도 값이 바뀐다", async () => {
    const { stepId } = await preparedRun(ALICE);
    const at = new Date(Date.now() + 600_000);
    const hash = async () => (await one<{ h: string }>("select public.approval_hash($1, $2) as h", [stepId, at])).h;
    const before = await hash();
    await db.query("update public.execution_steps set provider = 'other' where id = $1", [stepId]);
    const afterProvider = await hash();
    await db.query("update public.execution_steps set effect_class = 'external' where id = $1", [stepId]);
    expect(new Set([before, afterProvider, await hash()]).size).toBe(3);
  });
});

describe("끝내기 · 멈추기", () => {
  it("settle_step: lease 소유자만 끝낸다. 남은 단계가 없으면 run done과 결과(outcome)를 함께 적는다", async () => {
    await db.query("insert into public.execution_actors (user_id) values ($1) on conflict do nothing", [ALICE]);
    await setGlobal(false);
    try {
      const { runId, stepId } = await preparedRun(ALICE);
      expect((await gate(stepId, "fn-owner")).gate).toBe("ok");
      const settle = async (owner: string) =>
        (await one<{ ok: boolean }>("select public.settle_step($1, $2, 'called', '{\"via\": \"response\"}', 'needs_connection') as ok", [stepId, owner])).ok;
      expect(await settle("fn-other")).toBe(false);
      expect(await settle("fn-owner")).toBe(true);
      expect(await settle("fn-owner")).toBe(false); // 이미 끝났다
      expect(await one("select state, outcome from public.execution_runs where id = $1", [runId])).toEqual({ state: "done", outcome: "needs_connection" });
      await expect(db.query("select public.settle_step($1, 'fn-owner', 'unknown_outcome', '{}')", [stepId])).rejects.toThrow(/잘못된 상태/);

      // 계획 단계를 결과 없이 끝내면 run은 그대로(planner가 다음 단계를 붙인다). 붙인 것이 없으면 finish_run이 닫는다
      const other = await preparedRun(ALICE);
      expect((await gate(other.stepId, "fn-owner")).gate).toBe("ok");
      expect((await one<{ ok: boolean }>("select public.settle_step($1, 'fn-owner', 'called', '{}') as ok", [other.stepId])).ok).toBe(true);
      expect((await one<{ state: string }>("select state from public.execution_runs where id = $1", [other.runId])).state).toBe("running");
      expect(await one("select public.finish_run($1) as ok", [other.runId])).toEqual({ ok: true });
      expect(await one("select gate from public.execution_events where run_id = $1 and type = 'run' and to_state = 'done'", [other.runId])).toEqual({ gate: "finish" });
      expect(await one("select gate from public.execution_events where run_id = $1 and type = 'run' and to_state = 'done'", [runId])).toEqual({ gate: "response" });
    } finally {
      await setGlobal(true);
    }
  });

  it("stop_run: 본인 run만 멈추고 멈춘 뒤 상태를 돌려준다. 이미 끝난 run은 그대로, 다른 사용자의 run은 없는 것처럼(null)", async () => {
    const { runId } = await preparedRun(ALICE);
    expect(await one("select public.stop_run($1, $2) as s", [BOB, runId])).toEqual({ s: null });
    expect(await one("select public.stop_run($1, $2) as s", [ALICE, runId])).toEqual({ s: "stopped" });
    expect(await one("select public.stop_run($1, $2) as s", [ALICE, runId])).toEqual({ s: "stopped" });
    await db.query("update public.execution_runs set state = 'done' where id = $1", [runId]);
    expect(await one("select public.stop_run($1, $2) as s", [ALICE, runId])).toEqual({ s: "done" });
  });

  it("stop_run은 멈춘 시각(stopped_at, DB 시각)을 처음 멈출 때 한 번만 적는다: 다시 멈춰도 · 남이 멈추려 해도 그대로, 멈추지 않은 run은 null", async () => {
    const { runId } = await preparedRun(ALICE);
    const stoppedAt = async () => (await one<{ stopped_at: Date | null }>("select stopped_at from public.execution_runs where id = $1", [runId])).stopped_at;
    expect(await stoppedAt()).toBeNull();
    await db.query("select public.stop_run($1, $2)", [BOB, runId]);
    expect(await stoppedAt()).toBeNull();

    await db.query("select public.stop_run($1, $2)", [ALICE, runId]);
    const first = await stoppedAt();
    expect(first).toBeInstanceOf(Date);
    // 멈춘 전이의 실행 이벤트와 같은 DB 시각이다
    expect(await one("select gate, at from public.execution_events where run_id = $1 and type = 'run' and to_state = 'stopped'", [runId])).toEqual({ gate: "stop", at: first });
    await db.query("select public.stop_run($1, $2)", [ALICE, runId]);
    expect(await stoppedAt()).toEqual(first);

    const done = await preparedRun(ALICE);
    await db.query("update public.execution_runs set state = 'done' where id = $1", [done.runId]);
    await db.query("select public.stop_run($1, $2)", [ALICE, done.runId]);
    expect(await one("select state, stopped_at from public.execution_runs where id = $1", [done.runId])).toEqual({ state: "done", stopped_at: null });
  });

  it("begin_call: 할 일이 열려 있지 않으면(완료 · 삭제) 부르지 않고 run을 멈춘다(gate action_closed, 사용자가 멈춘 게 아니라 stopped_at은 null). 다시 열어도 멈춘 run은 그대로", async () => {
    await db.query("insert into public.execution_actors (user_id) values ($1) on conflict do nothing", [ALICE]);
    await setGlobal(false);
    try {
      for (const status of ["done", "dropped"]) {
        const { runId, stepId } = await preparedRun(ALICE);
        const actionId = (await one<{ action_id: string }>("select action_id from public.execution_runs where id = $1", [runId])).action_id;
        await db.query("update public.actions set status = $2 where id = $1", [actionId, status]);
        expect(await gate(stepId)).toEqual({ gate: "action_closed" });
        const run = await one<{ state: string; hold_reason: string | null; stopped_at: Date | null }>(
          "select state, hold_reason, stopped_at from public.execution_runs where id = $1",
          [runId],
        );
        expect(run).toEqual({ state: "stopped", hold_reason: null, stopped_at: null });
        expect(await one("select gate from public.execution_events where run_id = $1 and type = 'run' and to_state = 'stopped'", [runId])).toEqual({ gate: "action_closed" });
        // 단계는 부르지 않았다: prepared 그대로, 표식 · lease 없음
        expect(await one("select state, lease_owner from public.execution_steps where id = $1", [stepId])).toEqual({ state: "prepared", lease_owner: null });
        expect((await one<{ n: number }>("select count(*)::int as n from public.execution_intents where step_id = $1", [stepId])).n).toBe(0);

        await db.query("update public.actions set status = 'open' where id = $1", [actionId]);
        expect(await gate(stepId)).toEqual({ gate: "stopped" });
        expect(await one("select state, stopped_at from public.execution_runs where id = $1", [runId])).toEqual({ state: "stopped", stopped_at: null });
      }
    } finally {
      await setGlobal(true);
    }
  });

  it("begin_call: 할 일 확인은 차단 스위치 · 실행 주체보다 먼저다 (스위치가 막혀 있어도 닫힌 할 일의 run은 기다리지 않고 멈춘다)", async () => {
    const { runId, stepId } = await preparedRun(BOB); // BOB은 실행 주체가 아니고, 전체 스위치는 막혀 있다
    await db.query("update public.actions set status = 'done' where id = (select action_id from public.execution_runs where id = $1)", [runId]);
    expect(await gate(stepId)).toEqual({ gate: "action_closed" });
    expect(await one("select state, hold_reason from public.execution_runs where id = $1", [runId])).toEqual({ state: "stopped", hold_reason: null });
  });

  it("show_plan · approve_step: 다른 사용자의 단계는 보이지 않고, 지난 만료 · 1시간 넘는 만료는 승인하지 않는다", async () => {
    const { stepId } = await preparedRun(ALICE);
    expect((await db.query("select * from public.show_plan($1, $2)", [BOB, stepId])).rows).toHaveLength(0);
    const shown = await one<{ hash: string; expires_at: Date }>("select * from public.show_plan($1, $2)", [ALICE, stepId]);
    const approve = async (userId: string, hash: string, expires: string | Date) =>
      (await one<{ ok: boolean }>("select public.approve_step($1, $2, $3, $4::timestamptz) as ok", [userId, stepId, hash, expires])).ok;

    expect(await approve(BOB, shown.hash, shown.expires_at)).toBe(false);
    const late = (await one<{ e: Date }>("select date_trunc('second', now() + interval '2 hours') as e")).e;
    expect(await approve(ALICE, (await one<{ h: string }>("select public.approval_hash($1, $2) as h", [stepId, late])).h, late)).toBe(false);
    const past = (await one<{ e: Date }>("select date_trunc('second', now() - interval '1 minute') as e")).e;
    expect(await approve(ALICE, (await one<{ h: string }>("select public.approval_hash($1, $2) as h", [stepId, past])).h, past)).toBe(false);
    expect(await approve(ALICE, shown.hash, shown.expires_at)).toBe(true);
    const revoke = async (userId: string) => (await db.query("select * from public.revoke_approval($1, $2)", [userId, stepId])).rows;
    expect(await revoke(BOB)).toEqual([]);
    expect(await revoke(ALICE)).toEqual([{ revoked: 1, step_state: "prepared" }]);

    // 이미 부르기 시작했거나 끝난 단계는 승인하지 않고, 철회는 늦었다고 알린다
    await db.query("update public.execution_steps set state = 'called' where id = $1", [stepId]);
    expect(await approve(ALICE, shown.hash, shown.expires_at)).toBe(false);
    expect(await revoke(ALICE)).toEqual([{ revoked: 0, step_state: "called" }]);
  });

  it("내부 효과 다시 준비는 lease가 끝난 단계(sweep) 또는 그 lease 소유자(응답 없음)만: 겹친 sweep이 새 lease를 건드리지 않는다", async () => {
    await db.query("insert into public.execution_actors (user_id) values ($1) on conflict do nothing", [ALICE]);
    await setGlobal(false);
    try {
      const { stepId } = await preparedRun(ALICE);
      expect((await gate(stepId, "fn-live")).gate).toBe("ok");
      const retry = async (owner: string | null) =>
        (await one<{ n: number }>("select public.execution_retry_internal(array[$1]::uuid[], $2) as n", [stepId, owner])).n;
      expect(await retry(null)).toBe(0); // lease가 살아 있다
      expect(await retry("fn-other")).toBe(0);
      expect(await one("select state, attempt from public.execution_steps where id = $1", [stepId])).toEqual({ state: "calling", attempt: 0 });
      expect(await retry("fn-live")).toBe(1);
      expect(await one("select state, attempt from public.execution_steps where id = $1", [stepId])).toEqual({ state: "prepared", attempt: 1 });
    } finally {
      await setGlobal(true);
    }
  });
});

describe("실행 이벤트", () => {
  it("상태 · 막힌 이유가 바뀔 때만 남기고(같은 이유로 거듭 막혀도 한 번), 전이를 일으킨 판단을 함께 적는다. 글은 담지 않는다", async () => {
    const user = "00000000-0000-0000-0000-00000000000d";
    await db.query("insert into auth.users (id, email) values ($1, 'dave@example.com')", [user]);
    const { runId, stepId } = await preparedRun(user);
    for (let i = 0; i < 3; i++) expect((await gate(stepId)).gate).toBe("actor");
    await db.query("insert into public.execution_actors (user_id) values ($1)", [user]);
    await setGlobal(false);
    try {
      expect((await gate(stepId)).gate).toBe("ok");
    } finally {
      await setGlobal(true);
    }
    const events = await db.query("select type, from_state, to_state, gate, step_id is not null as on_step from public.execution_events where run_id = $1 order by id", [
      runId,
    ]);
    expect(events.rows).toEqual([
      { type: "run", from_state: null, to_state: "queued", gate: "create", on_step: false },
      { type: "step", from_state: null, to_state: "pending", gate: "create", on_step: true },
      { type: "step", from_state: "pending", to_state: "prepared", gate: "prepare", on_step: true },
      { type: "run", from_state: "queued", to_state: "running", gate: "prepare", on_step: false },
      { type: "hold", from_state: null, to_state: "actor", gate: "actor", on_step: false },
      { type: "hold", from_state: "actor", to_state: null, gate: "ok", on_step: false },
      { type: "step", from_state: "prepared", to_state: "calling", gate: "ok", on_step: true },
    ]);
    const { rows } = await db.query<{ column_name: string }>(
      "select column_name from information_schema.columns where table_schema = 'public' and table_name = 'execution_events' order by ordinal_position",
    );
    expect(rows.map((r) => r.column_name)).toEqual(["id", "user_id", "run_id", "step_id", "type", "from_state", "to_state", "gate", "at"]);
  });
});

describe("연결 끊기", () => {
  it("연결을 끊으면 끝난 단계는 상태 그대로 연결만 비고, 준비된 단계는 계획이 바뀐 것이라 다시 pending으로 간다", async () => {
    const connectionId = (await one<{ id: string }>("insert into public.connections (user_id, provider, external_account_id) values ($1, 'gmail', 'me@example.com') returning id", [ALICE])).id;
    const { runId } = await preparedRun(ALICE);
    const insertStep = async (seq: number, state: string) =>
      (
        await one<{ id: string }>(
          `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, state, policy_version)
           values ($1, $2, $3, 'external', 'gmail', 'send', $4, $5, $6, 1) returning id`,
          [ALICE, runId, seq, `send-${seq}`, connectionId, state],
        )
      ).id;
    const called = await insertStep(2, "called");
    const prepared = await insertStep(3, "prepared");

    expect(await one("select public.disconnect_connection($1, $2) as ok", [ALICE, connectionId])).toEqual({ ok: true });
    expect(await one("select state, connection_id, version from public.execution_steps where id = $1", [called])).toEqual({
      state: "called",
      connection_id: null,
      version: 0,
    });
    expect(await one("select state, connection_id, version from public.execution_steps where id = $1", [prepared])).toEqual({
      state: "pending",
      connection_id: null,
      version: 1,
    });
    // 연결이 아닌 계획 변경은 끝난 단계에서 여전히 거절한다
    await expect(db.query("update public.execution_steps set body = '다른 본문' where id = $1", [called])).rejects.toThrow(/frozen/);
  });
});

describe("run_create 횟수 제한 (POST /api/v1/runs, U2 PR6)", () => {
  it("take_rate_limit이 run_create를 세고 rate_limit_events에 남긴다", async () => {
    expect(await one("select public.take_rate_limit($1, 'run_create', 1, 600) as retry_at", [BOB])).toEqual({ retry_at: null });
    const { retry_at } = await one<{ retry_at: Date | null }>("select public.take_rate_limit($1, 'run_create', 1, 600) as retry_at", [BOB]);
    expect(retry_at).toBeInstanceOf(Date);
    expect(await one("select count(*)::int as n from public.rate_limit_events where user_id = $1 and kind = 'run_create'", [BOB])).toEqual({ n: 1 });
  });
});
