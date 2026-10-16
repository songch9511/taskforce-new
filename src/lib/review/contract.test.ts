import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import {
  pendingDecisionGroupSchema,
  pendingDecisionKindSchema,
  resolvePathConflictRequestSchema,
  resolvePathConflictResponseSchema,
  returnSummaryChangeSchema,
  returnSummaryItemSchema,
  returnSummaryResponseSchema,
  returnSummaryWithAgentsResponseSchema,
  reviewAgentRefSchema,
  reviewConflictRefSchema,
  reviewDecisionGroupSchema,
  reviewDecisionKindSchema,
  reviewResponseSchema,
  reviewResultRefSchema,
  reviewWithAgentsResponseSchema,
  suggestionKindSchema,
  suggestionSchema,
  suggestionSnoozeRequestSchema,
} from "@/lib/api/contract";
import { computePendingDecisions, PENDING_KINDS, type PendingInput } from "@/lib/coordinator/pending";

import { pendingGroupDto, suggestionDto } from "./dto";

// C3 JSON 계약의 서버 쪽 고정점 (Mac이 같은 JSON을 읽는다 — 한쪽을 고치면 notes의 "Mac에 넘기는 JSON 계약"도 고친다).

describe("C3 계약 일치", () => {
  it("결정 대기 종류: D4b-s 이후 reviewDecisionKindSchema가 pending.ts와 같고(순서까지), C3 종류(pendingDecisionKindSchema)는 그 앞부분 그대로다", () => {
    expect([...reviewDecisionKindSchema.options]).toEqual([...PENDING_KINDS]);
    expect([...reviewDecisionKindSchema.options].slice(0, pendingDecisionKindSchema.options.length)).toEqual([...pendingDecisionKindSchema.options]);
    expect([...reviewDecisionKindSchema.options].slice(pendingDecisionKindSchema.options.length)).toEqual(["agent_approval", "agent_secret_question", "result_ready", "path_conflict"]);
  });

  it("제안 종류는 마이그레이션이 만드는 세 가지뿐이다 (모르는 종류는 지어 보이지 않고 건너뛴다)", () => {
    expect([...suggestionKindSchema.options]).toEqual(["due_window", "run_failed", "source_revised_run"]);
    expect(suggestionDto({ id: "a5555555-5555-4555-8555-555555555555", kind: "from_the_future", action_id: "a6666666-6666-4666-8666-666666666666", state: "open", version: 1, urgent: false })).toBeNull();
  });

  it("변화 토큰은 이름 모양(소문자 · 숫자 · _)만, 시각은 마이크로초 UTC 글자만 받는다", () => {
    const good = { source: "action_event", kind: "due_changed", at: "2026-10-12T00:00:00.000123Z", detail: null, source_state: "available" };
    expect(returnSummaryChangeSchema.parse(good)).toEqual(good);
    for (const bad of [{ kind: "Due Changed" }, { kind: "한글" }, { at: "2026-10-12T00:00:00Z" }, { at: "2026-10-12T00:00:00.000123+00:00" }, { source: "inbox_event" }, { source_state: "gone" }]) {
      expect(returnSummaryChangeSchema.safeParse({ ...good, ...bad }).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("제안 snooze 요청: 시각은 오프셋이 있는 ISO만 (모호한 현지 시각은 받지 않는다), 알 수 없는 필드 거절", () => {
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00+09:00" }).success).toBe(true);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00Z" }).success).toBe(true);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00" }).success).toBe(false);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13" }).success).toBe(false);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00Z", extra: true }).success).toBe(false);
  });

  it("응답 모양의 필수 키 (Mac 디코딩 기준)", () => {
    expect(Object.keys(reviewResponseSchema.shape).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources", "suggestion_batch", "suggestions"]);
    expect(Object.keys(returnSummaryResponseSchema.shape).sort()).toEqual(["baseline", "complete", "cursor", "empty", "generated_at", "init_token", "items", "since", "sources"]);
    expect(Object.keys(returnSummaryItemSchema.shape).sort()).toEqual(["action_id", "changes", "decisions", "needs_answer", "next", "state", "status", "title", "urgent", "version"]);
    expect(Object.keys(suggestionSchema.shape).sort()).toEqual(["action_id", "created_at", "id", "kind", "offered_on", "run_id", "shown_at", "snooze_until", "state", "urgent", "version"]);
  });
});

// ─── D4b-s: 에이전트 입력이 붙은 Review · 복귀 요약 · 해소 계약 ────────────────────────────────────

const UUID = (n: number, prefix = "a") => `${prefix}0000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const NOW = new Date("2026-10-12T00:00:00Z");
const agentDetail = { task_id: UUID(1, "b"), session_id: UUID(2, "b"), provider_request_id: "req-1", adapter: "agent:codex", bridge_id: UUID(3, "b") };
const resultDetail = { session_id: UUID(2, "b"), reviewed_turn_seq: 1, last_turn_seq: 3, changed_at: "2026-10-11T05:00:00.000Z" };
const conflictDetail = { lease_id: UUID(1, "c"), conflict_version: 2, holder_action_id: UUID(7), holder_run_id: UUID(1, "d"), later_run_id: UUID(2, "d"), released: false, stopped: true };
const row = (over: Partial<PendingInput> & Pick<PendingInput, "kind" | "action_id" | "version">): PendingInput => ({ run_id: null, step_id: null, created_at: "2026-10-11T00:00:00Z", due_at: null, ...over });
const ALL_KIND_ROWS: PendingInput[] = [
  row({ kind: "confirm", action_id: UUID(1), version: "action:1:1" }),
  row({ kind: "agent_question", action_id: UUID(2), run_id: UUID(2, "d"), item_ref: UUID(1, "b"), version: "question:t:req-1", detail: agentDetail }),
  row({ kind: "agent_approval", action_id: UUID(3), run_id: UUID(2, "d"), item_ref: UUID(4, "b"), version: "question:t4:req-1", detail: { ...agentDetail, task_id: UUID(4, "b") } }),
  row({ kind: "agent_secret_question", action_id: UUID(4), run_id: UUID(2, "d"), item_ref: UUID(5, "b"), version: "question:t5:req-1", detail: { ...agentDetail, task_id: UUID(5, "b"), bridge_id: null } }),
  row({ kind: "result_ready", action_id: UUID(5), run_id: UUID(1, "d"), item_ref: UUID(1, "d"), version: "result:r:1:3:2", detail: resultDetail }),
  row({ kind: "path_conflict", action_id: UUID(6), run_id: UUID(2, "d"), item_ref: UUID(1, "c"), version: "conflict:l:2", detail: conflictDetail }),
];

describe("D4b-s 계약 일치", () => {
  const groups = computePendingDecisions({ rows: ALL_KIND_ROWS, now: NOW }).map(pendingGroupDto);
  const items = groups.flatMap((g) => g.items);

  it("Review 응답: 최상위 키는 C3 그대로이고, decisions만 에이전트 종류를 받는다", () => {
    expect(Object.keys(reviewWithAgentsResponseSchema.shape).sort()).toEqual(Object.keys(reviewResponseSchema.shape).sort());
    expect(Object.keys(reviewWithAgentsResponseSchema.shape.sources.shape).sort()).toEqual(["decisions", "suggestions", "time_zone"]);
    const body = {
      generated_at: NOW.toISOString(), complete: true, empty: false, sources: { decisions: "ok", suggestions: "ok", time_zone: "ok" }, decisions: groups, suggestions: [],
      suggestion_batch: { state: "ready", local_day: "2026-10-12", size: 3 },
    };
    expect(reviewWithAgentsResponseSchema.parse(body)).toEqual(body);
    expect(reviewResponseSchema.safeParse(body).success).toBe(false); // 옛 스키마는 새 종류를 모른다 (앱은 모르는 종류를 건너뛰고 complete를 믿지 않는다)
  });

  it("종류 ↔ ref: 새 종류는 자기 ref 하나만, C3 종류는 세 키가 모두 없다 (키 자체가 없다)", () => {
    const expected: Record<string, string[]> = {
      confirm: [], agent_question: ["agent"], agent_approval: ["agent"], agent_secret_question: ["agent"], result_ready: ["result"], path_conflict: ["conflict"],
    };
    expect(items).toHaveLength(Object.keys(expected).length);
    for (const item of items) expect((["agent", "result", "conflict"] as const).filter((key) => key in item), item.kind).toEqual(expected[item.kind]);
    expect(Object.keys(items.find((i) => i.kind === "confirm")!).sort()).toEqual(["action_id", "created_at", "id", "kind", "question_id", "run_id", "step_id", "urgent", "urgent_reason", "version"]);
    // C3 종류만 든 묶음은 옛 스키마로도 그대로 읽힌다
    const c3 = groups.find((g) => g.kind === "confirm")!;
    expect(pendingDecisionGroupSchema.parse(c3)).toEqual(c3);
    for (const group of groups) expect(reviewDecisionGroupSchema.parse(group)).toEqual(group);
  });

  it("ref 스키마는 엄격하다: 모르는 키(글이 실려 오는 길)와 틀린 값을 거절한다", () => {
    expect(reviewAgentRefSchema.safeParse({ ...agentDetail, text: "질문 글" }).success).toBe(false);
    expect(reviewAgentRefSchema.safeParse({ ...agentDetail, adapter: "codex" }).success).toBe(false);
    expect(reviewAgentRefSchema.safeParse({ ...agentDetail, provider_request_id: "" }).success).toBe(false);
    expect(reviewResultRefSchema.safeParse({ ...resultDetail, title: "제목" }).success).toBe(false);
    expect(reviewResultRefSchema.safeParse({ ...resultDetail, last_turn_seq: 0 }).success).toBe(false);
    expect(reviewConflictRefSchema.safeParse({ ...conflictDetail, rel_path: "/w/proj/a.mdx" }).success).toBe(false);
    expect(reviewConflictRefSchema.safeParse({ ...conflictDetail, conflict_version: 0 }).success).toBe(false);
  });

  it("복귀 요약: 최상위 키 · 줄 키는 C3 그대로, decisions[].kind와 next.decision_kinds만 새 종류를 받는다. Action id는 결정적 id라 UUID 버전 비트가 없어도 받는다", () => {
    expect(Object.keys(returnSummaryWithAgentsResponseSchema.shape).sort()).toEqual(Object.keys(returnSummaryResponseSchema.shape).sort());
    const body = {
      generated_at: NOW.toISOString(), since: null, baseline: "cleared", init_token: null, cursor: null, complete: true, empty: false, sources: { changes: "ok", decisions: "ok" },
      items: [{
        action_id: "d1b2c3d4-e5f6-0a7b-8c9d-0e1f2a3b4c5d", title: "견적서", status: "open", state: "to_do", needs_answer: true, urgent: false,
        decisions: [{ id: "agent_question:t", kind: "agent_question", version: "question:t:req-1", urgent: false }, { id: "result_ready:r", kind: "result_ready", version: "result:r:0:1:1", urgent: false }],
        changes: [], next: { kind: "answer", decision_kinds: ["agent_question", "result_ready"] }, version: "abc",
      }],
    };
    expect(returnSummaryWithAgentsResponseSchema.parse(body)).toEqual(body);
    expect(returnSummaryResponseSchema.safeParse(body).success).toBe(false);
  });

  it("해소 요청: keep과 정수 conflict_version(1 이상, DB integer 범위)만, 모르는 키는 거절한다", () => {
    expect(resolvePathConflictRequestSchema.parse({ keep: "holder", conflict_version: 1 })).toEqual({ keep: "holder", conflict_version: 1 });
    expect(resolvePathConflictRequestSchema.parse({ keep: "later", conflict_version: 2_147_483_647 })).toEqual({ keep: "later", conflict_version: 2_147_483_647 });
    for (const bad of [{}, { keep: "holder" }, { conflict_version: 1 }, { keep: "both", conflict_version: 1 }, { keep: "holder", conflict_version: 0 }, { keep: "holder", conflict_version: -1 }, { keep: "holder", conflict_version: 1.5 },
      { keep: "holder", conflict_version: "1" }, { keep: "holder", conflict_version: 2_147_483_648 }, { keep: "holder", conflict_version: 1, extra: true }, { keep: "holder", conflict_version: null }]) {
      expect(resolvePathConflictRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
    expect(resolvePathConflictResponseSchema.parse({ status: "resolved" })).toEqual({ status: "resolved" });
    expect(resolvePathConflictResponseSchema.safeParse({ status: "stale" }).success).toBe(false);
    expect(resolvePathConflictResponseSchema.safeParse({ status: "resolved", rel_path: "x" }).success).toBe(false);
  });
});
