import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { reviewDecisionsResponseSchema, reviewWithAgentsResponseSchema } from "@/lib/api/contract";

// OA R-dec U4: Mac 후속(Swift DTO)이 그대로 복사해 쓰는 JSON fixture. 서버가 내리는 모양 그대로 적고 스키마로 검증한다 — 한쪽을 고치면 `docs/review-summary.md` 1-1절 JSON 예도 함께 고친다.
// 응답에는 글이 없다 (질문 글 · 경로 · 이슈 제목은 앱이 RLS로 읽는다). 이 응답이 읽는 원천은 결정 하나라 `sources`에 `decisions`만 있다 —
// 읽지 않은 원천(suggestions · time_zone)을 상태로 적으면 거짓이라 키 자체가 없다. D4b-s의 `REVIEW_WITH_AGENTS_JSON`과 결정 묶음 모양은 같다.

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
  key: `${actionId}:${kind}`, action_id: actionId, kind, urgent, version: "0123456789abcdef", created_at: items[0].created_at,
  items: items.map((i) => ({ ...i, urgent, urgent_reason: urgent ? "due_window" : null })),
});
const agentRef = { task_id: TASK, session_id: SESSION, provider_request_id: "toolu-req-1", adapter: "agent:claude-code", bridge_id: BRIDGE };

const DECISIONS = [
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
];

/** GET /api/v2/review/decisions — 질문 셋 · 결과 준비 · 충돌 · confirm이 서버 순서로 든 응답 (긴급 → 오래 기다린 순 → 종류). 앱은 이 순서를 다시 매기지 않는다 */
export const REVIEW_DECISIONS_JSON = JSON.stringify({
  generated_at: "2026-10-15T02:00:00.000Z",
  complete: true,
  empty: false,
  sources: { decisions: "ok" },
  decisions: DECISIONS,
});

const parsed = () => JSON.parse(REVIEW_DECISIONS_JSON) as Record<string, unknown>;
const decisionsFixture = DECISIONS;

describe("U4 REVIEW_DECISIONS_JSON (Mac 후속이 복사하는 fixture)", () => {
  it("스키마를 통과하고, 읽은 값이 fixture와 같다 (조용히 바뀐 키가 없다)", () => {
    expect(reviewDecisionsResponseSchema.parse(parsed())).toEqual(parsed());
  });

  it("최상위 키는 정확히 다섯, sources 키는 정확히 하나다 (제안 · 시간대 키가 없다)", () => {
    expect(Object.keys(parsed()).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources"]);
    expect(Object.keys(parsed().sources as object)).toEqual(["decisions"]);
    expect(Object.keys(reviewDecisionsResponseSchema.shape).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources"]);
    expect(Object.keys(reviewDecisionsResponseSchema.shape.sources.shape)).toEqual(["decisions"]);
  });

  it("fixture에는 여섯 종류(질문 셋 · 결과 준비 · 충돌 · confirm)가 모두 있고 글이 없다", () => {
    const kinds = (parsed().decisions as { kind: string }[]).map((g) => g.kind);
    expect(kinds).toEqual(["agent_approval", "agent_question", "agent_secret_question", "result_ready", "path_conflict", "confirm"]);
    expect(REVIEW_DECISIONS_JSON).not.toMatch(/"(title|text|header|rel_path|summary|body)"/);
  });
});

describe("U4 strict: 이 응답에 없는 원천이 섞이면 스키마가 거절한다", () => {
  const withKey = (patch: (value: Record<string, unknown>) => void) => {
    const value = parsed();
    patch(value);
    return value;
  };
  const rejects: [string, Record<string, unknown>][] = [
    ["최상위 suggestions", withKey((v) => (v.suggestions = []))],
    ["최상위 suggestion_batch", withKey((v) => (v.suggestion_batch = { state: "ready", local_day: "2026-10-15", size: 3 }))],
    ["sources.suggestions", withKey((v) => ((v.sources as Record<string, unknown>).suggestions = "ok"))],
    ["sources.time_zone", withKey((v) => ((v.sources as Record<string, unknown>).time_zone = "ok"))],
    ["모르는 최상위 키", withKey((v) => (v.extra = 1))],
    ["sources.decisions 없음", withKey((v) => (v.sources = {}))],
    ["sources 없음", withKey((v) => delete v.sources)],
    ["decisions 키 없음 (null이어야 한다)", withKey((v) => delete v.decisions)],
    ["complete 없음", withKey((v) => delete v.complete)],
    ["empty 없음", withKey((v) => delete v.empty)],
    ["generated_at 없음", withKey((v) => delete v.generated_at)],
    ["모르는 원천 상태", withKey((v) => (v.sources = { decisions: "not_read" }))],
  ];
  it.each(rejects)("%s → 거절", (_name, value) => {
    expect(reviewDecisionsResponseSchema.safeParse(value).success).toBe(false);
  });

  it("D4b-s 모양(GET /api/v2/review: 제안 키와 시간대 원천이 있는 응답)을 새 스키마로 읽으면 거절한다", () => {
    const old = {
      generated_at: "2026-10-15T02:00:00.000Z", complete: true, empty: false, sources: { decisions: "ok", suggestions: "ok", time_zone: "ok" },
      decisions: decisionsFixture, suggestions: [], suggestion_batch: { state: "ready", local_day: "2026-10-15", size: 3 },
    };
    expect(reviewWithAgentsResponseSchema.safeParse(old).success).toBe(true); // 옛 모양 자체는 옛 스키마로 읽힌다 (이 fixture가 D4b-s 모양이다)
    expect(reviewDecisionsResponseSchema.safeParse(old).success).toBe(false);
  });

  it("그 decisions만 떼어 새 모양으로 감싸면 통과한다 (묶음 · 항목 스키마는 D4b-s 그대로)", () => {
    const wrapped = { generated_at: "2026-10-15T02:00:00.000Z", complete: true, empty: false, sources: { decisions: "ok" }, decisions: decisionsFixture };
    expect(reviewDecisionsResponseSchema.parse(wrapped).decisions).toEqual(decisionsFixture);
  });

  it("거꾸로, 새 모양을 옛 스키마로 읽으면 거절한다 (옛 클라이언트가 조용히 빈 제안으로 읽지 못한다)", () => {
    expect(reviewWithAgentsResponseSchema.safeParse(parsed()).success).toBe(false);
  });
});

describe("U4 못 읽음 · 빈 상태 모양", () => {
  it("원천을 못 읽은 응답: decisions null · unavailable · complete false · empty false", () => {
    const value = { generated_at: T, complete: false, empty: false, sources: { decisions: "unavailable" }, decisions: null };
    expect(reviewDecisionsResponseSchema.parse(value)).toEqual(value);
  });

  it("비어 있는 응답: decisions [] · complete true · empty true", () => {
    const value = { generated_at: T, complete: true, empty: true, sources: { decisions: "ok" }, decisions: [] };
    expect(reviewDecisionsResponseSchema.parse(value)).toEqual(value);
  });

  it("묶음 · 항목 안의 모르는 키도 에이전트 ref는 strict다 (글이 몰래 실리지 않는다)", () => {
    const value = parsed();
    ((value.decisions as { items: { agent?: Record<string, unknown> }[] }[])[1].items[0].agent as Record<string, unknown>).question_text = "글";
    expect(reviewDecisionsResponseSchema.safeParse(value).success).toBe(false);
  });
});

// ─── 기존 함수 본문 동일성 (T4) ───────────────────────────
// R-dec는 기존 함수를 고치지 않고 파일 끝에 덧붙인다. loadReview · handleGetReview · 기존 Review route의 글자를 origin/main b664d5a의 sha256과 견준다
// (loadReview의 동작은 golden 시험이 바이트로도 지킨다). 이 함수들을 일부러 고칠 때는 같은 PR에서 이 지문을 함께 바꾼다.
const ROOT = path.resolve(__dirname, "../..");
const textOf = (file: string) => readFileSync(path.join(ROOT, file), "utf8");
const sha256 = (text: string) => createHash("sha256").update(text).digest("hex");
/** header부터 그 함수를 닫는 첫 `}`(줄 시작)까지 */
function functionText(file: string, header: string) {
  const source = textOf(file);
  const start = source.indexOf(header);
  expect(start, `${file}에 ${header}가 없다`).toBeGreaterThanOrEqual(0);
  return source.slice(start, source.indexOf("\n}\n", start) + 3);
}

describe("T4 기존 함수 본문은 b664d5a와 같다 (덧붙임만 있다)", () => {
  it("loadReview (src/lib/review/review.ts)", () => {
    expect(sha256(functionText("src/lib/review/review.ts", "export async function loadReview("))).toBe("d545c14a2db5b4d8386c82c060a112da735172f90e85d692f2f0941ebb87d90b");
  });

  it("handleGetReview (src/lib/api/review.ts)", () => {
    expect(sha256(functionText("src/lib/api/review.ts", "export async function handleGetReview<"))).toBe("17d0b87734646f54fc043fcf946001512710a656174e1d42cb5f8b256d8d9cd4");
  });

  it("GET /api/v2/review route 파일 (src/app/api/v2/review/route.ts)", () => {
    expect(sha256(textOf("src/app/api/v2/review/route.ts"))).toBe("93b4db2f541c0f9ac68df9e2a62056879facd421eb636da086b1217f1de8837a");
  });

  it("새 읽기 함수 본문에는 제안 생산 · 노출 · 시간대 읽기 · loadReview 호출이 없다 (쓰기 길을 글자로도 막는다)", () => {
    const body = functionText("src/lib/review/review.ts", "export async function loadReviewDecisions(");
    for (const forbidden of ["loadReview(", "produceSuggestions", "exposeSuggestions", "loadUserTimeZone", "timeZone", "coordinatorEnabled", ".from("]) expect(body, forbidden).not.toContain(forbidden);
    expect(body).toContain("loadPendingDecisions(");
    expect(body).toContain("pendingGroupDto");
  });
});
