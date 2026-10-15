import { describe, expect, it, vi } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";
import { buildIntentState, INTENT_CRITERIA, INTENT_PROMPT_VERSION, INTENT_QUESTION } from "@/lib/ai/prompts/intent";
import { intentKindSchema } from "@/lib/api/contract";

import { classifyIntent, isWriteIntent, messageIntent, routeIntent } from "./intent";
import { INTENT_THRESHOLDS, REFERENT_CANDIDATE_LIMIT } from "./intent.config";

// J1 의도 분류 (런타임 계약 2장, A34): Jev choice 한 번에 질문 셋, 분기는 코드 규칙(임계값 0.8 / 0.5)으로만.

const answers = (overrides: Record<string, unknown>): JevDecision =>
  ({
    model: "fake-jev",
    answers: {
      intent: { type: "choice", choice: "consult", confidence: 0.9, probabilities: { consult: 0.9 } },
      remember: { type: "noul", noul: 0.1 },
      read: { type: "noul", noul: 0.7 },
      ...overrides,
    },
  }) as JevDecision;

describe("classifyIntent", () => {
  it("선택지는 계약의 의도 12개와 같다 (inform · correct · organize 포함, DR12)", () => {
    expect(Object.keys(INTENT_CRITERIA).sort()).toEqual([...intentKindSchema.options].sort());
    expect(INTENT_PROMPT_VERSION).toBe("intent-v3");
    expect(INTENT_CRITERIA.organize).toMatch(/#139/);
  });

  // intent-v3 (eval 반영): 삭제 · 병합 카드에 "응 지워"/"yes"가 organize와 겨뤄 확신이 낮았고(adopt 0.49 · 0.67), "Launch"(어느 프로젝트인가요?에 대한 답)는 instruct(0.90)로, 인용한 "> please delete #141"은 organize(0.43)로 갔다.
  it("intent-v3 설명: 열린 삭제 · 병합 · 이동 제안을 받아들이는 말은 adopt, 정리를 묻는 말에 이름 · 번호만 답하는 것은 answer, 인용 · 전달한 글과 열린 제안에 대한 짧은 답은 organize가 아니다", () => {
    expect(INTENT_CRITERIA.adopt).toMatch(/delete.*merge|merge.*delete/i);
    expect(INTENT_CRITERIA.adopt).toContain("yes, delete it");
    expect(INTENT_CRITERIA.answer).toMatch(/project|issue number/i);
    expect(INTENT_CRITERIA.organize).toMatch(/accepts or declines/i);
    expect(INTENT_CRITERIA.organize).toMatch(/quoted|forwarded/i);
    expect(INTENT_QUESTION.instructions).toContain("open_proposal");
    expect(INTENT_QUESTION.instructions).toContain("응 지워");
    expect(INTENT_QUESTION.instructions).toMatch(/Quoted text, forwarded messages/); // 인용 경고는 그대로
    for (const kind of ["instruct", "modify", "stop"] as const) expect(INTENT_CRITERIA[kind], kind).toMatch(/\(not reorganizing, deleting or merging issues\)$/);
  });

  it("Jev state: 삭제 · 병합 카드와 정리 질문은 뜻이 드러나는 말로 보낸다 (코드 이름 'confirm' · 'organize'를 그대로 보내지 않는다). 옛 값은 그대로", () => {
    const state = (asked: string | null, openProposal: string | null = null) => buildIntentState({ message: "응", previousReply: { text: "q", asked, openProposal }, selectedTargets: 0 }).previous_reply;
    expect(state("confirm", "Delete issue #141")).toEqual({ text: "q", asked_user: "confirm_yes_or_no", open_proposal: "Delete issue #141" });
    expect(state("organize")).toEqual({ text: "q", asked_user: "which_project_or_issue", open_proposal: null });
    for (const asked of ["adopt", "remember", "referent", "clarify", null]) expect(state(asked)).toMatchObject({ asked_user: asked });
  });

  it("Jev에 메시지 · 직전 답(물은 것 · 열린 제안)만 보내고 질문 셋(intent choice · remember · read noul)을 묻는다", async () => {
    const decide = vi.fn(async () => answers({}));
    const result = await classifyIntent({ message: "그렇게 해", previousReply: { text: "추가할까요?", asked: "adopt", openProposal: "Shape 출시" }, selectedTargets: 0 }, decide);
    const request = decide.mock.calls[0] as unknown as [{ state: Record<string, unknown>; questions: Record<string, { type: string }> }];
    expect(request[0].state).toEqual({
      message: "그렇게 해",
      previous_reply: { text: "추가할까요?", asked_user: "adopt", open_proposal: "Shape 출시" },
      selected_targets_in_app: 0,
    });
    expect(Object.fromEntries(Object.entries(request[0].questions).map(([k, q]) => [k, q.type]))).toEqual({ intent: "choice", remember: "noul", read: "noul" });
    expect(result).toEqual({ kind: "consult", confidence: 0.9, remember: 0.1, read: 0.7, judgeVersion: INTENT_PROMPT_VERSION, cost: 0 });
    expect(messageIntent(result)).toEqual({ kind: "consult", confidence: 0.9, judge_version: INTENT_PROMPT_VERSION });
  });

  it("confidence가 없으면 그 선택지의 확률, 모르는 선택지 · 빠진 답은 other(확신 0) → 묻는 쪽으로", async () => {
    const noConfidence = await classifyIntent(
      { message: "x", previousReply: null, selectedTargets: 0 },
      vi.fn(async () => answers({ intent: { type: "choice", choice: "inform", probabilities: { inform: 0.72, consult: 0.28 } } })),
    );
    expect([noConfidence.kind, noConfidence.confidence]).toEqual(["inform", 0.72]);
    const unknown = await classifyIntent({ message: "x", previousReply: null, selectedTargets: 0 }, vi.fn(async () => answers({ intent: { type: "choice", choice: "delete_all", confidence: 0.99, probabilities: {} } })));
    expect([unknown.kind, unknown.confidence]).toEqual(["other", 0]);
    expect(routeIntent(unknown).kind).toBe("clarify");
    const missing = await classifyIntent({ message: "x", previousReply: null, selectedTargets: 0 }, vi.fn(async () => ({ model: "m", answers: {} })) as never);
    expect([missing.kind, missing.confidence, missing.remember, missing.read]).toEqual(["other", 0, 0, 0]);
  });
});

describe("routeIntent: 임계값 (런타임 계약 12장 0.8 / 0.5)", () => {
  const route = (kind: string, confidence: number, extra: { remember?: number; read?: number } = {}) =>
    routeIntent({ kind: kind as never, confidence, remember: extra.remember ?? 0, read: extra.read ?? 0 });

  it("기본값", () => {
    expect(INTENT_THRESHOLDS).toEqual({ act: 0.8, ask: 0.5 });
    expect(REFERENT_CANDIDATE_LIMIT).toBe(3);
  });

  it("< 0.5는 어떤 의도든 묻는다", () => {
    for (const kind of intentKindSchema.options) expect(route(kind, 0.49)).toEqual({ kind: "clarify" });
  });

  it("조회 · 상담 · 그 밖은 0.5 이상이면 답한다. 함께 말한 사실은 의도 확신 ≥ 0.8 이고 remember ≥ 0.8일 때만 저장 가능 (M3: 쓰기는 확신 ≥ 0.8)", () => {
    expect(route("lookup", 0.5)).toEqual({ kind: "consult", memory: false });
    expect(route("consult", 0.95, { remember: 0.79 })).toEqual({ kind: "consult", memory: false });
    expect(route("other", 0.6, { remember: 0.95 })).toEqual({ kind: "consult", memory: false });
    expect(route("consult", 0.79, { remember: 0.95 })).toEqual({ kind: "consult", memory: false });
    expect(route("consult", 0.8, { remember: 0.8 })).toEqual({ kind: "consult", memory: true });
  });

  it("알림 · 정정 · 답: ≥ 0.8이면 저장 가능, 0.5–0.8이면 저장하지 않고 묻는다", () => {
    for (const kind of ["inform", "correct", "answer"]) {
      expect(route(kind, 0.8)).toEqual({ kind: "remember", memory: true });
      expect(route(kind, 0.79)).toEqual({ kind: "remember", memory: false });
    }
  });

  it("Taskforce가 물은 것에 답함(answer)은 그 질문에 맞게: 추가할까요 → 채택(열린 제안이 있을 때만), 어느 일인가요 → 실행 의도, 무엇을 원하나요 → 상담, 그 밖 → 기억", () => {
    const answer = (asked: "adopt" | "referent" | "clarify" | "remember" | "confirm" | "organize" | null, openProposal = false, confidence = 0.9) =>
      routeIntent({ kind: "answer", confidence, remember: 0, read: 0 }, { asked, openProposal });
    expect(answer("adopt", true)).toEqual({ kind: "adopt", confirm: false });
    expect(answer("adopt", true, 0.6)).toEqual({ kind: "adopt", confirm: true });
    expect(answer("adopt", false)).toEqual({ kind: "remember", memory: true });
    expect(answer("referent")).toEqual({ kind: "execution", confirm: false, alsoRead: false });
    expect(answer("clarify")).toEqual({ kind: "consult", memory: false });
    expect(routeIntent({ kind: "answer", confidence: 0.7, remember: 0.95, read: 0 }, { asked: "clarify", openProposal: false })).toEqual({ kind: "consult", memory: false });
    expect(answer("remember")).toEqual({ kind: "remember", memory: true });
    expect(answer(null)).toEqual({ kind: "remember", memory: true });
  });

  it("D4c-2: 삭제 · 병합 카드(asks confirm, 열린 제안 있음)에 답함 → 채택(0.5–0.8은 confirm), 열린 제안이 없으면 기억 쪽. 정리가 물은 것(asks organize)에 답함 → 정리", () => {
    const answer = (asked: "confirm" | "organize", openProposal: boolean, confidence = 0.9, read = 0) =>
      routeIntent({ kind: "answer", confidence, remember: 0, read }, { asked, openProposal });
    expect(answer("confirm", true)).toEqual({ kind: "adopt", confirm: false });
    expect(answer("confirm", true, 0.6)).toEqual({ kind: "adopt", confirm: true });
    expect(answer("confirm", false)).toEqual({ kind: "remember", memory: true });
    expect(answer("organize", false)).toEqual({ kind: "organize", confirm: false, alsoRead: false });
    expect(answer("organize", false, 0.6, 0.9)).toEqual({ kind: "organize", confirm: true, alsoRead: true });
  });

  it("채택 · 실행 · 선호: 0.5–0.8은 confirm(쓰기 0), 조회 부분(read ≥ 0.8)은 함께 답한다", () => {
    expect(route("adopt", 0.9)).toEqual({ kind: "adopt", confirm: false });
    expect(route("adopt", 0.7)).toEqual({ kind: "adopt", confirm: true });
    expect(route("instruct", 0.9, { read: 0.85 })).toEqual({ kind: "execution", confirm: false, alsoRead: true });
    expect(route("modify", 0.6)).toEqual({ kind: "execution", confirm: true, alsoRead: false });
    expect(route("stop", 0.9)).toEqual({ kind: "execution", confirm: false, alsoRead: false });
    expect(route("preference", 0.9, { read: 0.9 })).toEqual({ kind: "preference", alsoRead: true });
  });

  it("organize(D4c-2): ≥ 0.8은 바로, 0.5–0.8은 confirm(이동은 글로 한 번 묻는다), < 0.5는 clarify. 조회 부분(read ≥ 0.8)은 함께 답한다", () => {
    expect(route("organize", 0.9)).toEqual({ kind: "organize", confirm: false, alsoRead: false });
    expect(route("organize", 0.8)).toEqual({ kind: "organize", confirm: false, alsoRead: false });
    expect(route("organize", 0.79)).toEqual({ kind: "organize", confirm: true, alsoRead: false });
    expect(route("organize", 0.5)).toEqual({ kind: "organize", confirm: true, alsoRead: false });
    expect(route("organize", 0.49)).toEqual({ kind: "clarify" });
    expect(route("organize", 0.9, { read: 0.85 })).toEqual({ kind: "organize", confirm: false, alsoRead: true });
    expect(isWriteIntent("organize")).toBe(true);
  });
});
