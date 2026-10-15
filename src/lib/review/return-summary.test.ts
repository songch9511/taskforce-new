import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { returnSummaryResponseSchema } from "@/lib/api/contract";
import { computePendingDecisions, type PendingInput } from "@/lib/coordinator/pending";

import { decodeCursor } from "./cursor";
import { decodeInitToken } from "./init-token";
import { buildReturnSummaryItems, composeReturnSummary, scanResultSchema, type ActionBasics, type ScanResult, type ScanWork } from "./return-summary";

// 복귀 요약 계산 (순수): SQL 스캔 결과 + C2 결정 대기 → 응답. DB 없이 의미만 시험한다 (DB 쪽은 tests/db/review-summary.scenarios.ts, 연결은 tests/review).

const USER = "11111111-1111-4111-8111-111111111111";
const A = "a1111111-1111-4111-8111-111111111111";
const B = "a2222222-2222-4222-8222-222222222222";
const C = "a3333333-3333-4333-8333-333333333333";
const NOW = new Date("2026-10-12T09:00:00Z");
const at = (micro: number) => `2026-10-12T00:00:00.${String(micro).padStart(6, "0")}Z`;

const work = (id: string, over: Partial<ScanWork> = {}): ScanWork => ({
  action_id: id, title: `제목 ${id.slice(0, 2)}`, status: "open", started: false, last_user_at: null, changes: [], ...over,
});
const change = (kind: string, micro: number, over: Partial<ScanWork["changes"][number]> = {}): ScanWork["changes"][number] => ({
  source: "action_event", kind, at: at(micro), detail: null, source_state: "available", ...over,
});
const scan = (works: ScanWork[], over: Partial<ScanResult> = {}): ScanResult => ({
  since: null, horizon: at(900), digest: "a:1:5|r:0:0|m:0:0", truncated: false, page: null, baseline: true, baseline_state: "never_cleared", init_digest: "a:0:0|r:2:-9|m:1:4", works, ...over,
});
const pendingRow = (over: Partial<PendingInput> = {}): PendingInput => ({
  kind: "confirm", action_id: A, run_id: null, step_id: null, version: "action:A:1", created_at: "2026-10-11T00:00:00Z", due_at: null, ...over,
});
const groups = (rows: PendingInput[]) => computePendingDecisions({ rows, now: NOW });
const basics = (...items: ActionBasics[]) => new Map(items.map((b) => [b.id, b]));

describe("buildReturnSummaryItems: changed.ts 의미 (사용자 자기 수정은 변화가 아니다)", () => {
  it("사용자가 마지막으로 손댄 뒤의 변화만 남는다 (같은 밀리초는 본 것). 본 뒤 변화가 없으면 줄이 없다", () => {
    const items = buildReturnSummaryItems({
      works: [
        work(A, { last_user_at: at(2_000), changes: [change("due_changed", 1_000), change("merged", 2_000), change("owner_changed", 3_000)] }),
        work(B, { last_user_at: at(5_000), changes: [change("due_changed", 1_000), change("completed", 4_999)] }),
      ],
      pending: [],
      basics: basics(),
    });
    // A: 1.000ms · 2.000ms는 본 것(마이크로초 2000은 같은 2ms), 3.000ms만 남음 / B: 모두 본 것 → 줄 없음
    expect(items.map((i) => [i.action_id, i.changes.map((c) => c.kind)])).toEqual([[A, ["owner_changed"]]]);
  });

  it("사용자가 마지막으로 본 시각이 없으면 처음부터 본다 (changed.ts: 본 적이 없으면 AI가 만든 뒤 바뀐 적이 있으면 바뀜)", () => {
    const items = buildReturnSummaryItems({ works: [work(A, { changes: [change("due_changed", 10), change("merged", 20)] })], pending: [], basics: basics() });
    expect(items[0].changes.map((c) => c.kind)).toEqual(["due_changed", "merged"]);
  });

  it("run · 메시지 변화는 SQL이 읽음 기준으로 이미 걸렀으므로 사용자 손길로 다시 거르지 않는다 (사용자가 수정해도 결과 도착은 변화다)", () => {
    const items = buildReturnSummaryItems({
      works: [
        work(A, {
          last_user_at: at(9_999),
          changes: [change("due_changed", 100), change("done", 5_000, { source: "run", detail: "draft_ready", source_state: null }), change("event", 6_000, { source: "message", source_state: null })],
        }),
      ],
      pending: [],
      basics: basics(),
    });
    expect(items[0].changes.map((c) => `${c.source}:${c.kind}`)).toEqual(["run:done", "message:event"]);
  });

  it("변화는 시각 → 원천 → 종류 순으로 안정 정렬된다 (입력 순서와 무관)", () => {
    const changes = [change("merged", 30), change("done", 10, { source: "run", source_state: null }), change("due_changed", 10)];
    const forward = buildReturnSummaryItems({ works: [work(A, { changes })], pending: [], basics: basics() });
    const reverse = buildReturnSummaryItems({ works: [work(A, { changes: [...changes].reverse() })], pending: [], basics: basics() });
    expect(forward[0].changes.map((c) => c.kind)).toEqual(["due_changed", "done", "merged"]);
    expect(reverse).toEqual(forward);
  });

  it("원문 상태 토큰은 그대로 전달하고, 응답에 글 · 옛 제목 · 변경 전후 값이 없다 (지금 제목 하나뿐)", () => {
    const items = buildReturnSummaryItems({
      works: [work(A, { title: "지금 제목", changes: [change("due_changed", 1, { source_state: "deleted" }), change("merged", 2, { source_state: "access_lost" }), change("scope_changed", 3, { source_state: "text_expired" })] })],
      pending: [],
      basics: basics(),
    });
    expect(items[0].changes.map((c) => c.source_state)).toEqual(["deleted", "access_lost", "text_expired"]);
    expect(Object.keys(items[0]).sort()).toEqual(["action_id", "changes", "decisions", "needs_answer", "next", "state", "status", "title", "urgent", "version"]);
    expect(Object.keys(items[0].changes[0]).sort()).toEqual(["at", "detail", "kind", "source", "source_state"]);
  });
});

describe("buildReturnSummaryItems: 필요한 결정 · Next · 숫자 없음", () => {
  it("변화가 없어도 답할 결정이 있는 작업은 줄이 있다 (Needs your answer). 읽음은 결정을 지우지 않는다", () => {
    const items = buildReturnSummaryItems({
      works: [work(A, { last_user_at: at(9_000), changes: [change("due_changed", 1)] })],
      pending: groups([pendingRow({ action_id: A })]),
      basics: basics(),
    });
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ action_id: A, changes: [], needs_answer: true, next: { kind: "answer", decision_kinds: ["confirm"] } });
  });

  it("스캔에 없는 작업의 결정은 지금 제목으로 줄을 만든다. 이름을 댈 수 없는 작업(방금 지워짐)은 줄을 지어내지 않는다", () => {
    const items = buildReturnSummaryItems({
      works: [],
      pending: groups([pendingRow({ action_id: B, version: "action:B:1" }), pendingRow({ action_id: C, version: "action:C:1" })]),
      basics: basics({ id: B, title: "견적서 보내기", status: "open", started: true }),
    });
    expect(items.map((i) => [i.action_id, i.title, i.state, i.needs_answer])).toEqual([[B, "견적서 보내기", "in_progress", true]]);
  });

  it("긴급한 결정이 있는 줄이 맨 앞, 그다음 답할 결정, 그다음 최근 변화 순 (안정 순서)", () => {
    const urgentRow = pendingRow({ action_id: B, version: "action:B:1", due_at: "2026-10-12T10:00:00Z" });
    const calmRow = pendingRow({ action_id: A, version: "action:A:1" });
    const items = buildReturnSummaryItems({
      works: [
        work(C, { changes: [change("completed", 9_000)] }),
        work(A, { changes: [change("merged", 1_000)] }),
        work(B, { changes: [change("due_changed", 500)] }),
      ],
      pending: groups([urgentRow, calmRow]),
      basics: basics(),
    });
    expect(items.map((i) => i.action_id)).toEqual([B, A, C]);
    expect(items[0].urgent).toBe(true);
    expect(items[1].urgent).toBe(false);
  });

  it("Next: 결정이 있으면 answer(종류 목록), 끝난 결과(draft_ready)가 있으면 review_result, 아니면 open", () => {
    const done = change("done", 5, { source: "run", detail: "draft_ready", source_state: null });
    const needsInput = change("done", 6, { source: "run", detail: "needs_input", source_state: null });
    const items = buildReturnSummaryItems({
      works: [work(A, { changes: [done] }), work(B, { changes: [needsInput] }), work(C, { changes: [change("merged", 1)] })],
      pending: groups([
        pendingRow({ kind: "approval", action_id: B, run_id: "b0000000-0000-4000-8000-000000000001", step_id: "b0000000-0000-4000-8000-000000000002", version: "step:s:1:1" }),
        pendingRow({ kind: "run_input", action_id: B, run_id: "b0000000-0000-4000-8000-000000000001", version: "run:r:needs_input" }),
      ]),
      basics: basics(),
    });
    const byId = Object.fromEntries(items.map((i) => [i.action_id, i.next]));
    expect(byId[A]).toEqual({ kind: "review_result", decision_kinds: [] });
    expect(byId[B]).toEqual({ kind: "answer", decision_kinds: ["approval", "run_input"] });
    expect(byId[C]).toEqual({ kind: "open", decision_kinds: [] });
  });

  it("StatusMark 세 상태만: 할 일 · 진행 중 · 완료. 취소는 null", () => {
    const items = buildReturnSummaryItems({
      works: [
        work(A, { status: "open", started: false, changes: [change("merged", 1)] }),
        work(B, { status: "open", started: true, changes: [change("merged", 2)] }),
        work(C, { status: "done", changes: [change("completed", 3)] }),
        work("a4444444-4444-4444-8444-444444444444", { status: "dropped", changes: [change("dropped", 4)] }),
      ],
      pending: [],
      basics: basics(),
    });
    expect(Object.fromEntries(items.map((i) => [i.title.slice(-2), i.state]))).toEqual({ a1: "to_do", a2: "in_progress", a3: "done", a4: null });
  });

  it("줄의 version은 내용이 바뀌면 달라지고 같으면 같다 (stable)", () => {
    const make = (kind: string, version: string) =>
      buildReturnSummaryItems({ works: [work(A, { changes: [change(kind, 1)] })], pending: groups([pendingRow({ version })]), basics: basics() })[0].version;
    expect(make("merged", "action:A:1")).toBe(make("merged", "action:A:1"));
    expect(make("merged", "action:A:1")).not.toBe(make("completed", "action:A:1"));
    expect(make("merged", "action:A:1")).not.toBe(make("merged", "action:A:2"));
  });
});

// ─── D4b-s: 에이전트 결정(질문 · 결과 준비 · 경로 충돌)이 있는 줄 ────────────────────────────────────

const TASK = "b0000000-0000-4000-8000-000000000001";
const RUN = "d0000000-0000-4000-8000-000000000001";
const LEASE = "c0000000-0000-4000-8000-000000000001";
const SESSION = "b0000000-0000-4000-8000-000000000002";
const askedRow = (kind: "agent_question" | "agent_approval" | "agent_secret_question", over: Partial<PendingInput> = {}): PendingInput => ({
  kind, action_id: A, run_id: RUN, step_id: null, question_id: null, item_ref: TASK, version: `question:${TASK}:req-1`, created_at: "2026-10-11T00:00:00Z", due_at: null,
  detail: { task_id: TASK, session_id: SESSION, provider_request_id: "req-1", adapter: "agent:codex", bridge_id: null }, ...over,
});
const resultRow = (over: Partial<PendingInput> = {}): PendingInput => ({
  kind: "result_ready", action_id: A, run_id: RUN, step_id: null, question_id: null, item_ref: RUN, version: `result:${RUN}:0:2:2`, created_at: "2026-10-11T01:00:00Z", due_at: null,
  detail: { session_id: SESSION, reviewed_turn_seq: 0, last_turn_seq: 2, changed_at: "2026-10-11T02:00:00Z" }, ...over,
});
const conflictRow = (over: Partial<PendingInput> = {}): PendingInput => ({
  kind: "path_conflict", action_id: A, run_id: RUN, step_id: null, question_id: null, item_ref: LEASE, version: `conflict:${LEASE}:1`, created_at: "2026-10-11T03:00:00Z", due_at: null,
  detail: { lease_id: LEASE, conflict_version: 1, holder_action_id: B, holder_run_id: RUN, later_run_id: RUN, released: false, stopped: false }, ...over,
});

describe("buildReturnSummaryItems: 에이전트 결정 (D4b-s)", () => {
  const build = (rows: PendingInput[], works: ScanWork[] = []) =>
    buildReturnSummaryItems({ works, pending: groups(rows), basics: basics({ id: A, title: "견적서 보내기", status: "open", started: true }) })[0];

  it("에이전트 결정만 있는 Action도 줄이 있다 (제목 · 상태): 질문은 답할 것이라 needs_answer · next=answer", () => {
    for (const kind of ["agent_question", "agent_approval", "agent_secret_question"] as const) {
      const item = build([askedRow(kind)]);
      expect(item, kind).toMatchObject({ action_id: A, title: "견적서 보내기", state: "in_progress", changes: [], needs_answer: true, next: { kind: "answer", decision_kinds: [kind] } });
      expect(item.decisions, kind).toEqual([{ id: `${kind}:${TASK}`, kind, version: `question:${TASK}:req-1`, urgent: false }]);
    }
  });

  it("경로 충돌도 답할 것이다 (해소해야 한다): needs_answer · next=answer", () => {
    expect(build([conflictRow()])).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["path_conflict"] }, decisions: [{ id: `path_conflict:${LEASE}`, kind: "path_conflict", version: `conflict:${LEASE}:1` }] });
  });

  it("결과 준비만 있으면 답할 것이 아니라 검토할 것이다: needs_answer false · next=review_result (결정은 줄에 그대로 실린다)", () => {
    const item = build([resultRow()]);
    expect(item.needs_answer).toBe(false);
    expect(item.next).toEqual({ kind: "review_result", decision_kinds: ["result_ready"] });
    expect(item.decisions).toEqual([{ id: `result_ready:${RUN}`, kind: "result_ready", version: `result:${RUN}:0:2:2`, urgent: false }]);
  });

  it("결과 준비와 질문이 함께 있으면 질문이 이긴다: needs_answer true · next=answer, decision_kinds는 있는 종류 전부(종류 순서)", () => {
    const item = build([resultRow(), conflictRow(), askedRow("agent_approval")]);
    expect(item.needs_answer).toBe(true);
    expect(item.next).toEqual({ kind: "answer", decision_kinds: ["agent_approval", "result_ready", "path_conflict"] });
    expect(item.decisions.map((d) => d.kind)).toEqual(["agent_approval", "result_ready", "path_conflict"]);
  });

  it("C3 종류만 있는 줄은 이전과 같은 값이다 (needs_answer · next · decision_kinds)", () => {
    const withDecision = build([pendingRow({ action_id: A })]);
    expect(withDecision).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["confirm"] } });
    const none = buildReturnSummaryItems({ works: [work(A, { changes: [change("merged", 1)] })], pending: [], basics: basics() })[0];
    expect(none).toMatchObject({ needs_answer: false, next: { kind: "open", decision_kinds: [] }, decisions: [] });
  });

  it("긴급(기한 창 안)은 에이전트 결정에도 그대로 적용된다. 답할 줄이 결과만 있는 줄보다 앞이다", () => {
    const items = buildReturnSummaryItems({
      works: [],
      pending: groups([resultRow({ action_id: A }), askedRow("agent_question", { action_id: B, item_ref: "b0000000-0000-4000-8000-000000000009", detail: { task_id: "b0000000-0000-4000-8000-000000000009", session_id: SESSION, provider_request_id: "r", adapter: "agent:codex", bridge_id: null } })]),
      basics: basics({ id: A, title: "A 일", status: "open", started: false }, { id: B, title: "B 일", status: "open", started: false }),
    });
    expect(items.map((i) => [i.action_id, i.needs_answer])).toEqual([[B, true], [A, false]]);
  });

  it("run 변화(draft_ready)만 있는 줄의 next는 그대로 review_result이고 decision_kinds는 비어 있다", () => {
    const done = change("done", 5, { source: "run", detail: "draft_ready", source_state: null });
    const item = buildReturnSummaryItems({ works: [work(A, { changes: [done] })], pending: [], basics: basics() })[0];
    expect(item.next).toEqual({ kind: "review_result", decision_kinds: [] });
  });
});

// 결정적 Action id(start_agent_turn이 sha256에서 만든다)는 UUID 버전 · variant 비트가 없다: SQL 스캔 결과의 Action id를 z.uuid()로 거절하면 복귀 요약 변화 원천 전체가 unavailable이 된다.
describe("scanResultSchema: 결정적 Action id를 받는다", () => {
  const DETERMINISTIC = "d1b2c3d4-e5f6-0a7b-8c9d-0e1f2a3b4c5d"; // 버전 비트 0, variant 비트 0
  const raw = (over: Record<string, unknown> = {}) => ({
    since: null, horizon: at(900), digest: "a:1:5|r:0:0|m:0:0", truncated: false, page: null, baseline: true, baseline_state: "never_cleared", init_digest: null,
    works: [{ action_id: DETERMINISTIC, title: "t", status: "open", started: false, last_user_at: null, changes: [] }], ...over,
  });

  it("works[].action_id", () => {
    expect(scanResultSchema.parse(raw()).works[0].action_id).toBe(DETERMINISTIC);
  });

  it("page[] (잘린 조회의 Clear 범위)", () => {
    expect(scanResultSchema.parse(raw({ truncated: true, page: [DETERMINISTIC] })).page).toEqual([DETERMINISTIC]);
  });

  it("그래도 UUID 모양이 아닌 글자는 거절한다", () => {
    expect(scanResultSchema.safeParse(raw({ works: [{ action_id: "not-an-id", title: "t", status: "open", started: false, last_user_at: null, changes: [] }] })).success).toBe(false);
    expect(scanResultSchema.safeParse(raw({ truncated: true, page: ["x"] })).success).toBe(false);
  });
});

describe("composeReturnSummary: 완전성 표시 (일부를 못 읽으면 비었다고 하지 않는다)", () => {
  const compose = (over: { scan?: ScanResult | null; pending?: ReturnType<typeof groups> | null }) =>
    composeReturnSummary({ now: NOW, userId: USER, scan: over.scan === undefined ? scan([]) : over.scan, pending: over.pending === undefined ? [] : over.pending, basics: basics() });

  it("모든 원천을 읽었고 잘리지 않았고 줄이 없을 때만 empty다", () => {
    const body = compose({});
    expect(body).toMatchObject({ complete: true, empty: true, baseline: "never_cleared", since: null, sources: { changes: "ok", decisions: "ok" } });
    expect(body.cursor).not.toBeNull();
    expect(returnSummaryResponseSchema.parse(body)).toEqual(body);
  });

  it("변화 원천을 못 읽었다 → unavailable, 비었다고 하지 않고(empty false) 커서도 없다 (Clear 불가)", () => {
    const body = compose({ scan: null });
    expect(body).toMatchObject({ complete: false, empty: false, baseline: "unknown", cursor: null, sources: { changes: "unavailable", decisions: "ok" } });
  });

  it("결정 대기를 못 읽었다 → unavailable, 비었다고 하지 않는다. 변화는 그대로 보이고 Clear는 된다", () => {
    const body = compose({ scan: scan([work(A, { changes: [change("merged", 1)] })]), pending: null });
    expect(body).toMatchObject({ complete: false, empty: false, sources: { changes: "ok", decisions: "unavailable" } });
    expect(body.items).toHaveLength(1);
    expect(body.cursor).not.toBeNull();
  });

  it("작업이 너무 많아 잘렸다 → truncated · complete false · empty false, 그래도 커서가 있다: 보인 작업(page)만 가리킨다 (P2-C)", () => {
    const body = compose({ scan: scan([work(A, { changes: [change("merged", 1)] })], { truncated: true, page: [A], baseline: false }) });
    expect(body).toMatchObject({ complete: false, empty: false, sources: { changes: "truncated" } });
    expect(body.items).toHaveLength(1);
    expect(decodeCursor(body.cursor!, USER)).toEqual({ userId: USER, horizon: at(900), digest: "a:1:5|r:0:0|m:0:0", page: [A], baseline: false });
  });

  it("잘리지 않았으면 커서에 작업 id를 싣지 않는다 (후보 전부가 범위). 잘렸는데 page가 없으면(있을 수 없는 응답) 커서를 내지 않는다", () => {
    expect(decodeCursor(compose({ scan: scan([], { page: [A] }) }).cursor!, USER)?.page).toBeNull();
    expect(compose({ scan: scan([], { truncated: true, page: null }) }).cursor).toBeNull();
  });

  it("커서는 사용자에 묶이고 조회가 낸 지평 · digest를 그대로 담는다 (시각 위치가 아니다). 한 번 Clear했으면 baseline cleared + since(표시용)", () => {
    const body = compose({ scan: scan([], { since: at(100), horizon: at(900), digest: "a:3:-7|r:0:0|m:0:0", baseline_state: "cleared", init_digest: null }) });
    expect(body).toMatchObject({ baseline: "cleared", since: at(100) });
    expect(decodeCursor(body.cursor!, USER)).toEqual({ userId: USER, horizon: at(900), digest: "a:3:-7|r:0:0|m:0:0", page: null, baseline: true });
    expect(decodeCursor(body.cursor!, "22222222-2222-4222-8222-222222222222")).toBeNull();
  });

  it("init_token: 기준점이 없고(never_cleared) 변화 원천을 읽었을 때만 나온다 — 빈 첫 화면 · 잘린 첫 화면 포함. 지평 · 기준점 범위 digest를 싣는다", () => {
    const empty = compose({});
    expect(empty).toMatchObject({ empty: true, baseline: "never_cleared" });
    expect(decodeInitToken(empty.init_token!, USER)).toEqual({ userId: USER, horizon: at(900), digest: "a:0:0|r:2:-9|m:1:4" });
    const truncated = compose({ scan: scan([work(A, { changes: [change("merged", 1)] })], { truncated: true, page: [A], baseline: true }) });
    expect(truncated.init_token).not.toBeNull();
    // 토큰은 Clear 커서가 아니고 커서는 토큰이 아니다
    expect(decodeInitToken(truncated.cursor!, USER)).toBeNull();
    expect(decodeCursor(truncated.init_token!, USER)).toBeNull();
  });

  it("init_token은 읽기에 실패했거나(unknown) 이미 기준점이 있거나(initialized) Clear한 적이 있으면(cleared) null이다", () => {
    expect(compose({ scan: null })).toMatchObject({ baseline: "unknown", init_token: null });
    expect(compose({ scan: scan([], { baseline_state: "initialized", baseline: false, init_digest: null }) })).toMatchObject({ baseline: "initialized", since: null, init_token: null });
    expect(compose({ scan: scan([], { baseline_state: "cleared", since: at(100), baseline: false, init_digest: null }) })).toMatchObject({ baseline: "cleared", init_token: null });
  });

  it("결정 대기만 못 읽었어도(변화는 정상) 토큰은 나온다: 토큰 조건은 변화 원천이다", () => {
    expect(compose({ pending: null })).toMatchObject({ complete: false, sources: { changes: "ok", decisions: "unavailable" } });
    expect(compose({ pending: null }).init_token).not.toBeNull();
  });

  it("숫자를 내리지 않는다: 최상위 키에 개수 · 합계가 없다", () => {
    const keys = Object.keys(compose({ scan: scan([work(A, { changes: [change("merged", 1)] })]) })).sort();
    expect(keys).toEqual(["baseline", "complete", "cursor", "empty", "generated_at", "init_token", "items", "since", "sources"]);
  });
});
