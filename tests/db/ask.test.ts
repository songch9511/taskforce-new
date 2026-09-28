import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const vector = (hot: number) => `[${Array.from({ length: 1536 }, (_, i) => (i === hot ? 1 : 0)).join(",")}]`;

let db: PGlite;
const ids: Record<string, string> = {};

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  const action = async (key: string, userId: string, status: string, updatedDaysAgo = 0) => {
    const { rows } = await db.query<{ id: string }>(
      `insert into public.actions (user_id, title, embedding, status) values ($1, $2, $3, $4) returning id`,
      [userId, key, vector(0), status],
    );
    ids[key] = rows[0].id;
    // updated_at은 트리거가 now()로 덮으므로 트리거를 잠시 끄고 옛 시각으로 둔다.
    if (updatedDaysAgo > 0) {
      await db.exec(`alter table public.actions disable trigger actions_set_updated_at`);
      await db.query(`update public.actions set updated_at = now() - make_interval(days => $2) where id = $1`, [rows[0].id, updatedDaysAgo]);
      await db.exec(`alter table public.actions enable trigger actions_set_updated_at`);
    }
  };
  await action("open", ALICE, "open");
  await action("done-recent", ALICE, "done", 3);
  await action("done-old", ALICE, "done", 60);
  await action("dropped-by-source", ALICE, "dropped", 2);
  await action("deleted-by-user", ALICE, "dropped", 1);
  await action("bob-open", BOB, "open");
  await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_deleted', 'user')`, [
    ALICE,
    ids["deleted-by-user"],
  ]);
}, 60_000);

describe("물어보기 (20261004000000_ask)", () => {
  it("열린 Action과 최근에 끝나거나 취소된 Action만, 그 사용자 것만 찾는다", async () => {
    const { rows } = await db.query<{ id: string }>(`select id from public.match_actions_for_ask($1, $2, 10)`, [ALICE, vector(0)]);
    expect(rows.map((r) => r.id).sort()).toEqual([ids.open, ids["done-recent"], ids["dropped-by-source"]].sort());
  });

  it("사용자가 지운 Action(오판)은 빼고, 기간을 넓히면 오래 전에 끝난 것도 찾는다", async () => {
    const { rows } = await db.query<{ id: string }>(
      `select id from public.match_actions_for_ask($1, $2, 10, now() - interval '90 days')`,
      [ALICE, vector(0)],
    );
    expect(rows.map((r) => r.id)).toContain(ids["done-old"]);
    expect(rows.map((r) => r.id)).not.toContain(ids["deleted-by-user"]);
  });

  it("클라이언트는 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.match_actions_for_ask($1, $2, 5)`, [ALICE, vector(0)])).rejects.toThrow(/permission denied/);
    });
  });
});
