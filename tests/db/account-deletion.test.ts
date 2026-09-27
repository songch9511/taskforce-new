import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { createLocalSupabase } from "./local-supabase";

// 계정 삭제 (DELETE /api/v1/account → auth.admin.deleteUser): auth.users 행을 지우면
// 사용자 테이블의 행이 모두 on delete cascade로 지워지고, 다른 사용자의 행은 그대로여야 한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

/** user_id 열이 있는 사용자 테이블 전부. 새 테이블을 만들면 여기와 seed()에 더한다 (아래 첫 테스트가 알려 준다). */
const USER_TABLES = [
  "action_events",
  "action_links",
  "actions",
  "claims",
  "connections",
  "devices",
  "evidence",
  "judge_logs",
  "metric_events",
  "missing_reports",
  "profiles",
  "sources",
  "weekly_checks",
];

let db: PGlite;

/** 서버(service role)가 쓰듯 모든 사용자 테이블에 한 사용자의 행을 넣는다. 연결된 원문 · 이벤트의 set null 경로도 거치게 한다. */
async function seed(userId: string, tokenHex: string) {
  const one = async (sql: string, params: unknown[]) => (await db.query<{ id: string }>(sql, params)).rows[0].id;

  const connectionId = await one(
    `insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', 'ws') returning id`,
    [userId],
  );
  await db.query(`insert into public.connection_secrets (connection_id, sealed_token) values ($1, 'v1.x.y.z')`, [connectionId]);
  const sourceId = await one(
    `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version)
     values ($1, 'meeting', '원문', now(), $2, 'page-1', 'v1') returning id`,
    [userId, connectionId],
  );
  const actionId = await one(`insert into public.actions (user_id, title) values ($1, '할 일') returning id`, [userId]);
  await db.query(
    `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at,
                                speaker_role, certainty, directness, audience)
     values ($1, $2, $3, 'due', '2026-10-02', '금요일까지', now(), 'me', 'firm', 'first_hand', 'shared')`,
    [userId, actionId, sourceId],
  );
  await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '금요일까지', 'created')`, [
    userId,
    actionId,
    sourceId,
  ]);
  await db.query(`insert into public.action_events (user_id, action_id, type, source_id, actor) values ($1, $2, 'created', $3, 'ai')`, [
    userId,
    actionId,
    sourceId,
  ]);
  await db.query(
    `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version)
     values ($1, $2, '{}', '{}', 'auto', 'typesafe/jev-1.13')`,
    [userId, sourceId],
  );
  await db.query(`insert into public.metric_events (user_id, type, action_id) values ($1, 'action_started', $2)`, [userId, actionId]);
  await db.query(`insert into public.profiles (user_id, display_name) values ($1, '이름')`, [userId]);
  await db.query(`insert into public.devices (user_id, token, platform) values ($1, $2, 'ios')`, [userId, tokenHex]);
  await db.query(`insert into public.action_links (user_id, connection_id, external_id, action_id) values ($1, $2, 'page-1', $3)`, [
    userId,
    connectionId,
    actionId,
  ]);
  await db.query(`insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-21', 'no')`, [userId]);
  await db.query(`insert into public.missing_reports (user_id) values ($1)`, [userId]);
  return connectionId;
}

async function rowCounts(userId: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const table of USER_TABLES) {
    const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.${table} where user_id = $1`, [userId]);
    counts[table] = rows[0].n;
  }
  return counts;
}

async function secretCount(connectionId: string): Promise<number> {
  const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.connection_secrets where connection_id = $1`, [
    connectionId,
  ]);
  return rows[0].n;
}

let aliceConnection: string;
let bobConnection: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  aliceConnection = await seed(ALICE, "a".repeat(64));
  bobConnection = await seed(BOB, "b".repeat(64));
}, 60_000);

describe("계정 삭제 (auth.users on delete cascade)", () => {
  it("user_id가 있는 테이블을 빠짐없이 확인한다", async () => {
    const { rows } = await db.query<{ table_name: string }>(
      `select table_name from information_schema.columns
       where table_schema = 'public' and column_name = 'user_id' order by table_name`,
    );
    expect(rows.map((r) => r.table_name)).toEqual(USER_TABLES);
  });

  it("삭제 전에는 두 사용자 모두 모든 테이블에 행이 있다", async () => {
    for (const userId of [ALICE, BOB]) {
      expect(Object.values(await rowCounts(userId)).every((n) => n > 0)).toBe(true);
    }
    expect(await secretCount(aliceConnection)).toBe(1);
  });

  it("auth 사용자를 지우면 그 사용자의 행은 모두 지워지고, 다른 사용자의 행은 그대로다", async () => {
    const bobBefore = await rowCounts(BOB);

    await db.query(`delete from auth.users where id = $1`, [ALICE]);

    const aliceAfter = await rowCounts(ALICE);
    expect(aliceAfter).toEqual(Object.fromEntries(USER_TABLES.map((t) => [t, 0])));
    expect(await secretCount(aliceConnection)).toBe(0);

    expect(await rowCounts(BOB)).toEqual(bobBefore);
    expect(await secretCount(bobConnection)).toBe(1);
    const { rows } = await db.query<{ id: string }>(`select id from auth.users`);
    expect(rows.map((r) => r.id)).toEqual([BOB]);
  });
});
