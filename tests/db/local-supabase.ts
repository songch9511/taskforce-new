import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";

import { openPglite } from "./pglite-template";

const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");

// Supabase가 기본으로 제공하는 것 중 마이그레이션이 기대는 최소한만 흉내 낸다.
const SUPABASE_STUB = `
  create schema if not exists extensions;
  create schema if not exists auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;
  -- 역할은 클러스터 전체에 남는다: 실제 Postgres(tests/pg)에서 데이터베이스를 새로 만들어도 다시 만들지 않는다
  do $$
  begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
    if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
  end $$;
  grant usage on schema auth, extensions to anon, authenticated;
`;

// Supabase는 public 스키마에 새로 만드는 테이블 · 함수에 기본 권한을 준다(default privileges). 실제 접근 제어는 RLS가 한다.
// 테이블을 만들 때 권한이 붙으므로, 마이그레이션 안의 revoke가 실제처럼 효과를 낸다.
const SUPABASE_DEFAULT_GRANTS = `
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`;

/**
 * Supabase 흉내 + 모든 마이그레이션 (적용 순서대로). PGlite와 실제 Postgres(tests/pg)가 같은 SQL을 적용한다.
 * PR-D3s의 20261207은 20261206(PR-D2)이 먼저 적용돼야 한다(적용 순서 가드). `without`은 그 이름의 마이그레이션을 뺀다 (적용 순서 가드 시험이 쓴다).
 */
export async function supabaseSchemaScripts(options: { without?: readonly string[] } = {}): Promise<string[]> {
  const without = new Set(options.without ?? []);
  const files = (await readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith(".sql"));
  const entries = await Promise.all(files.map(async (file) => ({ name: file, sql: await readFile(path.join(MIGRATIONS_DIR, file), "utf8") })));
  const migrations = entries.filter((entry) => !without.has(entry.name)).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)).map((entry) => entry.sql);
  return [SUPABASE_STUB, SUPABASE_DEFAULT_GRANTS, ...migrations];
}

/** 마이그레이션까지 적용된 새 PGlite. 같은 스크립트로 만든 템플릿 클러스터를 복제한다(없으면 처음부터 — tests/db/pglite-template.ts) */
export async function createLocalSupabase(): Promise<PGlite> {
  return openPglite(await supabaseSchemaScripts());
}

// 로그인한 사용자로 쿼리를 실행한다. RLS가 적용된다.
export async function asUser<T>(db: PGlite, userId: string, fn: () => Promise<T>): Promise<T> {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${userId}', false);`);
  try {
    return await fn();
  } finally {
    await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false);`);
  }
}
