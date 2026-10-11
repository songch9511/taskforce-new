import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { PENDING_ITEMS_MAX, URGENT_WINDOW_HOURS } from "./coordinator.config";
import { computePendingDecisions, matchPendingVersion, urgency, type FutureInputs, type PendingInput } from "./pending";

// 결정 대기 목록 계산 (A39, 런타임 계약 6장). 순수 함수 시험. [현재 실제] 원천(승인 · run 결과 · 확인 요청)은 tests/coordinator/pending.test.ts가 실제 DB로 본다.
// [미래 fixture] 에이전트 질문 · 열린 제안 · 막힌 의존은 원천 표가 없어 입력 타입으로만 만든다.

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
  it("에이전트 질문 · 열린 제안 · 긴급 창의 막힌 의존이 같은 업무에 동시에 생겨도 (action, kind)로 묶이고, 막는 의존은 긴급이다", () => {
    const future: FutureInputs = {
      agentQuestions: [row({ kind: "agent_question", action_id: id(1), run_id: id(1, "cccccccc"), question_id: "q-1", version: "q-1", created_at: "2026-10-11T05:00:00Z" })],
      openSuggestions: [row({ kind: "suggestion", action_id: id(1), question_id: null, version: "sg-1", created_at: "2026-10-11T06:00:00Z" })],
      blockedDependencies: [row({ kind: "blocked_dependency", action_id: id(1), version: "dep-1", created_at: "2026-10-11T07:00:00Z", due_at: hours(3), blocks_other_work: true })],
    };
    const groups = computePendingDecisions({
      now: NOW,
      rows: [row({ kind: "approval", action_id: id(1), step_id: id(1, "bbbbbbbb"), version: "step:a:1:1", created_at: "2026-10-11T04:00:00Z" }), row({ kind: "confirm", action_id: id(1), version: "action:a:2", created_at: "2026-10-11T03:00:00Z" })],
      future,
    });
    expect(groups.map((g) => g.kind)).toEqual(["blocked_dependency", "confirm", "approval", "agent_question", "suggestion"]);
    expect(groups[0]).toMatchObject({ urgent: true });
    expect(groups.slice(1).every((g) => !g.urgent)).toBe(true);
    expect(groups.find((g) => g.kind === "agent_question")!.items[0].questionId).toBe("q-1");
  });
});

describe("크기 상한 · 같은 항목 중복", () => {
  it("항목이 상한을 넘으면 오래 기다린 것부터 남긴다", () => {
    const rows = Array.from({ length: PENDING_ITEMS_MAX + 20 }, (_, i) =>
      row({ kind: "confirm", action_id: id(i + 1), version: "v", created_at: new Date(Date.UTC(2026, 9, 1, 0, 0, i)).toISOString() }),
    );
    const groups = computePendingDecisions({ rows, now: NOW });
    expect(groups).toHaveLength(PENDING_ITEMS_MAX);
    expect(groups[0].actionId).toBe(id(1));
  });

  it("같은 항목이 두 번 들어오면 하나만, 입력 순서와 무관하게 같은 version", () => {
    const a = row({ kind: "confirm", action_id: id(1), version: "action:a:1" });
    const b = row({ kind: "confirm", action_id: id(1), version: "action:a:2" });
    expect(computePendingDecisions({ rows: [a, b], now: NOW })).toEqual(computePendingDecisions({ rows: [b, a], now: NOW }));
    expect(computePendingDecisions({ rows: [a, b], now: NOW })[0].items).toHaveLength(1);
  });
});
