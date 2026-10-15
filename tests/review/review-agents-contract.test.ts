import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import {
  answerAgentQuestionRequestSchema,
  apiErrorV2Schema,
  resolvePathConflictRequestSchema,
  resolvePathConflictResponseSchema,
  returnSummaryWithAgentsResponseSchema,
  reviewWithAgentsResponseSchema,
} from "@/lib/api/contract";

// OA D4b-s U11: D4b-m(Mac Swift DTO)이 그대로 복사해 쓰는 JSON fixture. 서버가 내리는 모양 그대로 적고 스키마로 검증한다 — 한쪽을 고치면 `docs/review-summary.md` JSON 계약 절도 함께 고친다.
// 응답에는 글이 없다: 질문 글 · 경로 · 이슈 번호는 앱이 RLS로 읽는다 (agent_tasks.pending_question · agent_path_leases.rel_path · actions.number).

const T = "2026-10-15T01:00:00.000Z";
const A = (n: number) => `a0000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const TASK = "b0000000-0000-4000-8000-000000000001";
const RUN = "d0000000-0000-4000-8000-000000000001";
const LEASE = "c0000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const BRIDGE = "b1000000-0000-4000-8000-000000000001";

const item = (kind: string, actionId: string, extra: Record<string, unknown>) => ({
  id: "", kind, action_id: actionId, run_id: RUN, step_id: null, question_id: null, version: "", urgent: false, urgent_reason: null, created_at: T, ...extra,
});
const group = (kind: string, actionId: string, items: ReturnType<typeof item>[], urgent = false) => ({
  key: `${actionId}:${kind}`, action_id: actionId, kind, urgent, version: "0123456789abcdef", created_at: items[0].created_at, items: items.map((i) => ({ ...i, urgent })),
});
const agentRef = { task_id: TASK, session_id: SESSION, provider_request_id: "toolu-req-1", adapter: "agent:claude-code", bridge_id: BRIDGE };

/** GET /api/v2/review — 다섯 종류가 서버 순서로 든 응답 (긴급 → 오래 기다린 순 → 종류). 앱은 이 순서를 다시 매기지 않는다 */
export const REVIEW_WITH_AGENTS_JSON = JSON.stringify({
  generated_at: "2026-10-15T02:00:00.000Z",
  complete: true,
  empty: false,
  sources: { decisions: "ok", suggestions: "ok", time_zone: "ok" },
  decisions: [
    group("agent_approval", A(1), [item("agent_approval", A(1), { id: `agent_approval:${TASK}`, version: `question:${TASK}:toolu-req-1`, agent: { ...agentRef, adapter: "agent:codex" } })], true),
    group("agent_question", A(2), [item("agent_question", A(2), { id: `agent_question:${TASK}`, version: `question:${TASK}:toolu-req-1`, agent: agentRef })]),
    group("agent_secret_question", A(3), [item("agent_secret_question", A(3), { id: `agent_secret_question:${TASK}`, version: `question:${TASK}:toolu-req-2`, agent: { ...agentRef, bridge_id: null } })]),
    group("result_ready", A(4), [item("result_ready", A(4), { id: `result_ready:${RUN}`, version: `result:${RUN}:0:3:2`, result: { session_id: SESSION, reviewed_turn_seq: 0, last_turn_seq: 3, changed_at: T } })]),
    group("path_conflict", A(5), [
      item("path_conflict", A(5), {
        id: `path_conflict:${LEASE}`, version: `conflict:${LEASE}:2`,
        conflict: { lease_id: LEASE, conflict_version: 2, holder_action_id: A(6), holder_run_id: RUN, later_run_id: RUN, released: false, stopped: true },
      }),
    ]),
    group("confirm", A(7), [item("confirm", A(7), { id: `confirm:${A(7)}`, run_id: null, version: `action:${A(7)}:3` })]),
  ],
  suggestions: [],
  suggestion_batch: { state: "ready", local_day: "2026-10-15", size: 3 },
});

/** GET /api/v2/return-summary — 질문이 있는 줄(answer)과 결과 준비만 있는 줄(review_result). decisions[].id/version은 Review 항목과 같다 */
export const RETURN_SUMMARY_WITH_AGENTS_JSON = JSON.stringify({
  generated_at: "2026-10-15T02:00:00.000Z",
  since: null,
  baseline: "cleared",
  init_token: null,
  cursor: "c3.AAAA",
  complete: true,
  empty: false,
  sources: { changes: "ok", decisions: "ok" },
  items: [
    {
      action_id: A(2), title: "견적서 보내기", status: "open", state: "in_progress", needs_answer: true, urgent: false,
      decisions: [{ id: `agent_question:${TASK}`, kind: "agent_question", version: `question:${TASK}:toolu-req-1`, urgent: false }],
      changes: [], next: { kind: "answer", decision_kinds: ["agent_question"] }, version: "0123456789abcdef",
    },
    {
      action_id: A(4), title: "가격표 고치기", status: "open", state: "in_progress", needs_answer: false, urgent: false,
      decisions: [{ id: `result_ready:${RUN}`, kind: "result_ready", version: `result:${RUN}:0:3:2`, urgent: false }],
      changes: [], next: { kind: "review_result", decision_kinds: ["result_ready"] }, version: "fedcba9876543210",
    },
  ],
});

/** POST /api/v2/path-conflicts/{lease_id}/resolve */
export const RESOLVE_REQUEST_JSON = JSON.stringify({ keep: "holder", conflict_version: 2 });
export const RESOLVE_RESPONSE_JSON = JSON.stringify({ status: "resolved" });
export const RESOLVE_STALE_409_JSON = JSON.stringify({ error: { code: "conflict", message: "그 사이 충돌이 바뀌었거나 이미 해소됐습니다. 다시 불러온 뒤 시도해 주세요." } });
/** Review 항목의 agent ref로 부르는 D1d 답 route: POST /api/v2/agent-tasks/{agent.task_id}/answer */
export const ANSWER_REQUEST_FROM_REVIEW_JSON = JSON.stringify({ provider_request_id: "toolu-req-1", answers: { choice: "Yes" } });

/** 응답 안의 모든 문자열 값: 글이 아니라 id · 토큰 · version · 시각이어야 한다 (공백이나 한글이 든 값이 없다) */
const strings = (value: unknown, skip = new Set<string>(), key = ""): string[] =>
  typeof value === "string" ? (skip.has(key) ? [] : [value]) : Array.isArray(value) ? value.flatMap((v) => strings(v, skip, key)) : value && typeof value === "object" ? Object.entries(value).flatMap(([k, v]) => strings(v, skip, k)) : [];

describe("D4b-m용 JSON fixture (스키마로 검증)", () => {
  it("Review 응답: 다섯 종류 + C3 종류, 종류마다 자기 ref 하나, 글 없음", () => {
    const parsed = reviewWithAgentsResponseSchema.parse(JSON.parse(REVIEW_WITH_AGENTS_JSON));
    expect(parsed.decisions!.map((g) => g.kind)).toEqual(["agent_approval", "agent_question", "agent_secret_question", "result_ready", "path_conflict", "confirm"]);
    const refs = parsed.decisions!.flatMap((g) => g.items).map((i) => [i.kind, (["agent", "result", "conflict"] as const).filter((k) => k in i)]);
    expect(refs).toEqual([["agent_approval", ["agent"]], ["agent_question", ["agent"]], ["agent_secret_question", ["agent"]], ["result_ready", ["result"]], ["path_conflict", ["conflict"]], ["confirm", []]]);
    for (const text of strings(JSON.parse(REVIEW_WITH_AGENTS_JSON))) expect(text, text).toMatch(/^[A-Za-z0-9:_.\-+]+$/);
    // 스키마는 값을 바꾸지 않는다 (모르는 키가 있었다면 여기서 달라진다)
    expect(parsed).toEqual(JSON.parse(REVIEW_WITH_AGENTS_JSON));
  });

  it("복귀 요약 줄: answer(질문) · review_result(결과 준비만). 제목 외에는 글이 없다", () => {
    const parsed = returnSummaryWithAgentsResponseSchema.parse(JSON.parse(RETURN_SUMMARY_WITH_AGENTS_JSON));
    expect(parsed.items.map((i) => [i.needs_answer, i.next.kind, i.next.decision_kinds])).toEqual([[true, "answer", ["agent_question"]], [false, "review_result", ["result_ready"]]]);
    for (const text of strings(JSON.parse(RETURN_SUMMARY_WITH_AGENTS_JSON), new Set(["title"]))) expect(text, text).toMatch(/^[A-Za-z0-9:_.\-+]+$/);
  });

  it("복귀 요약 줄의 decisions[].id/version은 Review 항목과 같다", () => {
    const review = reviewWithAgentsResponseSchema.parse(JSON.parse(REVIEW_WITH_AGENTS_JSON));
    const items = new Map(review.decisions!.flatMap((g) => g.items).map((i) => [i.id, i]));
    for (const line of returnSummaryWithAgentsResponseSchema.parse(JSON.parse(RETURN_SUMMARY_WITH_AGENTS_JSON)).items) {
      for (const decision of line.decisions) expect([decision.kind, decision.version]).toEqual([items.get(decision.id)!.kind, items.get(decision.id)!.version]);
    }
  });

  it("해소 요청 · 응답 · 409 본문", () => {
    expect(resolvePathConflictRequestSchema.parse(JSON.parse(RESOLVE_REQUEST_JSON))).toEqual({ keep: "holder", conflict_version: 2 });
    expect(resolvePathConflictResponseSchema.parse(JSON.parse(RESOLVE_RESPONSE_JSON))).toEqual({ status: "resolved" });
    const error = apiErrorV2Schema.parse(JSON.parse(RESOLVE_STALE_409_JSON));
    expect(error.error.code).toBe("conflict");
    // Review 항목의 conflict_version이 그대로 요청에 간다
    const review = reviewWithAgentsResponseSchema.parse(JSON.parse(REVIEW_WITH_AGENTS_JSON));
    const conflict = review.decisions!.flatMap((g) => g.items).find((i) => i.kind === "path_conflict")!.conflict!;
    expect(resolvePathConflictRequestSchema.parse({ keep: "later", conflict_version: conflict.conflict_version })).toEqual({ keep: "later", conflict_version: 2 });
    expect(`/api/v2/path-conflicts/${conflict.lease_id}/resolve`).toBe(`/api/v2/path-conflicts/${LEASE}/resolve`);
  });

  it("Review 항목의 agent ref로 부르는 D1d 답 요청 모양", () => {
    expect(answerAgentQuestionRequestSchema.parse(JSON.parse(ANSWER_REQUEST_FROM_REVIEW_JSON))).toEqual({ provider_request_id: "toolu-req-1", answers: { choice: "Yes" } });
    const review = reviewWithAgentsResponseSchema.parse(JSON.parse(REVIEW_WITH_AGENTS_JSON));
    const asked = review.decisions!.flatMap((g) => g.items).find((i) => i.kind === "agent_question")!;
    expect(JSON.parse(ANSWER_REQUEST_FROM_REVIEW_JSON).provider_request_id).toBe(asked.agent!.provider_request_id);
  });
});
