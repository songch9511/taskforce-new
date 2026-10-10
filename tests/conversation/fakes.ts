import { vi } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";
import type { JsonCompletionRequest } from "@/lib/ai/llm";
import type { IntentKind, MessageRefs } from "@/lib/api/contract";
import type { ConsultContext, ConsultModelResponse, RespondDeps, RespondInput, WindowMessage } from "@/lib/conversation/respond";
import type { CompleteJson } from "@/lib/pipeline/extract";
import type { Decide } from "@/lib/pipeline/judge";

// 대화 v2 테스트의 가짜 모델 · 입력. 실제 모델 · 공급자를 부르지 않는다: 호출 수(mock.calls)로 "AI 호출 0"을 증명한다.

/** 고정 uuid (z.uuid가 받는 모양: version 4 · variant 8) */
export const id = (n: number, prefix = "aaaaaaaa") => `${prefix}-0000-4000-8000-${String(n).padStart(12, "0")}`;

export const USER = id(1, "11111111");
export const CONVERSATION = id(1, "cccccccc");

/**
 * support: 기억 판정(support_i, 인용이 문장을 그대로 말하는가)의 답. 숫자 하나면 모든 후보, 배열이면 후보 순서대로 (기본 0.95).
 * agrees: "기억해 둘까요?"에 대한 지금 답이 동의하는가 (기본 0.95). supportError: 판정 요청이 실패한다
 */
export type FakeIntent = { intent: IntentKind; confidence?: number; remember?: number; read?: number; support?: number | number[]; agrees?: number; supportError?: Error };

/** 가짜 Jev: J1 질문 셋(intent · remember · read)과 기억 판정(support_i)에 정해 둔 답 */
export function fakeDecide(answer: FakeIntent | ((request: Parameters<Decide>[0]) => FakeIntent)) {
  return vi.fn(async (request: Parameters<Decide>[0]): Promise<JevDecision> => {
    const a = typeof answer === "function" ? answer(request) : answer;
    const keys = Object.keys(request.questions);
    if (keys.every((key) => key.startsWith("support_") || key === "agrees")) {
      if (a.supportError) throw a.supportError;
      const value = (key: string) => {
        if (key === "agrees") return a.agrees ?? 0.95;
        const i = Number(key.slice("support_".length));
        return Array.isArray(a.support) ? (a.support[i] ?? 0.95) : (a.support ?? 0.95);
      };
      return {
        model: "fake-jev",
        answers: Object.fromEntries(keys.map((key) => [key, { type: "noul" as const, noul: value(key) }])),
        usage: { input_tokens: 1, output_tokens: 1, cost: 0 },
      };
    }
    const confidence = a.confidence ?? 0.95;
    return {
      model: "fake-jev",
      answers: {
        intent: { type: "choice", choice: a.intent, confidence, probabilities: { [a.intent]: confidence } },
        remember: { type: "noul", noul: a.remember ?? 0 },
        read: { type: "noul", noul: a.read ?? 0 },
      },
      usage: { input_tokens: 1, output_tokens: 1, cost: 0 },
    };
  });
}

export const reply = (overrides: Partial<ConsultModelResponse> = {}): ConsultModelResponse => ({
  segments: [{ text: "확인했어요.", tier: "T5" }],
  citations: [],
  proposal: null,
  memory_candidates: [],
  ...overrides,
});

/** 가짜 LLM: J2 구조화 출력으로 정해 둔 답 (요청을 보고 답을 고를 수도 있다) */
export function fakeComplete(data: ConsultModelResponse | ((request: JsonCompletionRequest<never>) => ConsultModelResponse)) {
  const fn = vi.fn(async (request: JsonCompletionRequest<never>) => ({
    data: typeof data === "function" ? data(request) : data,
    model: "fake-llm",
    usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0 },
  }));
  return fn as unknown as CompleteJson & typeof fn;
}

/** J2 요청의 자료(JSON) 부분 */
export function materialOf(request: { user: string }): Record<string, unknown> & {
  intent: { kind: string; allow_memory: boolean; allow_proposal: boolean; execution_requested: boolean };
  records: { open_actions: { total: number; shown: number; items: { id: string; title: string }[] }; recently_done: { total: number; items: { id: string; title: string }[] } };
  memory: { id: string; statement: string }[];
  memory_messages: string[];
  conversation: { earlier_messages_not_shown: number; current: string; messages: { id: string; role: string; text: string; truncated: boolean }[] };
  sources: { id: string; excerpts: string[] }[];
} {
  const start = request.user.indexOf("{");
  return JSON.parse(request.user.slice(start));
}

export const emptyRefs = (overrides: Partial<MessageRefs> = {}): MessageRefs => ({
  action_ids: [],
  run_ids: [],
  artifact_ids: [],
  suggestion_ids: [],
  dependency_ids: [],
  memory_item_ids: [],
  context_ids: [],
  proposal: null,
  ...overrides,
});

export function windowMessage(seq: number, role: WindowMessage["role"], text: string, overrides: Partial<WindowMessage> = {}): WindowMessage {
  return {
    id: id(seq, "dddddddd"),
    seq,
    role,
    text,
    textExpired: false,
    createdAt: new Date(Date.UTC(2026, 9, 10, 1, 0, seq)).toISOString(),
    refs: emptyRefs(),
    content: null,
    ...overrides,
  };
}

export const emptyContext = (overrides: Partial<ConsultContext> = {}): ConsultContext => ({
  openActions: [],
  openTotal: 0,
  doneRecent: [],
  doneRecentTotal: 0,
  memory: [],
  sources: [],
  contextVersion: null,
  ...overrides,
});

/** 대화 입력: history(앞 메시지들) + 지금 사용자 메시지 */
export function respondInput(text: string, options: { history?: WindowMessage[]; contextId?: string | null; contextName?: string | null; memory?: boolean } & Partial<RespondInput> = {}): RespondInput {
  const history = options.history ?? [];
  const seq = (history.at(-1)?.seq ?? 0) + 1;
  const current = windowMessage(seq, "user", text);
  return {
    userId: USER,
    conversation: { id: CONVERSATION, contextId: options.contextId ?? null, contextName: options.contextName ?? null },
    message: { id: current.id, seq, text, createdAt: current.createdAt },
    window: [...history, current],
    omitted: options.omitted ?? 0,
    selected: options.selected ?? [],
    flags: { memory: options.memory ?? true },
    now: new Date("2026-10-10T01:00:00Z"),
  };
}

let counter = 0;
export function deps(models: { decide: ReturnType<typeof fakeDecide>; complete?: ReturnType<typeof fakeComplete> }, context: ConsultContext = emptyContext()) {
  const retrieve = vi.fn(async () => context);
  const complete = models.complete ?? fakeComplete(reply());
  const value: RespondDeps = { decide: models.decide, complete, retrieve, newId: () => id(++counter, "eeeeeeee") };
  return { deps: value, retrieve, complete, decide: models.decide };
}
