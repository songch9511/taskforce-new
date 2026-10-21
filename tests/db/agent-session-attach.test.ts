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

/** 주석 줄을 지운 SQL */
const stripComments = (sql: string) => sql.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
/** `create [or replace] function public.take_rate_limit(...)`부터 `$$;`까지 (주석 없이, 공백을 하나로) */
function takeRateLimitBody(sql: string): string {
  const text = stripComments(sql);
  const from = text.search(/create (?:or replace )?function public\.take_rate_limit\(/);
  if (from < 0) throw new Error("take_rate_limit not found");
  const open = text.indexOf("$$", from);
  const close = text.indexOf("$$;", open + 2);
  return text.slice(from, close + 3).replace(/\s+/g, " ").trim();
}
/** rate_limit_events_kind_check의 목록 (그 파일의 마지막 정의) */
function rateLimitKinds(sql: string): string[] {
  const lists = [...stripComments(sql).matchAll(/constraint\s+rate_limit_events_kind_check\s+check\s*\(\s*kind\s+in\s*\(([^)]*)\)\s*\)/gi)];
  const list = lists.at(-1)?.[1];
  if (list === undefined) throw new Error("rate_limit_events_kind_check not found");
  return [...list.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}
const PREVIOUS_RATE_LIMIT_MIGRATION = "20261130000000_user_ai_keys.sql";

describe("마이그레이션 경계 (20261204000000_agent_session_attach)", () => {
  it("한 트랜잭션, 짧은 lock_timeout. 새 함수는 attach_agent_session 하나이고 take_rate_limit만 다시 만든다 (새 표 · 정책 · 트리거 · 인덱스 0)", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(code.endsWith("commit;")).toBe(true);
    expect(code.match(/^begin;$/gm)).toHaveLength(1);
    expect(code.match(/^commit;$/gm)).toHaveLength(1);
    expect([...code.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["attach_agent_session", "take_rate_limit"]);
    expect([...code.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["attach_agent_session"]);
    expect(code).not.toMatch(/create table|create policy|create trigger|create index|create unique index/i);
    // 바꾸는 표는 metric_events(종류 검사)와 rate_limit_events(종류 검사)뿐이다
    expect([...code.matchAll(/alter table ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.metric_events", "public.metric_events", "public.rate_limit_events", "public.rate_limit_events"]);
    // 앱 insert 정책(owner_insert_client_app_types)은 건드리지 않는다
    expect(code).not.toMatch(/owner_insert_client_app_types|\bpolicy\b/i);
    // 함수 권한: PUBLIC · anon · authenticated는 거두고 service_role에만 준다
    expect(code).toMatch(/revoke all on function public\.attach_agent_session\([^)]*\) from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.attach_agent_session\([^)]*\) to service_role;/);
    expect(code).toMatch(/revoke execute on function public\.take_rate_limit from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.take_rate_limit to service_role;/);
    expect(code).not.toMatch(/\bgrant\b[^;]*\bto\s+(?:public|anon|authenticated)\b/i);
    // 형제 서버 전용 함수(report_external_sessions 등)처럼 invoker다: security definer가 필요한 일이 없다 (호출자는 service role)
    expect(code).not.toMatch(/security definer/i);
    expect(code).toMatch(/set search_path = ''/);
  });

  it("지표 종류 검사는 바로 앞 목록 그대로 session_attached 하나만 더한다", () => {
    const previous = readdirSync(MIGRATIONS)
      .filter((name) => name.endsWith(".sql") && name < ATTACH_MIGRATION && /metric_events_type_check/i.test(stripComments(readFileSync(path.join(MIGRATIONS, name), "utf8"))))
      .sort()
      .at(-1)!;
    const before = typeList(readFileSync(path.join(MIGRATIONS, previous), "utf8"));
    const after = typeList(migration);
    expect(after).toEqual([...before, "session_attached"]);
    expect(new Set(after).size).toBe(after.length);
  });

  it("속도 제한: rate_limit_events 종류 검사는 앞 목록 + agent_attach 하나, take_rate_limit 본문은 앞 정의에서 그 종류 하나만 더한다", () => {
    const previousSql = readFileSync(path.join(MIGRATIONS, PREVIOUS_RATE_LIMIT_MIGRATION), "utf8");
    // 앞 목록의 집이 정말 그 파일이다 (그 뒤 파일들이 이 제약 · 함수를 다시 만들지 않았다)
    const later = readdirSync(MIGRATIONS).filter((name) => name > PREVIOUS_RATE_LIMIT_MIGRATION && name < ATTACH_MIGRATION && /rate_limit_events_kind_check|function public\.take_rate_limit\(/i.test(stripComments(readFileSync(path.join(MIGRATIONS, name), "utf8"))));
    expect(later).toEqual([]);
    expect(rateLimitKinds(migration)).toEqual([...rateLimitKinds(previousSql), "agent_attach"]);
    const before = takeRateLimitBody(previousSql);
    const after = takeRateLimitBody(migration);
    expect(after).not.toBe(before);
    expect(after.replace(",'agent_attach'", "")).toBe(before);
    expect(after.match(/'agent_attach'/g)).toHaveLength(1);
  });
});
