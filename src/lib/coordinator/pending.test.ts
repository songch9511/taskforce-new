import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { URGENT_WINDOW_HOURS } from "./coordinator.config";
import { computePendingDecisions, loadPendingDecisions, matchPendingVersion, PENDING_KINDS, urgency, type FutureInputs, type PendingInput } from "./pending";

// 결정 대기 목록 계산 (A39, 런타임 계약 6장). 순수 함수 시험. [현재 실제] 원천(승인 · run 결과 · 확인 요청)은 tests/coordinator/pending.test.ts가 실제 DB로 본다.
// [미래 fixture] 열린 제안 · 막힌 의존은 원천 표가 없어 입력 타입으로만 만든다. 에이전트 입력(질문 · 결과 준비 · 경로 충돌, OA D4b-s)은 review_agent_inputs가 준다 — 아래 [D4b-s] 절.

const NOW = new Date("2026-10-12T00:00:00Z");
const id = (n: number, prefix = "aaaaaaaa") => `${prefix}-0000-4000-8000-${String(n).padStart(12, "0")}`;
const hours = (h: number) => new Date(NOW.getTime() + h * 3_600_000).toISOString();
const row = (over: Partial<PendingInput> & Pick<PendingInput, "kind" | "action_id" | "version">): PendingInput => ({
  run_id: null,
  step_id: null,
  created_at: "2026-10-11T00:00:00Z",
  due_at: null,
  ...over,
});

describe("긴급: 기한이 긴급 창(24시간) 안이거나 다른 작업을 막음", () => {
  it("기한이 24시간 안 · 이미 지남은 긴급, 24시간 밖 · 없음은 아니다. 다른 작업을 막으면 기한과 상관없이 긴급", () => {
    expect(urgency({ due_at: hours(URGENT_WINDOW_HOURS), blocks_other_work: false }, NOW)).toEqual({ urgent: true, reason: "due_window" });
    expect(urgency({ due_at: hours(1), blocks_other_work: false }, NOW).urgent).toBe(true);
    expect(urgency({ due_at: hours(-30), blocks_other_work: false }, NOW).urgent).toBe(true);
    expect(urgency({ due_at: hours(URGENT_WINDOW_HOURS + 1), blocks_other_work: false }, NOW)).toEqual({ urgent: false, reason: null });
    expect(urgency({ due_at: null, blocks_other_work: false }, NOW)).toEqual({ urgent: false, reason: null });
    expect(urgency({ due_at: hours(300), blocks_other_work: true }, NOW)).toEqual({ urgent: true, reason: "blocks_other_work" });
  });
});

describe("묶음: 같은 (action_id, kind)는 한 묶음", () => {
  it("같은 업무의 승인 둘은 한 묶음, 종류가 다르면 따로, 업무가 다르면 따로", () => {
    const groups = computePendingDecisions({
      now: NOW,
      rows: [
        row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), run_id: id(1, "cccccccc"), version: "step:a:1:1", created_at: "2026-10-11T01:00:00Z" }),
        row({ kind: "approval", action_id: id(1), step_id: id(2, "bbbbbbbb"), run_id: id(1, "cccccccc"), version: "step:b:1:1", created_at: "2026-10-11T02:00:00Z" }),
        row({ kind: "confirm", action_id: id(1), version: "action:a:3", created_at: "2026-10-11T03:00:00Z" }),
        row({ kind: "approval", action_id: id(2), step_id: id(3, "bbbbbbbb"), version: "step:c:1:1", created_at: "2026-10-11T04:00:00Z" }),
      ],
    });
    expect(groups.map((g) => [g.key.split(":")[1], g.actionId, g.items.length])).toEqual([
      ["approval", id(1), 2],
      ["confirm", id(1), 1],
      ["approval", id(2), 1],
    ]);
  });

  it("긴급 묶음이 먼저(일일 묶음을 기다리지 않는다), 같으면 오래 기다린 묶음 먼저. 입력 순서와 상관없이 같은 결과(안정 순서)", () => {
    const rows = [
      row({ kind: "confirm", action_id: id(1), version: "v1", created_at: "2026-10-01T00:00:00Z", due_at: hours(300) }),
      row({ kind: "confirm", action_id: id(2), version: "v1", created_at: "2026-10-05T00:00:00Z", due_at: hours(5) }),
      row({ kind: "approval", action_id: id(3), step_id: id(3, "bbbbbbbb"), version: "v1", created_at: "2026-10-03T00:00:00Z", due_at: hours(2) }),
      row({ kind: "run_input", action_id: id(4), run_id: id(4, "cccccccc"), version: "v1", created_at: "2026-10-02T00:00:00Z" }),
    ];
    const first = computePendingDecisions({ rows, now: NOW });
    expect(first.map((g) => g.actionId)).toEqual([id(3), id(2), id(1), id(4)]);
    expect(first.map((g) => g.urgent)).toEqual([true, true, false, false]);
    for (const shuffled of [[...rows].reverse(), [rows[2], rows[0], rows[3], rows[1]]]) {
      expect(computePendingDecisions({ rows: shuffled, now: NOW })).toEqual(first);
    }
  });

  it("묶음이 긴급이면 항목 중 하나라도 긴급일 때다", () => {
    const groups = computePendingDecisions({
      now: NOW,
      rows: [
        row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), version: "a", due_at: hours(100) }),
        row({ kind: "approval", action_id: id(1), step_id: id(2, "bbbbbbbb"), version: "b", due_at: hours(2) }),
      ],
    });
    expect(groups).toHaveLength(1);
    expect(groups[0].urgent).toBe(true);
    // 항목마다 자기 긴급 여부를 가진다 (실제로는 같은 Action이라 기한이 같다): 묶음은 하나라도 긴급이면 긴급
    expect(groups[0].items.map((i) => i.urgent).sort()).toEqual([false, true]);
  });
});

describe("처리된 항목은 version 불일치로 사라진다 (다른 기기에서 처리 · 삭제, C10)", () => {
  const before = () => computePendingDecisions({ now: NOW, rows: [row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), version: "step:a:1:1" }), row({ kind: "confirm", action_id: id(2), version: "action:b:4" })] });

  it("같은 id · 같은 version이면 current, id는 같은데 version이 달라졌으면 stale, 목록에 없으면 gone", () => {
    const list = before();
    expect(matchPendingVersion(list, { itemId: `approval:${id(1, "bbbbbbbb")}`, version: "step:a:1:1" })).toBe("current");
    expect(matchPendingVersion(list, { itemId: `approval:${id(1, "bbbbbbbb")}`, version: "step:a:0:1" })).toBe("stale");
    expect(matchPendingVersion(list, { itemId: `confirm:${id(2)}`, version: "action:b:3" })).toBe("stale");
    expect(matchPendingVersion(list, { itemId: `confirm:${id(9)}`, version: "action:b:4" })).toBe("gone");
  });

  it("다른 기기에서 하나를 처리하면(입력에서 빠짐) 새 계산에 그 항목이 없고 묶음 version이 바뀐다. 나머지는 그대로", () => {
    const a = before();
    const b = computePendingDecisions({ now: NOW, rows: [row({ kind: "confirm", action_id: id(2), version: "action:b:4" })] });
    expect(matchPendingVersion(b, { itemId: `approval:${id(1, "bbbbbbbb")}`, version: "step:a:1:1" })).toBe("gone");
    expect(matchPendingVersion(b, { itemId: `confirm:${id(2)}`, version: "action:b:4" })).toBe("current");
    expect(a.find((g) => g.kind === "confirm")!.version).toBe(b.find((g) => g.kind === "confirm")!.version);
  });

  it("묶음 version은 항목 version이 하나라도 바뀌거나 빠지면 달라진다 (열린 묶음 화면이 낡았음을 알 수 있다)", () => {
    const two = (v: string) => [row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), version: "a" }), row({ kind: "approval", action_id: id(1), step_id: id(2, "bbbbbbbb"), version: v })];
    const base = computePendingDecisions({ now: NOW, rows: two("b") })[0].version;
    expect(computePendingDecisions({ now: NOW, rows: two("c") })[0].version).not.toBe(base);
    expect(computePendingDecisions({ now: NOW, rows: two("b").slice(0, 1) })[0].version).not.toBe(base);
    expect(computePendingDecisions({ now: NOW, rows: [...two("b")].reverse() })[0].version).toBe(base);
  });
});

describe("[미래 fixture] 아직 원천이 없는 종류: 입력 타입으로만 섞는다 (연결되지 않았다)", () => {
  it("에이전트 질문(실제 입력 행) · 열린 제안 · 긴급 창의 막힌 의존이 같은 업무에 동시에 생겨도 (action, kind)로 묶이고, 막는 의존은 긴급이다", () => {
    const future: FutureInputs = {
      openSuggestions: [row({ kind: "suggestion", action_id: id(1), question_id: null, version: "sg-1", created_at: "2026-10-11T06:00:00Z" })],
      blockedDependencies: [row({ kind: "blocked_dependency", action_id: id(1), version: "dep-1", created_at: "2026-10-11T07:00:00Z", due_at: hours(3), blocks_other_work: true })],
    };
    const groups = computePendingDecisions({
      now: NOW,
      rows: [
        row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), version: "step:a:1:1", created_at: "2026-10-11T04:00:00Z" }),
        row({ kind: "confirm", action_id: id(1), version: "action:a:2", created_at: "2026-10-11T03:00:00Z" }),
        agentRow("agent_question", { action_id: id(1), created_at: "2026-10-11T05:00:00Z" }),
      ],
      future,
    });
    expect(groups.map((g) => g.kind)).toEqual(["blocked_dependency", "confirm", "approval", "agent_question", "suggestion"]);
    expect(groups[0]).toMatchObject({ urgent: true });
    expect(groups.slice(1).every((g) => !g.urgent)).toBe(true);
    expect(groups.find((g) => g.kind === "agent_question")!.items[0].agent).toMatchObject({ task_id: TASK });
  });
});

// ─── [D4b-s] 에이전트 입력: 질문 셋 · 결과 준비 · 경로 충돌 ────────────────────────────────────────

const TASK = "c0000000-0000-4000-8000-000000000001";
const RUN = "d0000000-0000-4000-8000-000000000001";
const LEASE = "e0000000-0000-4000-8000-000000000001";
const SESSION = "f0000000-0000-4000-8000-000000000001";
type AgentKind = "agent_question" | "agent_approval" | "agent_secret_question" | "result_ready" | "path_conflict";
const DETAIL: Record<AgentKind, Record<string, unknown>> = {
  agent_question: { task_id: TASK, session_id: SESSION, provider_request_id: "req-1", adapter: "agent:codex", bridge_id: null },
  agent_approval: { task_id: TASK, session_id: SESSION, provider_request_id: "req-1", adapter: "agent:codex", bridge_id: SESSION },
  agent_secret_question: { task_id: TASK, session_id: SESSION, provider_request_id: "req-1", adapter: "agent:claude-code", bridge_id: SESSION },
  result_ready: { session_id: SESSION, reviewed_turn_seq: 0, last_turn_seq: 2, changed_at: "2026-10-11T05:30:00.123456+00:00" },
  path_conflict: { lease_id: LEASE, conflict_version: 1, holder_action_id: id(9), holder_run_id: RUN, later_run_id: RUN, released: false, stopped: false },
};
const REF: Record<AgentKind, string> = { agent_question: TASK, agent_approval: TASK, agent_secret_question: TASK, result_ready: RUN, path_conflict: LEASE };
/** review_agent_inputs 한 행이 가는 PendingInput (item_ref가 항목 열쇠, step_id · question_id는 null) */
const agentRow = (kind: AgentKind, over: Partial<PendingInput> = {}): PendingInput => ({
  kind, action_id: id(1), run_id: RUN, step_id: null, question_id: null, item_ref: REF[kind], version: `${kind}:v1`, created_at: "2026-10-11T05:00:00Z", due_at: null, detail: DETAIL[kind], ...over,
});

describe("[D4b-s] 에이전트 종류의 항목: id · ref · 묶음 · 순서", () => {
  it("종류 순서: C3 종류가 앞 그대로이고 에이전트 종류 넷이 끝에 덧붙는다", () => {
    expect([...PENDING_KINDS]).toEqual([
      "approval", "review_failed", "run_input", "confirm", "agent_question", "suggestion", "blocked_dependency", "agent_approval", "agent_secret_question", "result_ready", "path_conflict",
    ]);
  });

  it("항목 id는 `${kind}:${item_ref}` (task · run · lease). step_id · question_id는 null이고 ref는 자기 종류에만 붙는다", () => {
    const groups = computePendingDecisions({ now: NOW, rows: (Object.keys(DETAIL) as AgentKind[]).map((kind, i) => agentRow(kind, { action_id: id(i + 1) })) });
    const items = groups.flatMap((g) => g.items);
    expect(items.map((i) => i.id).sort()).toEqual([`agent_approval:${TASK}`, `agent_question:${TASK}`, `agent_secret_question:${TASK}`, `path_conflict:${LEASE}`, `result_ready:${RUN}`].sort());
    for (const item of items) {
      expect([item.stepId, item.questionId]).toEqual([null, null]);
      const refs = (["agent", "result", "conflict"] as const).filter((key) => key in item);
      const expected = item.kind === "result_ready" ? ["result"] : item.kind === "path_conflict" ? ["conflict"] : ["agent"];
      expect(refs, item.kind).toEqual(expected);
    }
    expect(items.find((i) => i.kind === "result_ready")!.result).toMatchObject({ reviewed_turn_seq: 0, last_turn_seq: 2, changed_at: "2026-10-11T05:30:00.123Z" });
  });

  it("C2 종류 항목에는 ref 키 자체가 없다 (JSON이 C3 그대로)", () => {
    const [group] = computePendingDecisions({ now: NOW, rows: [row({ kind: "confirm", action_id: id(1), version: "action:a:1" })] });
    expect(Object.keys(group.items[0]).sort()).toEqual(["actionId", "createdAt", "id", "kind", "questionId", "runId", "stepId", "urgent", "urgentReason", "version"]);
    expect(group.items[0].id).toBe(`confirm:${id(1)}`);
  });

  it("묶음 = (Action, 종류): 같은 Action의 질문 종류가 달라도 따로, 다른 Action의 같은 종류도 따로", () => {
    const task2 = "c0000000-0000-4000-8000-000000000002";
    const groups = computePendingDecisions({
      now: NOW,
      rows: [
        agentRow("agent_question"),
        agentRow("agent_question", { item_ref: task2, detail: { ...DETAIL.agent_question, task_id: task2 }, created_at: "2026-10-11T05:10:00Z" }),
        agentRow("agent_approval", { created_at: "2026-10-11T05:20:00Z", item_ref: "c0000000-0000-4000-8000-000000000003", detail: { ...DETAIL.agent_approval, task_id: "c0000000-0000-4000-8000-000000000003" } }),
        agentRow("agent_question", { action_id: id(2), item_ref: "c0000000-0000-4000-8000-000000000004", detail: { ...DETAIL.agent_question, task_id: "c0000000-0000-4000-8000-000000000004" } }),
      ],
    });
    expect(groups.map((g) => [g.actionId, g.kind, g.items.length])).toEqual([[id(1), "agent_question", 2], [id(2), "agent_question", 1], [id(1), "agent_approval", 1]]);
  });

  it("순서: 긴급 묶음 → 오래 기다린 묶음 → 종류 → Action id. 새 종류에 새 긴급 이유는 없다 (기한 창만)", () => {
    const rows = [
      agentRow("path_conflict", { action_id: id(1), created_at: "2026-10-11T00:00:00Z" }),
      agentRow("result_ready", { action_id: id(2), created_at: "2026-10-11T00:00:00Z" }),
      agentRow("agent_question", { action_id: id(3), created_at: "2026-10-11T00:00:00Z" }),
      agentRow("agent_approval", { action_id: id(4), created_at: "2026-10-12T00:00:00Z", due_at: hours(5) }),
      row({ kind: "confirm", action_id: id(5), version: "action:5:1", created_at: "2026-10-09T00:00:00Z" }),
    ];
    const groups = computePendingDecisions({ rows, now: NOW });
    // 긴급(approval, 기한 5시간) → 가장 오래된 confirm → 같은 시각 셋은 종류 순서(agent_question < result_ready < path_conflict)
    expect(groups.map((g) => g.kind)).toEqual(["agent_approval", "confirm", "agent_question", "result_ready", "path_conflict"]);
    expect(groups.map((g) => g.urgent)).toEqual([true, false, false, false, false]);
    expect(groups[0].items[0].urgentReason).toBe("due_window");
    for (const shuffled of [[...rows].reverse(), [rows[3], rows[0], rows[4], rows[2], rows[1]]]) expect(computePendingDecisions({ rows: shuffled, now: NOW })).toEqual(groups);
  });

  it("묶음 version은 에이전트 항목 version이 바뀌면 달라진다", () => {
    const first = computePendingDecisions({ now: NOW, rows: [agentRow("agent_question", { version: "question:t:req-1" })] })[0];
    const second = computePendingDecisions({ now: NOW, rows: [agentRow("agent_question", { version: "question:t:req-2" })] })[0];
    expect(first.version).not.toBe(second.version);
  });

  it("ref 모양이 틀리면 계산이 throw한다: 빠진 detail · 틀린 타입 · 모르는 키 · 다른 종류의 ref", () => {
    const bad: Partial<PendingInput>[] = [
      { detail: undefined },
      { detail: { ...DETAIL.agent_question, task_id: "not-a-guid" } },
      { detail: { ...DETAIL.agent_question, extra: "x" } },
      { detail: { ...DETAIL.agent_question, adapter: "claude" } },
      { detail: DETAIL.result_ready },
    ];
    for (const over of bad) expect(() => computePendingDecisions({ now: NOW, rows: [agentRow("agent_question", over)] }), JSON.stringify(over)).toThrow();
    expect(() => computePendingDecisions({ now: NOW, rows: [agentRow("result_ready", { detail: { ...DETAIL.result_ready, last_turn_seq: 0 } })] })).toThrow();
    expect(() => computePendingDecisions({ now: NOW, rows: [agentRow("result_ready", { detail: { ...DETAIL.result_ready, changed_at: "not a time" } })] })).toThrow();
    expect(() => computePendingDecisions({ now: NOW, rows: [agentRow("path_conflict", { detail: { ...DETAIL.path_conflict, conflict_version: 0 } })] })).toThrow();
  });
});

describe("[D4b-s] version 대조 (ONE-TF-03 서버 몫): 질문 교체 · 답함 · 충돌 재발생 · 해소", () => {
  const listOf = (rows: PendingInput[]) => computePendingDecisions({ now: NOW, rows });
  const questionItem = `agent_question:${TASK}`;

  it("같은 task의 질문이 교체되면 같은 id에 다른 version이라 옛 화면은 stale이다", () => {
    const old = { itemId: questionItem, version: `question:${TASK}:req-1` };
    expect(matchPendingVersion(listOf([agentRow("agent_question", { version: old.version })]), old)).toBe("current");
    expect(matchPendingVersion(listOf([agentRow("agent_question", { version: `question:${TASK}:req-2` })]), old)).toBe("stale");
  });

  it("답한 뒤(질문이 목록에서 빠짐)에는 gone이다", () => {
    expect(matchPendingVersion(listOf([]), { itemId: questionItem, version: `question:${TASK}:req-1` })).toBe("gone");
  });

  it("충돌이 해소되면 gone, 같은 lease에 새 충돌(conflict_version 증가)이 생기면 stale이다", () => {
    const seen = { itemId: `path_conflict:${LEASE}`, version: `conflict:${LEASE}:1` };
    expect(matchPendingVersion(listOf([agentRow("path_conflict", { version: seen.version })]), seen)).toBe("current");
    expect(matchPendingVersion(listOf([agentRow("path_conflict", { version: `conflict:${LEASE}:2` })]), seen)).toBe("stale");
    expect(matchPendingVersion(listOf([]), seen)).toBe("gone");
  });
});

describe("[D4b-s] loadPendingDecisions: gate · 두 함수 · 실패는 전체 실패", () => {
  afterEach(() => vi.unstubAllEnvs());
  const AGENT_ROW = { kind: "agent_question", item_ref: TASK, action_id: id(1), run_id: RUN, version: `question:${TASK}:req-1`, created_at: "2026-10-11T05:00:00+00:00", due_at: null, detail: DETAIL.agent_question };
  /** supabase-js 흉내: 함수 이름 → 돌려줄 행 (Error면 실패). 부른 함수와 인자를 기록한다 */
  function fakeAdmin(results: Record<string, unknown[] | Error>) {
    const calls: { name: string; args: unknown }[] = [];
    const admin = {
      rpc: (name: string, args: unknown) => {
        calls.push({ name, args });
        const result = results[name];
        return { throwOnError: () => (result instanceof Error ? Promise.reject(result) : Promise.resolve({ data: result ?? [] })) };
      },
    } as unknown as SupabaseClient;
    return { admin, calls };
  }
  const C2_ROW = { kind: "confirm", action_id: id(2), run_id: null, step_id: null, version: "action:b:1", created_at: "2026-10-11T00:00:00Z", due_at: null };

  it("켜진 adapter가 없으면(빈 배열) review_agent_inputs를 부르지 않는다 — C2 함수 하나만, 결과도 C2 그대로", async () => {
    const { admin, calls } = fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: [AGENT_ROW] });
    const groups = await loadPendingDecisions(admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: [] });
    expect(calls.map((c) => c.name)).toEqual(["coordinator_pending_inputs"]);
    expect(groups.map((g) => g.kind)).toEqual(["confirm"]);
  });

  it("기본값은 환경의 openAgentAdapters()다: 플래그가 모두 꺼져 있으면 부르지 않고, 대화 v2 ∧ adapter가 켜지면 그 adapter만 넘겨 부른다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "");
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "");
    const off = fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: [AGENT_ROW] });
    await loadPendingDecisions(off.admin, "10000000-0000-4000-8000-000000000001", NOW);
    expect(off.calls.map((c) => c.name)).toEqual(["coordinator_pending_inputs"]);

    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    const on = fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: [AGENT_ROW] });
    const groups = await loadPendingDecisions(on.admin, "10000000-0000-4000-8000-000000000001", NOW);
    expect(on.calls.map((c) => c.name).sort()).toEqual(["coordinator_pending_inputs", "review_agent_inputs"]);
    expect(on.calls.find((c) => c.name === "review_agent_inputs")!.args).toEqual({ p_user_id: "10000000-0000-4000-8000-000000000001", p_adapters: ["agent:codex"] });
    expect(groups.map((g) => g.kind).sort()).toEqual(["agent_question", "confirm"]);
  });

  it("켜진 adapter가 있으면 두 함수의 행을 합쳐 한 목록으로 계산한다 (C2 행은 ref 없음, 에이전트 행은 ref 있음)", async () => {
    const { admin } = fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: [AGENT_ROW] });
    const groups = await loadPendingDecisions(admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex", "agent:claude-code"] });
    const items = groups.flatMap((g) => g.items);
    expect(items.find((i) => i.kind === "confirm")).not.toHaveProperty("agent");
    expect(items.find((i) => i.kind === "agent_question")).toMatchObject({ id: `agent_question:${TASK}`, runId: RUN, agent: { task_id: TASK, adapter: "agent:codex" } });
  });

  it("어느 함수든 실패하면 throw한다 (일부만 보이지 않는다 — 호출한 쪽이 결정 전체를 unavailable로 표시)", async () => {
    await expect(loadPendingDecisions(fakeAdmin({ coordinator_pending_inputs: new Error("c2 down") }).admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] })).rejects.toThrow("c2 down");
    await expect(loadPendingDecisions(fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: new Error("agent down") }).admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] })).rejects.toThrow("agent down");
  });

  it("모르는 종류 · 틀린 ref 모양 · 틀린 열쇠를 받으면 throw한다", async () => {
    const run = (row: unknown) => loadPendingDecisions(fakeAdmin({ coordinator_pending_inputs: [], review_agent_inputs: [row] }).admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] });
    await expect(run({ ...AGENT_ROW, kind: "from_the_future" })).rejects.toThrow();
    await expect(run({ ...AGENT_ROW, detail: { ...DETAIL.agent_question, task_id: 3 } })).rejects.toThrow();
    await expect(run({ ...AGENT_ROW, detail: {} })).rejects.toThrow();
    await expect(run({ ...AGENT_ROW, item_ref: "x" })).rejects.toThrow();
    await expect(run({ ...AGENT_ROW, version: "" })).rejects.toThrow();
    await expect(run({ ...AGENT_ROW, detail: null })).rejects.toThrow();
  });

  it("review_agent_inputs의 반환은 배열이어야 한다: null · 객체 · 글자는 비었다고 읽지 않고 throw한다 (잘린/깨진 응답을 빈 목록으로 두지 않는다)", async () => {
    for (const data of [null, undefined, {}, "[]", 3]) {
      const t = fakeAdmin({ coordinator_pending_inputs: [C2_ROW] });
      const admin = { rpc: (name: string, args: unknown) => (name === "review_agent_inputs" ? { throwOnError: () => Promise.resolve({ data }) } : t.admin.rpc(name, args)) } as unknown as SupabaseClient;
      await expect(loadPendingDecisions(admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] }), JSON.stringify(data) ?? "undefined").rejects.toThrow();
    }
  });

  it("빈 배열은 정당한 빈 목록이다 (C2 항목만 나온다)", async () => {
    const { admin } = fakeAdmin({ coordinator_pending_inputs: [C2_ROW], review_agent_inputs: [] });
    expect((await loadPendingDecisions(admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] })).map((g) => g.kind)).toEqual(["confirm"]);
  });

  it("행이 1,001개여도 하나도 버리지 않는다 (개수 상한 없음 — 잘림은 SQL 반환 형태가 막는다)", async () => {
    const rows = Array.from({ length: 1001 }, (_, i) => {
      const lease = `c0000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`;
      return { ...AGENT_ROW, kind: "path_conflict", item_ref: lease, version: `conflict:${lease}:1`, detail: { ...DETAIL.path_conflict, lease_id: lease } };
    });
    const { admin } = fakeAdmin({ coordinator_pending_inputs: [], review_agent_inputs: rows });
    const groups = await loadPendingDecisions(admin, "10000000-0000-4000-8000-000000000001", NOW, { agentAdapters: ["agent:codex"] });
    expect(groups.flatMap((g) => g.items)).toHaveLength(1001);
  });
});

describe("계산은 실제 대기 항목을 하나도 버리지 않는다 (개수 상한 없음 — 상한 때문에 항목이 gone으로 보이면 안 된다)", () => {
  // 오래된 긴급 아닌 확인 요청이 많이 쌓인 사용자에게 새 긴급 확인 요청이 생겼다 (P2-A 재현)
  const OLD = 200;
  const rowsWithNewUrgent = () => [
    ...Array.from({ length: OLD }, (_, i) =>
      row({ kind: "confirm", action_id: id(i + 1), version: `action:old-${i + 1}:1`, created_at: new Date(Date.UTC(2026, 8, 1, 0, 0, i)).toISOString(), due_at: hours(24 * 30) }),
    ),
    row({ kind: "confirm", action_id: id(9999), version: "action:urgent:1", created_at: "2026-10-11T23:00:00Z", due_at: hours(2) }),
  ];

  it("오래된 긴급 아닌 확인 요청 200건 + 새 긴급 1건: 긴급 항목이 목록에 있고 맨 앞이다 (뒤쪽 항목 때문에 밀려나지 않는다)", () => {
    const groups = computePendingDecisions({ rows: rowsWithNewUrgent(), now: NOW });
    expect(groups).toHaveLength(OLD + 1);
    expect(groups[0]).toMatchObject({ actionId: id(9999), kind: "confirm", urgent: true });
    expect(groups[0].items.map((i) => i.id)).toEqual([`confirm:${id(9999)}`]);
    expect(groups.slice(1).every((g) => !g.urgent)).toBe(true);
    // 입력 순서와 무관하다 (긴급 항목이 입력 끝에 있든 앞에 있든)
    expect(computePendingDecisions({ rows: [...rowsWithNewUrgent()].reverse(), now: NOW })).toEqual(groups);
  });

  it("matchPendingVersion: 바뀌지 않은 긴급 항목 · 예전 상한 밖이던 항목(201번째)은 current, version이 바뀌었으면 stale, 정말 없는 id만 gone", () => {
    const groups = computePendingDecisions({ rows: rowsWithNewUrgent(), now: NOW });
    expect(matchPendingVersion(groups, { itemId: `confirm:${id(9999)}`, version: "action:urgent:1" })).toBe("current");
    expect(matchPendingVersion(groups, { itemId: `confirm:${id(OLD)}`, version: `action:old-${OLD}:1` })).toBe("current");
    expect(matchPendingVersion(groups, { itemId: `confirm:${id(OLD + 1)}`, version: "action:old-201:1" })).toBe("gone"); // 입력에 없는 id
    expect(matchPendingVersion(groups, { itemId: `confirm:${id(9999)}`, version: "action:urgent:2" })).toBe("stale");
    expect(matchPendingVersion(groups, { itemId: `confirm:${id(1)}`, version: "action:old-1:0" })).toBe("stale");
    expect(matchPendingVersion(groups, { itemId: "confirm:00000000-0000-4000-8000-0000000000ff", version: "x" })).toBe("gone");
  });

  it("입력의 모든 서로 다른 항목이 결과에 있다 (몇 건이든): 450건이어도 하나도 빠지지 않고 어느 것도 gone이 아니다", () => {
    const rows = Array.from({ length: 450 }, (_, i) =>
      row({ kind: "confirm", action_id: id(i + 1), version: `action:${i + 1}:1`, created_at: new Date(Date.UTC(2026, 8, 1, 0, 0, i)).toISOString(), due_at: i % 50 === 0 ? hours(1) : null }),
    );
    const groups = computePendingDecisions({ rows, now: NOW });
    expect(groups.flatMap((g) => g.items)).toHaveLength(450);
    for (const r of rows) expect(matchPendingVersion(groups, { itemId: `confirm:${r.action_id}`, version: r.version })).toBe("current");
    // 긴급 9건이 모두 비긴급보다 앞이다
    expect(groups.slice(0, 9).every((g) => g.urgent)).toBe(true);
    expect(groups.slice(9).some((g) => g.urgent)).toBe(false);
  });

  it("같은 항목이 두 번 들어오면 하나만, 입력 순서와 무관하게 같은 version", () => {
    const a = row({ kind: "confirm", action_id: id(1), version: "action:a:1" });
    const b = row({ kind: "confirm", action_id: id(1), version: "action:a:2" });
    expect(computePendingDecisions({ rows: [a, b], now: NOW })).toEqual(computePendingDecisions({ rows: [b, a], now: NOW }));
    expect(computePendingDecisions({ rows: [a, b], now: NOW })[0].items).toHaveLength(1);
  });
});

beforeEach(() => { vi.stubEnv("AGENT_BETA_USER_IDS", "10000000-0000-4000-8000-000000000001"); vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true"); });
