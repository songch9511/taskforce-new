import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;
let aliceConnection: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  // 서버(service role, RLS 우회)가 연결과 토큰을 만든다.
  const { rows } = await db.query<{ id: string }>(
    `insert into public.connections (user_id, provider, external_account_id, display_name)
     values ($1, 'notion', 'ws-1', 'Alice 워크스페이스') returning id`,
    [ALICE],
  );
  aliceConnection = rows[0].id;
  await db.query(`insert into public.connection_secrets (connection_id, sealed_token) values ($1, 'v1.x.y.z')`, [aliceConnection]);
}, 60_000);

describe("연동 (20260928000000_connections)", () => {
  it("사용자는 자기 연결만 본다", async () => {
    await asUser(db, ALICE, async () => {
      expect((await db.query(`select id from public.connections`)).rows).toHaveLength(1);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select id from public.connections`)).rows).toHaveLength(0);
    });
  });

  it("토큰은 본인도 읽을 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query(`select * from public.connection_secrets`);
      expect(rows).toHaveLength(0);
    });
  });

  it("클라이언트는 연결을 만들거나 고칠 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(
        db.query(`insert into public.connections (provider, external_account_id) values ('notion', 'ws-2')`),
      ).rejects.toThrow();
      const updated = await db.query(`update public.connections set status = 'revoked' returning id`);
      expect(updated.rows).toHaveLength(0);
    });
  });

  it("같은 항목의 같은 버전은 두 번 들어가지 않는다", async () => {
    const insert = () =>
      db.query(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version)
         values ($1, 'meeting', 'x', now(), $2, 'page-1', '2026-09-22T07:20:38Z')`,
        [ALICE, aliceConnection],
      );
    await insert();
    await expect(insert()).rejects.toThrow(/duplicate key/);
  });

  it("다른 사용자의 연결을 가리키는 원문은 만들 수 없다", async () => {
    await expect(
      db.query(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version)
         values ($1, 'meeting', 'x', now(), $2, 'page-2', 'v')`,
        [BOB, aliceConnection],
      ),
    ).rejects.toThrow(/foreign key/);
  });

  it("연결을 끊으면 토큰은 지워지고 원문은 남는다", async () => {
    await asUser(db, ALICE, async () => {
      await db.query(`delete from public.connections where id = $1`, [aliceConnection]);
    });
    expect((await db.query(`select 1 from public.connection_secrets`)).rows).toHaveLength(0);
    const { rows } = await db.query<{ connection_id: string | null }>(`select connection_id from public.sources where external_id = 'page-1'`);
    expect(rows).toEqual([{ connection_id: null }]);
  });
});
