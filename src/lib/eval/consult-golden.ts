import { createHash } from "node:crypto";

import { z } from "zod";

import { contextTierSchema, intentKindSchema, messageRefsSchema } from "@/lib/api/contract";
import { payloadHash } from "@/lib/conversation/proposal";
import type { ConsultContext, RespondInput, TurnPlan, WindowMessage } from "@/lib/conversation/respond";
import { quoteInText } from "@/lib/pipeline/text";

// 대화 상담 골든셋 (evals/consult/*.json, 구현 계획 B2). 한 케이스 = 앞 대화 + 지금 메시지 + 등록된 할 일 · 기억 · 원문(합성) + 기대 결과.
// 실제 모델(J1 Jev · J2 LLM)로 respondToMessage를 돌려 채점한다 (npm run eval -- --consult). CI(키 없음)는 형식 · 라벨만 본다 (--labels).
// 문장 품질은 금지 표현 · 필수 정보로만 보고 특정 문구의 완전 일치는 보지 않는다 (0.2.0 개발 계획 5장).

const labelSchema = z.string().min(1).max(40);

const caseActionSchema = z.object({
  id: labelSchema,
  title: z.string().min(1),
  owner: z.enum(["me", "other", "unknown"]).default("me"),
  due_date: z.iso.date().optional(),
  counterpart: z.string().min(1).optional(),
  needs_confirmation: z.boolean().default(false),
  quotes: z.array(z.object({ source: labelSchema, quote: z.string().min(1) })).default([]),
});

const caseSourceSchema = z.object({
  id: labelSchema,
  kind: z.enum(["meeting", "message", "email", "doc", "note", "task"]),
  title: z.string().min(1).optional(),
  occurred_at: z.iso.datetime({ offset: true }),
  text: z.string().min(1),
});

const caseMemorySchema = z.object({
  id: labelSchema,
  kind: z.enum(["goal", "condition", "outcome_criteria", "relationship", "fact", "working_rule", "plan"]),
  subject: z.string().min(1).nullable().default(null),
  statement: z.string().min(1),
  origin: z.enum(["explicit", "observed"]).default("explicit"),
  /** global = 전체, context = 케이스의 범위 */
  scope: z.enum(["global", "context"]).default("global"),
});

const routeSchema = z.enum(["clarify", "consult", "remember", "adopt", "execution", "preference"]);

export const consultCaseSchema = z.object({
  id: z.string().min(1),
  description: z.string().min(1),
  /** 대응하는 기준 (0.2.0 개발 계획 5장 A## · 아키텍처 13장 ARCH##) */
  maps_to: z.array(z.string().regex(/^(A\d{2}|ARCH\d{2})$/)).min(1),
  origin: z.enum(["real", "synthetic"]).default("synthetic"),
  asked_at: z.iso.datetime({ offset: true }),
  /** 대화의 범위 (null = All work) */
  context: z.object({ name: z.string().min(1) }).nullable().default(null),
  memory_enabled: z.boolean().default(true),
  history: z
    .array(
      z.object({
        role: z.enum(["user", "assistant"]),
        text: z.string().min(1),
        asks: z.enum(["remember", "referent", "clarify", "adopt"]).optional(),
        proposal: z.object({ title: z.string().min(1), state: z.enum(["open", "adopted"]).default("open") }).optional(),
        /** 이 메시지 refs가 가리킨 할 일 (지시 대상 규칙 3 · 4) */
        action_refs: z.array(labelSchema).default([]),
      }),
    )
    .default([]),
  message: z.string().min(1).max(4000),
  /** 앱이 고른 대상 (지시 대상 규칙 1) */
  selected: z.array(labelSchema).default([]),
  records: z
    .object({
      open_actions: z.array(caseActionSchema).default([]),
      /** 등록된 열린 할 일 전체 수 (보여 준 것보다 많을 때, A04) */
      open_total: z.number().int().nonnegative().optional(),
      done_recent: z.array(caseActionSchema).default([]),
    })
    .default({ open_actions: [], done_recent: [] }),
  memory: z.array(caseMemorySchema).default([]),
  sources: z.array(caseSourceSchema).default([]),
  expect: z.object({
    intent_any: z.array(intentKindSchema).min(1),
    route_any: z.array(routeSchema).min(1),
    /** 답에 맞으면 안 되는 정규식 (예: 등록 0건을 "할 일 없음"으로 단정, 원문 속 지시를 했다고 말함) */
    reply_must_not_match: z.array(z.string().min(1)).default([]),
    /** 답에 이 중 하나는 있어야 한다 */
    reply_contains_any: z.array(z.string().min(1)).default([]),
    memory_writes: z.object({ min: z.number().int().nonnegative(), max: z.number().int().nonnegative() }).default({ min: 0, max: 0 }),
    /** 저장한 기억 문장 중 하나에 각각 들어 있어야 한다 */
    memory_statements_contain: z.array(z.string().min(1)).default([]),
    /** 정정해야 하는 기억 (케이스의 memory id) */
    corrects: z.array(labelSchema).default([]),
    adopt: z.boolean().default(false),
    proposal: z.enum(["none", "some", "any"]).default("any"),
    /** 이 제목의 제안은 안 된다 (예: 끝낸 할 일을 다시 만들기, A01) */
    proposal_not_titles: z.array(z.string().min(1)).default([]),
    /** 검증된 인용 중 하나가 이 원문 중 하나 (없으면 보지 않는다) */
    cite_sources_any: z.array(labelSchema).default([]),
    /** 답 구간에 이 등급이 모두 있어야 한다 */
    tiers_include: z.array(contextTierSchema).default([]),
    asks: z.enum(["remember", "referent", "clarify", "adopt"]).nullable().optional(),
  }),
});

export type ConsultCase = z.infer<typeof consultCaseSchema>;

/** 라벨링 실수 찾기: 없는 원문 · 원문에 없는 근거 구절 · 없는 할 일 · 기억 참조, 깨진 정규식, 모순된 기대 */
export function findConsultLabelErrors(golden: ConsultCase): string[] {
  const errors: string[] = [];
  const sources = new Map(golden.sources.map((s) => [s.id, s]));
  const actions = [...golden.records.open_actions, ...golden.records.done_recent];
  const actionIds = new Set(actions.map((a) => a.id));
  const openIds = new Set(golden.records.open_actions.map((a) => a.id));
  const memoryIds = new Set(golden.memory.map((m) => m.id));
  if (sources.size !== golden.sources.length) errors.push("source id가 중복되었습니다");
  if (actionIds.size !== actions.length) errors.push("action id가 중복되었습니다");
  if (memoryIds.size !== golden.memory.length) errors.push("memory id가 중복되었습니다");
  for (const action of actions) {
    for (const q of action.quotes) {
      const source = sources.get(q.source);
      if (!source) errors.push(`${action.id}: 없는 source ${q.source}`);
      else if (!quoteInText(q.quote, source.text)) errors.push(`${action.id}: 인용이 원문 ${q.source}에 없습니다: "${q.quote}"`);
    }
  }
  for (const ref of [...golden.selected, ...golden.history.flatMap((h) => h.action_refs)]) if (!openIds.has(ref)) errors.push(`없는 열린 할 일 ${ref}`);
  for (const id of golden.expect.corrects) if (!memoryIds.has(id)) errors.push(`기대 정정: 없는 memory ${id}`);
  for (const id of golden.expect.cite_sources_any) if (!sources.has(id)) errors.push(`기대 인용: 없는 source ${id}`);
  for (const pattern of golden.expect.reply_must_not_match) {
    try {
      new RegExp(pattern, "u");
    } catch {
      errors.push(`깨진 정규식: ${pattern}`);
    }
  }
  const { min, max } = golden.expect.memory_writes;
  if (min > max) errors.push("memory_writes.min이 max보다 큽니다");
  if (golden.expect.memory_statements_contain.length > max) errors.push("memory_statements_contain이 max보다 많습니다");
  if (golden.expect.corrects.length > max) errors.push("corrects가 memory_writes.max보다 많습니다");
  if ((min > 0 || golden.expect.corrects.length > 0) && !golden.memory_enabled) errors.push("기억이 꺼진 케이스에 기억 쓰기를 기대합니다");
  if (golden.memory.some((m) => m.scope === "context") && !golden.context) errors.push("범위 기억에는 context가 필요합니다");
  if (golden.expect.adopt) {
    const last = golden.history.at(-1);
    if (last?.role !== "assistant" || last.proposal?.state !== "open") errors.push("채택을 기대하면 마지막 앞 메시지가 열린 제안을 낸 assistant여야 합니다");
    if (golden.expect.proposal === "some") errors.push("채택 케이스에 새 제안을 기대합니다");
  }
  return errors;
}

/** 케이스 라벨 → 고정 uuid (z.uuid가 받는 version 4 · variant 8 모양) */
function uuidOf(caseId: string, label: string): string {
  const h = createHash("sha256").update(`${caseId}:${label}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/** respondToMessage에 넘길 입력 · 기록 (DB 대신 케이스) */
export function consultInputOf(golden: ConsultCase): { input: RespondInput; context: ConsultContext; ids: (label: string) => string } {
  const ids = (label: string) => uuidOf(golden.id, label);
  const now = new Date(golden.asked_at);
  const contextId = golden.context ? ids("context") : null;
  const base = now.getTime() - (golden.history.length + 1) * 60_000;
  const window: WindowMessage[] = golden.history.map((h, i) => {
    const payload = h.proposal ? { kind: "create_action" as const, title: h.proposal.title } : null;
    return {
      id: ids(`m${i + 1}`),
      seq: i + 1,
      role: h.role,
      text: h.text,
      textExpired: false,
      createdAt: new Date(base + i * 60_000).toISOString(),
      refs: messageRefsSchema.parse({
        action_ids: h.action_refs.map(ids),
        proposal: payload ? { id: ids(`p${i + 1}`), kind: "create_action", payload_hash: payloadHash(payload), state: h.proposal!.state } : null,
      }),
      content: h.role === "assistant" ? { segments: [], citations: [], proposal: payload, asks: h.asks ?? null, used: null, window: null } : null,
    };
  });
  const seq = golden.history.length + 1;
  const current: WindowMessage = { id: ids("current"), seq, role: "user", text: golden.message, textExpired: false, createdAt: new Date(base + seq * 60_000).toISOString(), refs: messageRefsSchema.parse({}), content: null };
  const open = golden.records.open_actions;
  const action = (a: ConsultCase["records"]["open_actions"][number], status: "open" | "done") => ({
    id: ids(a.id),
    title: a.title,
    status,
    owner: a.owner,
    due_date: a.due_date ?? null,
    counterpart: a.counterpart ?? null,
    needs_confirmation: a.needs_confirmation,
    in_scope: null,
    quotes: a.quotes.map((q) => ({ sourceId: ids(q.source), quote: q.quote })),
  });
  const context: ConsultContext = {
    openActions: open.map((a) => action(a, "open")),
    openTotal: golden.records.open_total ?? open.length,
    doneRecent: golden.records.done_recent.map((a) => action(a, "done")),
    doneRecentTotal: golden.records.done_recent.length,
    memory: golden.memory.map((m) => ({
      id: ids(m.id),
      version: 1,
      kind: m.kind,
      subject: m.subject,
      statement: m.statement,
      origin: m.origin,
      scope_kind: m.scope === "context" ? "context" : "global",
      context_id: m.scope === "context" ? contextId : null,
      action_id: null,
      person_id: null,
      agent_adapter: null,
      observed_at: new Date(base).toISOString(),
    })),
    // 케이스 원문은 짧아 글 전체를 발췌로 준다 (운영은 근거 구절 앞뒤 · 범위 조각만, store.ts)
    sources: golden.sources.map((s) => ({
      id: ids(s.id),
      title: s.title ?? null,
      kind: s.kind,
      occurredAt: new Date(s.occurred_at),
      externalUrl: null,
      text: s.text,
      excerpts: [s.text],
    })),
    contextVersion: contextId ? 1 : null,
  };
  const selected = golden.selected.map((label) => ({ kind: "action" as const, id: ids(label), title: open.find((a) => a.id === label)!.title }));
  return {
    input: {
      userId: ids("user"),
      conversation: { id: ids("conversation"), contextId, contextName: golden.context?.name ?? null },
      message: { id: current.id, seq, text: golden.message, createdAt: current.createdAt },
      window: [...window, current],
      omitted: 0,
      selected,
      flags: { memory: golden.memory_enabled },
      now,
    },
    context,
    ids,
  };
}

export type ConsultScore = {
  caseId: string;
  pass: boolean;
  checks: Record<string, boolean | null>;
};

/** 채점: 의도 · 분기 · 금지 표현 · 필수 정보 · 기억 쓰기 · 정정 · 채택 · 제안 · 인용 · 등급 · 질문 */
export function scoreConsultCase(golden: ConsultCase, plan: Pick<TurnPlan, "intent" | "route" | "reply" | "memory" | "adopt">, ids: (label: string) => string): ConsultScore {
  const text = plan.reply.text;
  const statements = plan.memory.map((w) => w.item.statement);
  const corrected = new Set(plan.memory.map((w) => w.corrects).filter((v): v is string => Boolean(v)));
  const proposalTitle = plan.reply.content.proposal?.title ?? null;
  const e = golden.expect;
  const checks: Record<string, boolean | null> = {
    intent: e.intent_any.includes(plan.intent.kind),
    route: e.route_any.includes(plan.route as (typeof e.route_any)[number]),
    must_not_match: e.reply_must_not_match.length ? !e.reply_must_not_match.some((p) => new RegExp(p, "u").test(text)) : null,
    contains_any: e.reply_contains_any.length ? e.reply_contains_any.some((w) => text.toLowerCase().includes(w.toLowerCase())) : null,
    memory_count: plan.memory.length >= e.memory_writes.min && plan.memory.length <= e.memory_writes.max,
    memory_statements: e.memory_statements_contain.length ? e.memory_statements_contain.every((w) => statements.some((s) => s.includes(w))) : null,
    corrects: e.corrects.length ? e.corrects.every((label) => corrected.has(ids(label))) : null,
    adopt: (plan.adopt !== null) === e.adopt,
    proposal: e.proposal === "any" ? null : e.proposal === "some" ? proposalTitle !== null : proposalTitle === null,
    proposal_titles: e.proposal_not_titles.length ? !e.proposal_not_titles.some((t) => proposalTitle?.includes(t)) : null,
    cites: e.cite_sources_any.length ? plan.reply.citations.some((c) => e.cite_sources_any.map(ids).includes(c.source_id)) : null,
    tiers: e.tiers_include.length ? e.tiers_include.every((tier) => plan.reply.segments.some((s) => s.tier === tier)) : null,
    asks: e.asks === undefined ? null : plan.reply.content.asks === e.asks,
  };
  return { caseId: golden.id, pass: Object.values(checks).every((v) => v !== false), checks };
}
