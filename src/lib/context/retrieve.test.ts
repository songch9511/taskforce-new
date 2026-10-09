import { describe, expect, it } from "vitest";

import { memoryWriteRow, normalizeMemorySubject, sameFact, type MemoryLike } from "./memory";
import { appliesTo, effectiveMemory, isSlackDerived, isUsableMemory, unavailableSources } from "./retrieve";

// 읽을 때의 해석 (사용자 결정 2026-10-10): 범위 사이의 우선은 그 범위 안에서만, 주제 없는 항목은 아무것도 가리지 않는다.

const PROJECT_A = "aaaaaaaa-0000-4000-8000-000000000001";
const PROJECT_B = "aaaaaaaa-0000-4000-8000-000000000002";
const ACTION = "bbbbbbbb-0000-4000-8000-000000000001";
const PERSON = "cccccccc-0000-4000-8000-000000000001";
const SOURCE = "dddddddd-0000-4000-8000-000000000001";
const NOW = new Date("2026-10-10T00:00:00Z");

let n = 0;
function item(overrides: Partial<MemoryLike> = {}): MemoryLike {
  n += 1;
  return {
    id: `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`,
    kind: "fact",
    scope_kind: "global",
    context_id: null,
    action_id: null,
    person_id: null,
    agent_adapter: null,
    subject: "deploy day",
    statement: `사실 ${n}`,
    origin: "explicit",
    source_ref: null,
    observed_at: "2026-10-01T00:00:00Z",
    valid_from: null,
    valid_until: null,
    superseded_at: null,
    revoked_at: null,
    source_purged: false,
    ...overrides,
  };
}

describe("normalizeMemorySubject · sameFact · memoryWriteRow", () => {
  it("같은 사실의 열쇠: NFKC · 소문자 · 공백 하나 · 제어 문자 제거, 비면 null, 200자까지", () => {
    expect(normalizeMemorySubject("  Deploy\n\tDAY  ")).toBe("deploy day");
    expect(normalizeMemorySubject("ＤＥＰＬＯＹ　day")).toBe("deploy day");
    expect(normalizeMemorySubject("배포\u0000요일")).toBe("배포 요일");
    expect(normalizeMemorySubject("   ")).toBeNull();
    expect(normalizeMemorySubject(null)).toBeNull();
    expect([...normalizeMemorySubject("가".repeat(300))!]).toHaveLength(200);
  });

  it("같은 사실 = 같은 범위(대상까지) · 같은 kind · 같은 비어 있지 않은 subject", () => {
    const global = item();
    expect(sameFact(global, item())).toBe(true);
    expect(sameFact(global, item({ scope_kind: "context", context_id: PROJECT_A }))).toBe(false);
    expect(sameFact(item({ scope_kind: "context", context_id: PROJECT_A }), item({ scope_kind: "context", context_id: PROJECT_B }))).toBe(false);
    expect(sameFact(global, item({ kind: "working_rule" }))).toBe(false);
    expect(sameFact(global, item({ subject: "meeting day" }))).toBe(false);
    expect(sameFact(item({ subject: null }), item({ subject: null }))).toBe(false);
  });

  it("쓰기 입력: 범위를 열로, 주제를 정규화, observed는 출처 · inferred는 confidence가 필요하다", () => {
    expect(
      memoryWriteRow({ kind: "fact", scope: { kind: "context", contextId: PROJECT_A }, subject: " Deploy Day ", statement: " 목요일 배포 ", origin: "explicit" }),
    ).toMatchObject({ scope_kind: "context", context_id: PROJECT_A, action_id: null, subject: "deploy day", statement: "목요일 배포", value: {}, source_ref: null });
    expect(() => memoryWriteRow({ kind: "fact", scope: { kind: "global" }, statement: "x", origin: "observed" })).toThrow(/출처/);
    expect(() => memoryWriteRow({ kind: "fact", scope: { kind: "global" }, statement: "x", origin: "inferred" })).toThrow(/confidence/);
    expect(() => memoryWriteRow({ kind: "fact", scope: { kind: "global" }, statement: "x", origin: "explicit", confidence: 0.5 })).toThrow(/confidence/);
    expect(() => memoryWriteRow({ kind: "fact", scope: { kind: "agent", agentAdapter: "claude" }, statement: "x", origin: "explicit" })).toThrow();
    expect(() => memoryWriteRow({ kind: "fact", scope: { kind: "global" }, subject: " Memory:abc ", statement: "x", origin: "explicit" })).toThrow(/memory:/);
    expect(() =>
      memoryWriteRow({ kind: "fact", scope: { kind: "global" }, statement: "x", origin: "explicit", valid_from: "2026-10-10T00:00:00Z", valid_until: "2026-10-09T00:00:00Z" }),
    ).toThrow(/valid_from/);
  });
});

describe("appliesTo · isUsableMemory", () => {
  it("전체는 늘, 범위 · 할 일 · 상대 · 에이전트는 요청이 그 대상일 때만", () => {
    expect(appliesTo(item(), {})).toBe(true);
    expect(appliesTo(item({ scope_kind: "context", context_id: PROJECT_A }), { contextId: PROJECT_A })).toBe(true);
    expect(appliesTo(item({ scope_kind: "context", context_id: PROJECT_A }), { contextId: PROJECT_B })).toBe(false);
    expect(appliesTo(item({ scope_kind: "context", context_id: PROJECT_A }), {})).toBe(false);
    expect(appliesTo(item({ scope_kind: "action", action_id: ACTION }), { actionIds: [ACTION] })).toBe(true);
    expect(appliesTo(item({ scope_kind: "counterpart", person_id: PERSON }), { personIds: [] })).toBe(false);
    expect(appliesTo(item({ scope_kind: "agent", agent_adapter: "agent:claude-code" }), { agentAdapter: "agent:codex" })).toBe(false);
  });

  it("정정 · 잊기 · 글 지움 · 추정(기본) · 유효 구간 밖 · 읽을 수 없는 원문의 observed는 쓰지 않는다", () => {
    const usable = (m: MemoryLike, extra: Partial<Parameters<typeof isUsableMemory>[1]> = {}) => isUsableMemory(m, { now: NOW, ...extra });
    expect(usable(item())).toBe(true);
    expect(usable(item({ superseded_at: "2026-10-02T00:00:00Z" }))).toBe(false);
    expect(usable(item({ revoked_at: new Date("2026-10-02T00:00:00Z") }))).toBe(false);
    expect(usable(item({ origin: "observed", statement: "", source_purged: true }))).toBe(false);
    expect(usable(item({ origin: "inferred" }))).toBe(false);
    expect(usable(item({ origin: "inferred" }), { includeInferred: true })).toBe(true);
    expect(usable(item({ valid_from: "2026-10-11T00:00:00Z" }))).toBe(false);
    expect(usable(item({ valid_until: "2026-10-09T23:59:59Z" }))).toBe(false);
    expect(usable(item({ valid_from: "2026-10-01T00:00:00Z", valid_until: "2026-10-31T00:00:00Z" }))).toBe(true);
    const observed = item({ origin: "observed", source_ref: { source_id: SOURCE.toUpperCase() } });
    expect(usable(observed)).toBe(true);
    expect(usable(observed, { unavailableSourceIds: new Set([SOURCE]) })).toBe(false);
    // 사용자가 저장한 기억은 출처 원문을 잃어도 쓴다
    expect(usable(item({ source_ref: { source_id: SOURCE } }), { unavailableSourceIds: new Set([SOURCE]) })).toBe(true);
  });
});

describe("effectiveMemory: 좁은 범위는 그 범위 안에서만 이긴다", () => {
  it("프로젝트 A의 예외는 A 안에서만 전체 기본값을 가리고, B · 전체에서는 기본값이 나온다", () => {
    const fallback = item({ statement: "금요일 배포" });
    const inA = item({ scope_kind: "context", context_id: PROJECT_A, statement: "A는 목요일" });
    const inB = item({ scope_kind: "context", context_id: PROJECT_B, statement: "B는 수요일" });
    const rows = [fallback, inA, inB];
    expect(effectiveMemory(rows, { contextId: PROJECT_A }, { now: NOW }).map((m) => m.statement)).toEqual(["A는 목요일"]);
    expect(effectiveMemory(rows, { contextId: PROJECT_B }, { now: NOW }).map((m) => m.statement)).toEqual(["B는 수요일"]);
    expect(effectiveMemory(rows, {}, { now: NOW }).map((m) => m.statement)).toEqual(["금요일 배포"]);
    // 예외가 잊히거나 범위가 지워지면(행 없음) 기본값이 다시 보인다 (기본값은 무효가 된 적이 없다)
    expect(effectiveMemory([fallback, { ...inA, revoked_at: "2026-10-05T00:00:00Z" }], { contextId: PROJECT_A }, { now: NOW }).map((m) => m.statement)).toEqual([
      "금요일 배포",
    ]);
  });

  it("할 일 > 범위 > 상대 > 에이전트 > 전체. 같은 범위면 explicit > observed, 같은 origin이면 늦게 말한 것", () => {
    const rows = [
      item({ statement: "전체" }),
      item({ scope_kind: "agent", agent_adapter: "agent:claude-code", statement: "에이전트" }),
      item({ scope_kind: "counterpart", person_id: PERSON, statement: "상대" }),
      item({ scope_kind: "context", context_id: PROJECT_A, statement: "범위" }),
      item({ scope_kind: "action", action_id: ACTION, statement: "할 일" }),
    ];
    const target = { contextId: PROJECT_A, actionIds: [ACTION], personIds: [PERSON], agentAdapter: "agent:claude-code" };
    expect(effectiveMemory(rows, target, { now: NOW }).map((m) => m.statement)).toEqual(["할 일"]);
    expect(effectiveMemory(rows.slice(0, 4), target, { now: NOW }).map((m) => m.statement)).toEqual(["범위"]);
    expect(effectiveMemory(rows.slice(0, 3), target, { now: NOW }).map((m) => m.statement)).toEqual(["상대"]);
    expect(effectiveMemory(rows.slice(0, 2), target, { now: NOW }).map((m) => m.statement)).toEqual(["에이전트"]);

    const sameScope = [
      item({ origin: "observed", statement: "자료", observed_at: "2026-10-09T00:00:00Z", source_ref: { source_id: SOURCE } }),
      item({ origin: "explicit", statement: "사용자", observed_at: "2026-10-01T00:00:00Z" }),
    ];
    expect(effectiveMemory(sameScope, {}, { now: NOW }).map((m) => m.statement)).toEqual(["사용자"]);
    const twoSaid = [item({ statement: "먼저", observed_at: "2026-10-01T00:00:00Z" }), item({ statement: "나중", observed_at: "2026-10-02T00:00:00Z" })];
    expect(effectiveMemory(twoSaid, {}, { now: NOW }).map((m) => m.statement)).toEqual(["나중"]);
  });

  it("같은 수준의 다른 대상(상대 둘 · 할 일 둘)의 같은 사실은 둘 다 남고, 넓은 수준(전체)은 가려진다. id는 대소문자를 가리지 않는다", () => {
    const P2 = "cccccccc-0000-4000-8000-000000000002";
    const A2 = "bbbbbbbb-0000-4000-8000-000000000002";
    const rows = [
      item({ scope_kind: "counterpart", person_id: PERSON, kind: "relationship", subject: "role", statement: "P1 결정권자" }),
      item({ scope_kind: "counterpart", person_id: P2, kind: "relationship", subject: "role", statement: "P2 실무자" }),
      item({ statement: "전체: 금요일" }),
      item({ scope_kind: "action", action_id: ACTION, statement: "A1: 수요일" }),
      item({ scope_kind: "action", action_id: A2, statement: "A2: 목요일" }),
    ];
    const target = { actionIds: [ACTION.toUpperCase(), A2], personIds: [PERSON.toUpperCase(), P2] };
    expect(effectiveMemory(rows, target, { now: NOW }).map((m) => m.statement).sort()).toEqual(["A1: 수요일", "A2: 목요일", "P1 결정권자", "P2 실무자"].sort());
    // 같은 대상 안에서는 하나: 늦게 말한 것
    const sameTarget = [...rows, item({ scope_kind: "counterpart", person_id: PERSON, kind: "relationship", subject: "role", statement: "P1 새 역할", observed_at: "2026-10-05T00:00:00Z" })];
    expect(effectiveMemory(sameTarget, { personIds: [PERSON] }, { now: NOW }).map((m) => m.statement)).toEqual(["P1 새 역할", "전체: 금요일"]);
    expect(appliesTo(item({ scope_kind: "context", context_id: PROJECT_A }), { contextId: PROJECT_A.toUpperCase() })).toBe(true);
  });

  it("좁은 수준이 요청한 대상을 모두 덮지 못하면(할 일 둘 중 하나에만 예외) 넓은 수준의 기본값도 남는다", () => {
    const A2 = "bbbbbbbb-0000-4000-8000-000000000002";
    const rows = [
      item({ statement: "전체: 금요일" }),
      item({ scope_kind: "context", context_id: PROJECT_A, statement: "프로젝트: 목요일" }),
      item({ scope_kind: "action", action_id: ACTION, statement: "A1: 수요일" }),
    ];
    const both = { contextId: PROJECT_A, actionIds: [ACTION, A2] };
    expect(effectiveMemory(rows, both, { now: NOW }).map((m) => m.statement)).toEqual(["A1: 수요일", "프로젝트: 목요일"]);
    expect(effectiveMemory(rows, { contextId: PROJECT_A, actionIds: [ACTION] }, { now: NOW }).map((m) => m.statement)).toEqual(["A1: 수요일"]);
    expect(effectiveMemory(rows, { actionIds: [ACTION, A2] }, { now: NOW }).map((m) => m.statement)).toEqual(["A1: 수요일", "전체: 금요일"]);
  });

  it("kind만 같거나 주제가 없으면 둘 다 남는다. 다른 범위 · 추정은 처음부터 보지 않는다", () => {
    const rows = [
      item({ statement: "배포 금요일" }),
      item({ subject: "meeting day", statement: "회의 화요일" }),
      item({ kind: "working_rule", statement: "배포 전 확인" }),
      item({ subject: null, statement: "주제 없음 1" }),
      item({ subject: null, statement: "주제 없음 2", scope_kind: "context", context_id: PROJECT_A }),
      item({ subject: null, statement: "다른 범위", scope_kind: "context", context_id: PROJECT_B }),
      item({ statement: "추정", origin: "inferred", scope_kind: "context", context_id: PROJECT_A }),
    ];
    expect(new Set(effectiveMemory(rows, { contextId: PROJECT_A }, { now: NOW }).map((m) => m.statement))).toEqual(
      new Set(["배포 금요일", "회의 화요일", "배포 전 확인", "주제 없음 1", "주제 없음 2"]),
    );
  });
});

describe("원문 상태", () => {
  it("Slack 원문: 연결이 Slack · Slack 끊기로 지움 · Slack 링크", () => {
    expect(isSlackDerived({ provider: "slack", purgeReason: null, externalUrl: null })).toBe(true);
    expect(isSlackDerived({ provider: null, purgeReason: "disconnected", externalUrl: null })).toBe(true);
    expect(isSlackDerived({ provider: null, purgeReason: null, externalUrl: "https://acme.slack.com/archives/C1/p1" })).toBe(true);
    expect(isSlackDerived({ provider: "notion", purgeReason: "retention", externalUrl: "https://notion.so/x" })).toBe(false);
    expect(isSlackDerived({ provider: null, purgeReason: null, externalUrl: "not a url" })).toBe(false);
  });

  it("쓸 수 없는 원문: 글 지움 · 접근 상실 · Slack (소문자 id)", () => {
    const base = { provider: "notion", purgeReason: null, externalUrl: null, purged: false, accessLost: false };
    expect(
      unavailableSources([
        { ...base, id: "A" },
        { ...base, id: "B", purged: true },
        { ...base, id: "C", accessLost: true },
        { ...base, id: "D", provider: "slack" },
      ]),
    ).toEqual(new Set(["b", "c", "d"]));
  });
});
