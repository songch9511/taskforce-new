import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { agentDeliveryReasonSchema, agentDeliverySchema } from "@/lib/api/contract";

import { agentDeliveryView, agentMessageDelivery } from "./delivery";

it.each(["queued", "not_sent", "expired", "cancelled"] as const)("preserves %s", (state) => {
  expect(agentMessageDelivery(state, "called")).toBe(state);
});
it.each([["prepared", "sent"], ["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("maps dispatched/%s to %s", (step, state) => {
  expect(agentMessageDelivery("dispatched", step)).toBe(state);
});
it.each(["failed", "pending", "skipped", null] as const)("defensively maps inconsistent dispatched/%s instead of claiming delivery", (step) => {
  expect(agentMessageDelivery("dispatched", step)).toBe("not_sent");
});

// ─── D1d: 응답 전달 표시 계산 (계약 2.15 · OD-11 · OD-12 · OD-15 · 코디네이터 5.1 답 메시지) ───
const A1 = "aaaaaaaa-0000-4000-8000-000000000001";
const A2 = "aaaaaaaa-0000-4000-8000-000000000002";
const A3 = "aaaaaaaa-0000-4000-8000-000000000003";
const view = (row: Partial<Parameters<typeof agentDeliveryView>[0]["row"]>, rest: Partial<Parameters<typeof agentDeliveryView>[0]> = {}) =>
  agentDeliveryView({ row: { state: "queued", reason: null, refs: {}, ...row }, stepState: null, titles: new Map(), ...rest });

describe("agentDeliveryView: 계약 2.15 표의 모든 행", () => {
  it.each(["queued", "not_sent", "expired"] as const)("%s는 그 상태 + 이유(있으면)", (state) => {
    expect(view({ state })).toEqual({ state });
    expect(view({ state, reason: "session_busy" })).toEqual({ state, reason: "session_busy" });
  });

  it("cancelled는 이유 없이 cancelled", () => {
    expect(view({ state: "cancelled", reason: "usage_limited" })).toEqual({ state: "cancelled" });
  });

  it("queued + 후보가 있고 아직 고르지 않았으면 needs_referent + 후보 제목 (≤ 3)", () => {
    const titles = new Map([[A1, "가격 문구"], [A2, "온보딩"], [A3, "제안서"]]);
    expect(view({ refs: { referent_candidates: [A1, A2, A3] } }, { titles })).toEqual({
      state: "needs_referent",
      candidates: [{ action_id: A1, title: "가격 문구" }, { action_id: A2, title: "온보딩" }, { action_id: A3, title: "제안서" }],
    });
    // 네 번째 후보는 자른다 · 제목을 못 읽은(지워진) 후보는 뺀다
    expect(view({ refs: { referent_candidates: [A1, A2, A3, "aaaaaaaa-0000-4000-8000-000000000004"] } }, { titles })).toMatchObject({ candidates: [{ action_id: A1 }, { action_id: A2 }, { action_id: A3 }] });
    expect(view({ refs: { referent_candidates: [A1, "aaaaaaaa-0000-4000-8000-000000000009"] } }, { titles })).toEqual({ state: "needs_referent", candidates: [{ action_id: A1, title: "가격 문구" }] });
  });

  it("제목을 읽은 후보가 넷이어도 셋까지만 돌려준다", () => {
    const A4 = "aaaaaaaa-0000-4000-8000-000000000004";
    const titles = new Map([[A1, "하나"], [A2, "둘"], [A3, "셋"], [A4, "넷"]]);
    expect(view({ refs: { referent_candidates: [A1, A2, A3, A4] } }, { titles })).toMatchObject({ state: "needs_referent", candidates: [{ action_id: A1 }, { action_id: A2 }, { action_id: A3 }] });
    expect((view({ refs: { referent_candidates: [A1, A2, A3, A4] } }, { titles }) as { candidates: unknown[] }).candidates).toHaveLength(3);
  });

  it("후보를 이미 골랐으면(referent_action_id) 보통 queued 표시다. not_sent · 후보 빈 목록도 보통 표시다", () => {
    const titles = new Map([[A1, "가격 문구"]]);
    expect(view({ reason: "session_busy", refs: { referent_candidates: [A1], referent_action_id: A1 } }, { titles })).toEqual({ state: "queued", reason: "session_busy" });
    expect(view({ state: "not_sent", reason: "usage_limited", refs: { referent_candidates: [A1] } }, { titles })).toEqual({ state: "not_sent", reason: "usage_limited" });
    expect(view({ refs: { referent_candidates: [] } })).toEqual({ state: "queued" });
  });

  it.each([["prepared", "sent"], ["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("dispatched + 단계 %s → %s", (stepState, state) => {
    expect(view({ state: "dispatched" }, { stepState })).toEqual({ state });
  });

  it.each([["prepared", "queued"], ["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("unreachable + 단계 %s → %s (OD-11)", (stepState, state) => {
    expect(view({ state: "dispatched" }, { stepState, sessionStatus: "unreachable" })).toEqual({ state });
  });

  // F1s 항목 1 (D1): unreachable만 prepared를 queued로 보인다. 다른 세션 상태는 모두 sent (`sessionStatus !== "bound"` 같은 변이를 잡는다)
  it.each(["bound", "external", "closed"] as const)("dispatched + 단계 prepared + 세션 %s → sent (OD-11은 unreachable만)", (sessionStatus) => {
    expect(agentMessageDelivery("dispatched", "prepared", sessionStatus)).toBe("sent");
    expect(view({ state: "dispatched" }, { stepState: "prepared", sessionStatus })).toEqual({ state: "sent" });
  });

  it.each(["failed", "pending", "skipped", null] as const)("dispatched + 단계 %s는 전달했다고 말하지 않는다 (not_sent, 이유 없음)", (stepState) => {
    expect(view({ state: "dispatched", reason: "usage_limited" }, { stepState })).toEqual({ state: "not_sent" });
  });

  it("모르는 이유 문자열은 빼고 표시한다 (500으로 깨지지 않는다)", () => {
    expect(view({ state: "not_sent", reason: "brand_new_reason" })).toEqual({ state: "not_sent" });
  });
});

describe("agentDeliveryView: 질문에 자유 글로 답한 메시지 (OD-15 · 코디네이터 5.1)", () => {
  const answered = { state: "dispatched" as const, refs: { answer_for: [A1, "request"] } };

  it("답 단계가 접수 전이든 후든 answered", () => {
    for (const state of ["prepared", "calling", "called", "unknown_outcome"] as const) {
      expect(view(answered, { stepState: "called", answerStep: { state, reason: null } })).toEqual({ state: "answered" });
    }
    expect(view(answered, { stepState: "called" })).toEqual({ state: "answered" });
  });

  it("답 단계가 failed(DEC-5로 카드 복원)면 not_sent + 이유(알 수 있으면)", () => {
    expect(view(answered, { answerStep: { state: "failed", reason: "usage_limited" } })).toEqual({ state: "not_sent", reason: "usage_limited" });
    expect(view(answered, { answerStep: { state: "failed", reason: "agent_error" } })).toEqual({ state: "not_sent" });
    expect(view(answered, { answerStep: { state: "failed", reason: null } })).toEqual({ state: "not_sent" });
  });

  it("답 단계가 skipped(Stop · Done으로 버림)면 메시지는 cancelled", () => {
    expect(view({ ...answered, state: "cancelled" }, { answerStep: { state: "skipped", reason: null } })).toEqual({ state: "cancelled" });
    expect(view(answered, { answerStep: { state: "skipped", reason: null } })).toEqual({ state: "cancelled" });
  });
});

describe("R12: SQL이 delivery_reason에 쓸 수 있는 모든 값은 agentDeliveryReasonSchema에 있다 (마이그레이션 정적 검사)", () => {
  const dir = path.resolve(__dirname, "../../../supabase/migrations");
  const sql = readdirSync(dir)
    .filter((name) => name.endsWith(".sql"))
    .sort()
    .map((name) => readFileSync(path.join(dir, name), "utf8").split("\n").filter((line) => !line.trim().startsWith("--")).join("\n"))
    .join("\n");
  const literals = (text: string) => [...text.matchAll(/'([a-z][a-z0-9_]*)'/g)].map((match) => match[1]);
  const written = new Set<string>();
  const add = (values: string[]) => values.forEach((value) => written.add(value));
  for (const match of sql.matchAll(/delivery_reason\s*=\s*'([a-z][a-z0-9_]*)'/g)) written.add(match[1]);
  for (const match of sql.matchAll(/v_reason\s*:=\s*'([a-z][a-z0-9_]*)'/g)) written.add(match[1]);
  // Bridge stale/withdrawn 응답의 reason은 메시지 delivery_reason과 다른 계약이다.
  for (const match of sql.matchAll(/'status',\s*'(?:not_sent|queued)',\s*'reason',\s*'([a-z][a-z0-9_]*)'/g)) written.add(match[1]);
  for (const match of sql.matchAll(/mark_agent_message_not_sent\([^)]*?,\s*'([a-z][a-z0-9_]*)'\)/g)) written.add(match[1]);
  // bridge lease의 회수: withdraw_bridge_command(<id>, '<이유>')의 이유는 메시지 delivery_reason이 된다 (F1s 항목 5). enum 밖의 값을 넘기는 이름 붙은 예외는 둘뿐이다
  const WITHDRAW_EXCEPTIONS: Record<string, string> = {
    expired: "상태가 이미 expired라 이유는 덧말이다: 20261127000000 뒤 withdraw_bridge_command가 이유를 null로 저장한다",
    stale_answer: "answer 명령에서만 쓰고 메시지 행을 쓰지 않는다 (답 단계만 skipped)",
  };
  const withdrawCalls = new Set<string>();
  for (const match of sql.matchAll(/withdraw_bridge_command\([^,]+,\s*'([a-z][a-z0-9_]*)'\)/g)) withdrawCalls.add(match[1]);
  for (const reason of withdrawCalls) if (!(reason in WITHDRAW_EXCEPTIONS)) written.add(reason);
  for (const match of sql.matchAll(/p_reason not in \(([^)]*)\)/g)) add(literals(match[1]));
  // bridge가 알린 접수 전 실패 이유는 검증 목록 안에서만 delivery_reason이 된다 (apply_agent_event)
  for (const match of sql.matchAll(/v_payload->>'reason' not in \(('sign_in_needed'[^)]*)\) then\s*raise exception 'apply_agent_event: invalid pre-accept/g)) add(literals(match[1]));

  it("글자 검색이 말라 버리지 않았다: 계약에 없던 SQL 이유 여덟과 접수 전 실패 이유 넷을 찾아낸다", () => {
    for (const reason of ["session_busy", "live_limit", "queue_order", "session_closed", "invalid_referent", "not_found", "already_dispatched", "question_open", "session_external",
      "sign_in_needed", "usage_limited", "spawn_failed", "version_unsupported", "write_gate_closed", "not_connected", "unsupported"]) {
      expect(written, reason).toContain(reason);
    }
  });

  it("쓸 수 있는 값 전부가 zod enum에 있다", () => {
    const missing = [...written].filter((reason) => !agentDeliveryReasonSchema.safeParse(reason).success);
    expect(missing).toEqual([]);
  });

  it("zod enum의 값은 계약 아홉 + SQL이 쓰는 값뿐이다 (not_received는 bridge readback이 쓸 계약 값)", () => {
    const contractOnly = new Set(["not_received"]);
    const extra = agentDeliveryReasonSchema.options.filter((reason) => !written.has(reason) && !contractOnly.has(reason));
    expect(extra).toEqual([]);
  });

  it("agentDeliverySchema는 view의 결과를 모두 받는다", () => {
    expect(agentDeliverySchema.safeParse(view({ state: "queued", reason: "question_open" })).success).toBe(true);
  });

  it("회수 호출(withdraw_bridge_command)의 이유 글자를 모았고, 이름 붙인 예외 둘이 실제 호출에 있다 (마른 예외 0)", () => {
    for (const reason of ["write_gate_closed", "unsupported"]) expect(withdrawCalls, reason).toContain(reason);
    expect(Object.keys(WITHDRAW_EXCEPTIONS).sort()).toEqual(["expired", "stale_answer"]);
    for (const reason of Object.keys(WITHDRAW_EXCEPTIONS)) {
      expect(withdrawCalls, `${reason}: 호출에 없는 예외`).toContain(reason);
      expect(agentDeliveryReasonSchema.safeParse(reason).success, `${reason}: enum에 들어갔으면 예외에서 뺀다`).toBe(false);
    }
  });

  it("회수 호출의 이유는 enum이거나 이름 붙인 예외다", () => {
    const unknown = [...withdrawCalls].filter((reason) => !(reason in WITHDRAW_EXCEPTIONS) && !agentDeliveryReasonSchema.safeParse(reason).success);
    expect(unknown).toEqual([]);
  });

  it("withdraw_bridge_command의 마지막 정의는 expired 회수에 이유를 쓰지 않는다 (null) — 나머지 이유는 그대로", () => {
    const definitions = [...sql.matchAll(/create (?:or replace )?function public\.withdraw_bridge_command\([^)]*\)[\s\S]*?as \$\$([\s\S]*?)\$\$;/g)].map((match) => match[1]);
    expect(definitions.length).toBeGreaterThanOrEqual(2);
    const latest = definitions.at(-1)!;
    expect(latest).toContain("delivery_reason=case when p_reason='expired' then null else p_reason end");
    expect(latest).not.toMatch(/delivery_reason\s*=\s*p_reason/);
    expect(definitions[0]).toMatch(/delivery_reason=p_reason/); // BC의 원래 정의는 이유를 그대로 썼다 (기록)
  });
});

// ─── F1s 항목 7 (D7): 만료한 prepared 메시지는 expired로 보인다 ───
describe("agentDeliveryView 만료 표시: dispatched + prepared가 delivery_expires_at 뒤에도 queued로 보이던 틈 (F1s 항목 7)", () => {
  const EXPIRES = "2026-10-15T12:00:00.000Z";
  const before = new Date("2026-10-15T11:59:59.999Z");
  const at = new Date(EXPIRES);
  const after = new Date("2026-10-15T12:00:01.000Z");
  const dispatched = { state: "dispatched" as const };

  it("만료 전: unreachable + prepared는 queued (OD-11 그대로), 그 밖은 sent", () => {
    expect(view(dispatched, { stepState: "prepared", sessionStatus: "unreachable", expiresAt: EXPIRES, now: before })).toEqual({ state: "queued" });
    expect(view(dispatched, { stepState: "prepared", sessionStatus: "bound", expiresAt: EXPIRES, now: before })).toEqual({ state: "sent" });
  });

  it.each(["unreachable", "bound", "external", "closed", undefined] as const)("만료 시각이 되면(≤) prepared는 세션 %s여도 expired다 (lease의 회수 조건과 같다)", (sessionStatus) => {
    for (const now of [at, after]) expect(view(dispatched, { stepState: "prepared", sessionStatus, expiresAt: EXPIRES, now })).toEqual({ state: "expired" });
  });

  it.each([["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("단계 %s는 만료 뒤에도 %s 그대로다 (이미 Mac에 넘어갔다)", (stepState, state) => {
    expect(view(dispatched, { stepState, sessionStatus: "unreachable", expiresAt: EXPIRES, now: after })).toEqual({ state });
  });

  it("질문에 답한 글(answer_for)은 만료 시각과 상관없이 그대로다", () => {
    expect(view({ state: "dispatched", refs: { answer_for: [A1, "request"] } }, { stepState: "prepared", expiresAt: EXPIRES, now: after })).toEqual({ state: "answered" });
    expect(view({ state: "dispatched", refs: { answer_for: [A1, "request"] } }, { stepState: "prepared", expiresAt: EXPIRES, now: after, answerStep: { state: "failed", reason: "usage_limited" } })).toEqual({ state: "not_sent", reason: "usage_limited" });
  });

  it("만료 시각이 없거나 읽을 수 없으면 만료로 보지 않는다", () => {
    for (const expiresAt of [undefined, null, "", "not-a-date"]) {
      expect(view(dispatched, { stepState: "prepared", sessionStatus: "unreachable", expiresAt, now: after }), String(expiresAt)).toEqual({ state: "queued" });
    }
  });

  it("dispatched가 아닌 행은 만료 시각을 보지 않는다 (queued · not_sent는 만료 sweep의 몫)", () => {
    expect(view({ state: "queued" }, { stepState: "prepared", expiresAt: EXPIRES, now: after })).toEqual({ state: "queued" });
    expect(view({ state: "not_sent", reason: "session_busy" }, { stepState: "prepared", expiresAt: EXPIRES, now: after })).toEqual({ state: "not_sent", reason: "session_busy" });
    expect(view({ state: "cancelled" }, { stepState: "prepared", expiresAt: EXPIRES, now: after })).toEqual({ state: "cancelled" });
  });

  it("now를 안 주면 지금 시각이다", () => {
    expect(view(dispatched, { stepState: "prepared", sessionStatus: "unreachable", expiresAt: "2000-01-01T00:00:00.000Z" })).toEqual({ state: "expired" });
    expect(view(dispatched, { stepState: "prepared", sessionStatus: "unreachable", expiresAt: "2999-01-01T00:00:00.000Z" })).toEqual({ state: "queued" });
  });

  it("결과는 agentDeliverySchema를 지킨다 (이유 없는 expired)", () => {
    const result = view(dispatched, { stepState: "prepared", expiresAt: EXPIRES, now: after });
    expect(result).toEqual({ state: "expired" });
    expect(agentDeliverySchema.safeParse(result).success).toBe(true);
  });
});
