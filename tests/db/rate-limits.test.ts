import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 사용자별 횟수 제한 (20261005000000_atomic_rate_limits): 세기와 남기기를 한 함수(한 트랜잭션, advisory lock) 안에서 한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

const take = async (userId: string, kind: string, max = 3, windowSeconds = 600) =>
  (await db.query<{ retry_at: Date | null }>(`select public.take_rate_limit($1, $2, $3, $4) as retry_at`, [userId, kind, max, windowSeconds])).rows[0]
    .retry_at;
const count = async (table: string, userId: string, kind?: string) =>
  (
    await db.query<{ n: number }>(
      `select count(*)::int as n from public.${table} where user_id = $1${kind ? " and kind = $2" : ""}`,
      kind ? [userId, kind] : [userId],
    )
  ).rows[0].n;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("take_rate_limit", () => {
  it("한도 아래면 한 번을 남기고 null, 한도에 차면 남기지 않고 다시 할 수 있는 시각을 돌려준다", async () => {
    expect(await take(ALICE, "ask")).toBeNull();
    expect(await take(ALICE, "ask")).toBeNull();
    expect(await take(ALICE, "ask")).toBeNull();
    const retryAt = await take(ALICE, "ask");
    expect(retryAt).toBeInstanceOf(Date);
    // 가장 오래된(3번째로 최근) 시도가 창(10분) 밖으로 나가는 시각: 지금부터 10분 안
    const inMs = retryAt!.getTime() - Date.now();
    expect(inMs).toBeGreaterThan(9 * 60_000);
    expect(inMs).toBeLessThanOrEqual(10 * 60_000);
    expect(await count("rate_limit_events", ALICE, "ask")).toBe(3);
  });

  it("사용자 · 종류마다 따로 센다", async () => {
    expect(await take(BOB, "ask")).toBeNull();
    expect(await take(ALICE, "connection_start")).toBeNull();
    expect(await count("rate_limit_events", ALICE, "connection_start")).toBe(1);
  });

  it("창 밖의 시도는 세지 않는다", async () => {
    await db.query(`update public.rate_limit_events set created_at = now() - interval '11 minutes' where user_id = $1 and kind = 'ask'`, [ALICE]);
    expect(await take(ALICE, "ask")).toBeNull();
  });

  it("직접 추가(action_create, 20261009000000)도 rate_limit_events로 따로 센다", async () => {
    for (let i = 0; i < 2; i++) expect(await take(BOB, "action_create", 2)).toBeNull();
    expect(await take(BOB, "action_create", 2)).toBeInstanceOf(Date);
    expect(await count("rate_limit_events", BOB, "action_create")).toBe(2);
    expect(await take(BOB, "ask", 2)).toBeNull();
  });

  it("누락 신고는 missing_reports에 남긴다", async () => {
    for (let i = 0; i < 2; i++) expect(await take(BOB, "missing_report", 2)).toBeNull();
    expect(await take(BOB, "missing_report", 2)).toBeInstanceOf(Date);
    expect(await count("missing_reports", BOB)).toBe(2);
  });

  it("모르는 종류 · 잘못된 한도는 오류", async () => {
    await expect(take(ALICE, "other")).rejects.toThrow(/모르는 종류/);
    await expect(take(ALICE, "ask", 0)).rejects.toThrow(/잘못된 인자/);
  });

  it("클라이언트는 부를 수도, 시도 기록을 직접 쓸 수도 없고 자기 기록만 읽는다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.take_rate_limit($1, 'ask', 100, 600)`, [ALICE])).rejects.toThrow(/permission denied/);
      await expect(db.query(`insert into public.rate_limit_events (kind) values ('ask')`)).rejects.toThrow();
      const deleted = await db.query(`delete from public.rate_limit_events`).then((r) => r.affectedRows ?? 0, () => "blocked");
      expect([0, "blocked"]).toContain(deleted);
      const { rows } = await db.query<{ user_id: string }>(`select distinct user_id from public.rate_limit_events`);
      expect(rows).toEqual([{ user_id: ALICE }]);
    });
  });
});
