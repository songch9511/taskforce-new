import { z } from "zod";

import type { OrganizeContent, OrganizeOp, OrganizeTarget, ProposalPayloadV2 } from "@/lib/api/contract";

import { REFERENT_CANDIDATE_LIMIT } from "./intent.config";
import type { MovePlanItem } from "./proposal";

// 이슈 정리(organize 의도: 이동 · 빼기 · 삭제 · 병합)의 대상 정하기 (D4c-2, 런타임 계약 2장 "지시 대상"). DB · 모델과 분리된 순수 함수: route · eval · 테스트가 같은 코드를 쓴다.
// - 이슈는 앱이 붙인 added action 칩과 글의 #번호로만 정한다. 프로젝트는 added context 칩과 글에 이름이 그대로 있는 것만이다. 제목이 닮았다는 이유로 고르지 않는다 (규칙 1 = 분명한 지칭).
// - 무엇을 할지(op)와 병합에서 남는 쪽(into)은 Jev가 고른다 (src/lib/ai/prompts/organize.ts). 이 파일은 그 답을 받아 규칙으로 결과를 낸다.
// - 결과는 쓸 것(move) · 글로 한 번 물을 것(move_ask) · 확인 카드(delete · merge) · 더 물을 것(ask) · 쓰기 없는 답(reply) 중 하나다. 문구는 respond.ts가 붙인다.
// - 사용자 글 · 제목은 로그에 남기지 않는다 (이 파일은 로그를 남기지 않는다).

// ─── organize_lookup 결과 (SQL organize_lookup의 jsonb) ───

const lookupContextSchema = z.object({ id: z.string(), name: z.string(), status: z.enum(["active", "archived"]), context_version: z.number().int() });
export const organizeLookupSchema = z.object({
  actions: z.array(
    z.object({
      id: z.string(),
      number: z.number().int(),
      title: z.string(),
      status: z.enum(["open", "done", "dropped"]),
      version: z.number().int(),
      open_sessions: z.number().int(),
      evidence_count: z.number().int(),
      /** 확인된 멤버십만 (사용자가 뺀 것 · 추정은 없다) */
      contexts: z.array(lookupContextSchema),
    }),
  ),
  /** 이 사용자의 범위 전부 (active · archived) */
  contexts: z.array(lookupContextSchema.extend({ kind: z.string() })),
});
export type OrganizeLookup = z.infer<typeof organizeLookupSchema>;
export type OrganizeAction = OrganizeLookup["actions"][number];
export type OrganizeContext = OrganizeLookup["contexts"][number];

export type PendingOrganize = Extract<OrganizeContent, { state: "pending" }>;
export type PendingMissing = PendingOrganize["missing"];

// ─── 글에서 지칭 찾기 ───

/** '>'로 시작하는 인용 줄은 뺀다: 전달한 글 속 지시 · 이름은 요청이 아니다 */
function unquoted(text: string): string {
  return text
    .split(/\r?\n/)
    .filter((line) => !/^\s*>/.test(line))
    .join("\n");
}

const ISSUE_NUMBER = /(?<![A-Za-z0-9_])#(\d{1,9})(?!\d)/gu;

/** 글의 #번호를 나온 순서로 (중복 없이, 인용 줄 제외). index는 인용 줄을 뺀 글에서의 자리다 */
export function findIssueMentions(text: string): { number: number; index: number }[] {
  const seen = new Set<number>();
  const mentions: { number: number; index: number }[] = [];
  for (const match of unquoted(text).matchAll(ISSUE_NUMBER)) {
    const number = Number(match[1]);
    if (number < 1 || seen.has(number)) continue;
    seen.add(number);
    mentions.push({ number, index: match.index ?? 0 });
  }
  return mentions;
}

const normalizeName = (value: string) => value.normalize("NFC").toLowerCase().replace(/\s+/g, " ").trim();
const isLetterOrDigit = (ch: string) => /[\p{L}\p{N}]/u.test(ch);
const isAsciiAlnum = (ch: string) => /[A-Za-z0-9]/.test(ch);
/** 이름 뒤에 붙는 조사 (한 낱말로 끝나야 한다) */
const PARTICLE = /^(?:으로|에서|에게|한테|까지|부터|로|에|을|를|은|는|이|가|의|와|과|도|만|께)(?![\p{L}\p{N}])/u;

/**
 * 글에 이름이 그대로 있는 범위 (NFC · 소문자 · 공백 하나로 맞춘 뒤 글자 · 숫자 경계로 자른 부분 문자열).
 * 경계: 앞은 글자 · 숫자가 아니어야 하고, 뒤는 글자 · 숫자가 아니거나 (영문 · 숫자로 끝나는 이름이면) 영문 · 숫자가 아니거나 조사 한 낱말이어야 한다.
 * 더 긴 이름 안에 든 짧은 일치는 버린다 (Taskforce 0.2.0 안의 Taskforce). 나온 순서대로 id (중복 없음)
 */
export function matchProjectNames(text: string, contexts: readonly { id: string; name: string }[]): string[] {
  const haystack = normalizeName(unquoted(text));
  const spans: { id: string; start: number; end: number }[] = [];
  for (const context of contexts) {
    const name = normalizeName(context.name);
    if (!name) continue;
    for (let from = 0; ; ) {
      const start = haystack.indexOf(name, from);
      if (start < 0) break;
      from = start + 1;
      const end = start + name.length;
      const before = start === 0 ? "" : haystack[start - 1];
      if (before && isLetterOrDigit(before)) continue;
      const after = haystack[end] ?? "";
      const last = name[name.length - 1];
      const ok = after === "" || !isLetterOrDigit(after) || (isAsciiAlnum(last) && !isAsciiAlnum(after)) || PARTICLE.test(haystack.slice(end));
      if (ok) spans.push({ id: context.id, start, end });
    }
  }
  const kept = spans.filter((s) => !spans.some((o) => o.id !== s.id && o.start <= s.start && o.end >= s.end && o.end - o.start > s.end - s.start));
  const ids: string[] = [];
  for (const span of kept.sort((a, b) => a.start - b.start)) if (!ids.includes(span.id)) ids.push(span.id);
  return ids;
}

// ─── 대상 정하기 ───

export type ContextInfo = { id: string; name: string; status: "active" | "archived"; context_version: number };
/** 이동 · 빼기 한 건: add = 확인된 멤버로 넣을 범위, remove = 뺄 범위 */
export type MoveItem = { action: OrganizeAction; add: ContextInfo | null; remove: ContextInfo | null };

export type ReplyReason =
  /** 없는 번호 · 남의 번호 */
  | "issue_not_found"
  | "issue_dropped"
  | "already_deleted"
  | "already_there"
  | "not_member"
  | "context_archived"
  | "too_many"
  | "memory_off";

export type OrganizeResolution =
  /** 대상이 하나로 정해졌다: 이 턴에서 바로 쓴다. remove op는 add가 모두 null이고 to도 null이다 */
  | { kind: "move"; op: "move" | "remove"; items: MoveItem[]; to: ContextInfo | null; from: ContextInfo | null }
  /** J1 확신 0.5–0.8: 같은 내용을 쓰지 않고 글로 한 번 묻는다 (제안 move) */
  | { kind: "move_ask"; op: "move" | "remove"; items: MoveItem[]; to: ContextInfo | null; from: ContextInfo | null }
  /** 확인 카드 (제안 delete) */
  | { kind: "delete"; targets: OrganizeAction[] }
  /** 확인 카드 (제안 merge): from이 사라지고 into가 남는다 */
  | { kind: "merge"; from: OrganizeAction; into: OrganizeAction }
  /** 모자란 것을 한 번 묻는다 (candidates: 이름이 겹친 후보 ≤ 3) */
  | { kind: "ask"; pending: PendingOrganize; candidates?: { id: string; name: string }[] }
  /** 쓰기 없는 사실 답 (op: 이미 알던 무엇을 — 번호를 못 찾는 답처럼 그 전에 끝나면 null) */
  | { kind: "reply"; reason: ReplyReason; numbers?: number[]; names?: string[]; op?: OrganizeOp | null };

export type ResolveInput = {
  /** 이번 메시지 글 */
  text: string;
  /** 앱이 붙인 added 칩 (소유를 확인한 것) */
  chipActionIds: string[];
  chipContextIds: string[];
  lookup: OrganizeLookup;
  /** 앞 답이 한 번 물었다면 그 값 (asks organize) */
  pending: PendingOrganize | null;
  /** Jev organize-v1 답. 묻지 않은 질문은 null */
  judged: { op: { op: OrganizeOp | "other"; confidence: number } | null; into: { number: number | null; confidence: number } | null };
  /** J1 확신이 0.5–0.8 (act 임계값 미만): 이동은 바로 쓰지 않고 글로 묻는다 */
  confirm: boolean;
  /** MEMORY_ENABLED: 꺼져 있으면 이동 · 빼기는 쓰지 않는다 */
  memoryOn: boolean;
};

/** Jev op · into의 최소 확신 (INTENT_THRESHOLDS.act와 같다) */
const JEV_ACT = 0.8;
export const ORGANIZE_MAX_ISSUES = 3;

const lower = (value: string) => value.toLowerCase();
const unique = (values: string[]) => [...new Set(values.map(lower))];

/**
 * 이슈 지칭: 글의 #번호 ∪ added 칩 (+ 이번 메시지가 자기 이슈를 말하지 않았을 때만, 또는 남는 쪽을 물은 답일 때 앞 pending의 이슈).
 * 제목은 보지 않는다. unknown: lookup에 없는 번호 (없는 번호 · 남의 번호). ownIds: 이번 메시지가 직접 가리킨 이슈
 */
export function organizeIssues(input: Pick<ResolveInput, "text" | "chipActionIds" | "lookup" | "pending">) {
  const { lookup, pending } = input;
  const actionsByNumber = new Map(lookup.actions.map((a) => [a.number, a]));
  const actionsById = new Map(lookup.actions.map((a) => [lower(a.id), a]));
  const mentions = findIssueMentions(input.text);
  const unknown = mentions.filter((m) => !actionsByNumber.has(m.number)).map((m) => m.number);
  const ownIds = unique([...mentions.filter((m) => actionsByNumber.has(m.number)).map((m) => actionsByNumber.get(m.number)!.id), ...input.chipActionIds.filter((id) => actionsById.has(lower(id)))]);
  const keepPending = pending !== null && (ownIds.length === 0 || pending.missing === "into");
  const ids = unique([...ownIds, ...(keepPending ? pending.action_ids.filter((id) => actionsById.has(lower(id))) : [])]);
  return { mentions, unknown, ownIds, ids, actions: ids.map((id) => actionsById.get(id)!) };
}

export function resolveOrganize(input: ResolveInput): OrganizeResolution {
  const { lookup, pending } = input;
  const contextsById = new Map(lookup.contexts.map((c) => [lower(c.id), c]));
  const info = (context: { id: string; name: string; status: "active" | "archived"; context_version: number }): ContextInfo => {
    const current = contextsById.get(lower(context.id)) ?? context;
    return { id: current.id, name: current.name, status: current.status, context_version: current.context_version };
  };

  const { mentions, unknown, ownIds, ids, actions } = organizeIssues(input);
  if (unknown.length > 0) return { kind: "reply", reason: "issue_not_found", numbers: unknown };
  if (ids.length > ORGANIZE_MAX_ISSUES) return { kind: "reply", reason: "too_many" };
  const numbersOf = (list: OrganizeAction[]) => list.map((a) => a.number);

  // ─ 무엇을: Jev op ≥ 0.8, 아니면 앞 pending의 op
  const judgedOp = input.judged.op;
  const op: OrganizeOp | null = judgedOp && judgedOp.confidence >= JEV_ACT && judgedOp.op !== "other" ? judgedOp.op : (pending?.op ?? null);

  // ─ 프로젝트 후보: added context 칩 ∪ 글에 이름이 그대로 있는 범위
  const candidateIds = unique([...input.chipContextIds.filter((id) => contextsById.has(lower(id))), ...matchProjectNames(input.text, lookup.contexts).filter((id) => contextsById.has(lower(id)))]);
  const candidates = candidateIds.map((id) => info(contextsById.get(id)!));
  const candidateNames = candidates.slice(0, REFERENT_CANDIDATE_LIMIT).map((c) => ({ id: c.id, name: c.name }));
  const samePending = pending !== null && pending.op === op;
  const pendingContext = samePending && pending.context_id && pending.missing !== "from" ? (contextsById.get(lower(pending.context_id)) ?? null) : null;

  const ask = (missing: PendingMissing, over: Partial<PendingOrganize> = {}, withCandidates = false): OrganizeResolution => ({
    kind: "ask",
    pending: { state: "pending", op, action_ids: actions.map((a) => a.id), context_id: null, missing, ...over },
    ...(withCandidates ? { candidates: candidateNames } : {}),
  });

  if (!op) return ask("op", { context_id: candidates.length === 1 ? candidates[0].id : (pendingContext?.id ?? null) });

  // ─ 삭제: 이미 지운 것은 빼고 카드
  if (op === "delete") {
    if (actions.length === 0) return ask("issue");
    const live = actions.filter((a) => a.status !== "dropped");
    return live.length === 0 ? { kind: "reply", reason: "already_deleted", numbers: numbersOf(actions), op } : { kind: "delete", targets: live };
  }

  // ─ 병합: 서로 다른 이슈 정확히 둘, 남는 쪽은 (pending의 답 → Jev into ≥ 0.8 → 뒤에 말한 이슈) 순서로
  if (op === "merge") {
    if (actions.length !== 2) return ask("issue");
    const gone = actions.filter((a) => a.status === "dropped");
    if (gone.length > 0) return { kind: "reply", reason: "issue_dropped", numbers: numbersOf(gone), op };
    let into: OrganizeAction | null = null;
    if (pending?.missing === "into") {
      const named = actions.filter((a) => ownIds.includes(lower(a.id)));
      if (named.length === 1) into = named[0];
    }
    const judgedInto = input.judged.into;
    if (!into && judgedInto && judgedInto.number !== null && judgedInto.confidence >= JEV_ACT) into = actions.find((a) => a.number === judgedInto.number) ?? null;
    if (!into) {
      const at = (a: OrganizeAction) => mentions.find((m) => m.number === a.number)?.index;
      const [first, second] = actions;
      if (at(first) !== undefined && at(second) !== undefined) into = at(first)! > at(second)! ? first : second;
    }
    if (!into) return ask("into");
    return { kind: "merge", from: actions.find((a) => a !== into)!, into };
  }

  // ─ 이동 · 빼기: 프로젝트 기능이 꺼져 있으면 쓰지 않는다
  if (!input.memoryOn) return { kind: "reply", reason: "memory_off", op };
  if (actions.length === 0) return ask("issue", { context_id: candidates.length === 1 ? candidates[0].id : (pendingContext?.id ?? null) });
  const dropped = actions.filter((a) => a.status === "dropped");
  if (dropped.length > 0) return { kind: "reply", reason: "issue_dropped", numbers: numbersOf(dropped), op };
  const done = (items: MoveItem[], to: ContextInfo | null): OrganizeResolution => {
    const froms = items.map((i) => i.remove?.id ?? null);
    const from = froms.length > 0 && froms.every((f) => f === froms[0]) && items[0].remove ? items[0].remove : null;
    return { kind: input.confirm ? "move_ask" : "move", op: op, items, to, from };
  };

  if (op === "move") {
    let to: ContextInfo | null;
    let explicitFrom: ContextInfo | null = null;
    if (pending?.missing === "from" && pending.op === "move") {
      const target = pending.context_id ? contextsById.get(lower(pending.context_id)) : undefined;
      to = target ? info(target) : null;
      if (candidates.length > 1) return ask("from", { context_id: to?.id ?? null }, true);
      explicitFrom = candidates[0] ?? null;
      if (to && !explicitFrom) return ask("from", { context_id: to.id });
    } else {
      if (candidates.length > 1) return ask("project", {}, true);
      to = candidates[0] ?? (pendingContext ? info(pendingContext) : null);
    }
    if (!to) return ask("project");
    if (to.status === "archived") return { kind: "reply", reason: "context_archived", names: [to.name], op };
    const items: MoveItem[] = [];
    for (const action of actions) {
      const memberships = action.contexts.map(info);
      const inTo = memberships.some((c) => lower(c.id) === lower(to.id));
      let remove: ContextInfo | null;
      if (explicitFrom) remove = lower(explicitFrom.id) !== lower(to.id) && memberships.some((c) => lower(c.id) === lower(explicitFrom!.id)) ? explicitFrom : null;
      else {
        const others = memberships.filter((c) => lower(c.id) !== lower(to.id));
        if (others.length > 1) return ask("from", { context_id: to.id });
        remove = others[0] ?? null;
      }
      if (inTo && remove === null) continue;
      items.push({ action, add: to, remove });
    }
    if (items.length === 0) return { kind: "reply", reason: "already_there", numbers: numbersOf(actions), names: [to.name], op };
    return done(items, to);
  }

  // 빼기
  if (candidates.length > 1) return ask("project", {}, true);
  const explicit = candidates[0] ?? (pendingContext ? info(pendingContext) : null);
  const items: MoveItem[] = [];
  for (const action of actions) {
    const memberships = action.contexts.map(info);
    let target: ContextInfo | null;
    if (explicit) target = memberships.some((c) => lower(c.id) === lower(explicit.id)) ? explicit : null;
    else if (memberships.length === 1) target = memberships[0];
    else return ask("project");
    if (target?.status === "archived") return { kind: "reply", reason: "context_archived", names: [target.name], op };
    if (target) items.push({ action, add: null, remove: target });
  }
  if (explicit?.status === "archived") return { kind: "reply", reason: "context_archived", names: [explicit.name], op };
  if (items.length === 0) return { kind: "reply", reason: "not_member", numbers: numbersOf(actions), names: explicit ? [explicit.name] : [], op };
  return done(items, null);
}

// ─── 쓸 것 · 제안 내용 만들기 ───

const clip = (value: string, max: number) => [...value].slice(0, max).join("");
const contextRef = (context: ContextInfo) => ({ id: context.id, name: clip(context.name, 200), version: context.context_version });

/** 카드 · 질문이 보이는 이슈 한 줄 (제목은 200자까지, 프로젝트는 5개까지) */
export function organizeTarget(action: OrganizeAction): OrganizeTarget {
  return {
    action_id: action.id,
    number: action.number,
    title: clip(action.title, 200),
    version: action.version,
    contexts: action.contexts.slice(0, 5).map((c) => ({ id: c.id, name: clip(c.name, 200) })),
    open_sessions: action.open_sessions,
    evidence_count: action.evidence_count,
  };
}

/** 이동을 묻는 글의 제안 내용 (to null = 빼기, from null = 넣기 · 출발이 이슈마다 다르면 null) */
export function movePayload(move: { items: MoveItem[]; to: ContextInfo | null; from: ContextInfo | null }): Extract<ProposalPayloadV2, { kind: "move" }> {
  return { kind: "move", targets: move.items.map((i) => organizeTarget(i.action)), from: move.from ? contextRef(move.from) : null, to: move.to ? contextRef(move.to) : null };
}

export function deletePayload(targets: OrganizeAction[]): Extract<ProposalPayloadV2, { kind: "delete" }> {
  return { kind: "delete", targets: targets.map(organizeTarget) };
}

export function mergePayload(from: OrganizeAction, into: OrganizeAction): Extract<ProposalPayloadV2, { kind: "merge" }> {
  return { kind: "merge", from: organizeTarget(from), into: organizeTarget(into) };
}

/** finish_turn에 보낼 이동 (범위 version은 organize_lookup이 읽은 값: 요청이 본 version 하나만 조건이 된다) */
export function moveOps(items: MoveItem[]): MovePlanItem[] {
  return items.map((i) => ({
    action_id: i.action.id,
    add: i.add ? { context_id: i.add.id, expected_version: i.add.context_version } : null,
    remove: i.remove ? { context_id: i.remove.id, expected_version: i.remove.context_version } : null,
  }));
}

/**
 * 이동 제안을 글 "응"으로 채택할 때: 제안이 가리킨 이슈 · 프로젝트로 지금 기록에서 다시 푼다 (같은 규칙, 같은 resolveOrganize).
 * 그 사이 이슈를 지웠거나 프로젝트를 보관했거나 이미 옮겨졌으면 move가 아니라 쓰기 없는 답이 나온다.
 */
export function resolveMoveAdopt(payload: Extract<ProposalPayloadV2, { kind: "move" }>, lookup: OrganizeLookup, memoryOn: boolean): OrganizeResolution {
  const op: "move" | "remove" = payload.to ? "move" : "remove";
  const project = payload.to ?? payload.from;
  const actionIds = payload.targets.map((t) => t.action_id);
  const origin = payload.to ? payload.from : null;
  return resolveOrganize({
    text: "",
    chipActionIds: actionIds,
    chipContextIds: origin ? [origin.id] : project ? [project.id] : [],
    lookup,
    pending: origin ? { state: "pending", op: "move", action_ids: actionIds, context_id: payload.to!.id, missing: "from" } : null,
    judged: { op: { op, confidence: 1 }, into: null },
    confirm: false,
    memoryOn,
  });
}
