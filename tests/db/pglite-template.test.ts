import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

// PGlite 템플릿 복제(tests/db/pglite-template.ts)가 처음부터 만든 DB와 같은 상태를 주는지, 복제본끼리 격리되는지, 템플릿을 못 쓰면 예전 방식으로 돌아가는지 본다.
// 새 DB를 여러 번 만드는 시험이라 이 파일에만 제한을 늘렸다 (다른 시험의 제한은 그대로).

type Q = { rows: Record<string, unknown>[] };
const rowsOf = async (db: PGlite, sql: string) => JSON.stringify(((await db.query(sql)) as Q).rows);

/** public 스키마와 역할 · 권한 · RLS · 트리거 · 제약 · 함수 정의의 지문 */
async function fingerprint(db: PGlite): Promise<Record<string, string>> {
  return {
    tables: await rowsOf(db, `select table_schema, table_name from information_schema.tables where table_schema in ('public', 'auth', 'extensions') order by 1, 2`),
    columns: await rowsOf(db, `select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position`),
    functions: await rowsOf(db, `select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def, p.proacl::text as acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'auth') order by 1`),
    triggers: await rowsOf(db, `select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2`),
    constraints: await rowsOf(db, `select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`),
    rls: await rowsOf(db, `select c.relname, c.relrowsecurity, c.relacl::text as acl from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' order by 1`),
    policies: await rowsOf(db, `select tablename, policyname, cmd, roles::text, qual, with_check from pg_policies where schemaname = 'public' order by 1, 2`),
    roles: await rowsOf(db, `select rolname, rolbypassrls, rolcanlogin from pg_roles where rolname in ('anon', 'authenticated', 'service_role', 'supabase_auth_admin') order by 1`),
    extensions: await rowsOf(db, `select extname from pg_extension order by 1`),
  };
}

describe("PGlite 템플릿 복제", { timeout: 120_000 }, () => {
  let scripts: string[];
  let scratch: PGlite;
  let cloneA: PGlite;
  let cloneB: PGlite;
  const original = process.env.TASKFORCE_PGLITE_TEMPLATE;

  beforeAll(async () => {
    scripts = await supabaseSchemaScripts();
    process.env.TASKFORCE_PGLITE_TEMPLATE = "0"; // 처음부터 만든 기준
    scratch = await openPglite(scripts);
    if (original === undefined) delete process.env.TASKFORCE_PGLITE_TEMPLATE;
    else process.env.TASKFORCE_PGLITE_TEMPLATE = original;
    cloneA = await openPglite(scripts);
    cloneB = await openPglite(scripts);
  });
  afterAll(async () => {
    await Promise.allSettled([scratch?.close(), cloneA?.close(), cloneB?.close()]);
  });

  it("마이그레이션까지 적용한 복제본은 처음부터 만든 DB와 객체 지문(표 · 열 · 함수 정의와 권한 · 트리거 · 제약 · RLS · 정책 · 역할 · 확장)이 같다", async () => {
    const expected = await fingerprint(scratch);
    expect(JSON.parse(expected.tables).length).toBeGreaterThan(40); // 빈 지문끼리 견주는 헛된 통과를 막는다
    expect(JSON.parse(expected.functions).length).toBeGreaterThan(50);
    expect(await fingerprint(cloneA)).toEqual(expected);
    expect(await fingerprint(cloneB)).toEqual(expected);
  });

  it("복제본은 서로 격리된다: 한 복제본에 쓴 행이 다른 복제본 · 새 복제본에 보이지 않는다", async () => {
    const id = randomUUID();
    await cloneA.query(`insert into auth.users (id, email) values ($1, 'a@example.com')`, [id]);
    expect(((await cloneA.query(`select 1 from auth.users where id = $1`, [id])) as Q).rows).toHaveLength(1);
    expect(((await cloneB.query(`select 1 from auth.users where id = $1`, [id])) as Q).rows).toHaveLength(0);
    const later = await openPglite(scripts);
    try {
      expect(((await later.query(`select 1 from auth.users`)) as Q).rows).toHaveLength(0);
    } finally {
      await later.close();
    }
  });

  it("복제본에서 RLS · 역할이 실제로 동작한다 (역할 전환 · auth.uid)", async () => {
    const [alice, bob] = [randomUUID(), randomUUID()];
    await cloneB.exec(`insert into auth.users (id, email) values ('${alice}', 'a@example.com'), ('${bob}', 'b@example.com')`);
    await cloneB.query(`insert into public.actions (user_id, title) values ($1, '앨리스 일'), ($2, '밥 일')`, [alice, bob]);
    await cloneB.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${alice}', false);`);
    try {
      const rows = ((await cloneB.query(`select title from public.actions`)) as Q).rows;
      expect(rows).toEqual([{ title: "앨리스 일" }]);
    } finally {
      await cloneB.exec(`reset role; select set_config('request.jwt.claim.sub', '', false);`);
    }
  });

  it("빈 템플릿(스크립트 없음)은 initdb만 된 클러스터다: 앱 표는 없고, 스크립트를 적용하면 처음부터 만든 DB와 같아진다", async () => {
    const bare = await openPglite();
    try {
      expect(((await bare.query(`select 1 from information_schema.tables where table_name = 'actions'`)) as Q).rows).toHaveLength(0);
      for (const sql of scripts) await bare.exec(sql);
      expect(await fingerprint(bare)).toEqual(await fingerprint(scratch));
    } finally {
      await bare.close();
    }
  });

  it("TASKFORCE_PGLITE_TEMPLATE=0이면 템플릿 없이 처음부터 만든다 (같은 상태)", async () => {
    process.env.TASKFORCE_PGLITE_TEMPLATE = "0";
    try {
      const db = await openPglite(scripts);
      try {
        expect(await fingerprint(db)).toEqual(await fingerprint(scratch));
      } finally {
        await db.close();
      }
    } finally {
      if (original === undefined) delete process.env.TASKFORCE_PGLITE_TEMPLATE;
      else process.env.TASKFORCE_PGLITE_TEMPLATE = original;
    }
  });
});
