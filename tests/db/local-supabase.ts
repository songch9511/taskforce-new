import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite-pgvector";

const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");

// Supabase가 기본으로 제공하는 것 중 마이그레이션이 기대는 최소한만 흉내 낸다.
const SUPABASE_STUB = `
  create schema if not exists extensions;
  create schema if not exists auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;
  create role anon nologin;
  create role authenticated nologin;
  grant usage on schema auth, extensions to anon, authenticated;
`;

// Supabase는 public 스키마 테이블에 기본 권한을 준다. 실제 접근 제어는 RLS가 한다.
const SUPABASE_DEFAULT_GRANTS = `
  grant usage on schema public to anon, authenticated;
  grant all on all tables in schema public to anon, authenticated;
`;

export async function createLocalSupabase(): Promise<PGlite> {
  const db = new PGlite({ extensions: { vector } });
  await db.exec(SUPABASE_STUB);

  const files = (await readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith(".sql")).sort();
  for (const file of files) {
    await db.exec(await readFile(path.join(MIGRATIONS_DIR, file), "utf8"));
  }

  await db.exec(SUPABASE_DEFAULT_GRANTS);
  return db;
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
