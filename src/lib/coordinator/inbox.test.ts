import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import {
  actionEventDedupKey,
  agentEventEnvelope,
  approvalDedupKey,
  bridgeUnreachableEnvelope,
  buildEnvelope,
  compareEventOrder,
  CONNECTED_TYPES,
  dependencyChangedEnvelope,
  memoryChangedDedupKey,
  messageDedupKey,
  PRODUCERS,
  replyObservedEnvelope,
  runStopDedupKey,
  sourceDedupKey,
  suggestionDecisionEnvelope,
  timerDedupKey,
  timerDueEpoch,
} from "./inbox";
import { envelopeSchema, EVIDENCE_KINDS, INBOX_EVENT_TYPES, RESULT_KINDS } from "./types";

const U = "11111111-0000-4000-8000-000000000001";
const A = "aaaaaaaa-0000-4000-8000-000000000001";
const R = "cccccccc-0000-4000-8000-000000000001";
const migration = readFileSync(path.resolve(__dirname, "../../../supabase/migrations/20261110000000_coordinator_core.sql"), "utf8");

describe("사건 봉투: id · 종류 토큰 · 숫자만 (글 없음)", () => {
  it("글이 든 refs · 알 수 없는 종류 · 너무 긴 키는 봉투가 되지 못한다", () => {
    const ok = { userId: U, type: "user_message" as const, dedupKey: "message:x", refs: { message_id: A } };
    expect(buildEnvelope(ok)).toEqual({ user_id: U, type: "user_message", dedup_key: "message:x", refs: { message_id: A } });
    expect(() => buildEnvelope({ ...ok, refs: { note: "회의에서 김대리가 금요일까지 보낸다고 함" } })).toThrow();
    expect(() => buildEnvelope({ ...ok, refs: { note: "Hello World" } })).toThrow();
    expect(() => buildEnvelope({ ...ok, refs: { nested: { a: A } } as never })).toThrow();
    expect(() => buildEnvelope({ ...ok, refs: { flag: true } as never })).toThrow();
    expect(() => buildEnvelope({ ...ok, type: "timer" as never })).toThrow();
    expect(() => buildEnvelope({ ...ok, dedupKey: "" })).toThrow();
    expect(() => buildEnvelope({ ...ok, dedupKey: "x".repeat(301) })).toThrow();
    expect(envelopeSchema.safeParse({ ...ok, user_id: "no" }).success).toBe(false);
  });

  it("TS 종류 목록 · 결과 종류는 SQL과 같다 (coordinator_event_types · result_kind CHECK)", () => {
    const sqlTypes = [...migration.match(/coordinator_event_types\(\)[^]*?select array\[([^\]]*)\]/)![1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
    expect([...INBOX_EVENT_TYPES].sort()).toEqual(sqlTypes.sort());
    const sqlResults = [...migration.match(/result_kind text check \(result_kind in \(([^)]*)\)/)![1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
    expect([...RESULT_KINDS].sort()).toEqual(sqlResults.sort());
    for (const evidence of EVIDENCE_KINDS) expect(evidence).toMatch(/^[a-z][a-z0-9_]{0,63}$/);
  });
});

describe("생산자 연결 표", () => {
  it("모든 종류에 연결 여부가 있고, 연결된 것은 지금 실제 성공 경로뿐이다 (원천 없는 종류는 envelope_only)", () => {
    expect(Object.keys(PRODUCERS).sort()).toEqual([...INBOX_EVENT_TYPES].sort());
    expect([...CONNECTED_TYPES].sort()).toEqual(["decision_made", "memory_changed", "source_processed", "source_revised", "timer_due", "user_message"]);
    for (const type of ["reply_observed", "agent_event", "dependency_changed", "connection_changed", "bridge_unreachable"] as const) {
      expect(PRODUCERS[type].status, type).toBe("envelope_only");
    }
  });
});

describe("dedup_key 규칙 (SQL 트리거 · 회수와 같다)", () => {
  it("규칙 문자열", () => {
    expect(sourceDedupKey(A)).toBe(`source:${A}`);
    expect(messageDedupKey(A)).toBe(`message:${A}`);
    expect(actionEventDedupKey(A)).toBe(`action_event:${A}`);
    expect(approvalDedupKey(A)).toBe(`approval:${A}`);
    expect(approvalDedupKey(A, true)).toBe(`approval_revoked:${A}`);
    expect(runStopDedupKey(R)).toBe(`run_stop:${R}`);
    expect(memoryChangedDedupKey(A, 4)).toBe(`memory_changed:${A}:4`);
    expect(timerDedupKey(A, new Date("2026-10-12T12:00:00.900Z"))).toBe(`timer:due_window:${A}:${Math.floor(new Date("2026-10-12T12:00:00Z").getTime() / 1000)}`);
  });

  it("timer 키에서 기한(epoch 초)을 되읽는다. 형식이 아니면 null", () => {
    const key = timerDedupKey(A, new Date("2026-10-12T12:00:00Z"));
    expect(timerDueEpoch(key)).toBe(Math.floor(new Date("2026-10-12T12:00:00Z").getTime() / 1000));
    expect(timerDueEpoch("timer:other")).toBeNull();
    expect(timerDueEpoch(`timer:due_window:${A}:abc`)).toBeNull();
  });

  it("SQL의 키 문자열과 TS 규칙이 같다 (마이그레이션 본문에 같은 접두사)", () => {
    for (const fragment of ["'source:' ||", "'message:' ||", "'action_event:' ||", "'approval:' ||", "'approval_revoked:' ||", "'run_stop:' ||", "'memory_changed:' ||", "'timer:due_window:' ||"]) {
      expect(migration, fragment).toContain(fragment);
    }
  });
});

describe("처리 순서: 쌓인 시각, 같은 시각이면 쌓인 순서", () => {
  it("compareEventOrder", () => {
    const e = (created_at: string, seq: number | string) => ({ created_at, seq });
    expect(compareEventOrder(e("2026-10-12T00:00:00Z", 2), e("2026-10-12T00:00:01Z", 1))).toBe(-1);
    expect(compareEventOrder(e("2026-10-12T00:00:00Z", 1), e("2026-10-12T00:00:00Z", 2))).toBe(-1);
    expect(compareEventOrder(e("2026-10-12T00:00:00Z", "10"), e("2026-10-12T00:00:00Z", 9))).toBe(1);
    expect(compareEventOrder(e("2026-10-12T00:00:00Z", 5), e("2026-10-12T00:00:00Z", 5))).toBe(0);
  });
});

describe("[미래 fixture] 아직 원천이 없는 생산자의 어댑터 — 봉투만 만들고 연결은 없다", () => {
  it("회신 관찰 · 에이전트 사건 · 의존 변화 · bridge · 제안 결정: 모두 id · 종류 토큰뿐이고 같은 입력은 같은 dedup_key", () => {
    const reply = replyObservedEnvelope({ userId: U, actionId: A, replySourceId: R, kind: "requirement_change" });
    expect(reply).toMatchObject({ type: "reply_observed", dedup_key: `reply:${R}`, refs: { action_id: A, reply_source_id: R, kind: "requirement_change" } });
    const agent = agentEventEnvelope({ userId: U, runId: R, sessionId: "sess-1", eventId: "evt_42", kind: "completed", directiveVersion: 2, resultRevision: 1 });
    expect(agent).toMatchObject({ type: "agent_event", dedup_key: "agent:sess-1:evt_42", refs: { run_id: R, kind: "completed", directive_version: 2, result_revision: 1 } });
    expect(agentEventEnvelope({ userId: U, runId: R, sessionId: "sess-1", eventId: "evt_42", kind: "completed" }).dedup_key).toBe(agent.dedup_key);
    expect(dependencyChangedEnvelope({ userId: U, actionId: A, dependencyId: R, state: "satisfied" })).toMatchObject({ type: "dependency_changed", refs: { kind: "satisfied" } });
    expect(bridgeUnreachableEnvelope({ userId: U, bridgeId: R, sinceEpochSeconds: 1_790_000_000 })).toMatchObject({ type: "bridge_unreachable" });
    expect(suggestionDecisionEnvelope({ userId: U, suggestionId: R, decision: "dismissed" })).toMatchObject({ type: "decision_made", refs: { kind: "suggestion_dismissed" } });
  });

  it("외부 id가 글이면(공백 · 한글) 거절: dedup_key에도 글이 새지 않는다", () => {
    expect(() => agentEventEnvelope({ userId: U, runId: R, sessionId: "세션 하나", eventId: "e", kind: "progress" })).toThrow();
    expect(() => agentEventEnvelope({ userId: U, runId: R, sessionId: "s", eventId: "a b", kind: "progress" })).toThrow();
  });
});
