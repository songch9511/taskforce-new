import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { ATTACH_MIGRATION, attachAgentSessionTests } from "./agent-session-attach.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);
afterAll(async () => {
  await db?.close();
});

describe("외부 세션 이어받기 서버 (PGlite)", () => {
  attachAgentSessionTests(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
});

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const migration = readFileSync(path.join(MIGRATIONS, ATTACH_MIGRATION), "utf8");
const code = migration.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n").trim();

/** `check (type in ('a', 'b', …))`의 목록 (그 파일에서 마지막 정의) */
function typeList(sql: string): string[] {
  const text = sql.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
  const lists = [...text.matchAll(/constraint\s+metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi)];
  const list = lists.at(-1)?.[1];
  if (list === undefined) throw new Error("metric_events_type_check not found");
  return [...list.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}

describe("마이그레이션 경계 (20261204000000_agent_session_attach)", () => {
  it("한 트랜잭션, 짧은 lock_timeout, 함수 하나뿐: 새 표 · 정책 · 권한 부여는 이 함수와 지표 종류 검사 밖에 없다", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(code.endsWith("commit;")).toBe(true);
    expect(code.match(/^begin;$/gm)).toHaveLength(1);
    expect(code.match(/^commit;$/gm)).toHaveLength(1);
    expect([...code.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["attach_agent_session"]);
    expect(code).not.toMatch(/create (?:or replace )?function public\.(?!attach_agent_session\b)/);
    expect(code).not.toMatch(/create table|create policy|create trigger|create index|create unique index/i);
    // 바꾸는 표는 metric_events 하나(종류 검사)뿐이다
    expect([...code.matchAll(/alter table ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.metric_events", "public.metric_events"]);
    // 앱 insert 정책(owner_insert_client_app_types)은 건드리지 않는다
    expect(code).not.toMatch(/owner_insert_client_app_types|\bpolicy\b/i);
    // 함수 권한: PUBLIC · anon · authenticated는 거두고 service_role에만 준다
    expect(code).toMatch(/revoke all on function public\.attach_agent_session\([^)]*\) from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.attach_agent_session\([^)]*\) to service_role;/);
    expect(code).not.toMatch(/\bgrant\b[^;]*\bto\s+(?:public|anon|authenticated)\b/i);
    expect(code).toMatch(/security definer/);
    expect(code).toMatch(/set search_path = ''/);
  });

  it("지표 종류 검사는 바로 앞 목록 그대로에 session_attached 하나만 더한다", () => {
    const previous = readdirSync(MIGRATIONS)
      .filter((name) => name.endsWith(".sql") && name < ATTACH_MIGRATION && /metric_events_type_check/i.test(readFileSync(path.join(MIGRATIONS, name), "utf8").split("\n").filter((l) => !l.trim().startsWith("--")).join("\n")))
      .sort()
      .at(-1)!;
    const before = typeList(readFileSync(path.join(MIGRATIONS, previous), "utf8"));
    const after = typeList(migration);
    expect(after).toEqual([...before, "session_attached"]);
    expect(new Set(after).size).toBe(after.length);
  });
});
