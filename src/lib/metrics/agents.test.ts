import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import {
  agentDelivery,
  agentQuestions,
  agentStops,
  agentUsage,
  AGENT_EVENTS,
  BUCKET_LABELS,
  bucketText,
  PRE_OA_TYPES,
  type AgentEventRow,
  type AgentMetricRow,
  type DeliveryStep,
  type StepEvent,
} from "./agents";

// OA I-oa 7.1: 에이전트 지표 카드의 계산 (고정 행). 기대값은 손으로 센 값이다.

const period = { from: new Date("2026-10-10T00:00:00Z"), to: new Date("2026-10-17T00:00:00Z") };
const T = (s: number) => new Date(Date.parse("2026-10-15T00:00:00Z") + Math.round(s * 1000)).toISOString();

describe("U1 ① 에이전트 사용", () => {
  const row = (type: string, over: Partial<AgentMetricRow> = {}): AgentMetricRow => ({ userId: "u1", type, at: T(0), props: {}, ...over });
  const find = (card: ReturnType<typeof agentUsage>, type: string) => card.types.find((t) => t.type === type)!;

  it("등록부 순서로 26개 type이 모두 나오고, 수 · 사용자 수 · adapter를 센다", () => {
    const card = agentUsage(
      [
        row("agent_message_sent", { props: { adapter: "agent:codex", access: "write" } }),
        row("agent_message_sent", { props: { adapter: "agent:codex" } }),
        row("agent_message_sent", { userId: "u2", props: { adapter: "agent:claude-code" } }),
        row("agent_message_sent", { props: {} }),
      ],
      [],
      period,
    );
    expect(card.types.map((t) => t.type)).toEqual(AGENT_EVENTS.map((e) => e.type));
    expect(card.types).toHaveLength(26);
    expect(find(card, "agent_message_sent")).toMatchObject({ n: 4, users: 2 });
    // props가 없는 옛 행은 "(없음)"
    expect(find(card, "agent_message_sent").adapters).toEqual([
      { value: "agent:codex", n: 2 },
      { value: "(없음)", n: 1 },
      { value: "agent:claude-code", n: 1 },
    ]);
    expect(find(card, "stop_requested")).toMatchObject({ n: 0, users: 0 });
    expect(card.empty).toBe(false);
  });

  it("차원: question_answered 셋(kind · answered_locally · decision)", () => {
    const card = agentUsage(
      [
        row("question_answered", { props: { kind: "input", adapter: "agent:codex" } }),
        row("question_answered", { props: { kind: "input", adapter: "agent:codex", answered_locally: true } }),
        row("question_answered", { props: { kind: "approval", adapter: "agent:codex", decision: "allow" } }),
        row("question_answered", { props: { kind: "approval", adapter: "agent:claude-code", decision: "deny" } }),
      ],
      [],
      period,
    );
    const dims = Object.fromEntries(find(card, "question_answered").dims.map((d) => [d.key, d.values]));
    expect(dims.kind).toEqual([
      { value: "approval", n: 2 },
      { value: "input", n: 2 },
    ]);
    // 값이 없는 행은 "(없음)"으로 센다 (answered_locally는 로컬 답에만 있다)
    expect(dims.answered_locally).toEqual([
      { value: "(없음)", n: 3 },
      { value: "true", n: 1 },
    ]);
    expect(dims.decision).toEqual([
      { value: "(없음)", n: 2 },
      { value: "allow", n: 1 },
      { value: "deny", n: 1 },
    ]);
  });

  it("차원: tool_call_decided decision · reason + server_ms nearest-rank p50 · p95", () => {
    const rows = Array.from({ length: 20 }, (_, i) => row("tool_call_decided", { props: { adapter: "agent:codex", decision: i < 15 ? "defer" : "deny", reason: i < 15 ? "manual_write" : "path_in_use", server_ms: i + 1 } }));
    const card = agentUsage(rows, [], period);
    const t = find(card, "tool_call_decided");
    expect(t.numeric).toEqual({ key: "server_ms", n: 20, p50: 10, p95: 19 });
    expect(Object.fromEntries(t.dims.map((d) => [d.key, d.values]))).toMatchObject({
      decision: [
        { value: "defer", n: 15 },
        { value: "deny", n: 5 },
      ],
      reason: [
        { value: "manual_write", n: 15 },
        { value: "path_in_use", n: 5 },
      ],
    });
    // 숫자가 아닌 값 · 음수는 표본이 아니다
    const bad = agentUsage([row("tool_call_decided", { props: { server_ms: "12" } }), row("tool_call_decided", { props: { server_ms: -1 } }), row("tool_call_decided", { props: { server_ms: 7 } })], [], period);
    expect(find(bad, "tool_call_decided").numeric).toEqual({ key: "server_ms", n: 1, p50: 7, p95: 7 });
  });

  it("차원: from · surface · via · keep · context_attached 셋", () => {
    const card = agentUsage(
      [
        row("message_resent", { props: { adapter: "agent:codex", from: "not_sent", reason: "x" } }),
        row("message_resent", { props: { adapter: "agent:codex", from: "expired" } }),
        row("message_resent", { props: { adapter: "agent:codex", from: "not_sent" } }),
        row("stop_requested", { props: { surface: "assistant" } }),
        row("issue_moved", { props: { via: "menu", from_context: "11111111-1111-1111-1111-111111111111", to_context: null } }),
        row("path_conflict_resolved", { props: { keep: "later" } }),
        row("context_attached", { props: { kind: "issue", origin: "chip", sent: true, target_kind: "agent" } }),
        row("context_attached", { props: { kind: "issue", origin: "chip", sent: false, target_kind: "taskforce" } }),
      ],
      [],
      period,
    );
    const dim = (type: string, key: string) => find(card, type).dims.find((d) => d.key === key)?.values;
    expect(dim("message_resent", "from")).toEqual([
      { value: "not_sent", n: 2 },
      { value: "expired", n: 1 },
    ]);
    expect(dim("stop_requested", "surface")).toEqual([{ value: "assistant", n: 1 }]);
    expect(dim("issue_moved", "via")).toEqual([{ value: "menu", n: 1 }]);
    expect(dim("path_conflict_resolved", "keep")).toEqual([{ value: "later", n: 1 }]);
    expect(dim("context_attached", "target_kind")).toEqual([
      { value: "agent", n: 1 },
      { value: "taskforce", n: 1 },
    ]);
    expect(dim("context_attached", "sent")).toEqual([
      { value: "false", n: 1 },
      { value: "true", n: 1 },
    ]);
    // 등록부에 없는 차원(reason · from_context)은 보이지 않는다
    expect(find(card, "message_resent").dims.map((d) => d.key)).toEqual(["from"]);
  });

  it("차원 값이 토큰이 아니면(공백 · 한글 · 긴 글) 글을 보이지 않고 (기타)로 센다", () => {
    const card = agentUsage(
      [row("stop_requested", { props: { surface: "비밀 글 입니다" } }), row("stop_requested", { props: { surface: "x".repeat(65) } }), row("stop_requested", { props: { surface: { a: 1 } } })],
      [],
      period,
    );
    expect(find(card, "stop_requested").dims[0].values).toEqual([{ value: "(기타)", n: 3 }]);
    expect(JSON.stringify(card)).not.toContain("비밀");
  });

  it("기간 경계: from ≤ at < to", () => {
    const card = agentUsage(
      [
        row("stop_requested", { at: period.from.toISOString() }),
        row("stop_requested", { at: new Date(period.from.getTime() - 1).toISOString() }),
        row("stop_requested", { at: new Date(period.to.getTime() - 1).toISOString() }),
        row("stop_requested", { at: period.to.toISOString() }),
      ],
      [],
      period,
    );
    expect(find(card, "stop_requested").n).toBe(2);
  });

  it("모르는 type은 따로 센다 (OA 전 7개와 등록부 26개는 모르는 type이 아니다)", () => {
    const card = agentUsage([row("brand_new_type"), row("brand_new_type", { userId: "u2" }), row("other_new"), row("app_opened"), row("assistant_opened"), row("brand_new_type", { at: T(-86400 * 30) })], [], period);
    // 모르는 type 2개(brand_new_type · other_new), 기간 안 3건 (30일 전 brand_new_type은 기간 밖)
    expect(card.unknown).toEqual({ types: 2, events: 3 });
    expect(PRE_OA_TYPES).toContain("app_opened");
    expect(find(card, "assistant_opened").n).toBe(1);
  });

  it("에이전트가 만든 이슈는 수와 사용자 수만, 기간 안만 센다", () => {
    const card = agentUsage([], [{ userId: "u1", at: T(0) }, { userId: "u1", at: T(5) }, { userId: "u2", at: T(9) }, { userId: "u3", at: T(-86400 * 30) }], period);
    expect(card.agentIssues).toEqual({ n: 3, users: 2 });
    expect(card.empty).toBe(false);
  });

  it("아무것도 없으면 empty", () => {
    expect(agentUsage([], [], period).empty).toBe(true);
    expect(agentUsage([row("app_opened")], [], period).empty).toBe(true);
  });
});

describe("U2 ② 전달 · 지연 (ONE-TF-11 서버 구간)", () => {
  const step = (id: string, over: Partial<DeliveryStep> = {}): DeliveryStep => ({
    id,
    kind: "agent_message",
    adapter: "agent:codex",
    purpose: `message:${id}`,
    createdAt: T(0),
    taskId: null,
    requestId: null,
    answerMessageId: null,
    answeredLocally: null,
    receiptReason: null,
    ...over,
  });
  const lease = (stepId: string, atS: number, gate: string | null = "bridge_lease"): StepEvent => ({ stepId, toState: "calling", gate, at: T(atS) });
  const called = (stepId: string, atS: number): StepEvent => ({ stepId, toState: "called", gate: "response", at: T(atS) });
  const ended = (stepId: string, atS: number, toState = "failed"): StepEvent => ({ stepId, toState, gate: "bridge_withdraw", at: T(atS) });
  const run = (steps: DeliveryStep[], events: StepEvent[]) => agentDelivery({ steps, events, messages: [], commands: [] }, period).groups;

  it.each([
    [1, [4], 4, 4],
    [2, [1, 2], 1, 2],
    [20, Array.from({ length: 20 }, (_, i) => i + 1), 10, 19],
    [21, Array.from({ length: 21 }, (_, i) => i + 1), 11, 20],
  ])("nearest-rank: 표본 %i개의 p50 · p95", (_n, seconds, p50, p95) => {
    const steps = seconds.map((_, i) => step(`s${i}`));
    const events = seconds.map((s, i) => lease(`s${i}`, s));
    const [group] = run(steps, events);
    expect(group.lease).toMatchObject({ n: seconds.length, p50, p95, max: Math.max(...seconds) });
  });

  it("3 · 8 · 25초 칸: 경계는 위 칸이 아니라 아래 칸(≤)이다", () => {
    const seconds = [0, 3, 3.001, 8, 8.001, 25, 25.001, 90];
    const [group] = run(
      seconds.map((_, i) => step(`s${i}`)),
      seconds.map((s, i) => lease(`s${i}`, s)),
    );
    // 0 · 3 → ≤3 / 3.001 · 8 → ≤8 / 8.001 · 25 → ≤25 / 25.001 · 90 → >25
    expect(group.buckets).toEqual({ le3: 2, le8: 2, le25: 2, gt25: 2 });
  });

  it("칸은 겹치지 않는 구간이고(누적 아님) 표시 글자가 그 뜻을 말한다: 표본 2 · 5 · 10초", () => {
    const [group] = run(
      [step("a"), step("b"), step("c")],
      [lease("a", 2), lease("b", 5), lease("c", 10)],
    );
    // 2초 → 3초 이하, 5초 → 3초 초과 ~ 8초 이하, 10초 → 8초 초과 ~ 25초 이하 (누적이면 8초 이하 2 · 25초 이하 3)
    expect(group.buckets).toEqual({ le3: 1, le8: 1, le25: 1, gt25: 0 });
    expect(BUCKET_LABELS).toEqual({ le3: "3초 이하", le8: "3초 초과 ~ 8초 이하", le25: "8초 초과 ~ 25초 이하", gt25: "25초 초과" });
    expect(bucketText(group.buckets)).toBe("3초 이하 1 · 3초 초과 ~ 8초 이하 1 · 8초 초과 ~ 25초 이하 1 · 25초 초과 0");
  });

  it("화면(page.tsx)은 칸 글자를 이 함수로만 만든다 (손으로 적은 \"8초 이하\" 같은 누적처럼 읽히는 글자가 없다)", () => {
    const page = readFileSync(path.resolve(import.meta.dirname, "../../app/admin/metrics/page.tsx"), "utf8");
    expect(page).toContain("bucketText(g.buckets)");
    for (const stale of ["8초 이하 {", "25초 이하 {", "3초 이하 {"]) expect(page).not.toContain(stale);
  });

  it("lease는 gate bridge_lease의 첫 calling만, 접수는 첫 called, 둘 다 서버 사건 시각이다", () => {
    // 다른 gate의 calling(더 이른 1초 · 늦은 99초)은 집어 감이 아니다
    const [group] = run(
      [step("a")],
      [lease("a", 1, "begin_call"), lease("a", 99, "lease_expired"), lease("a", 7), lease("a", 5), called("a", 20), called("a", 30)],
    );
    expect(group.lease).toMatchObject({ n: 1, p50: 5, max: 5 });
    expect(group.accept).toMatchObject({ n: 1, p50: 20, p95: 20 });
  });

  it("집어 가지 않은 단계: 기다림(끝난 사건 없음) · 집힌 적 없이 끝남(failed · skipped)", () => {
    const [group] = run([step("w"), step("x"), step("y"), step("z")], [ended("x", 2), ended("y", 3, "skipped"), lease("z", 1)]);
    expect(group).toMatchObject({ n: 4, waiting: 1, neverLeased: 2 });
    expect(group.lease).toMatchObject({ n: 1, p50: 1 });
    // 표본 0인 접수 구간은 null
    expect(group.accept).toEqual({ n: 0, p50: null, p95: null, max: null });
  });

  it("종류: agent_cancel → cancel, 답 단계(purpose answer:) → answer, 그 밖 → message. 다시 보냄(message:<id>:1)은 따로 한 표본", () => {
    const groups = run(
      [
        step("m0", { purpose: "message:aaa" }),
        step("m1", { purpose: "message:aaa:1" }),
        step("a0", { purpose: "answer:t:r" }),
        step("c0", { kind: "agent_cancel", purpose: "cancel:t" }),
      ],
      ["m0", "m1", "a0", "c0"].map((id) => lease(id, 1)),
    );
    expect(groups.map((g) => [g.kind, g.adapter, g.n])).toEqual([
      ["message", "agent:codex", 2],
      ["answer", "agent:codex", 1],
      ["cancel", "agent:codex", 1],
    ]);
  });

  it("adapter마다 따로 (adapter가 없으면 (없음))", () => {
    const groups = run(
      [step("a", { adapter: "agent:codex" }), step("b", { adapter: "agent:claude-code" }), step("c", { adapter: null })],
      [lease("a", 1), lease("b", 2), lease("c", 3)],
    );
    expect(groups.map((g) => g.adapter)).toEqual(["(없음)", "agent:claude-code", "agent:codex"]);
  });

  it("시각 이상(집힌 때가 만든 때보다 앞)은 표본에서 빼고 이상 수로 센다", () => {
    const [group] = run([step("ok"), step("bad"), step("bad2")], [lease("ok", 2), lease("bad", -5), called("bad2", -1), lease("bad2", 4)]);
    expect(group.anomalies).toBe(2);
    expect(group.lease).toMatchObject({ n: 2, p50: 2, max: 4 });
    expect(group.accept).toEqual({ n: 0, p50: null, p95: null, max: null });
    expect(group.buckets).toEqual({ le3: 1, le8: 1, le25: 0, gt25: 0 });
  });

  it("기간: 단계를 만든 때가 from ≤ t < to인 것만", () => {
    const groups = run(
      [step("in"), step("early", { createdAt: new Date(period.from.getTime() - 1).toISOString() }), step("edge", { createdAt: period.from.toISOString() }), step("late", { createdAt: period.to.toISOString() })],
      [],
    );
    expect(groups[0].n).toBe(2);
  });

  it("단계가 없으면 그룹도 없다", () => {
    expect(run([], [])).toEqual([]);
  });

  it("PostgREST가 주는 시각 글자(마이크로초 · +00:00)도 읽는다", () => {
    const [group] = run(
      [step("a", { createdAt: "2026-10-15T00:00:00.000001+00:00" })],
      [{ stepId: "a", toState: "calling", gate: "bridge_lease", at: "2026-10-15T00:00:02.500002+00:00" }, { stepId: "a", toState: "called", gate: "response", at: "2026-10-15T00:00:09.000003+00:00" }],
    );
    expect(group.lease).toMatchObject({ n: 1, p50: 2.5 });
    expect(group.accept).toMatchObject({ n: 1, p50: 9 });
  });
});

describe("U3 ② 전달 결과 · 명령 결과", () => {
  const result = (input: Partial<Parameters<typeof agentDelivery>[0]>, p = period) => agentDelivery({ steps: [], events: [], messages: [], commands: [], ...input }, p);
  const msg = (id: string, deliveryState: string, deliveryReason: string | null, createdAt = T(0)) => ({ id, deliveryState, deliveryReason, createdAt });
  const withReason = (id: string, purpose: string, receiptReason: string | null): DeliveryStep => ({
    id: `step-${id}`, kind: "agent_message", adapter: "agent:codex", purpose, createdAt: T(0), taskId: null, requestId: null, answerMessageId: null, answeredLocally: null, receiptReason,
  });

  it("상태 · 이유 수. expired는 lease 전 만료(단계 receipt가 expired)와 대기열 만료(단계 없음)로 가른다", () => {
    const card = result({
      messages: [
        msg("m1", "dispatched", null),
        msg("m2", "dispatched", null),
        msg("m3", "not_sent", "bridge_offline"),
        msg("m4", "expired", "expired"),
        msg("m5", "expired", "expired"),
        msg("m6", "expired", "expired"),
        msg("m7", "cancelled", "user", "2026-09-01T00:00:00Z"),
        msg("m8", "queued", "자유 글 이유"),
      ],
      steps: [withReason("m4", "message:m4", "expired"), withReason("m5", "message:m5:1", "expired"), withReason("m6", "message:m6", "not_received")],
    });
    expect(card.results).toEqual([
      { state: "queued", reason: "(기타)", n: 1 },
      { state: "dispatched", reason: "(없음)", n: 2 },
      { state: "not_sent", reason: "bridge_offline", n: 1 },
      // m4 · m5는 lease 전 만료, m6은 단계가 있지만 receipt가 expired가 아니라서 대기열 만료로 센다
      { state: "expired", reason: "expired_before_lease", n: 2 },
      { state: "expired", reason: "expired_queue", n: 1 },
    ]);
  });

  it("명령 결과: 기간이 30일 이하면 전부, 30일보다 길면 최근 30일만 + clamped", () => {
    const commands = [
      { kind: "message", outcome: "sent", createdAt: T(0) },
      { kind: "message", outcome: "request_closed", createdAt: T(10) },
      { kind: "answer", outcome: "request_closed", createdAt: T(20) },
      { kind: "answer", outcome: null, createdAt: T(30) },
      { kind: "cancel", outcome: "withdrawn", createdAt: T(-86400 * 20) },
    ];
    const week = result({ commands });
    expect(week.commandsClamped).toBe(false);
    expect(week.commands).toEqual([
      { kind: "message", outcome: "sent", n: 1 },
      { kind: "message", outcome: "request_closed", n: 1 },
      { kind: "answer", outcome: "request_closed", n: 1 },
      { kind: "answer", outcome: "(진행 중)", n: 1 },
    ]);
    const wide = { from: new Date(period.to.getTime() - 90 * 86_400_000), to: period.to };
    const old = { kind: "message", outcome: "sent", createdAt: new Date(period.to.getTime() - 40 * 86_400_000).toISOString() };
    const third = { kind: "message", outcome: "sent", createdAt: new Date(period.to.getTime() - 29 * 86_400_000).toISOString() };
    const clamped = result({ commands: [old, third] }, wide);
    expect(clamped.commandsClamped).toBe(true);
    expect(clamped.commands).toEqual([{ kind: "message", outcome: "sent", n: 1 }]);
    // 정확히 30일 기간은 자르지 않는다
    expect(result({ commands: [] }, { from: new Date(period.to.getTime() - 30 * 86_400_000), to: period.to }).commandsClamped).toBe(false);
  });
});

describe("U4 ③ 질문 → 답", () => {
  const q = (taskId: string, requestId: string, over: Partial<AgentEventRow> = {}): AgentEventRow => ({ at: T(0), eventType: "question", status: "applied", kind: "input", taskId, requestId, ...over });
  const answer = (taskId: string, requestId: string, atS: number, over: Partial<DeliveryStep> = {}): DeliveryStep => ({
    id: `a-${taskId}-${requestId}-${atS}`,
    kind: "agent_message",
    adapter: "agent:codex",
    purpose: `answer:${taskId}:${requestId}`,
    createdAt: T(atS),
    taskId,
    requestId,
    answerMessageId: null,
    answeredLocally: null,
    receiptReason: null,
    ...over,
  });
  const run = (events: AgentEventRow[], steps: DeliveryStep[], tasks: { id: string; state: string; requestId: string | null }[] = []) => agentQuestions({ events, steps, tasks }, period);
  const find = (card: ReturnType<typeof run>, kind: string, path: string) => card.groups.find((g) => g.kind === kind && g.path === path);

  it("짝(task · request)으로 답한 길을 가른다: route · message(자유 글) · local · 답 없음", () => {
    const card = run(
      [q("t1", "r1"), q("t2", "r2"), q("t3", "r3"), q("t4", "r4"), q("t5", "r5", { kind: "approval" })],
      [answer("t1", "r1", 10), answer("t2", "r2", 20, { answerMessageId: "m" }), answer("t3", "r3", 30, { answeredLocally: "true" }), answer("t5", "r5", 4)],
      [{ id: "t4", state: "awaiting_answer", requestId: "r4" }],
    );
    expect(card.asked).toBe(5);
    expect(find(card, "input", "route")).toMatchObject({ n: 1, wait: { n: 1, p50: 10 } });
    expect(find(card, "input", "message")).toMatchObject({ n: 1, wait: { n: 1, p50: 20 } });
    expect(find(card, "input", "local")).toMatchObject({ n: 1, wait: { n: 1, p50: 30 } });
    expect(find(card, "input", "unanswered_open")).toMatchObject({ n: 1, wait: { n: 0, p50: null } });
    expect(find(card, "approval", "route")).toMatchObject({ n: 1, wait: { p50: 4, p95: 4, max: 4 } });
  });

  it("answer_message_id가 있는 답은 자유 글(message)이다 — 그 인자를 무시하면 route로 센다", () => {
    const card = run([q("t", "r")], [answer("t", "r", 5, { answerMessageId: "msg-1" })]);
    expect(card.groups.map((g) => g.path)).toEqual(["message"]);
  });

  it.each([
    ["첫 단계가 먼저", [12, 90]],
    ["첫 단계가 나중", [90, 12]],
  ])("다시 보낸 답(회차)은 읽는 순서와 상관없이 첫 단계만 센다 (%s, 기다린 시간 = 첫 단계 − 질문)", (_name, atSeconds) => {
    const card = run([q("t", "r")], atSeconds.map((at) => answer("t", "r", at, { id: `s${at}` })));
    expect(find(card, "input", "route")).toMatchObject({ n: 1, wait: { n: 1, p50: 12 } });
  });

  it("답 없음: 지금 그 질문이 열려 있으면 open, 아니면(작업이 닫히거나 다른 질문) closed", () => {
    const card = run(
      [q("t1", "r1"), q("t2", "r2"), q("t3", "r3")],
      [],
      [
        { id: "t1", state: "awaiting_answer", requestId: "r1" },
        { id: "t2", state: "awaiting_answer", requestId: "other" },
        { id: "t3", state: "unreachable", requestId: null },
      ],
    );
    expect(find(card, "input", "unanswered_open")!.n).toBe(1);
    expect(find(card, "input", "unanswered_closed")!.n).toBe(2);
  });

  it("질문 사건만: applied가 아닌 것 · 다른 사건 · 기간 밖은 세지 않는다", () => {
    const card = run(
      [q("t1", "r1"), q("t2", "r2", { status: "ignored" }), q("t3", "r3", { eventType: "turn_completed" }), q("t4", "r4", { at: new Date(period.from.getTime() - 1).toISOString() }), q("t5", "r5", { at: period.to.toISOString() })],
      [],
    );
    expect(card.asked).toBe(1);
  });

  it("답이 질문보다 앞서면(시각 이상) 기다림 표본에서 빼고 이상 수로 센다", () => {
    const card = run([q("t1", "r1"), q("t2", "r2")], [answer("t1", "r1", -3), answer("t2", "r2", 6)]);
    expect(card.anomalies).toBe(1);
    expect(find(card, "input", "route")).toMatchObject({ n: 2, wait: { n: 1, p50: 6 } });
  });

  it("기다린 시간 nearest-rank p50 · p95", () => {
    const events = Array.from({ length: 20 }, (_, i) => q(`t${i}`, "r"));
    const steps = Array.from({ length: 20 }, (_, i) => answer(`t${i}`, "r", i + 1));
    expect(find(run(events, steps), "input", "route")!.wait).toMatchObject({ n: 20, p50: 10, p95: 19, max: 20 });
  });

  it("task · request id가 없는 사건은 짝을 못 맞춰 답 없음(closed)으로 센다", () => {
    const card = run([q("t", "r", { taskId: null }), q("t", "r", { requestId: null })], [answer("t", "r", 1)]);
    expect(card.groups).toEqual([{ kind: "input", path: "unanswered_closed", n: 2, wait: { n: 0, p50: null, p95: null, max: null } }]);
  });
});

describe("U5 ④ 멈춤 · 지금 막힌 것", () => {
  const stop = (runId: string, gate: string | null, atS = 0) => ({ runId, gate, at: T(atS) });
  const done = (over: Partial<AgentEventRow> = {}): AgentEventRow => ({ at: T(0), eventType: "turn_completed", status: "applied", kind: null, taskId: "t", requestId: null, ...over });
  const base = { stopEvents: [], conversationRunIds: new Set<string>(), events: [], overdueLeases: 0, unknownOutcome: 0, tasks: [], conflicts: [] };

  it("대화 run이 멈춘 까닭을 gate별로: stop(사용자 Stop) · action_closed · path_conflict · session_deleted · 기타(task run은 세지 않는다)", () => {
    const card = agentStops(
      {
        ...base,
        conversationRunIds: new Set(["c1", "c2", "c3", "c4", "c5", "c6"]),
        stopEvents: [
          stop("c1", "action_closed"),
          stop("c2", "action_closed"),
          stop("c3", "path_conflict"),
          stop("c4", "session_deleted"),
          stop("c5", "agent_terminal"),
          stop("c5", null),
          stop("c6", "stop"),
          // task run의 stopped는 0 (대화 run이 아니다)
          stop("task-run", "action_closed"),
          stop("task-run-2", "stop"),
          // 기간 밖
          stop("c1", "action_closed", -86400 * 30),
        ],
      },
      period,
    );
    expect(card.stopped).toEqual([
      { gate: "stop", n: 1 },
      { gate: "action_closed", n: 2 },
      { gate: "path_conflict", n: 1 },
      { gate: "session_deleted", n: 1 },
      { gate: "other", n: 2 },
    ]);
  });

  it("끝난 턴 수 = 기간 안 applied turn_completed", () => {
    const card = agentStops({ ...base, events: [done(), done(), done({ status: "ignored" }), done({ eventType: "question" }), done({ at: new Date(period.from.getTime() - 1).toISOString() })] }, period);
    expect(card.turnsCompleted).toBe(2);
  });

  it("지금 값 넷 + 연체 lease: 열린 충돌 수와 가장 오래된 것의 나이(period.to 기준)", () => {
    const card = agentStops(
      {
        ...base,
        overdueLeases: 3,
        unknownOutcome: 2,
        tasks: [
          { id: "a", state: "awaiting_answer", requestId: "r" },
          { id: "b", state: "awaiting_answer", requestId: "r2" },
          { id: "c", state: "unreachable", requestId: null },
        ],
        conflicts: [{ conflictAt: new Date(period.to.getTime() - 600_000).toISOString() }, { conflictAt: new Date(period.to.getTime() - 90_000).toISOString() }],
      },
      period,
    );
    expect(card.now).toEqual({ overdueLeases: 3, unknownOutcome: 2, unreachable: 1, awaitingAnswer: 2, openConflicts: 2, oldestConflictAgeS: 600 });
  });

  it("아무것도 없으면 0 · null", () => {
    expect(agentStops(base, period)).toEqual({
      stopped: [
        { gate: "stop", n: 0 },
        { gate: "action_closed", n: 0 },
        { gate: "path_conflict", n: 0 },
        { gate: "session_deleted", n: 0 },
        { gate: "other", n: 0 },
      ],
      turnsCompleted: 0,
      now: { overdueLeases: 0, unknownOutcome: 0, unreachable: 0, awaitingAnswer: 0, openConflicts: 0, oldestConflictAgeS: null },
    });
  });
});
