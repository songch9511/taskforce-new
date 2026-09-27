import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [
    ALICE,
    BOB,
  ]);
}, 60_000);

async function insertSource(): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.sources (kind, raw_text, occurred_at)
     values ('meeting', '금요일까지 제안서 보내드릴게요', '2026-09-22T10:00:00+09:00') returning id`,
  );
  return rows[0].id;
}

// Action은 서버(service role)만 만든다 (20260929000000_actions_server_writes).
async function insertAction(userId: string): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.actions (user_id, title, due_at) values ($1, '제안서 발송', '2026-09-26T18:00:00+09:00') returning id`,
    [userId],
  );
  return rows[0].id;
}

describe("초기 마이그레이션", () => {
  it("모든 테이블을 만든다", async () => {
    const { rows } = await db.query<{ table_name: string }>(
      `select table_name from information_schema.tables where table_schema = 'public' order by table_name`,
    );
    expect(rows.map((r) => r.table_name)).toEqual([
      "action_events",
      "action_links",
      "actions",
      "claims",
      "connection_secrets",
      "connections",
      "devices",
      "evidence",
      "judge_logs",
      "metric_events",
      "profiles",
      "sources",
    ]);
  });

  it("모든 테이블에 RLS가 켜져 있다", async () => {
    const { rows } = await db.query<{ relname: string; relrowsecurity: boolean }>(
      `select c.relname, c.relrowsecurity from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r'`,
    );
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) expect(row, row.relname).toMatchObject({ relrowsecurity: true });
  });

  it("로그인한 사용자의 id가 user_id 기본값으로 들어간다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ user_id: string }>(
        `insert into public.sources (kind, raw_text, occurred_at)
         values ('note', '메모', now()) returning user_id`,
      );
      expect(rows[0].user_id).toBe(ALICE);
    });
  });

  it("다른 사용자의 행은 보이지 않는다", async () => {
    await asUser(db, ALICE, insertSource);
    await insertAction(ALICE);

    await asUser(db, BOB, async () => {
      const sources = await db.query("select * from public.sources");
      const actions = await db.query("select * from public.actions");
      expect(sources.rows).toHaveLength(0);
      expect(actions.rows).toHaveLength(0);
    });
  });

  it("다른 사용자 명의로는 행을 만들 수 없다", async () => {
    await asUser(db, BOB, async () => {
      await expect(
        db.query(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', 'x', now())`, [ALICE]),
      ).rejects.toThrow(/row-level security/);
    });
  });

  it("Claim은 다른 사용자의 Action을 가리킬 수 없다", async () => {
    const aliceAction = await insertAction(ALICE);
    const bobSource = await asUser(db, BOB, insertSource);
    // 서버 코드가 실수로 섞어도 복합 외래키가 막는다.
    await expect(
      db.query(
        `insert into public.claims
           (user_id, action_id, source_id, field, value, quote, occurred_at,
            speaker_role, certainty, directness, audience)
         values ($3, $1, $2, 'due', '2026-09-29', '월요일에 받아도 괜찮아요', now(),
                 'counterpart', 'firm', 'first_hand', 'shared')`,
        [aliceAction, bobSource, BOB],
      ),
    ).rejects.toThrow(/foreign key/);
  });

  it("같은 사용자의 Action과 원문으로는 Claim을 만들 수 있다", async () => {
    const actionId = await insertAction(ALICE);
    const sourceId = await asUser(db, ALICE, insertSource);
    const { rows } = await db.query<{ state: string }>(
      `insert into public.claims
         (user_id, action_id, source_id, field, value, value_text, quote, occurred_at,
          speaker_role, certainty, directness, audience)
       values ($3, $1, $2, 'due', '2026-09-26', '금요일까지', '금요일까지 제안서 보내드릴게요',
               '2026-09-22T10:00:00+09:00', 'me', 'firm', 'first_hand', 'shared')
       returning state`,
      [actionId, sourceId, ALICE],
    );
    expect(rows[0].state).toBe("active");
  });

  it("허용되지 않은 값은 거부한다", async () => {
    await expect(
      db.query(`insert into public.actions (user_id, title, status) values ($1, 'x', 'archived')`, [ALICE]),
    ).rejects.toThrow(/check constraint/);
  });

  it("Action을 고치면 updated_at이 갱신된다", async () => {
    const id = await insertAction(ALICE);
    await db.query(`update public.actions set updated_at = '2000-01-01' where id = $1`, [id]);
    await db.query(`update public.actions set title = '제안서 발송 (수정)' where id = $1`, [id]);
    const { rows } = await db.query<{ updated_at: Date }>(`select updated_at from public.actions where id = $1`, [id]);
    expect(rows[0].updated_at.getFullYear()).toBeGreaterThan(2000);
  });

  it("임베딩으로 가까운 Action을 찾을 수 있다", async () => {
    const near = `[${Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0)).join(",")}]`;
    const far = `[${Array.from({ length: 1536 }, (_, i) => (i === 1 ? 1 : 0)).join(",")}]`;
    await db.query(`insert into public.actions (user_id, title, embedding) values ($3, '가까운 일', $1), ($3, '먼 일', $2)`, [
      near,
      far,
      ALICE,
    ]);
    const { rows } = await db.query<{ title: string }>(
      `select title from public.actions where embedding is not null
       order by embedding operator(extensions.<=>) $1::extensions.vector limit 1`,
      [near],
    );
    expect(rows[0].title).toBe("가까운 일");
  });
});
