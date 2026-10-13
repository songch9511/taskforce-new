import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { PROJECT_ICON_POOL } from "@/lib/api/contract";

import { openPglite } from "./pglite-template";
import { asUser, supabaseSchemaScripts } from "./local-supabase";
import { contextIconVersionTests } from "./context-icon-version.scenarios";

let db: PGlite;
let backfill: { id: string; icon: string }[] = [];

beforeAll(async () => {
  const scripts = await supabaseSchemaScripts();
  const migrationIndex = scripts.findIndex((sql) => sql.includes("OA D4c-1s — 프로젝트 아이콘 · version"));
  const migration = scripts[migrationIndex];
  db = await openPglite(migrationIndex < 0 ? scripts : scripts.filter((_, index) => index !== migrationIndex));
  await db.query("insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'legacy@example.com')");
  const legacy = await db.query<{ id: string }>(
    `insert into public.work_contexts (id, user_id, name, kind) values
      ('00000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-00000000000a', 'Legacy A', 'project'),
      ('00000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-00000000000a', 'Legacy B', 'project') returning id`,
  );
  if (migration) {
    const file = path.resolve(process.cwd(), "supabase/migrations/20261117000000_context_icon_version.sql");
    await db.exec(await readFile(file, "utf8"));
    backfill = await db.query<{ id: string; icon: string }>(
      `select id, icon from public.work_contexts where id = any($1::uuid[]) order by id`,
      [legacy.rows.map((row) => row.id)],
    ).then((result) => result.rows);
  }
}, 60_000);

describe("프로젝트 아이콘 · version 마이그레이션 backfill", () => {
  it("기존 행은 ID hash로 결정적으로 icon 풀 안에 채워지고 version 기본값은 1", async () => {
    expect(backfill).toHaveLength(2);
    expect(backfill).toEqual([
      { id: "00000000-0000-4000-8000-000000000001", icon: "palette" },
      { id: "00000000-0000-4000-8000-000000000002", icon: "flask-conical" },
    ]);
    for (const row of backfill) expect(PROJECT_ICON_POOL).toContain(row.icon);
    const { rows } = await db.query<{ version: number }>(`select version from public.work_contexts where id = '00000000-0000-4000-8000-000000000001'`);
    expect(Number(rows[0].version)).toBe(1);
  });

  it("TypeScript 풀, SQL 제약, 랜덤 풀과 backfill 배열이 정확히 같다", () => {
    const sql = readFileSync(path.resolve(process.cwd(), "supabase/migrations/20261117000000_context_icon_version.sql"), "utf8");
    const parse = (value: string | undefined) => {
      expect(value).toBeDefined();
      return (value ?? "").split(",").map((icon) => icon.trim().replace(/^'|'$/g, ""));
    };
    const check = sql.match(/check\s*\(icon in\s*\(([^)]*)\)\)/i)?.[1];
    const randomPool = sql.match(/v_icons text\[\] := array\[([\s\S]*?)\]/)?.[1];
    const backfillPool = sql.match(/set icon = \(array\[([\s\S]*?)\]\)/)?.[1];
    expect(parse(check)).toEqual(PROJECT_ICON_POOL);
    expect(parse(randomPool)).toEqual(PROJECT_ICON_POOL);
    expect(parse(backfillPool)).toEqual(PROJECT_ICON_POOL);
  });
});

describe("프로젝트 아이콘 · version (PGlite)", () => {
  contextIconVersionTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));

});
