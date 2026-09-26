import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("프로필 · 원문 관련자 (20260927000000_profiles_participants)", () => {
  it("본인 프로필을 만들고 고칠 수 있다", async () => {
    await asUser(db, ALICE, async () => {
      await db.query(`insert into public.profiles (display_name, aliases, emails) values ('도윤', '{도연}', '{d@x.com}')`);
      await db.query(
        `insert into public.profiles (display_name, aliases) values ('도윤', '{도연,Doyun}')
         on conflict (user_id) do update set aliases = excluded.aliases`,
      );
      const { rows } = await db.query<{ user_id: string; aliases: string[] }>(`select user_id, aliases from public.profiles`);
      expect(rows).toEqual([{ user_id: ALICE, aliases: ["도연", "Doyun"] }]);
    });
  });

  it("다른 사용자의 프로필은 보이지 않고 대신 만들 수도 없다", async () => {
    await asUser(db, BOB, async () => {
      expect((await db.query(`select 1 from public.profiles`)).rows).toHaveLength(0);
      await expect(db.query(`insert into public.profiles (user_id, display_name) values ($1, 'x')`, [ALICE])).rejects.toThrow();
    });
  });

  it("별칭은 20개까지", async () => {
    await asUser(db, BOB, async () => {
      const many = `{${Array.from({ length: 21 }, (_, i) => `a${i}`).join(",")}}`;
      await expect(db.query(`insert into public.profiles (aliases) values ($1)`, [many])).rejects.toThrow(/check constraint/);
    });
  });

  it("원문에 관련자를 저장할 수 있다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ participants: unknown }>(
        `insert into public.sources (kind, raw_text, occurred_at, participants)
         values ('email', 'x', now(), '{"from":{"email":"ceo@x.com"},"cc":[{"email":"d@x.com"}]}') returning participants`,
      );
      expect(rows[0].participants).toEqual({ from: { email: "ceo@x.com" }, cc: [{ email: "d@x.com" }] });
    });
  });
});
