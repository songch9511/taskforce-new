import { randomUUID } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 OA D4c-3a (20261120000000_action_numbers) — 이슈 번호 "#139": actions.number + 사용자별 카운터 action_counters (서버 저장만).
// 번호는 insert 트리거가 카운터에서 준다: 호출자가 정하지 못하고(들어온 값은 무시), 바뀌지 않고, 삭제 · dropped 뒤에도 다시 쓰지 않는다.
// action_counters는 앱 역할(anon · authenticated)의 권한이 0인 내부 표다(앱이 카운터를 되돌리면 unique 위반으로 모든 생성이 막힌다, 계약 7장).
// 같은 시나리오를 PGlite(tests/db/action-numbers.test.ts)와 실제 Postgres(tests/pg/action-numbers.test.ts)에서 돈다.
// 연결이 둘 이상 필요한 경합(T7)은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type ActionNumbersDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export const ACTION_NUMBERS_MIGRATION = "20261120000000_action_numbers.sql";
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");

const FORBIDDEN = /permission denied/i;

export function actionNumbersFixtures(db: () => ActionNumbersDb) {
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  const fx = {
    q,
    async user(): Promise<string> {
      const userId = randomUUID();
      await q(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    /** 서버가 Action 행을 넣듯. 돌려주는 값은 트리거가 정한 번호 */
    async action(userId: string, title = "제안서 보내기"): Promise<{ id: string; number: number }> {
      const row = (await q(`insert into public.actions (user_id, title) values ($1, $2) returning id, number`, [userId, title]))[0];
      return { id: row.id as string, number: row.number as number };
    },
    async numbers(userId: string): Promise<number[]> {
      return (await q(`select number from public.actions where user_id = $1 order by number`, [userId])).map((r) => r.number as number);
    },
    /** 사용자의 카운터 next (다음에 줄 번호). 행이 없으면 null */
    async counter(userId: string): Promise<number | null> {
      const rows = await q(`select next from public.action_counters where user_id = $1`, [userId]);
      return rows.length === 0 ? null : (rows[0].next as number);
    },
    /** 로그인하지 않은 역할(anon)로 */
    async asAnon<T>(fn: () => Promise<T>): Promise<T> {
      await q(`set role anon`);
      try {
        return await fn();
      } finally {
        await q(`reset role`);
      }
    },
    /**
     * 사용자 트리거만 끈 트랜잭션 안에서 실행하고 되돌린다: 트리거가 막아 주던 행 모양을 표 제약이 따로 막는지 본다.
     * (session_replication_role = replica는 사용자 트리거만 끄고 제약은 그대로 둔다. 시험 DB의 역할은 슈퍼유저다)
     */
    async withoutTriggers<T>(fn: () => Promise<T>): Promise<T> {
      await q(`begin`);
      try {
        await q(`set local session_replication_role = replica`);
        return await fn();
      } finally {
        await q(`rollback`);
      }
    },
  };
  return fx;
}

export function actionNumbersTests(db: () => ActionNumbersDb) {
  const f = actionNumbersFixtures(db);
  const q = f.q;

  describe("T2 새 insert: 사용자별로 따로 1부터 이어서 늘고, 들어온 number는 무시한다", () => {
    it("두 사용자가 번갈아 만들어도 각자 1, 2, 3… 이고, 카운터 next는 다음에 줄 번호다", async () => {
      const alice = await f.user();
      const bob = await f.user();
      expect(await f.counter(alice)).toBeNull(); // 첫 insert 때 만든다
      expect((await f.action(alice)).number).toBe(1);
      expect((await f.action(bob)).number).toBe(1);
      expect((await f.action(alice)).number).toBe(2);
      expect((await f.action(alice)).number).toBe(3);
      expect((await f.action(bob)).number).toBe(2);
      expect((await f.action(alice)).number).toBe(4);
      expect(await f.numbers(alice)).toEqual([1, 2, 3, 4]);
      expect(await f.numbers(bob)).toEqual([1, 2]);
      expect(await f.counter(alice)).toBe(5);
      expect(await f.counter(bob)).toBe(3);
      // 카운터를 올릴 때마다 updated_at도 올라간다 (statement마다 now()가 다르다: 자동 commit)
      const stamp = async () => (await q(`select updated_at from public.action_counters where user_id = $1`, [bob]))[0].updated_at as Date | string;
      const before = new Date(await stamp()).getTime();
      await f.action(bob);
      expect(new Date(await stamp()).getTime()).toBeGreaterThan(before);
      // 카운터는 사용자마다 한 줄이다
      expect(await q(`select user_id from public.action_counters where user_id = any ($1::uuid[]) order by user_id`, [[alice, bob]])).toHaveLength(2);
    });

    it("한 문장에 여러 행을 넣어도 번호는 겹치지 않고 빈틈이 없다", async () => {
      const carol = await f.user();
      await q(`insert into public.actions (user_id, title) values ($1, 'a'), ($1, 'b'), ($1, 'c')`, [carol]);
      expect(await f.numbers(carol)).toEqual([1, 2, 3]);
      await q(`insert into public.actions (user_id, title) select $1, 'x' || g from generate_series(1, 4) g`, [carol]);
      expect(await f.numbers(carol)).toEqual([1, 2, 3, 4, 5, 6, 7]);
      expect(await f.counter(carol)).toBe(8);
    });

    it("호출자가 준 number는 무시한다: 겹치는 값 · 큰 값 · 0 · 음수 · null 모두 카운터 값이 된다", async () => {
      const me = await f.user();
      await f.action(me); // #1
      const given = await q(
        `insert into public.actions (user_id, title, number) values ($1, 'a', 1), ($1, 'b', 99), ($1, 'c', 0), ($1, 'd', -5), ($1, 'e', null) returning number`,
        [me],
      );
      expect(given.map((r) => r.number)).toEqual([2, 3, 4, 5, 6]);
      expect(await f.numbers(me)).toEqual([1, 2, 3, 4, 5, 6]);
      expect(await f.counter(me)).toBe(7);
    });

    it("서버가 Action을 만드는 길(RPC write_action)도 번호를 받는다", async () => {
      const me = await f.user();
      await f.action(me);
      const id = randomUUID();
      const written = await q(
        `select public.write_action($1, $2, null, $3::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb) as ok`,
        [me, id, JSON.stringify({ title: "새 할 일", owner: "me", status: "open", needs_confirmation: false })],
      );
      expect(written[0].ok).toBe(true);
      expect((await q(`select number from public.actions where id = $1`, [id]))[0].number).toBe(2);
      expect(await f.counter(me)).toBe(3);
    });

    it("앱은 RLS로 actions를 읽어 자기 번호를 본다 (남의 번호는 보이지 않는다)", async () => {
      const alice = await f.user();
      const bob = await f.user();
      await f.action(alice);
      await f.action(alice);
      await f.action(bob);
      expect(await db().asUser(alice, () => q(`select number from public.actions order by number`))).toEqual([{ number: 1 }, { number: 2 }]);
      expect(await db().asUser(bob, () => q(`select number from public.actions order by number`))).toEqual([{ number: 1 }]);
    });

    it("없는 사용자의 Action은 FK 위반(23503)으로 거절되고 카운터 행도 남지 않는다", async () => {
      const ghost = randomUUID();
      await expect(q(`insert into public.actions (user_id, title) values ($1, '유령')`, [ghost])).rejects.toMatchObject({ code: "23503" });
      expect(await f.counter(ghost)).toBeNull();
      expect(await f.numbers(ghost)).toEqual([]);
    });

    it("롤백한 insert는 번호를 쓰지 않는다 (트랜잭션 · savepoint)", async () => {
      const me = await f.user();
      await f.action(me); // #1
      await q(`begin`);
      try {
        expect((await f.action(me)).number).toBe(2);
        await q(`savepoint s`);
        expect((await f.action(me)).number).toBe(3);
        await q(`rollback to savepoint s`);
        expect((await f.action(me)).number).toBe(3); // savepoint 안에서 쓴 3은 돌아왔다
        await q(`rollback`);
      } catch (error) {
        await q(`rollback`);
        throw error;
      }
      expect(await f.numbers(me)).toEqual([1]);
      expect(await f.counter(me)).toBe(2);
      expect((await f.action(me)).number).toBe(2);
    });

    it("insert가 제약으로 실패해도 번호를 쓰지 않는다", async () => {
      const me = await f.user();
      await f.action(me);
      await expect(q(`insert into public.actions (user_id, title, owner) values ($1, 'x', 'nobody')`, [me])).rejects.toThrow(/check constraint|violates/i);
      expect(await f.counter(me)).toBe(2);
      expect((await f.action(me)).number).toBe(2);
    });
  });

  describe("T3 번호는 다시 쓰지 않는다", () => {
    it("실제 행 삭제 · status dropped · 전부 삭제 뒤에도 카운터는 내려가지 않는다", async () => {
      const me = await f.user();
      const a1 = await f.action(me);
      const a2 = await f.action(me);
      const a3 = await f.action(me);
      expect([a1.number, a2.number, a3.number]).toEqual([1, 2, 3]);

      // 가장 큰 번호를 지워도 3은 다시 나오지 않는다
      await q(`delete from public.actions where id = $1`, [a3.id]);
      expect(await f.counter(me)).toBe(4);
      expect((await f.action(me)).number).toBe(4);

      // dropped(삭제 = user Claim status dropped)는 행이 남으므로 번호도 남고, 새 번호는 이어진다
      await q(`update public.actions set status = 'dropped' where id = $1`, [a2.id]);
      expect((await q(`select number from public.actions where id = $1`, [a2.id]))[0].number).toBe(2);
      expect((await f.action(me)).number).toBe(5);
      expect(await f.numbers(me)).toEqual([1, 2, 4, 5]);

      // 전부 지워도 이어진다
      await q(`delete from public.actions where user_id = $1`, [me]);
      expect(await f.numbers(me)).toEqual([]);
      expect(await f.counter(me)).toBe(6);
      expect((await f.action(me)).number).toBe(6);
      expect(await f.counter(me)).toBe(7);
    });

    it("다른 사용자의 삭제는 내 카운터에 닿지 않는다", async () => {
      const alice = await f.user();
      const bob = await f.user();
      const mine = await f.action(alice);
      await f.action(bob);
      await q(`delete from public.actions where user_id = $1`, [bob]);
      expect(await f.counter(alice)).toBe(2);
      expect(mine.number).toBe(1);
      expect((await f.action(alice)).number).toBe(2);
    });
  });

  describe("T4 number는 바뀌지 않는다", () => {
    it("number를 바꾸는 update는 거절한다 (다른 값 · null · 서로 바꾸기 · 같은 트랜잭션의 insert 직후)", async () => {
      const me = await f.user();
      const first = await f.action(me);
      const second = await f.action(me);
      await expect(q(`update public.actions set number = number + 10 where id = $1`, [first.id])).rejects.toThrow(/actions_number_immutable/);
      await expect(q(`update public.actions set number = null where id = $1`, [first.id])).rejects.toThrow(/actions_number_immutable|null value/);
      await expect(q(`update public.actions set number = $2 where id = $1`, [first.id, second.number])).rejects.toThrow(/actions_number_immutable/);
      await expect(q(`update public.actions set number = $2 where id = $1`, [second.id, first.number])).rejects.toThrow(/actions_number_immutable/); // 줄이는 쪽도
      await expect(q(`update public.actions set number = 100 where user_id = $1`, [me])).rejects.toThrow(/actions_number_immutable/);
      await q(`begin`);
      try {
        const third = await f.action(me);
        await expect(q(`update public.actions set number = 50 where id = $1`, [third.id])).rejects.toThrow(/actions_number_immutable/);
      } finally {
        await q(`rollback`);
      }
      expect(await f.numbers(me)).toEqual([1, 2]);
      expect(await f.counter(me)).toBe(3);
    });

    it("그대로 두는 update는 된다: 다른 열을 바꿔도, number를 같은 값으로 쓰는 것도 번호는 그대로다", async () => {
      const me = await f.user();
      const first = await f.action(me, "처음");
      await q(`update public.actions set title = '고침', status = 'done', version = version + 1 where id = $1`, [first.id]);
      await q(`update public.actions set number = number where id = $1`, [first.id]);
      expect((await q(`select number, title, status from public.actions where id = $1`, [first.id]))[0]).toEqual({ number: 1, title: "고침", status: "done" });
    });

    it("앱 역할은 actions를 고치지 못한다 (number 포함)", async () => {
      const me = await f.user();
      const first = await f.action(me);
      await expect(db().asUser(me, () => q(`update public.actions set number = 9 where id = $1`, [first.id]))).rejects.toThrow(FORBIDDEN);
      await expect(db().asUser(me, () => q(`insert into public.actions (title, number) values ('앱이 만듦', 9)`))).rejects.toThrow(FORBIDDEN);
      expect(await f.numbers(me)).toEqual([1]);
    });
  });

  describe("표 모양: not null · unique(user_id, number) · check(number >= 1) · 카운터 next >= 1", () => {
    it("number는 not null이고 (user_id, number)는 유일하며 1 이상이다 (트리거를 꺼도 표 제약이 막는다)", async () => {
      const me = await f.user();
      const other = await f.user();
      await f.action(me); // #1
      const column = (await q(`select is_nullable, data_type from information_schema.columns where table_schema = 'public' and table_name = 'actions' and column_name = 'number'`))[0];
      expect(column).toEqual({ is_nullable: "NO", data_type: "integer" });
      await expect(
        f.withoutTriggers(() => q(`insert into public.actions (user_id, title, number) values ($1, 'dup', 1)`, [me])),
      ).rejects.toThrow(/actions_user_number_key|duplicate key/);
      await expect(
        f.withoutTriggers(() => q(`insert into public.actions (user_id, title, number) values ($1, 'zero', 0)`, [me])),
      ).rejects.toThrow(/actions_number_check|check constraint/);
      await expect(
        f.withoutTriggers(() => q(`insert into public.actions (user_id, title, number) values ($1, 'neg', -1)`, [me])),
      ).rejects.toThrow(/actions_number_check|check constraint/);
      await expect(f.withoutTriggers(() => q(`insert into public.actions (user_id, title) values ($1, 'none')`, [me]))).rejects.toThrow(/null value|not-null/i);
      // 다른 사용자는 같은 번호를 가질 수 있다
      await f.withoutTriggers(async () => {
        await q(`insert into public.actions (user_id, title, number) values ($1, 'same', 1)`, [other]);
      });
      expect(await f.numbers(me)).toEqual([1]);
    });

    it("카운터 next는 1 이상이고 사용자 한 줄이다", async () => {
      const me = await f.user();
      await f.action(me);
      await expect(q(`update public.action_counters set next = 0 where user_id = $1`, [me])).rejects.toThrow(/action_counters_next_check|check constraint/);
      await expect(q(`insert into public.action_counters (user_id, next) values ($1, 5)`, [me])).rejects.toThrow(/duplicate key|action_counters_pkey/);
      await expect(q(`insert into public.action_counters (user_id, next) values ($1, 1)`, [randomUUID()])).rejects.toThrow(/foreign key|violates/i);
      expect(await f.counter(me)).toBe(2);
    });

    it("action_counters 열: user_id(uuid, 기본 키) · next(integer, not null) · updated_at(timestamptz, not null, 기본 now())", async () => {
      const columns = await q(
        `select column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' and table_name = 'action_counters' order by ordinal_position`,
      );
      expect(columns).toEqual([
        { column_name: "user_id", data_type: "uuid", is_nullable: "NO", column_default: null },
        { column_name: "next", data_type: "integer", is_nullable: "NO", column_default: null },
        { column_name: "updated_at", data_type: "timestamp with time zone", is_nullable: "NO", column_default: "now()" },
      ]);
      expect(
        await q(`select a.attname from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey) where i.indrelid = 'public.action_counters'::regclass and i.indisprimary`),
      ).toEqual([{ attname: "user_id" }]);
    });

    it("트리거가 두 개 있다: insert 앞의 번호 부여 · number update 앞의 불변 가드 (켜져 있다)", async () => {
      const rows = await q(
        `select t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) as def
           from pg_trigger t where t.tgrelid = 'public.actions'::regclass and not t.tgisinternal and t.tgname in ('actions_assign_number', 'actions_number_immutable') order by t.tgname`,
      );
      expect(rows.map((r) => [r.tgname, r.tgenabled])).toEqual([
        ["actions_assign_number", "O"],
        ["actions_number_immutable", "O"],
      ]);
      expect(String(rows[0].def)).toMatch(/BEFORE INSERT ON public\.actions FOR EACH ROW/);
      expect(String(rows[1].def)).toMatch(/BEFORE UPDATE OF number ON public\.actions FOR EACH ROW/);
      // 원래 있던 updated_at 트리거는 켜져 있다 (백필이 잠시 끄고 되돌린다)
      expect((await q(`select tgenabled from pg_trigger where tgrelid = 'public.actions'::regclass and tgname = 'actions_set_updated_at'`))[0].tgenabled).toBe("O");
    });
  });

  describe("T5 권한: action_counters는 앱 역할의 권한이 0인 내부 표다", () => {
    it("authenticated · anon은 select · insert · update · delete 모두 거절된다", async () => {
      const me = await f.user();
      await f.action(me);
      const calls = [
        `select * from public.action_counters`,
        `select next from public.action_counters where user_id = '${me}'`,
        `insert into public.action_counters (user_id, next) values ('${randomUUID()}', 1)`,
        `update public.action_counters set next = 1`,
        `update public.action_counters set next = 1 where user_id = '${me}'`,
        `delete from public.action_counters`,
        `delete from public.action_counters where user_id = '${me}'`,
        `truncate public.action_counters`,
      ];
      for (const call of calls) {
        await expect(db().asUser(me, () => q(call)), `authenticated: ${call}`).rejects.toThrow(FORBIDDEN);
        await expect(f.asAnon(() => q(call)), `anon: ${call}`).rejects.toThrow(FORBIDDEN);
      }
      // 거절되었으니 카운터는 그대로다
      expect(await f.counter(me)).toBe(2);
    });

    it("표 · 열 권한을 두 역할 모두 갖지 않고, RLS는 켜져 있고 정책은 없다", async () => {
      for (const role of ["anon", "authenticated"]) {
        for (const privilege of ["select", "insert", "update", "delete", "truncate", "references", "trigger"]) {
          const has = (await q(`select has_table_privilege($1, 'public.action_counters', $2) as has`, [role, privilege]))[0].has;
          expect(has, `${role} ${privilege}`).toBe(false);
        }
        for (const privilege of ["select", "insert", "update", "references"]) {
          const has = (await q(`select has_any_column_privilege($1, 'public.action_counters', $2) as has`, [role, privilege]))[0].has;
          expect(has, `${role} column ${privilege}`).toBe(false);
        }
      }
      expect((await q(`select relrowsecurity, relforcerowsecurity from pg_class where oid = 'public.action_counters'::regclass`))[0]).toEqual({ relrowsecurity: true, relforcerowsecurity: false });
      expect(await q(`select policyname from pg_policies where schemaname = 'public' and tablename = 'action_counters'`)).toEqual([]);
    });

    it("트리거 함수 둘은 앱 · 익명이 직접 실행하지 못한다", async () => {
      const me = await f.user();
      for (const call of [`select public.actions_assign_number()`, `select public.actions_number_immutable()`]) {
        await expect(db().asUser(me, () => q(call)), `authenticated: ${call}`).rejects.toThrow(FORBIDDEN);
        await expect(f.asAnon(() => q(call)), `anon: ${call}`).rejects.toThrow(FORBIDDEN);
      }
      const functions = await q(
        `select p.proname as name, has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as auth,
                p.prosecdef as definer, p.proconfig as config
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname in ('actions_assign_number', 'actions_number_immutable') order by p.proname`,
      );
      expect(functions.map((r) => r.name)).toEqual(["actions_assign_number", "actions_number_immutable"]);
      for (const row of functions) {
        expect(row, String(row.name)).toMatchObject({ anon: false, auth: false });
        expect(row.config, String(row.name)).toContain('search_path=""');
      }
      // 번호 부여는 호출한 역할의 권한이 아니라 소유자 권한으로 카운터를 고친다
      expect(functions.find((r) => r.name === "actions_assign_number")?.definer).toBe(true);
    });
  });

  describe("T6 계정 삭제: 카운터가 함께 지워진다", () => {
    it("auth 사용자를 지우면 그 사용자의 Action · 카운터가 지워지고 다른 사용자의 것은 그대로다", async () => {
      const alice = await f.user();
      const bob = await f.user();
      await f.action(alice);
      await f.action(alice);
      await f.action(bob);
      expect(await f.counter(alice)).toBe(3);
      await q(`delete from auth.users where id = $1`, [alice]);
      expect(await f.counter(alice)).toBeNull();
      expect(await f.numbers(alice)).toEqual([]);
      expect(await f.counter(bob)).toBe(2);
      expect(await f.numbers(bob)).toEqual([1]);
    });
  });

  describe("파일 경계", () => {
    it("마이그레이션은 begin → lock_timeout 5s → … → commit 한 트랜잭션이다", async () => {
      const sql = await readFile(path.join(MIGRATIONS_DIR, ACTION_NUMBERS_MIGRATION), "utf8");
      const statements = sql
        .split("\n")
        .filter((line) => !/^\s*--/.test(line))
        .join("\n")
        .trim();
      expect(statements.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
      expect(statements.endsWith("commit;")).toBe(true);
      // 앱 역할에 카운터 권한을 주지 않는다
      expect(statements).not.toMatch(/grant\s+[^;]*public\.action_counters[^;]*to\s+[^;]*(anon|authenticated)/i);
    });
  });
}

// ───────────────────────── 업그레이드 (T1) ─────────────────────────

export type FreshDb = {
  exec: (sql: string) => Promise<unknown>;
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
};

/** Supabase 흉내 + 이 마이그레이션 앞의 모든 마이그레이션 / 이 마이그레이션 */
async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(ACTION_NUMBERS_MIGRATION);
  expect(index, `${ACTION_NUMBERS_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  const scripts = await supabaseSchemaScripts();
  // scripts[0..1]은 Supabase 흉내 두 개다
  return { before: scripts.slice(0, 2 + index), migration: scripts[2 + index] };
}

const ISO = "2026-10-10T00:00:00.000Z";

/**
 * 마이그레이션 직전 상태를 만들고 적용한다. 옛 행은 사용자별 created_at, id 순으로 1부터 번호를 받고(같은 시각이면 id 순),
 * 번호 말고는 한 글자도 바뀌지 않으며(updated_at · version 포함), 카운터는 사용자별 max(number) + 1이다.
 */
export function actionNumbersUpgradeTests(fresh: () => Promise<FreshDb>) {
  describe("T1 업그레이드 (D4c-3a 전 상태 → 적용)", { timeout: 60_000 }, () => {
    // 삽입 순서와 번호 순서가 다르고, created_at이 같은 두 행은 id 순이다
    const ALICE_ROWS = [
      { id: "00000000-0000-4000-8000-0000000000a4", created: "2026-10-03T00:00:00Z", status: "open", expected: 4 },
      { id: "00000000-0000-4000-8000-0000000000a9", created: "2026-10-01T00:00:00Z", status: "dropped", expected: 1 },
      { id: "00000000-0000-4000-8000-0000000000a2", created: "2026-10-02T00:00:00Z", status: "done", expected: 3 },
      { id: "00000000-0000-4000-8000-0000000000a1", created: "2026-10-02T00:00:00Z", status: "open", expected: 2 },
    ];
    const BOB_ROWS = [
      { id: "00000000-0000-4000-8000-0000000000b1", created: "2026-10-05T00:00:00Z", status: "open", expected: 2 },
      { id: "00000000-0000-4000-8000-0000000000b2", created: "2026-10-04T00:00:00Z", status: "open", expected: 1 },
    ];

    async function seedLegacy(db: FreshDb) {
      const alice = randomUUID();
      const bob = randomUUID();
      const carol = randomUUID(); // Action이 없는 사용자
      for (const user of [alice, bob, carol]) await db.query(`insert into auth.users (id, email) values ($1, $2)`, [user, `${user}@example.com`]);
      for (const [user, rows] of [[alice, ALICE_ROWS], [bob, BOB_ROWS]] as const) {
        for (const row of rows) {
          await db.query(
            `insert into public.actions (id, user_id, title, status, created_at, updated_at, version) values ($1, $2, $3, $4, $5, $6, 7)`,
            [row.id, user, `할 일 ${row.id.slice(-2)}`, row.status, row.created, ISO],
          );
        }
      }
      return { alice, bob, carol };
    }
    const snapshot = async (db: FreshDb) =>
      JSON.stringify(await db.query(`select to_jsonb(a) - 'number' as row from public.actions a order by a.id`));
    const numberOf = async (db: FreshDb, id: string) => (await db.query(`select number from public.actions where id = $1`, [id]))[0].number as number;

    it("옛 행은 사용자별 created_at, id 순으로 1부터 번호를 받고 카운터는 사용자별 max + 1이다 (Action이 없는 사용자는 카운터 행이 없다)", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const { alice, bob, carol } = await seedLegacy(db);
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'actions' and column_name = 'number'`)).toEqual([]);
      await db.exec(migration);

      for (const row of ALICE_ROWS) expect(await numberOf(db, row.id), `alice ${row.id}`).toBe(row.expected);
      for (const row of BOB_ROWS) expect(await numberOf(db, row.id), `bob ${row.id}`).toBe(row.expected);
      const counters = await db.query(`select user_id, next from public.action_counters order by next`);
      expect(counters).toEqual([
        { user_id: bob, next: 3 },
        { user_id: alice, next: 5 },
      ]);
      expect(await db.query(`select 1 from public.action_counters where user_id = $1`, [carol])).toEqual([]);

      // 이어서: 새 insert는 n + 1부터, 사용자별로 따로
      const added = async (user: string) => (await db.query(`insert into public.actions (user_id, title) values ($1, '새 할 일') returning number`, [user]))[0].number;
      expect(await added(alice)).toBe(5);
      expect(await added(bob)).toBe(3);
      expect(await added(carol)).toBe(1);
      expect(await added(alice)).toBe(6);
      expect((await db.query(`select user_id, next from public.action_counters order by next, user_id`)).map((r) => r.next)).toEqual([2, 4, 7]);
    });

    it("번호 말고는 옛 행이 한 글자도 바뀌지 않는다 (updated_at · version 포함), updated_at 트리거는 켜져 있다", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      await seedLegacy(db);
      const rows = await snapshot(db);
      await db.exec(migration);
      expect(await snapshot(db)).toBe(rows);
      expect((await db.query(`select updated_at::text as at, version from public.actions where id = $1`, [ALICE_ROWS[0].id]))[0]).toMatchObject({ version: 7 });
      expect((await db.query(`select updated_at = $2::timestamptz as same from public.actions where id = $1`, [ALICE_ROWS[0].id, ISO]))[0].same).toBe(true);
      // 백필이 끈 트리거를 되돌렸다: 이후의 update는 updated_at을 올린다
      expect((await db.query(`select tgenabled from pg_trigger where tgrelid = 'public.actions'::regclass and tgname = 'actions_set_updated_at'`))[0].tgenabled).toBe("O");
      await db.query(`update public.actions set title = '고침' where id = $1`, [ALICE_ROWS[0].id]);
      expect((await db.query(`select updated_at > $2::timestamptz as bumped from public.actions where id = $1`, [ALICE_ROWS[0].id, ISO]))[0].bumped).toBe(true);
    });

    it("옛 객체(표 · 열 · 함수 · 트리거 · 제약)는 그대로이고 새 객체만 늘었다", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const fingerprint = async () => ({
        tables: JSON.stringify(await db.query(`select table_name from information_schema.tables where table_schema = 'public' order by table_name`)),
        columns: JSON.stringify(await db.query(`select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' and table_name <> 'action_counters' and not (table_name = 'actions' and column_name = 'number') order by table_name, ordinal_position`)),
        functions: JSON.stringify(await db.query(`select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' order by 1`)),
        triggers: JSON.stringify(await db.query(`select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2`)),
        constraints: JSON.stringify(await db.query(`select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`)),
      });
      const old = await fingerprint();
      await db.exec(migration);
      const now = await fingerprint();
      const rowsOf = <T>(json: string) => JSON.parse(json) as T[];
      expect(rowsOf<{ table_name: string }>(now.tables).map((r) => r.table_name).sort()).toEqual(
        [...rowsOf<{ table_name: string }>(old.tables).map((r) => r.table_name), "action_counters"].sort(),
      );
      expect(now.columns).toBe(old.columns);
      for (const key of ["functions", "triggers", "constraints"] as const) {
        const kept = new Set(rowsOf<Record<string, string>>(now[key]).map((r) => JSON.stringify(r)));
        for (const row of rowsOf<Record<string, string>>(old[key])) expect(kept.has(JSON.stringify(row)), `${key}: ${JSON.stringify(row)}`).toBe(true);
      }
      expect(rowsOf<{ sig: string }>(now.functions).map((r) => r.sig).filter((sig) => /^actions_/.test(sig))).toEqual([
        "actions_assign_number()",
        "actions_number_immutable()",
      ]);
    });

    it("같은 이름의 객체가 이미 있으면 아무것도 바꾸지 않고 실패한다 (한 트랜잭션 롤백: 열 · 표 · 백필 · 트리거 상태)", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      await seedLegacy(db);
      // 백필 · 제약 · 카운터 채우기를 다 한 뒤 함수를 만들 때 실패하도록: 파일 끝쪽 함수와 같은 이름
      await db.exec(`create function public.actions_assign_number() returns trigger language plpgsql as 'begin return new; end'`);
      const rows = await snapshot(db);
      await expect(db.exec(migration)).rejects.toThrow(/already exists|이미 있/);
      await db.exec("rollback").catch(() => undefined);
      expect(await snapshot(db)).toBe(rows);
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'actions' and column_name = 'number'`)).toEqual([]);
      expect(await db.query(`select 1 from information_schema.tables where table_name = 'action_counters'`)).toEqual([]);
      expect((await db.query(`select tgenabled from pg_trigger where tgrelid = 'public.actions'::regclass and tgname = 'actions_set_updated_at'`))[0].tgenabled).toBe("O");
    });
  });
}
