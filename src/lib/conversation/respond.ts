import { z } from "zod";

import { answerLanguage } from "@/lib/ai/prompts/ask";
import { buildConsultUserPrompt, CONSULT_PROMPT_VERSION, CONSULT_SYSTEM_PROMPT, type ConsultPromptAction } from "@/lib/ai/prompts/consult";
import { INTENT_PROMPT_VERSION } from "@/lib/ai/prompts/intent";
import { MEMORY_EXTRACT_PROMPT_VERSION } from "@/lib/ai/prompts/memory-extract";
import type { AskCitation, ConversationMessageContent, MessageIntent, MessageRefs, Proposal, ResponseSegment } from "@/lib/api/contract";
import type { MemoryScope } from "@/lib/context/memory";
import { verifyCitations, type AskAction, type AskSource } from "@/lib/pipeline/ask";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { CompleteJson } from "@/lib/pipeline/extract";
import type { Decide } from "@/lib/pipeline/judge";

import {
  CONVERSATION_WINDOW,
  DONE_RECENT_DAYS,
  MEMORY_SHOWN,
  REPLY_SEGMENTS_MAX,
  REPLY_TEXT_MAX_CHARS,
  SOURCES_SHOWN,
  WINDOW_MESSAGE_CHARS,
} from "./conversation.config";
import { classifyIntent, messageIntent, routeIntent, type IntentResult, type IntentRoute } from "./intent";
import {
  checkMemorySupport,
  planMemoryWrites,
  withSupport,
  type MemoryDropReason,
  type MemoryNote,
  type MemoryPlan,
  type MemoryWritePlan,
  type QuotableMessage,
  type ShownMemory,
} from "./memory";
import { adoptPlan, proposalFromModel, proposalIntact, reissueProposal, type AdoptPlan, type ProposalPayload } from "./proposal";
import { resolveReferent, type OpenProposalRef, type Referent, type Target } from "./referent";

// 대화 한 번의 답 (POST /api/v2/conversations/{id}/messages의 본체, 구현 계획 B2). DB와 분리된 함수: 모델(Jev · LLM)과 기록 읽기를 인자로 받아
// route · eval · 테스트가 같은 코드를 쓴다. 쓰기는 하지 않고 "무엇을 쓸지"(TurnPlan)를 돌려준다: store가 conversation_finish_turn 한 트랜잭션으로 쓴다.
//
// 흐름: J1 의도(Jev) → 분기(routeIntent, 앞 답이 물은 것 포함) → 필요할 때만 기록 읽기 + J2 상담(LLM 한 번, 기억 후보 J7 포함)
//   → 코드 확인(인용 · 등급 · 제안 · 기억 인용 대조) → 기억 후보가 남으면 판정(Jev 한 번: 인용이 문장을 그대로 말하는가) → 코드가 붙이는 문구.
// - 확인된 기록(T1) · 사용자가 한 말(T2) · 제안/추론(T5)을 나눈다. 기록이 없는데 T1이라고 한 구간은 T5로 내린다.
// - 원문 검색 결과가 없어도 상담을 끝내지 않는다(A02): 고정된 "모름" 답이 없다. 모델이 답을 만들지 못하면 오류다(가짜 답을 만들지 않는다).
// - 기억 · 채택 · 제안 · 실행 안내 문구는 코드가 실제 결과로 붙인다: 모델은 "기억했어요"를 말하지 않는다.
// - 실행 의도는 실행하지 않는다: run 0, "아직 실행을 맡길 연결이 없어요". 대상이 모호하면 후보 ≤ 3개로 한 번 묻고 쓰기 0 (A34).
// - 사용자 글 · 답은 로그에 남기지 않는다. summary에는 숫자 · 코드만.

export type WindowMessage = {
  id: string;
  seq: number;
  role: "user" | "assistant" | "event";
  text: string;
  /** 대화 글 보관 기한이 지나 글이 비었다 */
  textExpired: boolean;
  createdAt: string;
  refs: MessageRefs;
  content: ConversationMessageContent | null;
};

export type ConsultAction = AskAction & { needs_confirmation: boolean; in_scope: boolean | null };
export type ConsultSource = AskSource & { excerpts: string[] };
export type ConsultMemory = ShownMemory & { observed_at: string };

/** 상담에 쓰는 기록 (store.ts loadConsultContext). 할 일은 조건 조회 결과(검색 top-k가 아니다, A04) */
export type ConsultContext = {
  openActions: ConsultAction[];
  /** 등록된 열린 할 일 전체 수 (보여 준 수와 다를 수 있다) */
  openTotal: number;
  doneRecent: ConsultAction[];
  doneRecentTotal: number;
  /** 요청 범위에서 지금 쓰는 기억 (explicit · observed만, 추정 · 정정 · 잊은 · 만료 · 읽을 수 없는 원문 제외) */
  memory: ConsultMemory[];
  /** 근거 원문 (할 일 근거 · 범위 조각). text는 인용 검증용, excerpts는 모델에 보내는 발췌 */
  sources: ConsultSource[];
  /** 기억 · 조각을 읽은 범위의 version (범위가 없으면 null) */
  contextVersion: number | null;
};

export type RespondInput = {
  userId: string;
  conversation: { id: string; contextId: string | null; contextName: string | null };
  message: { id: string; seq: number; text: string; createdAt: string };
  /** 지금 메시지까지의 최근 메시지 (seq 순, 지금 메시지가 마지막) */
  window: WindowMessage[];
  /** 창에 넣지 않은 앞 메시지 수 */
  omitted: number;
  /** 앱이 보낸 대상 (소유를 확인한 것만) */
  selected: Target[];
  flags: { memory: boolean };
  now: Date;
};

export type RespondDeps = {
  decide: Decide;
  complete: CompleteJson;
  /** 기록 읽기. chunks: 범위 조각 검색(임베딩)을 할지. 모델 답이 필요 없는 분기에서는 부르지 않거나 chunks false로 부른다 */
  retrieve: (query: { text: string; chunks: boolean }) => Promise<ConsultContext>;
  newId: () => string;
};

export type TurnPlan = {
  intent: MessageIntent;
  route: IntentRoute["kind"];
  user: { refs: MessageRefs };
  reply: { text: string; segments: ResponseSegment[]; citations: AskCitation[]; refs: MessageRefs; content: ConversationMessageContent };
  memory: MemoryWritePlan[];
  adopt: AdoptPlan | null;
  /** 로그 · eval용 (글 없음) */
  summary: {
    intent: { kind: string; confidence: number; remember: number; read: number };
    route: IntentRoute["kind"];
    consulted: boolean;
    citations: number;
    citationsDropped: number;
    tierDowngraded: number;
    memoryWrites: number;
    memoryDropped: MemoryDropReason[];
    proposal: boolean;
    adopt: boolean;
    model: string | null;
    cost: number;
    promptVersions: { intent: string; consult: string; memory: string };
  };
};

/** 모델이 답을 만들지 못함 (빈 구간). route는 500으로 답하고 아무것도 쓰지 않는다 */
export class ConsultOutputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConsultOutputError";
  }
}

// ─── 모델 응답 스키마 (J2 + J7) ───────────────────────────

const MODEL_MEMORY_KINDS = ["goal", "condition", "outcome_criteria", "relationship", "fact", "working_rule", "plan"] as const;

export const consultModelResponseSchema = z.object({
  segments: z.array(z.object({ text: z.string(), tier: z.enum(["T1", "T2", "T5"]) })),
  citations: z.array(z.object({ source: z.string(), action: z.string().nullable(), quote: z.string() })),
  proposal: z.object({ title: z.string() }).nullable(),
  memory_candidates: z.array(
    z.object({
      kind: z.enum(MODEL_MEMORY_KINDS),
      subject: z.string(),
      statement: z.string(),
      message: z.string(),
      quote: z.string(),
      corrects: z.string().nullable(),
    }),
  ),
});
export type ConsultModelResponse = z.infer<typeof consultModelResponseSchema>;

// ─── 코드가 붙이는 문구 (사용자 언어: 한국어 또는 영어) ─────────────

type Lang = "ko" | "en";
const ALL_WORK = "All work";

const TEXT = {
  clarify: { ko: "어떤 걸 원하시는지 조금만 더 알려 주세요.", en: "Could you tell me a bit more about what you'd like?" },
  rememberAsk: { ko: "이 내용을 기억해 둘까요?", en: "Should I remember this?" },
  memoryOff: { ko: "기억 기능이 꺼져 있어 저장하지 않았어요.", en: "Memory is off, so nothing was saved." },
  memoryNone: { ko: "말씀에서 그대로 확인할 수 있는 내용이 없어 기억하지 않았어요.", en: "Nothing was saved: I couldn't match it to your exact words." },
  memoryFailed: { ko: "기억하지 못했어요. 다시 말해 주세요.", en: "Couldn't save that. Please say it again." },
  execution: { ko: "아직 실행을 맡길 연결이 없어요.", en: "There's no connected agent to run this yet." },
  preference: { ko: "선호 저장은 아직 지원하지 않아요.", en: "Saving preferences isn't supported yet." },
  noProposal: { ko: "추가할 제안이 없어요.", en: "There's nothing to add yet." },
} as const;

const remembered = (lang: Lang, statements: string[], scope: string) =>
  lang === "ko" ? `기억했어요: ${statements.join(" · ")} (범위: ${scope})` : `Remembered: ${statements.join(" · ")} (scope: ${scope})`;
const corrected = (lang: Lang, previous: string, next: string, scope: string) =>
  lang === "ko" ? `고쳤어요: ${previous} → ${next} (범위: ${scope})` : `Updated: ${previous} → ${next} (scope: ${scope})`;
const already = (lang: Lang, statements: string[]) =>
  lang === "ko" ? `이미 기억하고 있어요: ${statements.join(" · ")}` : `Already remembered: ${statements.join(" · ")}`;
const adopted = (lang: Lang, title: string) => (lang === "ko" ? `할 일로 추가했어요: ${title}` : `Added to your tasks: ${title}`);
const alreadyAdopted = (lang: Lang, title: string) => (lang === "ko" ? `이미 추가한 할 일이에요: ${title}` : `Already added: ${title}`);
const adoptAsk = (lang: Lang, title: string) => (lang === "ko" ? `‘${title}’을(를) 할 일로 추가할까요?` : `Add “${title}” to your tasks?`);
const referentAsk = (lang: Lang, candidates: Target[]) => {
  const label = (t: Target) => (t.kind === "action" ? t.title : `${t.kind} ${t.id.slice(0, 8)}`);
  const list = candidates.map((t, i) => `${i + 1}) ${label(t)}`).join(" ");
  return lang === "ko" ? `어느 일인가요? ${list}` : `Which one? ${list}`;
};

// ─── 본체 ─────────────────────────────────────────────

const emptyRefs = (): MessageRefs => ({
  action_ids: [],
  run_ids: [],
  artifact_ids: [],
  suggestion_ids: [],
  dependency_ids: [],
  memory_item_ids: [],
  context_ids: [],
  proposal: null,
});

const emptyContent = (): ConversationMessageContent => ({ segments: [], citations: [], proposal: null, asks: null, used: null, window: null });

/** 지금 메시지 바로 앞의 assistant 메시지 (규칙 2의 "직전 assistant 메시지") */
function previousAssistant(input: RespondInput): WindowMessage | null {
  for (let i = input.window.length - 1; i >= 0; i--) {
    const message = input.window[i];
    if (message.seq >= input.message.seq) continue;
    if (message.role === "assistant") return message;
    if (message.role === "user") return null; // 앞 사용자 메시지가 먼저 나오면 직전 답이 없다 (답을 못 받은 메시지)
  }
  return null;
}

function openProposalOf(message: WindowMessage | null): OpenProposalRef | null {
  const proposal = message?.refs.proposal;
  if (!message || !proposal || proposal.state !== "open") return null;
  const payload = message.content?.proposal ?? null;
  if (!proposalIntact(proposal, payload)) return null;
  return { messageId: message.id, proposalId: proposal.id, payloadHash: proposal.payload_hash, title: payload.title };
}

function targetsToRefs(targets: Target[]): Pick<MessageRefs, "action_ids" | "run_ids" | "artifact_ids"> {
  return {
    action_ids: targets.filter((t) => t.kind === "action").map((t) => t.id),
    run_ids: targets.filter((t) => t.kind === "run").map((t) => t.id),
    artifact_ids: targets.filter((t) => t.kind === "artifact").map((t) => t.id),
  };
}

export async function respondToMessage(input: RespondInput, deps: RespondDeps): Promise<TurnPlan> {
  const lang: Lang = answerLanguage(input.message.text) === "한국어" ? "ko" : "en";
  const previous = previousAssistant(input);
  const previousProposal = openProposalOf(previous);
  const intent = await classifyIntent(
    {
      message: input.message.text,
      previousReply: previous ? { text: previous.text, asked: previous.content?.asks ?? null, openProposal: previousProposal?.title ?? null } : null,
      selectedTargets: input.selected.length,
    },
    deps.decide,
  );
  const route = routeIntent(intent, { asked: previous?.content?.asks ?? null, openProposal: previousProposal !== null });
  // 앞 답이 "어느 일인가요?"였고 그 답이면 다시 묻지 않는다 (B2에는 실행 연결이 없어 고른 대상으로 할 일이 없다)
  const answeredReferent = intent.kind === "answer" && previous?.content?.asks === "referent";

  const userRefs: MessageRefs = { ...emptyRefs(), ...targetsToRefs(input.selected) };
  const replyRefs: MessageRefs = emptyRefs();
  const content = emptyContent();
  const segments: ResponseSegment[] = [];
  let citations: AskCitation[] = [];
  let memoryWrites: MemoryWritePlan[] = [];
  let adopt: AdoptPlan | null = null;
  let consulted: Consulted | null = null;
  const push = (text: string, tier: ResponseSegment["tier"]) => segments.push({ text: segments.length > 0 ? `\n\n${text}` : text, tier });

  const runConsult = async (options: ConsultOptions) => {
    consulted = await consult(input, deps, intent, options);
    segments.push(...consulted.segments);
    citations = consulted.citations;
    content.used = consulted.used;
    content.window = consulted.window;
    if (consulted.proposal) {
      replyRefs.proposal = consulted.proposal.ref;
      content.proposal = consulted.proposal.payload;
    }
    return consulted;
  };

  switch (route.kind) {
    case "clarify": {
      push(TEXT.clarify[lang], "T5");
      content.asks = "clarify";
      break;
    }

    case "adopt": {
      const referent: Referent = resolveReferent({ selected: [], previousProposal, linkedOpenActions: [], wants: "proposal" });
      if (referent.kind === "proposal") {
        const payload: ProposalPayload = { kind: "create_action", title: referent.proposal.title };
        if (route.confirm) {
          // 확신 0.5–0.8: 쓰지 않고 한 번 묻는다. 같은 내용을 새 id로 다시 낸다(앞 제안은 superseded): 다음 "응"이 이 제안을 가리킨다
          const again = reissueProposal(payload, deps.newId);
          replyRefs.proposal = again.ref;
          content.proposal = again.payload;
          content.asks = "adopt";
          push(adoptAsk(lang, payload.title), "T5");
        } else {
          adopt = adoptPlan({
            userId: input.userId,
            conversationId: input.conversation.id,
            adoptMessageId: input.message.id,
            proposalMessageId: referent.proposal.messageId,
            proposal: { id: referent.proposal.proposalId, payload_hash: referent.proposal.payloadHash },
            payload,
            now: input.now,
            newId: deps.newId,
          });
          userRefs.proposal = { id: referent.proposal.proposalId, kind: "create_action", payload_hash: referent.proposal.payloadHash, state: "adopted" };
          push(adopted(lang, payload.title), "T1");
        }
      } else {
        // 직전 답에 열린 제안이 없다: 이미 채택한 제안이면 그 Action을 가리키고(두 번째 채택은 멱등, A41), 아니면 쓰지 않는다
        const last = [...input.window].reverse().find((m) => m.seq < input.message.seq && m.role === "assistant" && m.refs.proposal);
        if (last?.refs.proposal?.state === "adopted" && last.content?.proposal) {
          replyRefs.action_ids = [...last.refs.action_ids];
          userRefs.action_ids = [...new Set([...userRefs.action_ids, ...last.refs.action_ids])];
          push(alreadyAdopted(lang, last.content.proposal.title), "T1");
        } else {
          push(TEXT.noProposal[lang], "T5");
        }
      }
      break;
    }

    case "execution": {
      // 실행하지 않는다 (B2에는 실행 연결이 없다: run 0). 대상만 정하고, 모호하면 묻는다
      // 모델 답이 필요한 때: 조회 부분이 있거나, 대상이 없는 새 지시라 할 일로 남길지 제안할 수 있을 때. 원문 조각은 조회 부분이 있을 때만 찾는다
      const context = await deps.retrieve({ text: input.message.text, chunks: route.alsoRead });
      const referent = resolveReferent({
        selected: input.selected,
        previousProposal: null,
        linkedOpenActions: linkedOpenActions(input, context),
        wants: "work",
      });
      const canPropose = intent.kind === "instruct" && referent.kind === "none" && !route.confirm;
      if (route.alsoRead || canPropose) {
        await runConsult({ context, allowMemory: false, allowProposal: canPropose, executionRequested: true });
      }
      push(TEXT.execution[lang], "T1");
      if (referent.kind === "target") Object.assign(userRefs, mergeTargetRefs(userRefs, referent.target));
      if (referent.kind === "ask" && !answeredReferent) {
        push(referentAsk(lang, referent.candidates), "T5");
        content.asks = "referent";
      }
      break;
    }

    case "preference": {
      if (route.alsoRead) {
        await runConsult({ context: await deps.retrieve({ text: input.message.text, chunks: true }), allowMemory: false, allowProposal: false, executionRequested: false });
      }
      push(TEXT.preference[lang], "T1");
      break;
    }

    case "remember":
    case "consult": {
      const allowMemory = route.memory && input.flags.memory;
      const context = await deps.retrieve({ text: input.message.text, chunks: true });
      const result = await runConsult({ context, allowMemory, allowProposal: route.kind === "consult", executionRequested: false });
      // 기계 확인을 통과한 후보만 판정(Jev): 인용이 문장을 그대로 말하는가. 후보가 없으면 부르지 않는다.
      // 판정만 실패하면(공급자 오류 · 마감 · 한도) 기억은 버리고(저장 0) 답은 남긴다. 동의 철회는 turn 전체를 멈춘다
      let memory: MemoryPlan;
      let supportFailed = false;
      try {
        const support = await checkMemorySupport(result.memory.planned, deps.decide, {
          previousReply: previous?.text ?? null,
          previousAsked: previous?.content?.asks ?? null,
          currentMessage: { id: input.message.id, text: input.message.text },
        });
        memory = withSupport(result.memory, support.verdicts);
        result.cost += support.cost;
      } catch (error) {
        if (error instanceof ConsentRequiredError) throw error;
        // 오류 이름만 남긴다 (원문 · 사용자 글 없음)
        console.error(JSON.stringify({ event: "memory_support_failed", error: error instanceof Error ? error.name : "unknown" }));
        memory = withSupport(result.memory, "not_checked");
        supportFailed = true;
      }
      result.memory = memory;
      // 사용자가 "기억해 둘까요?"를 거절했으면 아무 말도 덧붙이지 않는다. 판정이 실패했으면 기억하지 못했다고 짧게 알린다(아래)
      const quietDrop = supportFailed || memory.dropped.includes("declined");
      memoryWrites = memory.writes;
      userRefs.memory_item_ids = memory.targets;
      replyRefs.memory_item_ids = memory.existing;
      if (memory.writes.length > 0 && input.conversation.contextId) replyRefs.context_ids = [input.conversation.contextId];
      for (const note of memoryNoteTexts(lang, memory.notes, scopeLabel(input))) push(note, "T2");
      // 판정이 실패해 버린 기억이 있으면 사용자가 기억된 줄 알지 않게 한 줄 (확인 문구와 같은 자리)
      if (supportFailed) push(TEXT.memoryFailed[lang], "T1");
      if (route.kind === "remember") {
        // 저장하지 않았다고 말하는 것은 사용자가 기억을 알려 줬을 때만 (알림 · 정정, "기억해 둘까요?"에 대한 답)
        const toldToRemember = intent.kind === "inform" || intent.kind === "correct" || previous?.content?.asks === "remember";
        if (!input.flags.memory) push(TEXT.memoryOff[lang], "T1");
        else if (!route.memory) {
          // 확신 0.5–0.8: 쓰지 않고 한 번 묻는다. 다음 "응"은 이 앞 사용자 메시지를 인용해 기억할 수 있다
          push(TEXT.rememberAsk[lang], "T5");
          content.asks = "remember";
        } else if (memory.notes.length === 0 && toldToRemember && !quietDrop) push(TEXT.memoryNone[lang], "T5");
      }
      break;
    }
  }

  if (segments.length === 0) throw new ConsultOutputError("답 구간이 없습니다");
  content.segments = segments;
  content.citations = citations;
  const done = consulted as Consulted | null;
  return {
    intent: messageIntent(intent),
    route: route.kind,
    user: { refs: userRefs },
    reply: { text: segments.map((s) => s.text).join(""), segments, citations, refs: replyRefs, content },
    memory: memoryWrites,
    adopt,
    summary: {
      intent: { kind: intent.kind, confidence: intent.confidence, remember: intent.remember, read: intent.read },
      route: route.kind,
      consulted: done !== null,
      citations: citations.length,
      citationsDropped: done?.citationsDropped ?? 0,
      tierDowngraded: done?.tierDowngraded ?? 0,
      memoryWrites: memoryWrites.length,
      memoryDropped: done?.memory.dropped ?? [],
      proposal: replyRefs.proposal !== null,
      adopt: adopt !== null,
      model: done?.model ?? null,
      cost: intent.cost + (done?.cost ?? 0),
      promptVersions: { intent: INTENT_PROMPT_VERSION, consult: CONSULT_PROMPT_VERSION, memory: MEMORY_EXTRACT_PROMPT_VERSION },
    },
  };
}

function mergeTargetRefs(refs: MessageRefs, target: Target): Pick<MessageRefs, "action_ids" | "run_ids" | "artifact_ids"> {
  const add = targetsToRefs([target]);
  return {
    action_ids: [...new Set([...refs.action_ids, ...add.action_ids])],
    run_ids: [...new Set([...refs.run_ids, ...add.run_ids])],
    artifact_ids: [...new Set([...refs.artifact_ids, ...add.artifact_ids])],
  };
}

/** 이 대화의 메시지 refs가 가리킨 열린 내 Action (최근 메시지 것부터) */
function linkedOpenActions(input: RespondInput, context: ConsultContext): { id: string; title: string }[] {
  const open = new Map(context.openActions.map((a) => [a.id.toLowerCase(), a]));
  const linked: { id: string; title: string }[] = [];
  for (const message of [...input.window].reverse()) {
    for (const id of message.refs.action_ids) {
      const action = open.get(id.toLowerCase());
      if (action && !linked.some((l) => l.id === action.id)) linked.push({ id: action.id, title: action.title });
    }
  }
  return linked;
}

function scopeLabel(input: RespondInput): string {
  return input.conversation.contextId ? (input.conversation.contextName ?? ALL_WORK) : ALL_WORK;
}

function memoryNoteTexts(lang: Lang, notes: MemoryNote[], scope: string): string[] {
  const texts: string[] = [];
  const created = notes.filter((n) => n.kind === "new").map((n) => n.statement);
  if (created.length) texts.push(remembered(lang, created, scope));
  for (const note of notes) if (note.kind === "corrected") texts.push(corrected(lang, note.previous, note.statement, scope));
  const kept = notes.filter((n) => n.kind === "already").map((n) => n.statement);
  if (kept.length) texts.push(already(lang, kept));
  return texts;
}

// ─── J2 상담 (J7 기억 후보 포함) ─────────────────────────

type ConsultOptions = { context: ConsultContext; allowMemory: boolean; allowProposal: boolean; executionRequested: boolean };

type Consulted = {
  segments: ResponseSegment[];
  citations: AskCitation[];
  citationsDropped: number;
  tierDowngraded: number;
  proposal: { ref: Proposal; payload: ProposalPayload } | null;
  memory: MemoryPlan;
  used: NonNullable<ConversationMessageContent["used"]>;
  window: NonNullable<ConversationMessageContent["window"]>;
  model: string;
  cost: number;
};

function promptAction(alias: string, action: ConsultAction): ConsultPromptAction {
  return {
    id: alias,
    title: action.title,
    owner: action.owner,
    due: action.due_date,
    counterpart: action.counterpart,
    needs_confirmation: action.needs_confirmation,
    in_scope: action.in_scope,
  };
}

const isoOf = (value: string) => new Date(value).toISOString();

async function consult(input: RespondInput, deps: RespondDeps, intent: IntentResult, options: ConsultOptions): Promise<Consulted> {
  const { context } = options;

  // 번호: 사용자 메시지 U · 답 R · 할 일 A · 원문 S · 기억 M (모델이 id를 지어내지 못하게 번호로 가리킨다, pipeline/ask.ts 선례)
  const window = input.window.filter((m) => m.role !== "event" && m.seq <= input.message.seq).slice(-CONVERSATION_WINDOW);
  const omitted = input.omitted + Math.max(0, input.window.filter((m) => m.role !== "event" && m.seq <= input.message.seq).length - window.length);
  const userAlias = new Map<string, string>();
  let u = 0;
  let r = 0;
  const messages = window.map((m) => {
    const alias = m.role === "user" ? `U${++u}` : `R${++r}`;
    if (m.role === "user") userAlias.set(m.id, alias);
    const current = m.id === input.message.id;
    const text = current || [...m.text].length <= WINDOW_MESSAGE_CHARS ? m.text : `${[...m.text].slice(0, WINDOW_MESSAGE_CHARS).join("")}…`;
    return { id: alias, role: m.role as "user" | "assistant", text, truncated: text !== m.text, text_expired: m.textExpired };
  });
  const currentAlias = userAlias.get(input.message.id) ?? `U${u}`;

  // 기억 후보가 인용할 수 있는 메시지: 지금 메시지, 그리고 직전 답이 "기억해 둘까요?"였으면 그 앞 사용자 메시지
  const quotable = new Map<string, QuotableMessage>();
  quotable.set(currentAlias, { id: input.message.id, text: input.message.text, createdAt: input.message.createdAt });
  const previous = previousAssistant(input);
  if (previous?.content?.asks === "remember") {
    const before = [...window].reverse().find((m) => m.role === "user" && m.seq < previous.seq && !m.textExpired);
    const alias = before ? userAlias.get(before.id) : undefined;
    if (before && alias) quotable.set(alias, { id: before.id, text: before.text, createdAt: before.createdAt });
  }

  const actionAliases = new Map<string, AskAction>();
  const open = context.openActions.map((a, i) => {
    actionAliases.set(`A${i + 1}`, a);
    return promptAction(`A${i + 1}`, a);
  });
  const done = context.doneRecent.map((a, i) => {
    const alias = `A${context.openActions.length + i + 1}`;
    actionAliases.set(alias, a);
    return promptAction(alias, a);
  });

  const sources = context.sources.filter((s) => s.excerpts.length > 0).slice(0, SOURCES_SHOWN);
  const sourceAliases = new Map<string, AskSource>(sources.map((s, i) => [`S${i + 1}`, s]));

  const shownMemory = context.memory.slice(0, MEMORY_SHOWN);
  const memoryAliases = new Map<string, ShownMemory>(shownMemory.map((m, i) => [`M${i + 1}`, m]));
  const memoryScope = (m: ConsultMemory) => (m.scope_kind === "global" ? ALL_WORK : m.scope_kind === "context" ? (input.conversation.contextName ?? m.scope_kind) : m.scope_kind);

  const result = await deps.complete({
    system: CONSULT_SYSTEM_PROMPT,
    user: buildConsultUserPrompt({
      now: input.now,
      message: input.message.text,
      scope: { label: scopeLabel(input), all_work: input.conversation.contextId === null },
      intent: { kind: intent.kind, allow_memory: options.allowMemory, allow_proposal: options.allowProposal, execution_requested: options.executionRequested },
      conversation: { earlier_messages_not_shown: omitted, current: currentAlias, messages },
      memory_messages: options.allowMemory ? [...quotable.keys()] : [],
      records: {
        open_actions: {
          total: Math.max(context.openTotal, open.length),
          shown: open.length,
          items: open,
        },
        recently_done: {
          days: DONE_RECENT_DAYS,
          total: Math.max(context.doneRecentTotal, done.length),
          shown: done.length,
          items: done,
        },
      },
      memory: shownMemory.map((m, i) => ({
        id: `M${i + 1}`,
        kind: m.kind,
        subject: m.subject && !m.subject.startsWith("memory:") ? m.subject : null,
        statement: m.statement,
        origin: m.origin,
        scope: memoryScope(m),
        said_at: isoOf(m.observed_at),
      })),
      sources: sources.map((s, i) => ({
        id: `S${i + 1}`,
        kind: s.kind,
        title: s.title,
        date: s.occurredAt ? s.occurredAt.toISOString().slice(0, 10) : null,
        excerpts: s.excerpts,
      })),
    }),
    schemaName: "conversation_reply",
    schema: consultModelResponseSchema,
    maxTokens: 2048,
  });

  // 인용: 원문과 대조해 없는 것은 버린다 (물어보기와 같은 함수)
  const verified = verifyCitations(result.data.citations, { actions: actionAliases as Map<string, AskAction>, sources: sourceAliases });
  const hasRecords = open.length + done.length > 0 || verified.citations.length > 0;

  // 구간: 빈 구간을 빼고, 기록이 하나도 없는데 T1이라고 한 구간은 T5로 내린다. 개수 · 길이 상한
  let tierDowngraded = 0;
  let length = 0;
  const segments: ResponseSegment[] = [];
  for (const segment of result.data.segments) {
    if (segments.length >= REPLY_SEGMENTS_MAX || segment.text.trim() === "") continue;
    const remaining = REPLY_TEXT_MAX_CHARS - length;
    if (remaining <= 0) break;
    const text = [...segment.text].length > remaining ? [...segment.text].slice(0, remaining).join("") : segment.text;
    let tier: ResponseSegment["tier"] = segment.tier;
    if (tier === "T1" && !hasRecords) {
      tier = "T5";
      tierDowngraded++;
    }
    segments.push({ text, tier });
    length += [...text].length;
  }
  if (segments.length === 0) throw new ConsultOutputError("모델이 답 구간을 내지 않았습니다");

  // 열린 할 일 · 최근 끝낸 할 일과 같은 제목은 제안하지 않는다 (원칙 4 중복 없음, A01 끝낸 일을 다시 만들지 않음)
  const knownTitles = [...context.openActions, ...context.doneRecent].map((a) => a.title);
  const proposal = options.allowProposal ? proposalFromModel(result.data.proposal, knownTitles, deps.newId) : null;

  const scope: MemoryScope = input.conversation.contextId ? { kind: "context", contextId: input.conversation.contextId } : { kind: "global" };
  const memory = planMemoryWrites({ candidates: result.data.memory_candidates, allowed: options.allowMemory, quotable, shown: memoryAliases, scope });

  return {
    segments,
    citations: verified.citations,
    citationsDropped: verified.dropped,
    tierDowngraded,
    proposal,
    memory,
    used: {
      context_id: input.conversation.contextId,
      context_version: context.contextVersion,
      memory_item_ids: shownMemory.map((m) => m.id),
      source_ids: sources.map((s) => s.id),
      action_ids: [...context.openActions, ...context.doneRecent].map((a) => a.id),
    },
    window: { shown: window.length, omitted },
    model: result.model,
    cost: result.usage?.cost ?? 0,
  };
}
