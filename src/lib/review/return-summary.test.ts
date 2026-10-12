import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { returnSummaryResponseSchema } from "@/lib/api/contract";
import { computePendingDecisions, type PendingInput } from "@/lib/coordinator/pending";

import { decodeCursor } from "./cursor";
import { buildReturnSummaryItems, composeReturnSummary, type ActionBasics, type ScanResult, type ScanWork } from "./return-summary";

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
  since: null, horizon: at(900), digest: "a:1:5|r:0:0|m:0:0", truncated: false, works, ...over,
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

  it("작업이 너무 많아 잘렸다 → truncated, empty 아님, 커서 없음 (일부만 보고 전체를 읽음 처리하지 않는다)", () => {
    const body = compose({ scan: scan([work(A, { changes: [change("merged", 1)] })], { truncated: true }) });
    expect(body).toMatchObject({ complete: false, empty: false, cursor: null, sources: { changes: "truncated" } });
    expect(body.items).toHaveLength(1);
  });

  it("커서는 사용자에 묶이고 조회가 낸 지평 · digest를 그대로 담는다 (시각 위치가 아니다). 한 번 Clear했으면 baseline cleared + since(표시용)", () => {
    const body = compose({ scan: scan([], { since: at(100), horizon: at(900), digest: "a:3:-7|r:0:0|m:0:0" }) });
    expect(body).toMatchObject({ baseline: "cleared", since: at(100) });
    expect(decodeCursor(body.cursor!, USER)).toEqual({ userId: USER, horizon: at(900), digest: "a:3:-7|r:0:0|m:0:0" });
    expect(decodeCursor(body.cursor!, "22222222-2222-4222-8222-222222222222")).toBeNull();
  });

  it("숫자를 내리지 않는다: 최상위 키에 개수 · 합계가 없다", () => {
    const keys = Object.keys(compose({ scan: scan([work(A, { changes: [change("merged", 1)] })]) })).sort();
    expect(keys).toEqual(["baseline", "complete", "cursor", "empty", "generated_at", "items", "since", "sources"]);
  });
});
