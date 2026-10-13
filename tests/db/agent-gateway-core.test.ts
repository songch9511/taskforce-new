import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { D1A_MIGRATION, agentGatewayCoreTests, agentGatewayUpgradeTests } from "./agent-gateway-core.scenarios";
import { freshPgliteForEachTest } from "./fresh-pglite";
import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 에이전트 게이트웨이 저장 계약 (20261113000000_agent_gateway_core, 구현 계획 D1a) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/agent-gateway-core.test.ts (동시성 포함).
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("에이전트 게이트웨이 저장 계약 (PGlite)", () => {
  agentGatewayCoreTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 업그레이드 회귀는 새 PGlite를 마이그레이션 중간까지만 만든다 (위의 db와 따로)
const freshDb = freshPgliteForEachTest();
agentGatewayUpgradeTests(async () => {
  const fresh = await freshDb(); // 마이그레이션 전 상태에서 시작하는 시험: initdb만 된 빈 클러스터를 복제하고, 시험이 끝나면 닫는다
  return {
    exec: (sql) => fresh.exec(sql),
    query: async (sql, params) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});

// 마이그레이션 파일 자체의 경계 (주석을 뺀 SQL): 저장 계약뿐이다 — 함수 · 실행 입구 · 도구 · 스위치를 만들지도 고치지도 않는다
describe("마이그레이션 파일이 건드리는 것", () => {
  const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", D1A_MIGRATION), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

  it("한 트랜잭션이고 lock_timeout 바로 뒤에 기존 실행 표의 잠금을 정해진 순서로 한꺼번에 잡는다 (begin … commit)", () => {
    const statements = sql.split(";").map((statement) => statement.trim()).filter(Boolean);
    expect(statements[0]).toBe("begin");
    expect(statements[1]).toBe("set local lock_timeout = '5s'");
    // 교착 없이 빨리 실패하려고: 새 표를 만들기 전에, 실행기 · sweep과 같은 순서(runs → steps → events)로
    expect(statements[2]).toBe("lock table public.execution_runs, public.execution_steps, public.execution_events in access exclusive mode");
    expect(statements.at(-1)).toBe("commit");
    expect(statements.filter((statement) => statement === "begin" || statement === "commit")).toHaveLength(2);
  });

  it("함수를 만들지도 바꾸지도 않는다 (create_run · append_step · begin_call · 승인 함수 · 실행기가 부르는 함수는 그대로)", () => {
    expect(sql).not.toMatch(/create (or replace )?function|alter function|drop function|create (or replace )?procedure/i);
    expect(sql).not.toMatch(/create_run|append_step|begin_call|prepare_step|approval_hash|auto_allowed|approve_step|show_plan|revoke_approval|settle_step|complete_internal_step|stop_run|finish_run/);
  });

  it("도구 · 스위치 · 실행 주체 · 허용 목록 · 승인 · intent · 산출물 · 크레딧 표에 쓰지도 고치지도 않는다", () => {
    expect(sql).not.toMatch(/(insert into|update|delete from|alter table|drop table|truncate|create table)\s+public\.(execution_(tools|controls|actors|recipient_allowlist|approvals|intents|artifacts|usage|policies|steps|connection_policies)|credit_[a-z]+)/);
    expect(sql).not.toMatch(/credit_/);
    expect(sql).not.toMatch(/\b(insert into|delete from|truncate)\b/i);
  });

  it("새 표는 네 개(bridges · agent_connections · agent_sessions · agent_tasks)이고, 고치는 기존 표는 execution_runs · execution_events 둘뿐이다", () => {
    expect([...sql.matchAll(/create table public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["bridges", "agent_connections", "agent_sessions", "agent_tasks"]);
    expect([...new Set([...sql.matchAll(/alter table public\.([a-z_]+)/g)].map((m) => m[1]))].sort()).toEqual(["execution_events", "execution_runs"]);
    // 이 묶음에 없는 표 (D1b · D2a · D3c)
    expect(sql).not.toMatch(/bridge_commands|agent_path_leases|alter table public\.(conversations|conversation_messages|context_members)/);
  });

  it("앱 권한: 새 표 넷은 owner_all 정책 + select 권한뿐이다 (insert · update · delete를 주지 않는다)", () => {
    expect(sql).toMatch(/foreach t in array array\['bridges', 'agent_connections', 'agent_sessions', 'agent_tasks'\]/);
    expect(sql).toMatch(/revoke all on public\.%I from anon, authenticated/);
    expect(sql).toMatch(/grant select on public\.%I to authenticated/);
    expect(sql).not.toMatch(/grant (insert|update|delete|all)/i);
  });
});
