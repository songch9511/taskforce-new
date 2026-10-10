import { buildMemorySupportRequest } from "@/lib/ai/prompts/memory-extract";
import { MEMORY_STATEMENT_MAX_CHARS, memoryKindSchema } from "@/lib/api/contract";
import { memoryWriteRow, normalizeMemorySubject, sameScope, scopeColumns, type MemoryKind, type MemoryScope } from "@/lib/context/memory";
import type { Decide } from "@/lib/pipeline/judge";
import { findQuoteSpan, normalizeForMatch } from "@/lib/pipeline/text";

import { MEMORY_SUPPORT_ACCEPT, MEMORY_WRITES_PER_TURN } from "./conversation.config";

// 기억 후보(J7) → 저장할 기억 (아키텍처 5.3 · 6.4 · 7.3 J7, ARCH01 · 02 · 04). DB와 분리된 함수 (확인 판정만 Jev를 인자로 받는다).
//
// - explicit 기억은 실제 사용자 발화의 인용을 확인한 것만 저장한다:
//   1) 기계 확인: 인용이 허락된 사용자 메시지에 이어진 한 덩어리로 있고(findQuoteSpan) 너무 짧지 않으며, 기억 문장이 인용과 글자쌍 하나 이상을 나눈다.
//   2) 판정(Jev, 예/아니오): 그 인용이 기억 문장을 그대로 말하는가(덧붙임 · 부정 뒤집기 · 일반화 · 남의 말 아님), 정정이면 같은 대상의 이전 기억을 바꾸는가.
//      "기억해 둘까요?"에 답한 경우 앞 메시지 인용은 지금 답이 동의할 때만. MEMORY_SUPPORT_ACCEPT 미만이면 버린다.
// - 가리킨 정정 대상(M번호)은 kind가 같고, 둘 다 주제가 있으면 주제도 같아야 한다 (모델 혼자 무관한 사실을 덮지 못하게).
//   확인에 실패한 후보는 저장하지 않는다. inferred로 바꿔 저장하지도 않는다 (ARCH04).
// - 범위: 대화의 범위(범위 또는 전체)에만 쓴다. 다른 범위로 일반화하지 않는다 (6.4 · A06).
// - 정정: 모델이 가리킨 기억(M번호, 보여 준 것만)이나 보여 준 기억과 같은 범위 · 같은 사실(kind + subject)을 다시 말한 것이면 그 행을 version과 함께 정정한다
//   (새 행 + 옛 행 superseded_by, DB remember_memory_item. 그 사이 다른 곳에서 바뀌었으면 conflict).
//   더 넓은 범위(전체)의 기억이면 그것을 지우지 않고 대화 범위에 같은 사실의 새 행을 쓴다: 읽을 때 그 범위 안에서만 이긴다 (프로젝트 예외는 전역 기억을 지우지 않는다).
// - 같은 kind라는 것만으로 덮지 않는다: 같은 사실은 kind + subject가 같을 때뿐이다 (B1 규칙). 같은 범위 · 같은 사실 · 같은 문장이 이미 있으면 다시 쓰지 않는다.
// - 한 번의 쓰기는 잠금 순서(같은 사실 열쇠)대로 정렬해 보낸다: 두 turn이 같은 기억 둘을 반대 순서로 고쳐도 서로 기다리다 교착하지 않게.

/** 이보다 짧은 인용은 무엇이든 맞아 버려서 근거로 치지 않는다 (공백 · 문장부호 뺀 글자 수, 물어보기와 같다) */
export const MIN_MEMORY_QUOTE_CHARS = 4;

export type MemoryCandidate = {
  kind: string;
  subject: string;
  statement: string;
  /** 인용한 사용자 메시지 번호 (U1 · U2 …) */
  message: string;
  quote: string;
  /** 정정하는 기억 번호 (M1 …) 또는 null */
  corrects: string | null;
};

/** 모델에 보여 준 지금 기억 (정정 대상이 될 수 있는 것) */
export type ShownMemory = {
  id: string;
  version: number;
  kind: string;
  subject: string | null;
  statement: string;
  origin: "explicit" | "observed";
  scope_kind: MemoryScope["kind"];
  context_id: string | null;
  action_id: string | null;
  person_id: string | null;
  agent_adapter: string | null;
};

/** 인용할 수 있는 사용자 메시지 */
export type QuotableMessage = { id: string; text: string; createdAt: string };

export type MemoryWritePlan = {
  /** remember_memory_item의 p_item */
  item: ReturnType<typeof memoryWriteRow>;
  corrects: string | null;
  expected_version: number | null;
};

export type MemoryNote =
  | { kind: "new"; statement: string }
  | { kind: "corrected"; statement: string; previous: string }
  | { kind: "already"; statement: string; id: string };

export type MemoryDropReason =
  | "not_allowed"
  | "unknown_message"
  | "quote_not_found"
  | "quote_too_short"
  | "unrelated_statement"
  | "bad_kind"
  | "bad_statement"
  | "reserved_subject"
  | "no_subject"
  | "unknown_memory"
  | "duplicate"
  | "limit"
  | "not_supported"
  | "declined"
  | "not_checked";

/** 판정(Jev)에 넘기는 것: 기억 문장 · 인용 · 인용한 메시지 글 · 정정이면 옛 기억 문장 */
export type SupportCheck = { statement: string; quote: string; message: string; messageId: string; previous: string | null };

/** 저장할 후보 하나 (판정 전) */
export type PlannedWrite = { write: MemoryWritePlan; note: MemoryNote; target: string | null; check: SupportCheck; lockKey: string };

export type MemoryPlan = {
  writes: MemoryWritePlan[];
  notes: MemoryNote[];
  /** 정정 대상으로 고른 기억 id (사용자 메시지 refs.memory_item_ids: 정한 대상) */
  targets: string[];
  /** 이미 같은 기억이 있어 쓰지 않은 행 id (답 refs에 더한다) */
  existing: string[];
  dropped: MemoryDropReason[];
  /** 판정 전 후보 (withSupport가 거른다) */
  planned: PlannedWrite[];
  already: { note: MemoryNote; id: string; target: string | null }[];
};

/** 글자쌍(문자 · 숫자만, NFKC · 소문자) */
function letterPairs(text: string): Set<string> {
  const letters = text.normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
  const pairs = new Set<string>();
  for (let i = 0; i + 1 < letters.length; i++) pairs.add(letters.slice(i, i + 2));
  return pairs;
}

/** 기억 문장이 인용과 연결되는가 (글자쌍 하나 이상). 싼 걸러내기일 뿐이고 뜻이 맞는지는 판정(checkMemorySupport)이 본다 */
export function statementLinkedToQuote(statement: string, quote: string): boolean {
  const quotePairs = letterPairs(quote);
  for (const pair of letterPairs(statement)) if (quotePairs.has(pair)) return true;
  return false;
}

const aliasNumber = (value: string | null, prefix: "U" | "M") => {
  const match = value?.match(new RegExp(`^\\s*\\[?${prefix}\\s*(\\d+)\\]?\\s*$`, "i"));
  return match ? `${prefix}${Number(match[1])}` : null;
};

/** 판정 · 정렬을 거친 후보로 결과를 만든다 (쓰기는 잠금 열쇠 순서) */
function summarize(planned: PlannedWrite[], already: MemoryPlan["already"], dropped: MemoryDropReason[]): MemoryPlan {
  const ordered = [...planned].sort((a, b) => (a.lockKey < b.lockKey ? -1 : a.lockKey > b.lockKey ? 1 : 0));
  return {
    writes: ordered.map((p) => p.write),
    notes: [...planned.map((p) => p.note), ...already.map((a) => a.note)],
    targets: [...new Set([...planned, ...already].map((p) => p.target).filter((t): t is string => t !== null))],
    existing: already.map((a) => a.id),
    dropped,
    planned,
    already,
  };
}

export function planMemoryWrites(input: {
  candidates: readonly MemoryCandidate[];
  /** 기억을 쓸 수 있는 의도 · gate인가. false면 모두 버린다 */
  allowed: boolean;
  /** 인용할 수 있는 사용자 메시지 (번호 → 메시지) */
  quotable: ReadonlyMap<string, QuotableMessage>;
  /** 보여 준 기억 (번호 → 기억) */
  shown: ReadonlyMap<string, ShownMemory>;
  /** 대화의 범위 */
  scope: MemoryScope;
}): MemoryPlan {
  const planned: PlannedWrite[] = [];
  const already: MemoryPlan["already"] = [];
  const dropped: MemoryDropReason[] = [];
  const seenFacts = new Set<string>();
  const seenTargets = new Set<string>();
  const scopeRow = scopeColumns(input.scope);
  const scopeKey = `${scopeRow.scope_kind}:${scopeRow.context_id ?? ""}`;
  const shownList = [...input.shown.values()];

  for (const candidate of input.candidates) {
    if (!input.allowed) {
      dropped.push("not_allowed");
      continue;
    }
    const message = input.quotable.get(aliasNumber(candidate.message, "U") ?? "");
    if (!message) {
      dropped.push("unknown_message");
      continue;
    }
    const span = findQuoteSpan(message.text, candidate.quote);
    if (!span) {
      dropped.push("quote_not_found");
      continue;
    }
    if (normalizeForMatch(span.quote).length < MIN_MEMORY_QUOTE_CHARS) {
      dropped.push("quote_too_short");
      continue;
    }
    const statement = candidate.statement.replace(/\s+/g, " ").trim();
    if (!statement || [...statement].length > MEMORY_STATEMENT_MAX_CHARS) {
      dropped.push("bad_statement");
      continue;
    }
    if (!statementLinkedToQuote(statement, span.quote)) {
      dropped.push("unrelated_statement");
      continue;
    }
    const sourceRef = { message_id: message.id, quote: span.quote };
    const row = (kind: MemoryKind, subject: string | null) =>
      memoryWriteRow({ kind, scope: input.scope, subject, statement, origin: "explicit", source_ref: sourceRef, observed_at: message.createdAt });

    // 정정할 기억: 모델이 가리킨 것(M번호) 또는 보여 준 것 중 같은 범위 · 같은 사실(kind + subject)
    let target: ShownMemory | undefined;
    let kind: MemoryKind;
    let subject: string | null;
    const pointed = candidate.corrects && candidate.corrects.trim() !== "" && candidate.corrects.trim().toLowerCase() !== "null";
    if (pointed) {
      const alias = aliasNumber(candidate.corrects, "M");
      target = alias ? input.shown.get(alias) : undefined;
      // 가리킨 대상은 같은 사실이어야 한다: kind가 같고, 둘 다 주제가 있으면 주제도 같다 (모델 혼자 무관한 사실을 덮지 못하게)
      const candidateKind = memoryKindSchema.safeParse(candidate.kind);
      const candidateSubject = normalizeMemorySubject(candidate.subject);
      const targetSubject = target?.subject && !target.subject.startsWith("memory:") ? target.subject : null;
      if (!target || !candidateKind.success || candidateKind.data !== target.kind || (targetSubject && candidateSubject && candidateSubject !== targetSubject)) {
        dropped.push("unknown_memory");
        continue;
      }
      kind = target.kind as MemoryKind;
      subject = targetSubject ?? candidateSubject;
    } else {
      const parsed = memoryKindSchema.safeParse(candidate.kind);
      if (!parsed.success || parsed.data === "identity_link") {
        dropped.push("bad_kind");
        continue;
      }
      kind = parsed.data;
      subject = normalizeMemorySubject(candidate.subject);
      if (subject) target = shownList.find((m) => m.kind === kind && m.subject === subject && sameScope(m, scopeRow));
    }
    if (subject?.startsWith("memory:")) {
      dropped.push("reserved_subject");
      continue;
    }

    // 판정에 넘길 것: 정정이면 옛 기억 문장도 (인용이 같은 대상의 이전 기억을 바꾸는가)
    const check: SupportCheck = { statement, quote: span.quote, message: message.text, messageId: message.id, previous: target?.statement ?? null };
    const sameScopeTarget = target !== undefined && sameScope(target, scopeRow);
    const factKey = sameScopeTarget ? `id:${target!.id}` : subject ? `${kind}\u0000${subject}` : null;
    if (factKey && (seenFacts.has(factKey) || (target && seenTargets.has(target.id)))) {
      dropped.push("duplicate");
      continue;
    }
    // 같은 범위 · 같은 사실 · 같은 문장이 이미 지금 기억이면 다시 쓰지 않는다
    if (sameScopeTarget && target!.statement === statement) {
      if (factKey) seenFacts.add(factKey);
      seenTargets.add(target!.id);
      already.push({ note: { kind: "already", statement, id: target!.id }, id: target!.id, target: pointed ? target!.id : null });
      continue;
    }
    if (planned.length >= MEMORY_WRITES_PER_TURN) {
      dropped.push("limit");
      continue;
    }

    if (sameScopeTarget) {
      // 같은 범위 · 같은 사실의 정정: 그 행 id + version (범위 · kind · subject는 DB가 그 행에서 물려받는다, subject는 넘기지 않는다)
      planned.push({
        write: { item: row(kind, null), corrects: target!.id, expected_version: target!.version },
        note: { kind: "corrected", statement, previous: target!.statement },
        target: target!.id,
        check,
        lockKey: `${kind}\u0000${target!.subject ?? `memory:${target!.id}`}\u0000${scopeKey}`,
      });
      seenTargets.add(target!.id);
    } else if (target) {
      // 더 넓은 범위(전체)의 기억: 지우지 않고 대화 범위에 같은 사실을 새로 쓴다. 같은 사실 열쇠(subject)가 없으면 읽을 때 이기지 못해 정정이 되지 않는다
      if (!subject) {
        dropped.push("no_subject");
        continue;
      }
      planned.push({
        write: { item: row(kind, subject), corrects: null, expected_version: null },
        note: { kind: "corrected", statement, previous: target.statement },
        target: target.id,
        check,
        lockKey: `${kind}\u0000${subject}\u0000${scopeKey}`,
      });
      seenTargets.add(target.id);
    } else {
      planned.push({
        write: { item: row(kind, subject), corrects: null, expected_version: null },
        note: { kind: "new", statement },
        target: null,
        check,
        lockKey: subject ? `${kind}\u0000${subject}\u0000${scopeKey}` : `￿${planned.length}`,
      });
    }
    if (factKey) seenFacts.add(factKey);
  }
  return summarize(planned, already, dropped);
}

/** 판정 결과 (후보마다): null = 통과, not_supported = 인용이 문장을 뒷받침하지 않음, declined = "기억해 둘까요?"에 동의하지 않음 */
export type SupportVerdict = null | "not_supported" | "declined";

/**
 * 판정: 인용이 기억 문장을 그대로 말하는가 (Jev noul, 후보마다 질문 하나 · 한 번에). 정정이면 같은 대상의 이전 기억을 바꾸는지도.
 * 지금 메시지가 아닌 앞 메시지를 인용한 후보가 있으면("기억해 둘까요?"에 대한 답) 지금 답이 기억에 동의하는지(agrees)도 같은 요청에서 묻고,
 * 동의하지 않으면 그 후보들은 저장하지 않는다(declined). 후보가 없으면 부르지 않는다. 결과는 planned와 같은 순서.
 */
export async function checkMemorySupport(
  planned: readonly PlannedWrite[],
  decide: Decide,
  context: { previousReply: string | null; currentMessage: { id: string; text: string } },
): Promise<{ verdicts: SupportVerdict[]; cost: number }> {
  if (planned.length === 0) return { verdicts: [], cost: 0 };
  const fromEarlier = planned.map((p) => p.check.messageId !== context.currentMessage.id);
  const response = await decide(
    buildMemorySupportRequest(
      planned.map((p) => ({ statement: p.check.statement, quote: p.check.quote, message: p.check.message, previous_statement: p.check.previous })),
      { previousReply: context.previousReply, currentMessage: context.currentMessage.text, askAgreement: fromEarlier.some(Boolean) },
    ),
  );
  const yes = (key: string) => {
    const answer = response.answers[key];
    return answer?.type === "noul" && answer.noul >= MEMORY_SUPPORT_ACCEPT;
  };
  const agrees = yes("agrees");
  return {
    verdicts: planned.map((_, i) => (fromEarlier[i] && !agrees ? "declined" : yes(`support_${i}`) ? null : "not_supported")),
    cost: response.usage?.cost ?? 0,
  };
}

/** 판정을 통과한 후보만 남긴다. 판정 자체가 실패했으면(공급자 오류 등) 모두 not_checked로 버린다 */
export function withSupport(plan: MemoryPlan, verdicts: readonly SupportVerdict[] | "not_checked"): MemoryPlan {
  const reasons = plan.planned.map((_, i): MemoryDropReason | null => (verdicts === "not_checked" ? "not_checked" : (verdicts[i] ?? null)));
  const kept = plan.planned.filter((_, i) => reasons[i] === null);
  return summarize(kept, plan.already, [...plan.dropped, ...reasons.filter((r): r is MemoryDropReason => r !== null)]);
}
