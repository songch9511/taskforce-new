import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

// 적용 순서 가드 (OA PR-D3s 보안 검토 P2-2): 20261207은 metric_events_type_check를 "20261206의 목록 + 새 종류 둘"로 다시 만든다.
// 20261206(PR-D2)보다 먼저 적용하면 claude_app_session_opened가 목록에서 조용히 빠지고 D2의 route가 23514로 실패한다.
// 그래서 20261207은 맨 앞에서 20261206이 적용됐는지 확인하고, 아니면 예외로 멈춘다 (운영 DB는 파일을 하나씩 적용하므로 순서를 사람이 지킨다).

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const D2_MIGRATION_NAME = "20261206000000_claude_app_session_metrics.sql";
const MINE = "20261207000000_claude_app_chats.sql";
/** 20261207 뒤에 적용하는 마이그레이션은 20261207 없이 적용하면 스스로 멈춘다 (적용 순서 가드): 20261208(D3v-s)은 자기 가드로, 20261209(T3s)는 20261207 · 20261208을 모두 요구한다. 20261207을 뺀 시험 DB에서는 함께 뺀다 */
const LATER = ["20261208000000_claude_app_chats_delete_all.sql", "20261209000000_agent_tree_metrics.sql"];
const mineSql = readFileSync(path.join(MIGRATIONS, MINE), "utf8");
const code = mineSql.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n").trim();

// 실제 적용 시험은 빈 PGlite에 마이그레이션을 직접 적용한다 (템플릿 캐시가 없는 환경에서는 initdb + 수십 개 적용이라 기본 5초를 넘을 수 있다):
// 그 시험들은 시험마다 제한을 명시한다 (describe 한 곳에 기대지 않는다). 부하가 큰 CI에서도 걸리지 않게 넉넉히.
const APPLY = { timeout: 300_000 };
describe("적용 순서 가드 (20261207 → 20261206)", () => {
  it("맨 앞(begin · lock_timeout 바로 뒤, 어떤 DDL보다 먼저)에서 종류 검사에 claude_app_session_opened가 있는지 보고 없으면 20261206을 먼저 적용하라는 예외를 던진다", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    const afterLock = code.slice("begin;\nset local lock_timeout = '5s';".length).trimStart();
    expect(afterLock.startsWith("do $$")).toBe(true);
    const guard = afterLock.slice(0, afterLock.indexOf("$$;") + 3);
    expect(guard).toMatch(/metric_events_type_check/);
    expect(guard).toMatch(/claude_app_session_opened/);
    expect(guard).toMatch(/raise exception[^;]*20261206000000_claude_app_session_metrics/);
    // 가드보다 앞에 표 · 함수를 만들거나 바꾸는 문장이 없다
    const before = code.slice(0, code.indexOf(guard));
    expect(before).not.toMatch(/\b(create|alter|drop|insert|update|delete)\b/i);
  });

  it("20261206 없이 20261207을 적용하면 거절되고 아무것도 남지 않는다 (실제 적용)", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [D2_MIGRATION_NAME, MINE, ...LATER] })) await db.exec(script);
      await expect(db.exec(mineSql)).rejects.toThrow(/20261206/);
      await db.exec("rollback").catch(() => undefined);
      const { rows } = await db.query<{ chats: string | null; domain: string | null; kinds: boolean }>(
        `select to_regclass('public.claude_app_chats')::text as chats, to_regtype('public.claude_app_tool_name')::text as domain,
                (select pg_get_constraintdef(oid) like '%claude_app_chat%' from pg_constraint where conname = 'rate_limit_events_kind_check') as kinds`,
      );
      expect(rows[0]).toEqual({ chats: null, domain: null, kinds: false });
    } finally {
      await db.close();
    }
  });

  it("종류 검사에 claude_app_session_opened가 없는 DB(20261204까지)에서도 같다: 20261206만 빠진 것과 구별하지 않고 멈춘다", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [D2_MIGRATION_NAME, MINE, ...LATER] })) await db.exec(script);
      const { rows } = await db.query<{ has: boolean }>("select pg_get_constraintdef(oid) like '%claude_app_session_opened%' as has from pg_constraint where conname = 'metric_events_type_check'");
      expect(rows[0].has).toBe(false);
      await expect(db.exec(mineSql)).rejects.toThrow(/claude_app_session_opened|20261206/);
    } finally {
      await db.close();
    }
  });

  it("20261206을 적용한 뒤에는 통과한다 (정상 순서)", APPLY, async () => {
    const db = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [MINE, ...LATER] })) await db.exec(script);
      const { rows: before } = await db.query<{ has: boolean }>("select pg_get_constraintdef(oid) like '%claude_app_session_opened%' as has from pg_constraint where conname = 'metric_events_type_check'");
      expect(before[0].has).toBe(true);
      await db.exec(mineSql);
      const { rows } = await db.query<{ chats: string | null; has: boolean }>(
        "select to_regclass('public.claude_app_chats')::text as chats, (select pg_get_constraintdef(oid) like '%claude_app_session_opened%' and pg_get_constraintdef(oid) like '%claude_app_message_sent%' from pg_constraint where conname = 'metric_events_type_check') as has",
      );
      expect(rows[0]).toEqual({ chats: "claude_app_chats", has: true });
    } finally {
      await db.close();
    }
  });

  it("20261206과 20261207 사이에 종류 검사(metric_events_type_check)를 다시 만드는 마이그레이션이 없다 (있으면 20261207의 '앞 목록'이 틀어진다)", () => {
    const strip = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
    const between = readdirSync(MIGRATIONS).filter((name) => name.endsWith(".sql") && name > D2_MIGRATION_NAME && name < MINE);
    expect(between, "20261206과 20261207 사이에 파일이 끼면 그 파일이 종류 검사를 건드리는지 본다").toEqual(between.filter((name) => !/metric_events_type_check/i.test(strip(readFileSync(path.join(MIGRATIONS, name), "utf8")))));
    // D2 파일 자신은 종류 검사를 만든다 (20261207의 '앞 목록'의 집)
    expect(strip(readFileSync(path.join(MIGRATIONS, D2_MIGRATION_NAME), "utf8"))).toMatch(/metric_events_type_check/i);
    // 20261204(session_attached까지)와 20261206 사이에도 종류 검사를 다시 만드는 파일이 없다: 20261206의 앞 목록은 20261204의 것이다
    const before = readdirSync(MIGRATIONS).filter((name) => name.endsWith(".sql") && name > "20261204000000_agent_session_attach.sql" && name < D2_MIGRATION_NAME);
    expect(before.filter((name) => /metric_events_type_check/i.test(strip(readFileSync(path.join(MIGRATIONS, name), "utf8"))))).toEqual([]);
  });

  it("실제 20261206 파일(PR-D2)이 claude_app_session_opened를 종류 검사에 더하고, 20261207의 새 목록이 그것을 이어 가져온다", () => {
    const d2 = readFileSync(path.join(MIGRATIONS, D2_MIGRATION_NAME), "utf8");
    expect(d2).toContain("claude_app_session_opened");
    expect(mineSql).toContain("claude_app_session_opened");
  });
});
