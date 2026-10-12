import type { PGlite } from "@electric-sql/pglite";
import { describe, expect, it } from "vitest";

import { freshPgliteForEachTest } from "./fresh-pglite";
import { openPglite } from "./pglite-template";

// freshPgliteForEachTest: 시험이 끝나면 그 시험에서 만든 인스턴스가 모두 닫힌다 (인스턴스가 파일 안에서 쌓이지 않는다).
// 새 DB를 여러 번 띄우는 시험이라 이 파일에만 제한을 늘렸다 (다른 시험의 제한은 그대로).
const freshDb = freshPgliteForEachTest();
const made: PGlite[] = [];

describe("시험마다 새 DB를 닫는 팩토리", { timeout: 60_000 }, () => {
  it("1) 한 시험에서 둘을 만들면 시험 안에서는 열려 있고 쿼리가 된다", async () => {
    made.push(await freshDb(), await freshDb());
    expect(made.map((db) => db.closed)).toEqual([false, false]);
    expect(((await made[0].query("select 1 as one")) as { rows: unknown[] }).rows).toEqual([{ one: 1 }]);
  });

  it("2) 앞 시험의 인스턴스는 모두 닫혔다. 새로 만든 것은 열려 있다", async () => {
    expect(made.map((db) => db.closed)).toEqual([true, true]);
    made.push(await freshDb());
    expect(made[2].closed).toBe(false);
  });

  it("3) 계속 쌓이지 않는다: 이전 시험들의 인스턴스는 전부 닫혀 있고, 열린 것은 이 시험의 것뿐이다", async () => {
    expect(made.map((db) => db.closed)).toEqual([true, true, true]);
    made.push(await freshDb());
    expect(made.filter((db) => !db.closed)).toHaveLength(1);
  });
});

// 늦은 생성: 시험이 끝난 뒤(afterEach 이후)에 끝나는 생성은 닫히고, 그 사이 시작한 다음 시험의 인스턴스는 그대로 둔다.
// 실제 helper(freshPgliteForEachTest)에 실제 PGlite를 만드는 opener를 넣고, 만든 뒤 풀어 주는 문(gate)으로 끝나는 시점만 조절한다.
describe("늦은 생성 (시간 초과로 끝난 시험의 본문이 afterEach 뒤에 PGlite를 만드는 경우)", { timeout: 60_000 }, () => {
  const created: PGlite[] = [];
  let release: () => void = () => undefined;
  let gate: Promise<void> = Promise.resolve();
  const slowOpen = async (scripts: string[]) => {
    const myGate = gate; // 호출 시점의 문을 잡는다: 나중에 gate를 바꿔도 이 생성은 자기 문만 기다린다
    const db = await openPglite(scripts);
    created.push(db);
    await myGate; // 이 문이 열릴 때까지 "생성 중"인 척 한다
    return db;
  };
  const freshLate = freshPgliteForEachTest([], slowOpen);
  let latePromise: Promise<unknown> = Promise.resolve();

  it("1) 생성이 끝나기 전에 시험이 끝난다 (본문이 생성을 기다리지 않고 반환)", async () => {
    gate = new Promise<void>((resolve) => (release = resolve));
    latePromise = freshLate().then(() => null, (error: unknown) => error); // 기다리지 않고 시험이 끝난다
  });

  it("2) 시험이 끝난 뒤 도착한 인스턴스는 닫히고 그 본문은 오류를 받는다. 이 시험이 만든 인스턴스는 닫히지 않는다", async () => {
    // 먼저 이 시험의 인스턴스를 만든다 (문은 아직 닫혀 있으므로 새 문을 따로 쓴다)
    const lateGate = gate;
    const lateRelease = release;
    gate = Promise.resolve();
    const mine = await freshLate();
    expect(mine.closed).toBe(false);
    // 이제 앞 시험의 늦은 생성을 풀어 준다
    lateRelease();
    await lateGate;
    const outcome = await latePromise;
    expect(outcome).toBeInstanceOf(Error);
    const lateOne = created.find((db) => db !== mine && db.closed);
    expect(lateOne, "늦게 도착한 인스턴스가 닫혔다").toBeDefined();
    expect(mine.closed, "다음(이) 시험의 인스턴스는 그대로다").toBe(false);
    created.length = 0;
    created.push(mine);
  });

  it("3) 이 시험의 인스턴스는 다음 시험 전에 닫혔다", async () => {
    expect(created.every((db) => db.closed)).toBe(true);
  });
});
