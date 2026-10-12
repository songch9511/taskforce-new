import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { C1_MIGRATION, executionAdditiveTests, executionUpgradeTests } from "./execution-additive-contract.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";
import { freshPgliteForEachTest } from "./fresh-pglite";

// 0.2.0 실행 additive 확장 (20261109000000_execution_additive_contract, 구현 계획 C1) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/execution-additive-contract.test.ts (동시성 포함).
// 실행기가 새 goal · 단계 종류를 fail closed로 다루는 것은 tests/db/execution-additive-executor.test.ts.
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("실행 additive 확장 (PGlite)", () => {
  executionAdditiveTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 업그레이드 회귀는 새 PGlite를 마이그레이션 중간까지만 만든다 (위의 db와 따로)
const freshDb = freshPgliteForEachTest();
executionUpgradeTests(async () => {
  const fresh = await freshDb(); // 마이그레이션 전 상태에서 시작하는 시험: initdb만 된 빈 클러스터를 복제하고, 시험이 끝나면 닫는다
  return {
    exec: (sql) => fresh.exec(sql),
    query: async (sql, params) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});

// 마이그레이션 파일 자체의 경계 (주석을 뺀 SQL): 다시 만드는 함수는 셋뿐이고, 판단 함수 · 도구 · 스위치 · 산출물 · 이벤트 표는 건드리지 않는다
describe("마이그레이션 파일이 건드리는 것", () => {
  const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", C1_MIGRATION), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

  it("만들거나 바꾸는 함수는 create_run · append_step · 연결별 정책 보호 트리거 셋뿐이다 (begin_call · prepare_step · approval_hash · auto_allowed · 승인 함수는 그대로)", () => {
    const defined = [...sql.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1]).sort();
    expect(defined).toEqual(["append_step", "create_run", "execution_connection_policies_guard"]);
    expect(sql).not.toMatch(/begin_call|prepare_step|approval_hash|auto_allowed|approve_step|show_plan|revoke_approval|settle_step|complete_internal_step/);
  });

  it("도구 · 스위치 · 실행 주체 · 허용 목록 · 승인 · intent · 이벤트 · 산출물 · 크레딧 표에 쓰지도 고치지도 않는다 (append_step이 효과 종류를 정하려고 도구 목록을 읽는 것은 예전 그대로)", () => {
    expect(sql).not.toMatch(/(insert into|update|delete from|alter table|drop table|truncate|create table)\s+public\.(execution_(tools|controls|actors|recipient_allowlist|approvals|intents|events|artifacts|usage)|credit_[a-z]+)/);
    expect(sql).not.toMatch(/credit_/);
    expect([...sql.matchAll(/execution_(tools|controls|actors|recipient_allowlist|approvals|intents|events|artifacts|usage)/g)].map((m) => m[0])).toEqual(["execution_tools"]);
  });

  it("고치는 기존 표는 execution_runs · execution_steps 둘이고 새 표는 execution_connection_policies 하나뿐이다", () => {
    expect([...new Set([...sql.matchAll(/alter table public\.([a-z_]+)/g)].map((m) => m[1]))].sort()).toEqual(["execution_connection_policies", "execution_runs", "execution_steps"]);
    expect([...sql.matchAll(/create table public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["execution_connection_policies"]);
  });
});
