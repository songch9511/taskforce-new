import { describe, expect, it, vi } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";

import { MEMORY_WRITES_PER_TURN } from "./conversation.config";
import { checkMemorySupport, planMemoryWrites, statementLinkedToQuote, withSupport, type MemoryCandidate, type ShownMemory } from "./memory";

// 기억 후보 → 저장할 기억 (ARCH01 · 02 · 04, 아키텍처 5.3 · 6.4 · 7.3 J7). 쓰기 자체(같은 범위 · 같은 사실 정정)는 DB remember_memory_item이 한다.

const MESSAGE = { id: "aaaaaaaa-0000-4000-8000-000000000001", text: "디자인 확정되면 개발 시작하고, 개발은 Opus 5.5로 할 거야.", createdAt: "2026-10-10T01:00:00.000Z" };
const quotable = new Map([["U1", MESSAGE]]);
const CONTEXT = "cdcdcdcd-0000-4000-8000-000000000001";

const candidate = (overrides: Partial<MemoryCandidate> = {}): MemoryCandidate => ({
  kind: "plan",
  subject: "개발 에이전트",
  statement: "개발은 Opus 5.5로",
  message: "U1",
  quote: "개발은 Opus 5.5로 할 거야",
  corrects: null,
  ...overrides,
});

const shown = (overrides: Partial<ShownMemory> = {}): ShownMemory => ({
  id: "acacacac-0000-4000-8000-000000000001",
  version: 2,
  kind: "plan",
  subject: "개발 에이전트",
  statement: "개발은 Opus 5.5로",
  origin: "explicit",
  scope_kind: "global",
  context_id: null,
  action_id: null,
  person_id: null,
  agent_adapter: null,
  ...overrides,
});

const plan = (candidates: MemoryCandidate[], options: { shownMemory?: ShownMemory[]; contextId?: string; allowed?: boolean } = {}) =>
  planMemoryWrites({
    candidates,
    allowed: options.allowed ?? true,
    quotable,
    shown: new Map((options.shownMemory ?? []).map((m, i) => [`M${i + 1}`, m])),
    scope: options.contextId ? { kind: "context", contextId: options.contextId } : { kind: "global" },
  });

describe("planMemoryWrites: 인용 기계 확인 (ARCH04)", () => {
  it("인용이 허락된 메시지에 이어진 한 덩어리로 있으면 explicit 새 행. 인용은 원문에서 잘라 낸 구간 (모델 문자열이 아님)", () => {
    const result = plan([candidate({ quote: "개발은  Opus 5.5로 할 거야" })]);
    expect(result.writes).toEqual([
      {
        item: expect.objectContaining({ kind: "plan", scope_kind: "global", subject: "개발 에이전트", statement: "개발은 Opus 5.5로", origin: "explicit", confidence: null, source_ref: { message_id: MESSAGE.id, quote: "개발은 Opus 5.5로 할 거야" } }),
        corrects: null,
        expected_version: null,
      },
    ]);
    expect(result.notes).toEqual([{ kind: "new", statement: "개발은 Opus 5.5로" }]);
  });

  it.each([
    ["발화에 없는 인용", { quote: "개발은 Sonnet으로 할 거야" }, "quote_not_found"],
    ["너무 짧은 인용", { quote: "개발" }, "quote_too_short"],
    ["모르는 메시지 번호", { message: "U7" }, "unknown_message"],
    ["인용과 글자쌍이 하나도 없는 문장", { statement: "사용자는 다음 달 퇴사" }, "unrelated_statement"],
    ["빈 문장", { statement: "   " }, "bad_statement"],
    ["신원 링크는 대화에서 만들지 않는다", { kind: "identity_link" }, "bad_kind"],
    ["예약 주제(memory:)", { subject: "memory:abc" }, "reserved_subject"],
    ["보여 주지 않은 기억 정정", { corrects: "M9" }, "unknown_memory"],
  ] as const)("%s → 저장 0, inferred로도 0", (_name, overrides, reason) => {
    const result = plan([candidate(overrides as Partial<MemoryCandidate>)]);
    expect(result.writes).toEqual([]);
    expect(result.dropped).toEqual([reason]);
  });

  it("의도 · gate가 허락하지 않으면 모두 버린다", () => {
    expect(plan([candidate()], { allowed: false })).toMatchObject({ writes: [], dropped: ["not_allowed"] });
  });

  it("번호는 [U1] · u 1처럼 적어도 같은 번호", () => {
    expect(plan([candidate({ message: "[U1]" })]).writes).toHaveLength(1);
    expect(plan([candidate({ message: "u 1" })]).writes).toHaveLength(1);
  });

  it("문장 ↔ 인용 연결은 글자쌍 하나 이상 (공백 · 문장부호 · 대소문자 무시)", () => {
    expect(statementLinkedToQuote("디자인이 확정됨", "확정됐어")).toBe(true);
    expect(statementLinkedToQuote("Dev uses Sonnet", "switch to SONNET")).toBe(true);
    expect(statementLinkedToQuote("회사를 그만둠", "확정됐어")).toBe(false);
  });
});

describe("planMemoryWrites: 범위 · 같은 사실 (ARCH02, B1 규칙)", () => {
  it("같은 범위의 기억을 정정: 그 행 id + version (범위 · kind · subject는 DB가 물려받는다)", () => {
    const target = shown();
    const result = plan([candidate({ statement: "개발은 Sonnet 5.5로", quote: "개발은 Opus 5.5로 할 거야", corrects: "M1" })], { shownMemory: [target] });
    expect(result.writes).toEqual([{ item: expect.objectContaining({ subject: null, origin: "explicit" }), corrects: target.id, expected_version: 2 }]);
    expect(result.targets).toEqual([target.id]);
    expect(result.notes).toEqual([{ kind: "corrected", statement: "개발은 Sonnet 5.5로", previous: "개발은 Opus 5.5로" }]);
  });

  it("범위 대화에서 전체 기억을 정정하면 전체 행은 그대로 두고 대화 범위의 같은 사실을 새로 쓴다", () => {
    const result = plan([candidate({ statement: "개발은 Sonnet 5.5로", corrects: "M1" })], { shownMemory: [shown()], contextId: CONTEXT });
    expect(result.writes).toEqual([{ item: expect.objectContaining({ scope_kind: "context", context_id: CONTEXT, subject: "개발 에이전트", kind: "plan" }), corrects: null, expected_version: null }]);
  });

  it("같은 범위 · 같은 사실 · 같은 문장은 다시 쓰지 않는다 (이미 기억)", () => {
    const target = shown();
    const result = plan([candidate()], { shownMemory: [target] });
    expect(result.writes).toEqual([]);
    expect(result.existing).toEqual([target.id]);
    expect(result.notes).toEqual([{ kind: "already", statement: "개발은 Opus 5.5로", id: target.id }]);
  });

  it("같은 kind라도 주제가 다르면 다른 사실: 새 행, 정정 표시 없음", () => {
    const result = plan([candidate({ subject: "디자인 에이전트", statement: "개발 시작 전 디자인", quote: "디자인 확정되면 개발 시작하고" })], { shownMemory: [shown()] });
    expect(result.writes).toHaveLength(1);
    expect(result.writes[0].corrects).toBeNull();
    expect(result.notes).toEqual([{ kind: "new", statement: "개발 시작 전 디자인" }]);
  });

  it("보여 준 기억과 같은 범위 · 같은 사실을 다시 말하면(정정 번호 없이도) 그 행을 version과 함께 정정한다: 그 사이 바뀌었으면 DB가 conflict", () => {
    const target = shown();
    const result = plan([candidate({ statement: "개발은 Opus 5.5로 진행" })], { shownMemory: [target] });
    expect(result.writes).toEqual([{ item: expect.objectContaining({ subject: null }), corrects: target.id, expected_version: 2 }]);
    expect(result.notes).toEqual([{ kind: "corrected", statement: "개발은 Opus 5.5로 진행", previous: "개발은 Opus 5.5로" }]);
  });

  it("범위 대화에서 주제 없는 전체 기억을 정정하는데 후보에도 주제가 없으면 버린다 (읽을 때 이기지 못해 정정이 되지 않는다)", () => {
    const result = plan([candidate({ subject: "  ", statement: "개발은 Sonnet 5.5로", corrects: "M1" })], { shownMemory: [shown({ subject: null })], contextId: CONTEXT });
    expect(result.writes).toEqual([]);
    expect(result.dropped).toEqual(["no_subject"]);
  });

  it("쓰기는 잠금 순서(같은 사실 열쇠)로 정렬한다: 두 turn이 같은 기억 둘을 반대 순서로 고쳐도 교착하지 않게", () => {
    const a = shown({ id: "acacacac-0000-4000-8000-00000000000a", subject: "가 주제", statement: "가 옛" });
    const b = shown({ id: "acacacac-0000-4000-8000-00000000000b", subject: "나 주제", statement: "나 옛" });
    const forward = plan([candidate({ statement: "개발 가", corrects: "M1" }), candidate({ statement: "개발 나", corrects: "M2" })], { shownMemory: [a, b] });
    const backward = plan([candidate({ statement: "개발 나", corrects: "M2" }), candidate({ statement: "개발 가", corrects: "M1" })], { shownMemory: [a, b] });
    expect(forward.writes.map((w) => w.corrects)).toEqual([a.id, b.id]);
    expect(backward.writes.map((w) => w.corrects)).toEqual([a.id, b.id]);
  });

  it("한 번에 같은 사실 · 같은 정정 대상은 하나만, 쓰기는 MEMORY_WRITES_PER_TURN개까지", () => {
    expect(plan([candidate(), candidate({ statement: "개발은 Opus 5.5" })]).dropped).toEqual(["duplicate"]);
    const many = Array.from({ length: MEMORY_WRITES_PER_TURN + 1 }, (_, i) => candidate({ subject: `주제 ${i}` }));
    const result = plan(many);
    expect(result.writes).toHaveLength(MEMORY_WRITES_PER_TURN);
    expect(result.dropped).toEqual(["limit"]);
  });
});

describe("판정 (Jev): 인용이 문장을 그대로 말하는가", () => {
  it("기계 확인을 통과한 후보마다 질문 하나를 한 번에 묻고, 0.8 미만(부정 뒤집기 등)은 저장하지 않는다 (not_supported, inferred로도 0)", async () => {
    const result = plan([
      candidate({ subject: "Opus 사용 여부", statement: "개발에 Opus 5.5는 쓰지 않음", kind: "fact" }), // 글자쌍은 겹치지만 뜻이 뒤집힘
      candidate(),
    ]);
    const decide = vi.fn(async (): Promise<JevDecision> => ({ model: "fake", answers: { support_0: { type: "noul", noul: 0.2 }, support_1: { type: "noul", noul: 0.91 } }, usage: { input_tokens: 1, cost: 0.001 } }));
    const support = await checkMemorySupport(result.planned, decide, "확정됐나요?");
    const request = decide.mock.calls[0] as unknown as [{ state: { previous_reply: string; candidates: { statement: string; quote: string; message: string }[] }; questions: Record<string, { type: string }> }];
    expect(Object.keys(request[0].questions)).toEqual(["support_0", "support_1"]);
    expect(request[0].state.previous_reply).toBe("확정됐나요?");
    expect(request[0].state.candidates[1]).toEqual({ statement: "개발은 Opus 5.5로", quote: "개발은 Opus 5.5로 할 거야", message: MESSAGE.text });
    expect(support).toEqual({ keep: [false, true], cost: 0.001 });
    const kept = withSupport(result, support.keep);
    expect(kept.writes.map((w) => w.item.statement)).toEqual(["개발은 Opus 5.5로"]);
    expect(kept.notes).toEqual([{ kind: "new", statement: "개발은 Opus 5.5로" }]);
    expect(kept.dropped).toEqual(["not_supported"]);
  });

  it("후보가 없으면 판정을 부르지 않는다", async () => {
    const decide = vi.fn();
    expect(await checkMemorySupport([], decide as never, null)).toEqual({ keep: [], cost: 0 });
    expect(decide).not.toHaveBeenCalled();
  });
});
