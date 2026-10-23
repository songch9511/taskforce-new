import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

// 마이그레이션 경계 + 적용 순서 가드 (20261208000000_claude_app_chats_delete_all, OA D3v-s, 계약 27장).
// 파일 글자 시험은 DB 0이다. 실제 적용 시험은 빈 PGlite에 마이그레이션을 직접 적용한다 (템플릿 캐시가 없는 환경에서는 initdb + 수십 개 적용이라 기본 5초를 넘을 수 있어 시험마다 제한을 명시한다).

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const FILE = "20261208000000_claude_app_chats_delete_all.sql";
const PREVIOUS = "20261207000000_claude_app_chats.sql";
const NEW_TYPE = "claude_app_chats_deleted_all";
const NEW_KIND = "claude_app_chat_delete_all";
const APPLY = { timeout: 300_000 };

const strip = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
const migration = readFileSync(path.join(MIGRATIONS, FILE), "utf8");
const code = strip(migration).trim();
const read = (name: string) => readFileSync(path.join(MIGRATIONS, name), "utf8");

function list(file: string, pattern: RegExp): string[] {
  const found = [...strip(read(file)).matchAll(pattern)].at(-1)?.[1];
  if (found === undefined) throw new Error(`${file}: 목록을 찾지 못했다`);
  return [...found.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}
const typeList = (file: string) => list(file, /constraint\s+metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi);
const kindList = (file: string) => list(file, /constraint\s+rate_limit_events_kind_check\s+check\s*\(\s*kind\s+in\s*\(([^)]*)\)\s*\)/gi);

/** `create [or replace] function public.take_rate_limit(...)`부터 `$$;`까지 (주석 없이, 공백을 하나로) */
function takeRateLimitBody(sql: string): string {
  const text = strip(sql);
  const from = text.search(/create (?:or replace )?function public\.take_rate_limit\(/);
  if (from < 0) throw new Error("take_rate_limit not found");
  const open = text.indexOf("$$", from);
  const close = text.indexOf("$$;", open + 2);
  return text.slice(from, close + 3).replace(/\s+/g, " ").trim();
}

describe("마이그레이션 경계 (20261208000000_claude_app_chats_delete_all)", () => {
  it("한 트랜잭션, 짧은 lock_timeout", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(code.endsWith("commit;")).toBe(true);
    expect(code.match(/^begin;$/gm)).toHaveLength(1);
    expect(code.match(/^commit;$/gm)).toHaveLength(1);
  });

  it("만드는 것: 함수 하나(delete_all_claude_app_chats) + take_rate_limit 재정의뿐이다 (새 표 · 도메인 · 트리거 · 정책 · 인덱스 · 열 0)", () => {
    expect([...code.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["delete_all_claude_app_chats", "take_rate_limit"]);
    expect([...code.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["delete_all_claude_app_chats"]);
    expect(code).not.toMatch(/create\s+(table|domain|trigger|policy|index|unique index|view)\b|add column|drop table|drop function|drop policy/i);
    // 바꾸는 기존 표는 metric_events(종류 검사)와 rate_limit_events(종류 검사)뿐이다
    expect([...code.matchAll(/alter table ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.metric_events", "public.metric_events", "public.rate_limit_events", "public.rate_limit_events"]);
    expect(code).not.toMatch(/owner_insert_client_app_types/);
  });

  it("함수 권한: PUBLIC · anon · authenticated는 거두고 service_role에만 준다. invoker(security definer 아님) + search_path 빈 값", () => {
    expect(code).toMatch(/revoke all on function public\.delete_all_claude_app_chats\(uuid\) from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.delete_all_claude_app_chats\(uuid\) to service_role;/);
    expect(code).toMatch(/revoke execute on function public\.take_rate_limit from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.take_rate_limit to service_role;/);
    expect(code).not.toMatch(/\bgrant\b[^;]*\bto\s+(?:public|anon|authenticated)\b/i);
    expect(code).not.toMatch(/security definer/i);
    expect(code.match(/set search_path = ''/g)).toHaveLength(2);
  });

  it("지우는 문장은 둘이고 모두 호출한 사용자 것만 겨냥한다 (채팅 · 묘비 개수 상한). 자동 정리 · 시간 간격이 없다 (26장 Q-D3b)", () => {
    expect([...code.matchAll(/delete from ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.claude_app_chats", "public.claude_app_chat_tombstones"]);
    expect(code).toMatch(/delete from public\.claude_app_chats where user_id = p_user_id;/);
    expect(code).toMatch(/delete from public\.claude_app_chat_tombstones t\s+where t\.user_id = p_user_id/);
    expect(code).not.toMatch(/purge|retention|expire/i);
    // 시간 간격은 이 함수에 없다 (take_rate_limit 본문의 v_window interval은 20261207에서 이어 받은 것이다)
    const fn = code.slice(code.indexOf("create function public.delete_all_claude_app_chats"), code.indexOf("revoke all on function public.delete_all_claude_app_chats"));
    expect(fn.length).toBeGreaterThan(500);
    expect(fn).not.toMatch(/interval|now\(\)|clock_timestamp/i);
  });

  it("묘비는 지우기 전에 남긴다 (지운 뒤에는 사용자 글이 없다) · 사용자 글만 · 호출자 것만", () => {
    expect(code.indexOf("insert into public.claude_app_chat_tombstones")).toBeGreaterThan(-1);
    expect(code.indexOf("insert into public.claude_app_chat_tombstones")).toBeLessThan(code.indexOf("delete from public.claude_app_chats"));
    const insert = code.slice(code.indexOf("insert into public.claude_app_chat_tombstones"), code.indexOf("delete from public.claude_app_chats"));
    expect(insert).toMatch(/m\.role = 'user'/);
    expect(insert).toMatch(/m\.user_id = p_user_id/);
  });

  it("사용자별 잠금은 저장 · 지우기와 같은 열쇠이고 어떤 쓰기보다 앞에서 잡는다", () => {
    const body = code.slice(code.indexOf("create function public.delete_all_claude_app_chats"));
    expect(body).toContain("pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0))");
    expect(body.indexOf("pg_advisory_xact_lock")).toBeLessThan(body.indexOf("insert into public.claude_app_chat_tombstones"));
    expect(body.indexOf("pg_advisory_xact_lock")).toBeLessThan(body.indexOf("delete from public.claude_app_chats"));
    // 저장 · 지우기와 같은 열쇠 문자열 (20261207)
    expect(read(PREVIOUS)).toContain("pg_advisory_xact_lock(hashtextextended('claude_app_chat:' || p_user_id::text, 0))");
  });
});

describe("종류 검사 · take_rate_limit (20261208000000)", () => {
  it("metric_events_type_check = 20261207의 전체 목록 + claude_app_chats_deleted_all 하나와 정확히 같다 (순서 · 중복 포함)", () => {
    const previous = typeList(PREVIOUS);
    expect(previous.at(-1)).toBe("claude_app_chat_deleted");
    expect(typeList(FILE)).toEqual([...previous, NEW_TYPE]);
    expect(new Set(typeList(FILE)).size).toBe(typeList(FILE).length);
  });

  it("rate_limit_events_kind_check = 20261207의 목록 + claude_app_chat_delete_all 하나와 정확히 같다", () => {
    const previous = kindList(PREVIOUS);
    expect(previous.at(-1)).toBe("claude_app_chat_day");
    expect(kindList(FILE)).toEqual([...previous, NEW_KIND]);
  });

  it("take_rate_limit 본문은 20261207의 정의에서 종류 claude_app_chat_delete_all 하나만 더한다", () => {
    const before = takeRateLimitBody(read(PREVIOUS));
    const after = takeRateLimitBody(migration);
    expect(after).not.toBe(before);
    expect(after.replace(",'claude_app_chat_delete_all'", "")).toBe(before);
    expect(after.match(/'claude_app_chat_delete_all'/g)).toHaveLength(1);
  });

  it("바로 앞 정의의 집은 20261207다 (그 뒤 이 파일 전에 두 검사 · take_rate_limit을 다시 만든 파일이 없다)", () => {
    const between = readdirSync(MIGRATIONS).filter((name) => name > PREVIOUS && name < FILE && name.endsWith(".sql"));
    for (const name of between) {
      expect(strip(read(name)), name).not.toMatch(/metric_events_type_check|rate_limit_events_kind_check|function public\.take_rate_limit\(/i);
    }
  });

  it("이 파일 뒤에 두 검사 · take_rate_limit을 다시 만드는 마이그레이션이 있다면 새 종류를 이어 가져와야 한다", () => {
    for (const name of readdirSync(MIGRATIONS).filter((n) => n > FILE && n.endsWith(".sql"))) {
      const text = strip(read(name));
      if (/metric_events_type_check/i.test(text)) expect(text, name).toContain(NEW_TYPE);
      if (/rate_limit_events_kind_check|function public\.take_rate_limit\(/i.test(text)) expect(text, name).toContain(NEW_KIND);
    }
  });
});

describe("적용 순서 가드 (20261208 → 20261207)", () => {
  it("맨 앞(begin · lock_timeout 바로 뒤, 어떤 DDL보다 먼저)에서 20261207의 것(묘비 표 · delete_claude_app_chat · 지표 종류 · 속도 제한 종류)을 보고 없으면 20261207을 먼저 적용하라는 예외를 던진다", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    const afterLock = code.slice("begin;\nset local lock_timeout = '5s';".length).trimStart();
    expect(afterLock.startsWith("do $$")).toBe(true);
    const guard = afterLock.slice(0, afterLock.indexOf("$$;") + 3);
    expect(guard).toMatch(/claude_app_chat_tombstones/);
    expect(guard).toMatch(/delete_claude_app_chat\(uuid,\s*uuid\)/);
    expect(guard).toMatch(/metric_events_type_check/);
    expect(guard).toMatch(/claude_app_chat_deleted/);
    expect(guard).toMatch(/rate_limit_events_kind_check/);
    expect(guard).toMatch(/claude_app_chat_day/);
    expect(guard).toMatch(/raise exception[^;]*20261207000000_claude_app_chats/);
    // 가드보다 앞에 표 · 함수를 만들거나 바꾸는 문장이 없다
    const before = code.slice(0, code.indexOf(guard));
    expect(before).not.toMatch(/\b(create|alter|drop|insert|update|delete)\b/i);
  });

  it("20261207 없이 20261208을 적용하면 거절되고 아무것도 남지 않는다 (실제 적용)", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [PREVIOUS, FILE] })) await db.exec(script);
      await expect(db.exec(migration)).rejects.toThrow(/20261207/);
      await db.exec("rollback").catch(() => undefined);
      const { rows } = await db.query<{ fn: string | null; type: boolean; kind: boolean }>(
        `select to_regprocedure('public.delete_all_claude_app_chats(uuid)')::text as fn,
                (select pg_get_constraintdef(oid) like '%${NEW_TYPE}%' from pg_constraint where conname = 'metric_events_type_check') as type,
                (select pg_get_constraintdef(oid) like '%${NEW_KIND}%' from pg_constraint where conname = 'rate_limit_events_kind_check') as kind`,
      );
      expect(rows[0]).toEqual({ fn: null, type: false, kind: false });
    } finally {
      await db.close();
    }
  });

  it("20261206까지만 적용된 DB(묘비 표 · 지우기 함수 없음)에서도 같다", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [PREVIOUS, FILE] })) await db.exec(script);
      const { rows } = await db.query<{ tombstones: string | null; deleted: boolean }>(
        "select to_regclass('public.claude_app_chat_tombstones')::text as tombstones, (select pg_get_constraintdef(oid) like '%claude_app_chat_deleted%' from pg_constraint where conname = 'metric_events_type_check') as deleted",
      );
      expect(rows[0]).toEqual({ tombstones: null, deleted: false });
      await expect(db.exec(migration)).rejects.toThrow(/20261207|claude_app_chat/);
    } finally {
      await db.close();
    }
  });

  it("20261207을 적용한 뒤에는 통과한다 (정상 순서): 함수 · 새 지표 종류 · 새 속도 제한 종류가 생기고 20261207의 종류도 그대로다", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [FILE] })) await db.exec(script);
      await db.exec(migration);
      const { rows } = await db.query<{ fn: string | null; types: string; kinds: string }>(
        `select to_regprocedure('public.delete_all_claude_app_chats(uuid)')::text as fn,
                (select pg_get_constraintdef(oid) from pg_constraint where conname = 'metric_events_type_check') as types,
                (select pg_get_constraintdef(oid) from pg_constraint where conname = 'rate_limit_events_kind_check') as kinds`,
      );
      expect(rows[0].fn).toBe("delete_all_claude_app_chats(uuid)");
      for (const type of typeList(FILE)) expect(rows[0].types, type).toContain(`'${type}'`);
      for (const kind of kindList(FILE)) expect(rows[0].kinds, kind).toContain(`'${kind}'`);
    } finally {
      await db.close();
    }
  });
});
