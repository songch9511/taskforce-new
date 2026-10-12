import type { PGlite } from "@electric-sql/pglite";
import { describe, expect, it } from "vitest";

import { freshPgliteForEachTest } from "./fresh-pglite";

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
