import type { PGlite } from "@electric-sql/pglite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { Clock, Crash, createExecutionDb, Driver, FakeProvider, LEASE_MS } from "./execution-driver";

// A29: B2(Postgres 상태 머신)로 외부 효과 한 번 · 결과 불명 · 승인 경계 · 차단 스위치를 보인다. 규칙은 docs/EXECUTION.md.
// "함수가 죽는다" = Driver 인스턴스를 버리고 새로 만든다. 이어 가는 데 메모리 checkpoint를 쓰지 않는다.

const RULE = "rule@example.com"; // Auto 규칙이 허용한 수신자
const OTHER = "other@example.com";

let db: PGlite;
let clock: Clock;
let provider: FakeProvider;

beforeEach(async () => {
  db = await createExecutionDb();
  clock = new Clock();
  provider = new FakeProvider(db, clock);
});
afterEach(() => db.close());

type StepSpec = { origin?: "user" | "source" | "tool_output"; to?: string };

/** run 하나와 단계들(seq마다 목적이 다르다). 첫 단계 id를 돌려준다 */
async function createRun(id: string, mode: "manual" | "auto" | "full", steps: StepSpec[] = [{}], actionId = `action-${id}`) {
  await db.query("insert into runs (id, action_id, mode, auto_recipients) values ($1, $2, $3, $4::jsonb)", [id, actionId, mode, JSON.stringify([RULE])]);
  for (const [i, step] of steps.entries()) {
    await db.query(
      `insert into steps (id, run_id, seq, provider, tool, purpose, args, recipient_origin)
       values ($1, $2, $3, 'gmail', 'gmail.send', $4, $5::jsonb, $6)`,
      [`${id}-s${i + 1}`, id, i + 1, `send-${i + 1}`, JSON.stringify({ to: [step.to ?? RULE], body: "견적서 보내드립니다" }), step.origin ?? "user"],
    );
  }
  return `${id}-s1`;
}

const fn = (owner: string, hooks?: ConstructorParameters<typeof Driver>[4]) => new Driver(db, owner, provider, clock, hooks);
const effects = async () => (await db.query<{ n: number }>("select count(*)::int as n from provider_ledger")).rows[0].n;
const stepState = async (id: string) => (await db.query<{ state: string }>("select state from steps where id = $1", [id])).rows[0].state;
const runState = async (id: string) => (await db.query<{ state: string }>("select state from runs where id = $1", [id])).rows[0].state;
const setControl = (scope: string, key: string, blocked: boolean) =>
  db.query("update execution_controls set blocked = $3 where scope = $1 and key = $2", [scope, key, blocked]);

/** n개 함수가 모두 단계를 읽은 뒤에야 begin_call로 넘어가게 한다 (같은 버전을 들고 동시에 들어간다) */
function barrier(n: number) {
  let release = () => {};
  const all = new Promise<void>((resolve) => (release = resolve));
  let arrived = 0;
  return async () => {
    if (++arrived === n) release();
    await all;
  };
}

describe("A29 fixture: B2 실행기 (외부 효과 한 번, 모르면 결과 불명)", () => {
  it("1: 승인 대기 중 함수가 죽어도 새 인스턴스가 DB만 보고 이어 가고, 승인 뒤 한 번만 보낸다", async () => {
    const step = await createRun("r1", "manual");
    // prepared를 commit한 직후 죽는다
    const crashes = fn("fn-1", {
      afterPrepare: () => {
        throw new Crash();
      },
    });
    await expect(crashes.start("r1")).rejects.toThrow(Crash);
    expect(await stepState(step)).toBe("prepared");

    // 깨우기를 놓쳐도 sweep이 이어 간다. 승인이 없으니 승인 대기
    await fn("cron").sweep();
    expect(await runState("r1")).toBe("waiting_approval");
    expect(await effects()).toBe(0);

    // 승인(route) → commit 뒤 깨우기 → 처음 보는 인스턴스가 보낸다
    await fn("route").approve(step);
    await fn("fn-2").wake("r1");
    expect(await effects()).toBe(1);
    expect(await stepState(step)).toBe("called");

    await fn("fn-3").wake("r1");
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
    expect(await runState("r1")).toBe("done");
  });

  it("2: 공급자가 받은 직후 · called commit 전에 죽으면 lease 만료 뒤 결과 불명. 음성 readback은 재발송하지 않고, 양성이면 called", async () => {
    const step = await createRun("r2", "auto");
    provider.readbackLagMs = 2 * LEASE_MS; // 재조회에 늦게 보인다 (history · 색인 지연)
    provider.onAccepted = () => {
      throw new Crash();
    };
    await expect(fn("fn-1").start("r2")).rejects.toThrow(Crash);
    provider.onAccepted = undefined;
    expect(await stepState(step)).toBe("calling");
    expect(await effects()).toBe(1);

    // lease가 살아 있으면 손대지 않는다 (아직 부르는 중일 수 있다)
    await fn("cron").sweep();
    expect(await stepState(step)).toBe("calling");

    // lease 만료 → 결과 불명. readback 음성 → 다시 보내지 않는다. 깨워도 마찬가지
    clock.now += LEASE_MS + 1;
    await fn("cron").sweep();
    await fn("fn-2").wake("r2");
    expect(await stepState(step)).toBe("unknown_outcome");
    expect(await effects()).toBe(1);

    // readback이 표식(intent key)을 찾으면 called. receipt는 readback에서 온다
    clock.now += LEASE_MS;
    await fn("cron").sweep();
    expect(await stepState(step)).toBe("called");
    const { rows } = await db.query<{ receipt: { via: string } }>("select receipt from steps where id = $1", [step]);
    expect(rows[0].receipt.via).toBe("readback");
    expect(await effects()).toBe(1);
    expect(await runState("r2")).toBe("done");
  });

  it("3: 승인을 철회했거나 만료됐으면 이어서 실행해도 부르지 않는다", async () => {
    const step = await createRun("r3", "manual");
    await fn("fn-1").start("r3");
    await fn("route").approve(step);
    await fn("route").revoke(step);
    await fn("fn-2").wake("r3");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await runState("r3")).toBe("waiting_approval");

    await fn("route").approve(step, 60_000);
    clock.now += 60_001;
    await fn("fn-3").wake("r3");
    expect(await effects()).toBe(0);
    expect(await runState("r3")).toBe("waiting_approval");
  });

  it.each([
    ["수신자", `update steps set args = jsonb_set(args, '{to}', '["${RULE}", "${OTHER}"]'), state = 'pending', version = version + 1 where id = $1`],
    ["본문", `update steps set args = jsonb_set(args, '{body}', '"다른 본문"'), state = 'pending', version = version + 1 where id = $1`],
    ["원문 revision", "update steps set source_revision = source_revision + 1, state = 'pending', version = version + 1 where id = $1"],
    ["정책 버전", "update runs set policy_version = policy_version + 1 where id = (select run_id from steps where id = $1)"],
  ])("4: 승인 뒤 승인 hash 항목(%s)이 바뀌면 기존 승인으로 실행하지 않는다", async (_, change) => {
    const step = await createRun("r4", "manual");
    await fn("fn-1").start("r4");
    await fn("route").approve(step);
    await db.query(change, [step]);
    await fn("fn-2").wake("r4");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await runState("r4")).toBe("waiting_approval");
  });

  it.each([
    ["전체", "update execution_controls set blocked = true where scope = 'global'"],
    ["공급자(gmail)", "update execution_controls set blocked = true where scope = 'provider' and key = 'gmail'"],
    ["Manual만(auto · full 끔)", "update execution_controls set blocked = true where scope = 'mode' and key in ('auto', 'full')"],
    ["행 없는 공급자(닫힌 쪽)", "delete from execution_controls where scope = 'provider'"],
  ])("5: 차단 스위치 %s → route · 자기 호출 · sweep 모두 prepared → calling 거절", async (_, block) => {
    const step = await createRun("r5", "auto");
    await db.query(block);
    await fn("route").start("r5");
    await fn("fn-1").wake("r5");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await stepState(step)).toBe("prepared"); // 실패로 끝내지 않는다: 다시 켜면 이어 간다

    await db.query("update execution_controls set blocked = false");
    await db.query("insert into execution_controls (scope, key) values ('provider', 'gmail') on conflict do nothing");
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
  });

  it("5: Manual만이어도 승인된 Manual 단계는 나간다", async () => {
    const step = await createRun("r5m", "manual");
    await setControl("mode", "auto", true);
    await setControl("mode", "full", true);
    await fn("fn-1").start("r5m");
    await fn("route").approve(step);
    await fn("fn-2").wake("r5m");
    expect(await effects()).toBe(1);
  });

  it("5: 스위치는 전이 트랜잭션 안에서 읽는다. 단계를 읽은 뒤 · 부르기 직전에 끄면 막히고, calling commit 뒤에 끄면 그 호출만 끝난다", async () => {
    // 단계를 읽을 때는 켜져 있었다. 그 사이 다른 곳(운영자 db query)에서 끈다
    await createRun("r5a", "auto");
    const switchOff = async () => {
      await setControl("global", "*", true);
    };
    await fn("fn-1", { beforeBeginCall: switchOff }).start("r5a");
    expect(await effects()).toBe(0);
    expect(await stepState("r5a-s1")).toBe("prepared");
    await setControl("global", "*", false);

    // 첫 단계가 calling으로 commit된 뒤 끈다: 진행 중 호출은 결과를 받고, 다음 단계는 막힌다
    await createRun("r5b", "auto", [{}, {}]);
    provider.onAccepted = switchOff;
    await fn("fn-2").start("r5b");
    provider.onAccepted = undefined;
    expect(await stepState("r5b-s1")).toBe("called");
    await fn("fn-3").wake("r5b");
    await fn("cron").sweep();
    expect(await stepState("r5b-s2")).toBe("prepared");
    expect(await effects()).toBe(1);
  });

  it("6: 두 함수가 같은 단계를 같은 버전으로 동시에 시작해도 CAS가 하나만 통과시킨다", async () => {
    const step = await createRun("r6", "manual");
    await fn("fn-0").start("r6");
    await fn("route").approve(step);
    const bothRead = barrier(2);
    await Promise.all([fn("fn-1", { beforeBeginCall: bothRead }).wake("r6"), fn("fn-2", { beforeBeginCall: bothRead }).wake("r6")]);
    expect(await effects()).toBe(1);
    expect(await stepState(step)).toBe("called");
  });

  it("6: 같은 Action · 목적 · 대상 · 회차를 수동 run과 자동 run이 동시에 시작해도 intent unique가 하나만 보낸다 (A27)", async () => {
    await createRun("r6-manual", "manual", [{}], "action-6");
    await createRun("r6-auto", "auto", [{}], "action-6");
    await fn("fn-0").start("r6-manual");
    await fn("route").approve("r6-manual-s1");
    const bothReady = barrier(2);
    await Promise.all([
      fn("fn-1", { beforeBeginCall: bothReady }).wake("r6-manual"),
      fn("fn-2", { beforeBeginCall: bothReady }).start("r6-auto"),
    ]);
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
    expect([await stepState("r6-manual-s1"), await stepState("r6-auto-s1")].sort()).toEqual(["called", "skipped"]);
  });

  it.each([
    ["사용자가 정한 규칙 안 수신자", 1, "user", RULE, "done"],
    ["사용자가 정한 규칙 밖 수신자", 0, "user", OTHER, "waiting_approval"],
    ["원문에서 나온 규칙 안 수신자", 0, "source", RULE, "waiting_approval"],
    ["도구 출력에서 나온 규칙 안 수신자", 0, "tool_output", RULE, "waiting_approval"],
  ] as const)("7: Auto run, %s → 외부 효과 %i", async (_, expected, origin, to, state) => {
    await createRun("r7", "auto", [{ origin, to }]);
    await fn("fn-1").start("r7");
    await fn("cron").sweep();
    expect(await effects()).toBe(expected);
    expect(await runState("r7")).toBe(state);
    // 정책 평가(준비 단계)가 승인 필요로 표시한다: 앱이 승인 요청으로 보여 줄 값
    const { rows } = await db.query<{ needs_approval: boolean }>("select needs_approval from steps where id = 'r7-s1'");
    expect(rows[0].needs_approval).toBe(expected === 0);
  });

  it("7: 준비 단계의 판단이 틀려도(needs_approval = false) 도구 출력 수신자는 DB가 다시 막는다", async () => {
    await createRun("r7b", "auto", [{ origin: "tool_output" }]);
    await fn("fn-1").start("r7b");
    await db.query("update steps set needs_approval = false where id = 'r7b-s1'");
    await db.query("update runs set state = 'running' where id = 'r7b'");
    await fn("fn-2").wake("r7b");
    expect(await effects()).toBe(0);
    expect(await runState("r7b")).toBe("waiting_approval");
  });

  it("중단: 다음 단계만 막고, calling 중이던 호출은 결과를 받는다. 부르기 직전의 중단도 막는다", async () => {
    await createRun("r8", "auto", [{}, {}]);
    provider.onAccepted = () => fn("route").stop("r8");
    await fn("fn-1").start("r8");
    provider.onAccepted = undefined;
    expect(await stepState("r8-s1")).toBe("called");
    await fn("fn-2").wake("r8");
    await fn("cron").sweep();
    expect(await stepState("r8-s2")).toBe("pending");
    expect(await runState("r8")).toBe("stopped");

    await createRun("r9", "auto");
    await fn("fn-3", { beforeBeginCall: () => fn("route").stop("r9") }).start("r9");
    expect(await stepState("r9-s1")).toBe("prepared");
    expect(await effects()).toBe(1);
  });
});
