import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { ANSWER_LOCAL_MIGRATION, answerLocalFixtures, answerLocalTests } from "./answer-local.scenarios";
import { asUser, createLocalSupabase, supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const handle = () => ({ query: async (sql: string, params?: unknown[]) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: <T,>(user: string, fn: () => Promise<T>) => asUser(db, user, fn) });

describe("answer_agent_question_locally (PGlite)", () => {
  answerLocalTests(handle);
});

describe("T4 사후 소유 확인 · 본문 동일성 · 되돌리기", () => {
  const f = answerLocalFixtures(handle);

  it("쓰는 도중 연결의 bridge가 바뀌면 블록이 통째로 롤백되고 not_found (답 단계 · 명령 · 대화 줄 · 지표 0)", async () => {
    const w = await f.secretWorld();
    const other = await f.bridge(w.user);
    const before = await f.all(w.user);
    await f.q("begin");
    try {
      await f.q(`create function public.tmp_f2_flip() returns trigger language plpgsql as $$
        begin update public.agent_connections set bridge_id = '${other}' where id = '${w.connection}'; return new; end $$`);
      await f.q(`create trigger tmp_f2_flip after update of state on public.agent_tasks for each row
        when (old.state = 'awaiting_answer' and new.state = 'running') execute function public.tmp_f2_flip()`);
      expect(await f.local(w)).toEqual({ status: "not_found" });
      expect(await f.all(w.user)).toEqual(before);
      expect(await f.one("select bridge_id from public.agent_connections where id=$1", [w.connection])).toEqual({ bridge_id: w.bridge });
      expect(await f.answerSteps(w.task)).toEqual([]);
    } finally {
      await f.q("rollback");
    }
  });

  it("쓰는 도중 bridge가 폐기되면 같은 롤백 · not_found (사후 확인은 bridge active도 본다)", async () => {
    const w = await f.secretWorld();
    const before = await f.all(w.user);
    await f.q("begin");
    try {
      await f.q(`create function public.tmp_f2_revoke() returns trigger language plpgsql as $$
        begin update public.bridges set status = 'revoked', revoked_at = now() where id = '${w.bridge}'; return new; end $$`);
      await f.q(`create trigger tmp_f2_revoke after update of state on public.agent_tasks for each row
        when (old.state = 'awaiting_answer' and new.state = 'running') execute function public.tmp_f2_revoke()`);
      expect(await f.local(w)).toEqual({ status: "not_found" });
      expect(await f.all(w.user)).toEqual(before);
      expect(await f.one("select status from public.bridges where id=$1", [w.bridge])).toEqual({ status: "active" });
    } finally {
      await f.q("rollback");
    }
  });

  it("대조: 바뀌지 않으면 같은 호출이 answered이다 (위 시험이 트리거 때문에만 거절된 것을 확인)", async () => {
    const w = await f.secretWorld();
    expect((await f.local(w)).status).toBe("answered");
  });

  const fingerprint = async (target: PGlite) => {
    const rows = async (sql: string) => JSON.stringify((await target.query(sql)).rows);
    return {
      tables: await rows("select table_name from information_schema.tables where table_schema = 'public' order by 1"),
      columns: await rows("select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position"),
      functions: await rows("select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def, p.proacl::text as acl, p.proconfig::text as config from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"),
      triggers: await rows("select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2"),
      constraints: await rows("select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2"),
      indexes: await rows("select tablename, indexname, md5(indexdef) as def from pg_indexes where schemaname = 'public' order by 1, 2"),
      policies: await rows("select tablename, policyname, md5(coalesce(qual, '') || coalesce(with_check, '')) as def from pg_policies where schemaname = 'public' order by 1, 2"),
    };
  };

  it("이 마이그레이션은 새 함수 하나만 더한다: 기존 함수 본문 · 권한 · 표 · 열 · 색인 · 트리거 · 제약 · 정책의 지문이 그대로이고, 머리의 되돌리기 문장은 앞 지문으로 완전히 돌려놓는다", async () => {
    const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", ANSWER_LOCAL_MIGRATION), "utf8");
    const scripts = await supabaseSchemaScripts();
    const before = scripts.filter((script) => script !== sql);
    expect(before).toHaveLength(scripts.length - 1);
    const clone = await openPglite(before);
    try {
      const baseline = await fingerprint(clone);
      await clone.exec(sql);
      const after = await fingerprint(clone);
      type Fn = { sig: string; def: string; acl: string; config: string };
      const oldFns = JSON.parse(baseline.functions) as Fn[];
      const newFns = JSON.parse(after.functions) as Fn[];
      expect(newFns.filter((fn) => !oldFns.some((old) => old.sig === fn.sig)).map((fn) => fn.sig)).toEqual(["answer_agent_question_locally(uuid,uuid,uuid,text,text[])"]);
      const kept = new Set(newFns.map((fn) => JSON.stringify(fn)));
      for (const fn of oldFns) expect(kept.has(JSON.stringify(fn)), fn.sig).toBe(true);
      for (const key of ["tables", "columns", "triggers", "constraints", "indexes", "policies"] as const) expect(after[key], key).toBe(baseline[key]);
      const revert = /^-- 되돌리기: (drop function public\.answer_agent_question_locally\([^)]*\);)\s*$/m.exec(sql);
      expect(revert, "head comment has the revert statement").not.toBeNull();
      await clone.exec(revert![1]);
      expect(await fingerprint(clone)).toEqual(baseline);
    } finally {
      await clone.close();
    }
  }, 120_000);
});
