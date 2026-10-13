import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { D1B_MIGRATION, conversationAgentTargetTests } from "./conversation-agent-target.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 대화 대상과 에이전트 글 (20261114000000_conversation_agent_target, 구현 계획 D1b) — PGlite.
// 같은 시나리오를 실제 Postgres로: tests/pg/conversation-agent-target.test.ts (동시성 T10 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("대화 대상과 에이전트 글 (PGlite)", () => {
  conversationAgentTargetTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 마이그레이션 파일 자체의 경계 (주석을 뺀 SQL): 대화 두 표의 열 · 제약 · 트리거와 서버 함수뿐이다 — 실행 입구 · 도구 · 스위치 · 지표 · 에이전트 표에 쓰지 않는다
describe("마이그레이션 파일이 건드리는 것", () => {
  const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", D1B_MIGRATION), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

  it("한 트랜잭션이고 lock_timeout 바로 뒤에 두 대화 표의 잠금을 정해진 순서(대화 → 메시지)로 한꺼번에 잡는다 (begin … commit)", () => {
    const body = sql.trim();
    expect(body.startsWith("begin;")).toBe(true);
    expect(body.endsWith("commit;")).toBe(true);
    expect((body.match(/^begin;$/gm) ?? []).length).toBe(1);
    expect((body.match(/^commit;$/gm) ?? []).length).toBe(1);
    const order = ["begin;", "set local lock_timeout = '5s';", "lock table public.conversations, public.conversation_messages in access exclusive mode;"].map((statement) => body.indexOf(statement));
    expect(order.every((index) => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    // 잠금 문장 다음이 첫 변경이다 (그 사이에 다른 문장이 없다)
    expect(body.slice(order[2]).split("\n")[0]).toBe("lock table public.conversations, public.conversation_messages in access exclusive mode;");
  });

  it("함수: 서버 함수 둘 + 트리거 함수 둘을 새로 만들고, 기존 셋(post_message · coordinator_on_user_message · coordinator_recover_missing)만 시그니처 그대로 교체한다", () => {
    expect([...sql.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1]).sort()).toEqual([
      "conversation_append_agent_message",
      "conversation_expire_agent_messages",
      "conversation_messages_target_guard",
      "conversations_agent_target_guard",
    ]);
    expect([...sql.matchAll(/create or replace function public\.([a-z_]+)/g)].map((m) => m[1]).sort()).toEqual([
      "conversation_post_message",
      "coordinator_on_user_message",
      "coordinator_recover_missing",
    ]);
    // 이 묶음이 건드리지 않는 함수 · 표 (D1c-1 · D1d 몫)
    expect(sql).not.toMatch(/conversation_finish_turn|conversation_release_lease|create_run|append_step|begin_call|prepare_step|approve_step|settle_step|stop_run|finish_run/);
    expect(sql).not.toMatch(/execution_(tools|controls)|metric_events|credit_/);
  });

  it("에이전트 표 · 실행 표 · 지표에 쓰지 않는다 (읽기만). 새 표도 없다. 고치는 표는 conversations · conversation_messages뿐이다", () => {
    expect(sql).not.toMatch(/(insert into|update|delete from|truncate|create table)\s+public\.(agent_[a-z_]+|bridges|execution_[a-z_]+|metric_events)/);
    expect(sql).not.toMatch(/create table/i);
    // 사건함(inbox_events)에 쓰는 곳은 회수 함수 한 곳(coordinator_core 정의를 옮긴 세 insert)뿐이다 — 나머지 함수는 사건함에 쓰지 않는다
    const recover = sql.match(/create or replace function public\.coordinator_recover_missing[\s\S]*?\n\$\$;/)?.[0] ?? "";
    expect(recover).not.toBe("");
    expect([...sql.matchAll(/(insert into|update|delete from)\s+public\.inbox_events/g)]).toHaveLength(3);
    expect([...recover.matchAll(/insert into public\.inbox_events/g)]).toHaveLength(3);
    expect([...new Set([...sql.matchAll(/alter table public\.([a-z_]+)/g)].map((m) => m[1]))].sort()).toEqual(["conversation_messages", "conversations"]);
    expect(sql).not.toMatch(/alter table public\.(agent_|bridges|execution_)/);
  });

  it("권한: 서버 함수는 service_role만, 앱 권한은 늘리지 않는다 (grant to authenticated · anon 없음)", () => {
    expect(sql).not.toMatch(/grant [^;]*\bto\b[^;]*\b(authenticated|anon|public)\b/i);
    expect(sql).not.toMatch(/grant (insert|update|delete|all|select)\b/i);
    for (const signature of [
      "conversation_append_agent_message(uuid, uuid, uuid, integer, text, text, text)",
      "conversation_expire_agent_messages(timestamptz)",
    ]) {
      expect(sql).toContain(`revoke all on function public.${signature} from public, anon, authenticated;`);
      expect(sql).toContain(`grant execute on function public.${signature} to service_role;`);
    }
  });
});
