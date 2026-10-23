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

  it("만드는 것: 새 함수 하나(delete_all_claude_app_chats) + 다시 만드는 함수 둘(delete_claude_app_chat · take_rate_limit)뿐이다 (새 표 · 도메인 · 트리거 · 정책 · 인덱스 · 열 0)", () => {
    expect([...code.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["delete_all_claude_app_chats", "delete_claude_app_chat", "take_rate_limit"]);
    expect([...code.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["delete_all_claude_app_chats"]);
    expect(code).not.toMatch(/create\s+(table|domain|trigger|policy|index|unique index|view)\b|add column|drop table|drop function|drop policy/i);
    // 바꾸는 기존 표는 metric_events(종류 검사)와 rate_limit_events(종류 검사)뿐이다
    expect([...code.matchAll(/alter table ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.metric_events", "public.metric_events", "public.rate_limit_events", "public.rate_limit_events"]);
    expect(code).not.toMatch(/owner_insert_client_app_types/);
  });

  it("함수 권한: PUBLIC · anon · authenticated는 거두고 service_role에만 준다. invoker(security definer 아님) + search_path 빈 값", () => {
    expect(code).toMatch(/revoke all on function public\.delete_all_claude_app_chats\(uuid, integer\) from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.delete_all_claude_app_chats\(uuid, integer\) to service_role;/);
    expect(code).toMatch(/revoke all on function public\.delete_claude_app_chat\(uuid, uuid\) from public, anon, authenticated;\s+grant execute on function public\.delete_claude_app_chat\(uuid, uuid\) to service_role;/);
    expect(code).toMatch(/revoke execute on function public\.take_rate_limit from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.take_rate_limit to service_role;/);
    expect(code).not.toMatch(/\bgrant\b[^;]*\bto\s+(?:public|anon|authenticated)\b/i);
    expect(code).not.toMatch(/security definer/i);
    expect(code.match(/set search_path = ''/g)).toHaveLength(3);
  });

  it("지우는 문장은 호출한 사용자 것만 겨냥한다: 모두 지우기의 채팅(100개씩) · 묘비 상한, 하나 지우기의 채팅 · 묘비 상한. 자동 정리가 없다 (26장 Q-D3b)", () => {
    expect([...code.matchAll(/delete from ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.claude_app_chats", "public.claude_app_chat_tombstones", "public.claude_app_chats", "public.claude_app_chat_tombstones"]);
    // 채팅: 바깥도 안쪽 select도 호출한 사용자로 좁힌다 (한 판 100개)
    expect(code).toMatch(/delete from public\.claude_app_chats where user_id = p_user_id and id in \(select c\.id from public\.claude_app_chats c where c\.user_id = p_user_id order by c\.id limit c_batch\);/);
    expect(code).toMatch(/c_batch constant integer := 100;/);
    // 하나 지우기는 20261207과 같다 (id + 사용자)
    expect(code).toMatch(/delete from public\.claude_app_chats where id = p_chat_id and user_id = p_user_id returning id into v_id;/);
    // 묘비 상한: 두 함수 모두 넘친 묘비를 materialized CTE로 한 번 구하고 호출한 사용자로 좁힌다
    expect(code.match(/with excess as materialized \(\s+select o\.bridge_id, o\.session_ref, o\.mac_ref from public\.claude_app_chat_tombstones o\s+where o\.user_id = p_user_id order by o\.created_at desc, o\.mac_ref desc offset c_max_tombstones\s+\)/g)).toHaveLength(2);
    expect(code).not.toMatch(/purge|retention|expire/i);
  });

  // 20261207의 delete_claude_app_chat에서 바꾼 것은 묘비 상한 정리 한 문장뿐이다 (잠금 · 묘비 · 응답 · 지표는 같다)
  it("delete_claude_app_chat 다시 만들기: 묘비 상한 정리 문장을 빼면 20261207의 본문과 글자 하나 다르지 않다", () => {
    const fnBody = (sql: string, header: RegExp) => {
      const text = strip(sql);
      const from = text.search(header);
      if (from < 0) throw new Error("delete_claude_app_chat not found");
      const close = text.indexOf("$$;", text.indexOf("$$", from) + 2);
      return text.slice(from, close + 3);
    };
    const norm = (sql: string) => sql.replace(/\s+/g, " ").trim();
    const withoutTrim = (body: string) => norm(body.replace(/(?:with excess as materialized \([\s\S]*?\)\s+)?delete from public\.claude_app_chat_tombstones t[\s\S]*?;/, ""));
    const before = fnBody(read(PREVIOUS), /create function public\.delete_claude_app_chat\(/);
    const after = fnBody(migration, /create or replace function public\.delete_claude_app_chat\(/);
    expect(withoutTrim(after)).toBe(withoutTrim(before.replace("create function", "create or replace function")));
    // 바뀐 문장은 있다
    expect(norm(after)).not.toBe(norm(before));
    expect(norm(after)).toContain("with excess as materialized");
    expect(norm(before)).not.toContain("materialized");
  });

  // 보안 검토 P3-1: 묘비 상한 정리는 하루가 안 된 묘비를 지우지 않는다 (방금 하나씩 지운 대화의 묘비가 밀려나 재시도가 되살아나는 것을 막는다)
  it("묘비 상한 정리는 (모두 지우기 · 하나 지우기 모두) created_at이 하루보다 오래된 것만 지운다 · 모두 지우기 함수의 시간 간격은 그 '1 day' 하나뿐이다", () => {
    const young = /delete from public\.claude_app_chat_tombstones t using excess e\s+where t\.user_id = p_user_id\s+and t\.created_at < now\(\) - interval '1 day'\s+and t\.bridge_id = e\.bridge_id and t\.session_ref = e\.session_ref and t\.mac_ref = e\.mac_ref;/g;
    expect(code.match(young)).toHaveLength(2);
    const fn = code.slice(code.indexOf("create function public.delete_all_claude_app_chats"), code.indexOf("revoke all on function public.delete_all_claude_app_chats"));
    expect(fn.match(young)).toHaveLength(1);
    expect(fn.length).toBeGreaterThan(500);
    expect([...fn.matchAll(/interval\s+'([^']*)'/g)].map((m) => m[1])).toEqual(["1 day"]);
    expect(fn.match(/now\(\)/g)).toHaveLength(1);
  });

  // 보안 검토 P3-2: 함수 안에서 statement_timeout을 바꾸는 방법(function SET · 본문의 set local)은 이미 시작된 문장의 제한을 바꾸지 못한다 (tests/db/claude-app-chats.scenarios.ts의 관찰 시험).
  // 그래서 함수가 채팅을 100개씩 지우며 사이사이에 자기 제한을 본다: 넘으면 57014로 멈춰 호출 전체가 롤백된다 (route가 409 busy_retry로 돌려준다).
  it("자기 시간 제한: p_max_seconds(기본 60, 0–600 밖은 22023)를 사용자별 잠금을 쥔 뒤부터 재고, 더 지울 것이 있을 때만(한 판이 꽉 찼을 때만) 57014로 멈춘다. 묘비 · 지표는 그 뒤에 쓴다", () => {
    const fn = code.slice(code.indexOf("create function public.delete_all_claude_app_chats"), code.indexOf("revoke all on function public.delete_all_claude_app_chats"));
    expect(fn).toMatch(/create function public\.delete_all_claude_app_chats\(p_user_id uuid, p_max_seconds integer default 60\) returns jsonb/);
    expect(fn).toMatch(/p_max_seconds not between 0 and 600/);
    expect(fn).toMatch(/v_started := clock_timestamp\(\);/);
    expect(fn.indexOf("pg_advisory_xact_lock")).toBeLessThan(fn.indexOf("v_started := clock_timestamp()"));
    expect(fn).toMatch(/exit when v_round < c_batch;\s+if clock_timestamp\(\) - v_started > make_interval\(secs => p_max_seconds\) then\s+raise exception '[^']*' using errcode = '57014';/);
    // 시간 검사는 채팅 지우기 판 안에 있고, 지표 · 묘비 상한 정리는 판이 끝난 뒤다
    expect(fn.indexOf("errcode = '57014'")).toBeLessThan(fn.indexOf("delete from public.claude_app_chat_tombstones"));
    expect(fn.indexOf("errcode = '57014'")).toBeLessThan(fn.indexOf("insert into public.metric_events"));
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
        `select to_regprocedure('public.delete_all_claude_app_chats(uuid,integer)')::text as fn,
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
        `select to_regprocedure('public.delete_all_claude_app_chats(uuid,integer)')::text as fn,
                (select pg_get_constraintdef(oid) from pg_constraint where conname = 'metric_events_type_check') as types,
                (select pg_get_constraintdef(oid) from pg_constraint where conname = 'rate_limit_events_kind_check') as kinds`,
      );
      expect(rows[0].fn).toBe("delete_all_claude_app_chats(uuid,integer)");
      for (const type of typeList(FILE)) expect(rows[0].types, type).toContain(`'${type}'`);
      for (const kind of kindList(FILE)) expect(rows[0].kinds, kind).toContain(`'${kind}'`);
    } finally {
      await db.close();
    }
  });
});
