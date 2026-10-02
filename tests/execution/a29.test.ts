import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { advanceClock, createExecutionDb, Crash, Driver, FakeProvider, LEASE_SECONDS, READBACK_WINDOW_HOURS, resetExecutionDb } from "./driver";

// A29: B2(Postgres 상태 머신)로 외부 효과 한 번 · 결과 불명 · 승인 경계 · 차단 스위치를 보인다. 규칙은 docs/EXECUTION.md.
// "함수가 죽는다" = Driver 인스턴스를 버리고 새로 만든다. 이어 가는 데 메모리 checkpoint를 쓰지 않는다.

const RULE = "rule@example.com"; // Auto 규칙이 허용한 주소
const RULE2 = "rule2@example.com";
const OTHER = "other@example.com";
const LEASE_MS = LEASE_SECONDS * 1000;

type Origin = "user" | "source" | "tool_output" | "model";
type Recipient = { address: string; origin: Origin };
const user = (address = RULE): Recipient => ({ address, origin: "user" });

let db: PGlite;
let provider: FakeProvider;

beforeAll(async () => {
  db = await createExecutionDb();
});
beforeEach(async () => {
  await resetExecutionDb(db);
  provider = new FakeProvider(db);
});
afterAll(() => db.close());

/** 정책 · run · 단계(단계마다 수신자 목록, seq마다 목적이 다르다). 첫 단계 id를 돌려준다 */
async function createRun(id: string, mode: "manual" | "auto" | "full", steps: Recipient[][] = [[user()]], actionId = `action-${id}`) {
  await db.query("insert into policies (id, mode, auto_recipients) values ($1, $2, $3::jsonb)", [id, mode, JSON.stringify([RULE, RULE2])]);
  await db.query("insert into runs (id, action_id, policy_id) values ($1, $2, $1)", [id, actionId]);
  for (const [i, recipients] of steps.entries()) {
    await db.query(
      `insert into steps (id, run_id, seq, provider, tool, purpose, connection_id, recipients, body, args)
       values ($1, $2, $3, 'gmail', 'gmail.send', $4, 'conn-1', $5::jsonb, '견적서 보내드립니다', '{"subject": "견적"}')`,
      [`${id}-s${i + 1}`, id, i + 1, `send-${i + 1}`, JSON.stringify(recipients)],
    );
  }
  return `${id}-s1`;
}

const fn = (owner: string, hooks?: ConstructorParameters<typeof Driver>[3]) => new Driver(db, owner, provider, hooks);
/** route: 앱이 보여 준 계획 그대로 승인 */
const approveAsShown = async (step: string) => fn("route").approve(step, await fn("route").showPlan(step));
const ledger = async () =>
  (await db.query<{ marker: string; connection_id: string; body: string }>("select marker, connection_id, body from provider_ledger order by id")).rows;
const effects = async () => (await ledger()).length;
const stepState = async (id: string) => (await db.query<{ state: string }>("select state from steps where id = $1", [id])).rows[0].state;
const runState = async (id: string) => (await db.query<{ state: string }>("select state from runs where id = $1", [id])).rows[0].state;
const switchOff = async () => {
  await db.query("update execution_controls set blocked = true where scope = 'global'");
};

/** n개 함수가 모두 단계를 읽은 뒤에야 begin_call로 넘어가게 한다. 한쪽이 먼저 끝나면 1초 뒤 실패한다 */
function barrier(n: number) {
  let arrived = 0;
  let release = () => {};
  let fail: (error: Error) => void = () => {};
  const all = new Promise<void>((resolve, reject) => {
    release = resolve;
    fail = reject;
  });
  const timer = setTimeout(() => fail(new Error("barrier: 한 함수가 begin_call 전에 끝났다")), 1000);
  return async () => {
    if (++arrived === n) {
      clearTimeout(timer);
      release();
    }
    await all;
  };
}

describe("A29 fixture: B2 실행기 (외부 효과 한 번, 모르면 결과 불명)", () => {
  it("1: 승인 대기를 commit한 직후 함수가 죽어도 새 인스턴스가 DB만 보고 이어 가고, 승인 뒤 한 번만 보낸다", async () => {
    const step = await createRun("r1", "manual");
    const dies = fn("fn-1", {
      afterGate: (gate) => {
        if (gate === "not_approved") throw new Crash();
      },
    });
    await expect(dies.start("r1")).rejects.toThrow(Crash);
    expect(await runState("r1")).toBe("waiting_approval"); // run 전이는 begin_call 안에서 commit됐다

    expect(await approveAsShown(step)).toBe(true);
    await fn("fn-2").wake("r1");
    await fn("fn-3").wake("r1");
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
    expect(await runState("r1")).toBe("done");
    // 외부로 나가는 표식은 임의 값이다: 수신자 · Action id가 없다
    const [sent] = await ledger();
    expect(sent.marker).not.toMatch(/@|action-/);
  });

  it("2: 공급자가 받은 직후 · called commit 전에 죽으면 lease 만료 뒤 결과 불명. 음성 readback은 재발송하지 않고, 양성이면 called", async () => {
    const step = await createRun("r2", "auto");
    provider.readbackLagMs = 2 * LEASE_MS; // readback에 늦게 보인다 (history · 색인 지연)
    provider.onAccepted = () => {
      throw new Crash();
    };
    await expect(fn("fn-1").start("r2")).rejects.toThrow(Crash);
    provider.onAccepted = undefined;
    expect(await stepState(step)).toBe("calling");
    await expect(db.query("update steps set body = '다른 본문' where id = $1", [step])).rejects.toThrow(/frozen/);

    // lease가 살아 있으면 손대지 않는다 (아직 부르는 중일 수 있다)
    await fn("cron").sweep();
    expect(await stepState(step)).toBe("calling");

    // lease 만료 → 결과 불명. readback 음성 → 다시 보내지 않는다. 깨워도 마찬가지. 계획도 못 바꾼다
    await advanceClock(db, LEASE_MS + 1);
    await fn("cron").sweep();
    await fn("fn-2").wake("r2");
    expect(await stepState(step)).toBe("unknown_outcome");
    expect(await effects()).toBe(1);
    await expect(db.query("update steps set body = '다른 본문' where id = $1", [step])).rejects.toThrow(/frozen/);

    // readback이 표식을 찾으면 called. receipt는 readback에서 온다
    await advanceClock(db, LEASE_MS);
    await fn("cron").sweep();
    expect(await stepState(step)).toBe("called");
    const { rows } = await db.query<{ receipt: { via: string } }>("select receipt from steps where id = $1", [step]);
    expect(rows[0].receipt.via).toBe("readback");
    expect(await effects()).toBe(1);
    expect(await runState("r2")).toBe("done");
  });

  it("2: readback 창이 지나면 sweep은 더 찾지 않고 결과 불명으로 사용자에게 남긴다", async () => {
    const step = await createRun("r2w", "auto");
    provider.readbackLagMs = (READBACK_WINDOW_HOURS + 1) * 3_600_000;
    provider.onAccepted = () => {
      throw new Crash();
    };
    await expect(fn("fn-1").start("r2w")).rejects.toThrow(Crash);
    provider.onAccepted = undefined;
    await advanceClock(db, LEASE_MS + 1);
    await fn("cron").sweep();
    await advanceClock(db, (READBACK_WINDOW_HOURS + 1) * 3_600_000); // 이제 표식이 보이지만 창이 지났다
    await fn("cron").sweep();
    expect(await stepState(step)).toBe("unknown_outcome");
    expect(await effects()).toBe(1);
  });

  it("2: 응답을 못 받은 오류는 lease를 가진 함수가 바로 결과 불명으로, 확정 거절은 failed로 둔다", async () => {
    await createRun("r2t", "auto");
    provider.onAccepted = () => {
      throw new Error("timeout");
    };
    await fn("fn-1").start("r2t");
    provider.onAccepted = undefined;
    expect(await stepState("r2t-s1")).toBe("unknown_outcome");
    await fn("fn-2").wake("r2t");
    expect(await effects()).toBe(1);

    await createRun("r2f", "auto");
    provider.reject = true;
    await fn("fn-3").start("r2f");
    expect(await stepState("r2f-s1")).toBe("failed");
    expect(await runState("r2f")).toBe("failed");
    expect(await effects()).toBe(1);
  });

  it("3: 승인을 철회했거나 만료됐으면 이어서 실행해도 부르지 않는다", async () => {
    const step = await createRun("r3", "manual");
    await fn("fn-1").start("r3");
    await approveAsShown(step);
    await fn("route").revoke(step);
    await fn("fn-2").wake("r3");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await runState("r3")).toBe("waiting_approval");

    await approveAsShown(step); // 1시간짜리
    await advanceClock(db, 3_600_001);
    await fn("fn-3").wake("r3");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await runState("r3")).toBe("waiting_approval");
  });

  it("3: 승인 대기 commit 직후에 승인이 들어와도, 승인 행만 있고 깨우기가 없어도 run이 멈춰 있지 않는다", async () => {
    const step = await createRun("r3w", "manual");
    const approveRightAway = async (gate: string) => {
      if (gate === "not_approved") await approveAsShown(step);
    };
    await fn("fn-1", { afterGate: approveRightAway }).start("r3w");
    expect(await runState("r3w")).toBe("running");
    await fn("cron").sweep();
    expect(await effects()).toBe(1);

    const other = await createRun("r3x", "manual");
    await fn("fn-2").start("r3x");
    const shown = await fn("route").showPlan(other);
    await db.query("insert into approvals (step_id, hash, expires_at) values ($1, $2, $3::timestamptz)", [other, shown.hash, shown.expires_at]);
    expect(await runState("r3x")).toBe("waiting_approval");
    await fn("cron").sweep();
    expect(await effects()).toBe(2);
  });

  it.each([
    ["수신자", `update steps set recipients = recipients || '[{"address": "${OTHER}", "origin": "user"}]' where id = $1`],
    ["본문", "update steps set body = '다른 본문' where id = $1"],
    ["원문 revision", "update steps set source_revision = source_revision + 1 where id = $1"],
    ["정책 버전", "update policies set version = version + 1 where id = (select run_id from steps where id = $1)"],
    ["보내는 연결", "update steps set connection_id = 'conn-2' where id = $1"],
  ])("4: 승인 뒤 승인 hash 항목(%s)이 바뀌면 기존 승인으로 실행하지 않는다", async (_, change) => {
    const step = await createRun("r4", "manual");
    await fn("fn-1").start("r4");
    await approveAsShown(step);
    await db.query(change, [step]);
    await fn("fn-2").wake("r4");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await runState("r4")).toBe("waiting_approval");
  });

  it("4: 사용자가 본 뒤 계획이 바뀌면(수신자 추가) 승인을 기록하지 않는다", async () => {
    const step = await createRun("r4t", "manual");
    await fn("fn-1").start("r4t");
    const shown = await fn("route").showPlan(step);
    await db.query("update steps set recipients = recipients || $2::jsonb where id = $1", [step, JSON.stringify([user(OTHER)])]);
    expect(await fn("route").approve(step, shown)).toBe(false);
    await fn("fn-2").wake("r4t");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
  });

  it.each([
    ["본문", "body = '고친 본문'", { body: "고친 본문", connection_id: "conn-1" }],
    ["보내는 연결", "connection_id = 'conn-2'", { body: "견적서 보내드립니다", connection_id: "conn-2" }],
  ])("4: 부르기 직전에 %s이 바뀌면 옛 계획으로 보내지 않는다. 거절되고, 다시 준비한 계획 그대로 나간다", async (_, change, sent) => {
    await createRun("r4s", "auto");
    const edit = async () => {
      await db.query(`update steps set ${change} where id = 'r4s-s1'`);
    };
    await fn("fn-1", { beforeBeginCall: edit }).start("r4s");
    expect(await effects()).toBe(0);
    expect(await stepState("r4s-s1")).toBe("pending"); // 계획을 바꾸면 늘 version + 1, pending
    await fn("cron").sweep();
    expect((await ledger()).map(({ body, connection_id }) => ({ body, connection_id }))).toEqual([sent]);
  });

  it("4: 만료가 마이크로초인 시각에도 앱의 Date(밀리초)로 돌려받은 승인이 맞는다", async () => {
    await advanceClock(db, 1234.5678); // 테스트 시계를 초 단위가 아닌 시각으로
    const step = await createRun("r4p", "manual");
    await fn("fn-1").start("r4p");
    const shown = await fn("route").showPlan(step);
    expect(shown.expires_at).toBeInstanceOf(Date); // 앱처럼 Date로 받았다가 그대로 돌려보낸다
    expect(await fn("route").approve(step, shown)).toBe(true);
    await fn("fn-2").wake("r4p");
    expect(await effects()).toBe(1);
  });

  it.each([
    ["전체", "update execution_controls set blocked = true where scope = 'global'"],
    ["공급자(gmail)", "update execution_controls set blocked = true where scope = 'provider' and key = 'gmail'"],
    ["Manual만(auto · full 끔)", "update execution_controls set blocked = true where scope = 'mode' and key in ('auto', 'full')"],
    ["전체 행 없음", "delete from execution_controls where scope = 'global'"],
    ["공급자 행 없음", "delete from execution_controls where scope = 'provider'"],
    ["모드 행 없음", "delete from execution_controls where scope = 'mode'"],
  ])("5: 차단 스위치 %s → route · 자기 호출 · sweep 모두 begin_call에서 거절", async (_, block) => {
    const step = await createRun("r5", "auto");
    await db.query(block);
    await fn("route").start("r5");
    await fn("fn-1").wake("r5");
    await fn("cron").sweep();
    expect(await effects()).toBe(0);
    expect(await stepState(step)).toBe("prepared"); // 실패로 끝내지 않는다: 다시 켜면 이어 간다

    await db.query("update execution_controls set blocked = false");
    await db.query(
      `insert into execution_controls (scope, key) values ('global', '*'), ('provider', 'gmail'), ('mode', 'manual'), ('mode', 'auto'), ('mode', 'full')
       on conflict do nothing`,
    );
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
  });

  it("5: Manual만이어도 승인된 Manual 단계는 나간다", async () => {
    const step = await createRun("r5m", "manual");
    await db.query("update execution_controls set blocked = true where scope = 'mode' and key in ('auto', 'full')");
    await fn("fn-1").start("r5m");
    await approveAsShown(step);
    await fn("fn-2").wake("r5m");
    expect(await effects()).toBe(1);
  });

  it("5: 스위치는 begin_call 안에서 읽는다. 단계를 읽은 뒤 · 부르기 직전에 끄면 막히고, calling commit 뒤에 끄면 그 호출만 끝난다", async () => {
    await createRun("r5a", "auto");
    await fn("fn-1", { beforeBeginCall: switchOff }).start("r5a"); // 단계를 읽을 때는 켜져 있었다
    expect(await effects()).toBe(0);
    expect(await stepState("r5a-s1")).toBe("prepared");
    await db.query("update execution_controls set blocked = false");

    await createRun("r5b", "auto", [[user()], [user(RULE2)]]);
    provider.onAccepted = switchOff;
    await fn("fn-2").start("r5b");
    provider.onAccepted = undefined;
    expect(await stepState("r5b-s1")).toBe("called"); // 진행 중 호출은 결과를 받는다
    await fn("fn-3").wake("r5b");
    await fn("cron").sweep();
    expect(await stepState("r5b-s2")).toBe("prepared");
    expect(await effects()).toBe(1);
  });

  it("6: 두 함수가 같은 단계를 같은 버전으로 동시에 시작해도 CAS가 하나만 통과시킨다", async () => {
    const step = await createRun("r6", "manual");
    await fn("fn-0").start("r6");
    await approveAsShown(step);
    const bothRead = barrier(2);
    await Promise.all([fn("fn-1", { beforeBeginCall: bothRead }).wake("r6"), fn("fn-2", { beforeBeginCall: bothRead }).wake("r6")]);
    expect(await effects()).toBe(1);
    expect(await stepState(step)).toBe("called");
  });

  it("6: 같은 Action · 목적 · 대상 · 회차를 수동 run과 자동 run이 동시에 시작해도 intent unique가 하나만 보낸다", async () => {
    await createRun("r6-manual", "manual", undefined, "action-6");
    await createRun("r6-auto", "auto", undefined, "action-6");
    await fn("fn-0").start("r6-manual");
    await approveAsShown("r6-manual-s1");
    const bothReady = barrier(2);
    await Promise.all([fn("fn-1", { beforeBeginCall: bothReady }).wake("r6-manual"), fn("fn-2", { beforeBeginCall: bothReady }).start("r6-auto")]);
    await fn("cron").sweep();
    expect(await effects()).toBe(1);
    expect([await stepState("r6-manual-s1"), await stepState("r6-auto-s1")].sort()).toEqual(["called", "skipped"]);
  });

  it("6: 이미 보낸 목적을 다시 시작한 Manual run은 승인을 묻지 않고 건너뛴다", async () => {
    await createRun("r6-sent", "auto", undefined, "action-6c");
    await fn("fn-1").start("r6-sent");
    await createRun("r6-again", "manual", [[{ address: ` ${RULE.toUpperCase()} `, origin: "user" }]], "action-6c"); // 정규화하면 같은 대상
    await fn("fn-2").start("r6-again");
    expect(await stepState("r6-again-s1")).toBe("skipped");
    await fn("cron").sweep();
    expect(await runState("r6-again")).toBe("done");
    expect(await effects()).toBe(1);
  });

  it("6: 승인을 기다리던 run의 목적을 다른 run이 먼저 보내면, 기다리던 단계는 건너뛰고 run도 끝난다", async () => {
    await createRun("r6-wait", "manual", undefined, "action-6w");
    await fn("fn-1").start("r6-wait");
    expect(await runState("r6-wait")).toBe("waiting_approval");
    await createRun("r6-first", "auto", undefined, "action-6w");
    await fn("fn-2").start("r6-first");
    await fn("cron").sweep();
    expect(await stepState("r6-wait-s1")).toBe("skipped");
    await fn("cron").sweep();
    expect(await runState("r6-wait")).toBe("done");
    expect(await effects()).toBe(1);
  });

  it.each([
    ["사용자가 정한 규칙 안 수신자", 1, [user()]],
    ["사용자가 정한 규칙 밖 수신자", 0, [user(OTHER)]],
    ["원문에서 나온 규칙 안 수신자", 0, [{ address: RULE, origin: "source" }]],
    ["도구 출력에서 나온 규칙 안 수신자", 0, [{ address: RULE, origin: "tool_output" }]],
    ["모델이 제안한 규칙 안 수신자", 0, [{ address: RULE, origin: "model" }]],
    ["사용자 수신자 + 도구 출력 수신자", 0, [user(), { address: RULE2, origin: "tool_output" }]],
  ] as [string, number, Recipient[]][])("7: Auto run, %s → 외부 효과 %i", async (_, expected, recipients) => {
    await createRun("r7", "auto", [recipients]);
    await fn("fn-1").start("r7");
    await fn("cron").sweep();
    expect(await effects()).toBe(expected);
    expect(await runState("r7")).toBe(expected === 1 ? "done" : "waiting_approval");
    // 정책 평가(준비 단계)가 승인 필요로 표시한다: 앱이 승인 요청으로 보여 줄 값
    const { rows } = await db.query<{ needs_approval: boolean }>("select needs_approval from steps where id = 'r7-s1'");
    expect(rows[0].needs_approval).toBe(expected === 0);
  });

  it.each([
    ["도구 출력 수신자", { address: RULE, origin: "tool_output" }],
    ["사용자가 정한 규칙 밖 수신자", user(OTHER)],
  ] as [string, Recipient][])("7: 준비 단계의 판단이 틀려도(needs_approval = false) %s는 begin_call이 다시 막는다", async (_, recipient) => {
    await createRun("r7b", "auto", [[recipient]]);
    await fn("fn-1").start("r7b");
    await db.query("update steps set needs_approval = false where id = 'r7b-s1'");
    await db.query("update runs set state = 'running' where id = 'r7b'");
    await fn("fn-2").wake("r7b");
    expect(await effects()).toBe(0);
    expect(await runState("r7b")).toBe("waiting_approval");
  });

  it.each([
    ["규칙을 비우고 버전을 올림", "update policies set auto_recipients = '[]', version = version + 1 where id = 'r7c'"],
    ["버전만 올림", "update policies set version = version + 1 where id = 'r7c'"],
  ])("7: 준비한 뒤 Auto 규칙이 바뀌면(%s) 승인 없이 나가지 않는다", async (_, change) => {
    await createRun("r7c", "auto");
    const changePolicy = async () => {
      await db.query(change);
    };
    await fn("fn-1", { beforeBeginCall: changePolicy }).start("r7c");
    expect(await effects()).toBe(0);
    expect(await runState("r7c")).toBe("waiting_approval");
  });

  it("7: 준비할 때의 정책 버전이 비어 있으면(NULL) 막는다. 제약이 막고, 제약이 없어도 begin_call이 막는다", async () => {
    await createRun("r7m", "auto");
    const nullify = async () => {
      await db.query("update steps set policy_version = null where id = 'r7m-s1'");
    };
    await expect(fn("fn-1", { beforeBeginCall: nullify }).start("r7m")).rejects.toThrow(/prepared_has_policy_version/);
    await db.query("alter table steps drop constraint prepared_has_policy_version");
    try {
      await fn("fn-2", { beforeBeginCall: nullify }).start("r7m");
      expect(await effects()).toBe(0);
      expect(await runState("r7m")).toBe("waiting_approval");
    } finally {
      await db.query("alter table steps add constraint prepared_has_policy_version check (state = 'pending' or policy_version is not null) not valid");
    }
  });

  it("intent key에 공급자 · 도구가 들어간다: 같은 목적 · 대상이라도 도구가 다르면 서로 중복이 아니다", async () => {
    await createRun("r12", "auto");
    await db.query(
      `insert into steps (id, run_id, seq, provider, tool, purpose, connection_id, recipients, body)
       select 'r12-s2', run_id, 2, provider, 'gmail.reply', purpose, connection_id, recipients, body from steps where id = 'r12-s1'`,
    );
    await fn("fn-1").start("r12");
    await fn("fn-2").wake("r12");
    expect(await effects()).toBe(2);
  });

  it("받은 뒤 receipt 저장이 실패해도 결과 불명으로 바꾸지 않는다: 다시 써서 성공하거나, 오류를 내고 calling으로 남아 readback이 확인한다", async () => {
    // 테스트 전용 고장: 'called' 쓰기를 n번 실패시킨다 (sequence는 롤백되지 않는다)
    await db.exec(`
      create sequence if not exists settle_failures;
      create or replace function fail_settle() returns trigger language plpgsql as $$
      begin
        if new.state = 'called' and nextval('settle_failures') <= current_setting('app.settle_failures')::int then raise exception 'db down'; end if;
        return new;
      end $$;
      create trigger fail_settle before update on steps for each row execute function fail_settle();
    `);
    try {
      await db.query("select setval('settle_failures', 1, false), set_config('app.settle_failures', '1', false)");
      await createRun("r10", "auto");
      await fn("fn-1").start("r10"); // 한 번 실패, 다시 써서 성공
      const { rows } = await db.query<{ state: string; receipt: { via: string } }>("select state, receipt from steps where id = 'r10-s1'");
      expect(rows[0]).toMatchObject({ state: "called", receipt: { via: "response" } });

      await db.query("select setval('settle_failures', 1, false), set_config('app.settle_failures', '99', false)");
      await createRun("r11", "auto");
      await expect(fn("fn-2").start("r11")).rejects.toThrow(/db down/);
      expect(await stepState("r11-s1")).toBe("calling");
    } finally {
      await db.exec("drop trigger fail_settle on steps");
    }
    await advanceClock(db, LEASE_MS + 1);
    await fn("cron").sweep();
    expect(await stepState("r11-s1")).toBe("called");
    expect(await effects()).toBe(2);
  });

  it("중단: 다음 단계만 막고, calling 중이던 호출은 결과를 받는다. 부르기 직전의 중단도 막는다", async () => {
    await createRun("r8", "auto", [[user()], [user(RULE2)]]);
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
