import type { MemoryLike, MemoryOrigin, MemoryScopeKind } from "./memory";

// 읽을 때의 기억 해석과 검색 결과 거르기 (아키텍처 6.3 · 6.4 · 6.5). DB와 분리된 순수 함수: 묶음 조립(bundle.ts) · 대화(B2) · 테스트가 같은 코드를 쓴다.
//
// 범위 사이의 우선은 여기서만 정한다 (사용자 결정 2026-10-10): 요청의 범위(target)에 해당하는 항목만 보고, 같은 사실(kind + subject)이면
// 더 좁은 범위가 이긴다. 다른 범위 · 다른 프로젝트의 항목은 처음부터 보지 않으므로, 프로젝트의 예외는 그 프로젝트 안에서만 전체 기본값을 가린다.
// 같은 수준의 다른 대상(할 일 둘 · 상대 둘)은 서로 다른 사실이라 둘 다 남는다. 주제가 없는 항목은 아무것도 가리지 않는다 (kind만 같으면 둘 다 남는다).
// id는 대소문자를 가리지 않는다 (앱의 uuidString은 대문자).

/** 이 요청이 속한 범위들. 전체(global)는 늘 포함한다 */
export type ScopeTarget = {
  contextId?: string | null;
  actionIds?: readonly string[];
  personIds?: readonly string[];
  agentAdapter?: string | null;
};

/**
 * 좁은 범위가 이긴다: 할 일 > 범위(프로젝트 · 고객 · 목표) > 상대 > 에이전트 > 전체.
 * 범위 · 상대 · 에이전트 사이의 순서는 B1 결정이다(docs/context-layer.md). 같은 사실이 셋 이상의 범위에 겹칠 때만 의미가 있다
 */
export const SCOPE_RANK: Record<MemoryScopeKind, number> = { action: 5, context: 4, counterpart: 3, agent: 2, global: 1 };

/** explicit(사용자가 말함) > observed(자료에서 읽음) > inferred(모델 추정) (아키텍처 5.3) */
export const ORIGIN_RANK: Record<MemoryOrigin, number> = { explicit: 3, observed: 2, inferred: 1 };

const time = (value: string | Date | null): number | null => (value === null ? null : value instanceof Date ? value.getTime() : Date.parse(value));
const sameId = (a: string | null | undefined, b: string | null | undefined) => Boolean(a && b) && a!.toLowerCase() === b!.toLowerCase();
const includesId = (ids: readonly string[] | undefined, id: string | null) => (ids ?? []).some((candidate) => sameId(candidate, id));

/** 이 항목이 요청 범위에 해당하는가 (다른 범위 · 다른 프로젝트의 항목은 false) */
export function appliesTo(item: Pick<MemoryLike, "scope_kind" | "context_id" | "action_id" | "person_id" | "agent_adapter">, target: ScopeTarget): boolean {
  switch (item.scope_kind) {
    case "global":
      return true;
    case "context":
      return sameId(item.context_id, target.contextId);
    case "action":
      return includesId(target.actionIds, item.action_id);
    case "counterpart":
      return includesId(target.personIds, item.person_id);
    case "agent":
      return Boolean(target.agentAdapter) && item.agent_adapter === target.agentAdapter;
  }
}

export type UsableOptions = {
  now: Date;
  /** 모델 추정(inferred)도 넣는가. 묶음 · 응답 근거에는 넣지 않는다(기본 false). 확인 화면만 true */
  includeInferred?: boolean;
  /** 접근을 잃었거나(access_lost_at) 글이 지워진 원문 id: 그 원문에서 온 observed 기억은 쓰지 않는다 (소문자 uuid) */
  unavailableSourceIds?: ReadonlySet<string>;
  /** 주면, 상태를 아는 원문(소문자 uuid)에서 온 observed 기억만 쓴다: 모르는 원문(다른 사용자 · 지워진 원문)을 쓸 수 있는 것으로 보지 않는다 */
  knownSourceIds?: ReadonlySet<string>;
};

/** 지금 쓸 수 있는 항목인가: 정정 · 잊기 전, 글이 남음, 유효 구간 안, 추정 제외(기본), 출처 원문을 읽을 수 있음 */
export function isUsableMemory(item: MemoryLike, options: UsableOptions): boolean {
  if (item.superseded_at !== null || item.revoked_at !== null) return false;
  if (item.source_purged || item.statement === "") return false;
  if (item.origin === "inferred" && !options.includeInferred) return false;
  const now = options.now.getTime();
  const from = time(item.valid_from);
  const until = time(item.valid_until);
  if (from !== null && from > now) return false;
  if (until !== null && until < now) return false;
  const sourceId = typeof item.source_ref?.source_id === "string" ? item.source_ref.source_id.toLowerCase() : null;
  if (item.origin === "observed" && sourceId && options.unavailableSourceIds?.has(sourceId)) return false;
  if (item.origin === "observed" && sourceId && options.knownSourceIds && !options.knownSourceIds.has(sourceId)) return false;
  return true;
}

/** 같은 범위 · 같은 대상 · 같은 사실 안에서 이긴 쪽: 높은 origin > 늦게 말한 · 읽은 것 > id (결정적) */
function wins(a: MemoryLike, b: MemoryLike): boolean {
  const origin = ORIGIN_RANK[a.origin] - ORIGIN_RANK[b.origin];
  if (origin !== 0) return origin > 0;
  const observed = (time(a.observed_at) ?? 0) - (time(b.observed_at) ?? 0);
  if (observed !== 0) return observed > 0;
  return a.id > b.id;
}

/** 범위와 대상 (같은 수준의 다른 대상은 다른 자리다) */
const slotOf = (item: MemoryLike) =>
  `${item.scope_kind}\u0000${(item.context_id ?? item.action_id ?? item.person_id ?? item.agent_adapter ?? "").toLowerCase()}`;

/**
 * 요청 범위에서 지금 쓰는 기억. 범위에 해당하고 쓸 수 있는 항목만 본다. 같은 사실(kind + subject)이면 좁은 범위 수준부터 대상마다 하나(wins)를
 * 남기고, 그 수준이 요청한 대상을 모두 덮으면 넓은 수준은 가려진다. 덮지 못하면(할 일 둘 중 하나에만 예외) 다음 넓은 수준도 남긴다:
 * 예외가 없는 대상에는 기본값이 그대로 적용되기 때문이다. 할 일 둘 · 상대 둘의 같은 사실은 둘 다 남는다.
 * 주제 없는 항목은 모두 남는다. 순서: 좁은 범위 먼저, 같은 범위면 늦게 말한 것 먼저.
 */
export function effectiveMemory<T extends MemoryLike>(items: readonly T[], target: ScopeTarget, options: UsableOptions): T[] {
  const facts = new Map<string, Map<string, T>>();
  const rest: T[] = [];
  for (const item of items) {
    if (!appliesTo(item, target) || !isUsableMemory(item, options)) continue;
    if (!item.subject) {
      rest.push(item);
      continue;
    }
    const key = `${item.kind}\u0000${item.subject}`;
    const slots = facts.get(key) ?? new Map<string, T>();
    facts.set(key, slots);
    const current = slots.get(slotOf(item));
    if (!current || wins(item, current)) slots.set(slotOf(item), item);
  }
  // 여러 대상을 받는 수준: 요청한 대상마다 자기 행이 있어야 넓은 수준을 가린다 (범위 · 에이전트 · 전체는 대상이 하나다)
  const requested: Partial<Record<MemoryScopeKind, string[]>> = {
    action: (target.actionIds ?? []).map((id) => id.toLowerCase()),
    counterpart: (target.personIds ?? []).map((id) => id.toLowerCase()),
  };
  const kept: T[] = [];
  for (const slots of facts.values()) {
    const winners = [...slots.values()].sort((a, b) => SCOPE_RANK[b.scope_kind] - SCOPE_RANK[a.scope_kind]);
    for (const level of [...new Set(winners.map((item) => item.scope_kind))]) {
      const atLevel = winners.filter((item) => item.scope_kind === level);
      kept.push(...atLevel);
      const covered = new Set(atLevel.map((item) => (item.action_id ?? item.person_id ?? "").toLowerCase()));
      if ((requested[level] ?? []).every((id) => covered.has(id))) break;
    }
  }
  return [...kept, ...rest].sort(
    (a, b) => SCOPE_RANK[b.scope_kind] - SCOPE_RANK[a.scope_kind] || (time(b.observed_at) ?? 0) - (time(a.observed_at) ?? 0) || (a.id < b.id ? -1 : 1),
  );
}

/** 검색 · 묶음에서 원문을 거를 때 보는 값 */
export type SourceState = {
  id: string;
  /** 연결의 서비스 (connections.provider). 직접 붙여 넣은 원문 · 연결을 끊은 원문은 null */
  provider: string | null;
  /** sources.raw_text_purged_at: 보관 기간 · Slack 끊기로 글이 지워짐 */
  purged: boolean;
  /** sources.raw_text_purge_reason */
  purgeReason: string | null;
  /** sources.access_lost_at: 403 · 삭제 감지 */
  accessLost: boolean;
  externalUrl: string | null;
};

/**
 * Slack에서 온 원문인가 (Slack D3: Slack 글자는 묶음 · 조각으로 밖에 나가지 않는다). 연결이 Slack이거나, Slack 끊기로 지운 원문이거나,
 * 링크가 Slack이다 (연결 행이 지워져 provider가 비어도). 실행 자료 조립(src/lib/execution/context.ts isSlackSource)과 같은 기준이다:
 * 맥락층은 실행 코드를 가져오지 않으므로(boundary.test.ts) 같은 규칙을 여기 둔다
 */
export function isSlackDerived(source: Pick<SourceState, "provider" | "purgeReason" | "externalUrl">): boolean {
  if (source.provider === "slack" || source.purgeReason === "disconnected") return true;
  if (!source.externalUrl) return false;
  try {
    const host = new URL(source.externalUrl).hostname.toLowerCase();
    return host === "slack.com" || host.endsWith(".slack.com");
  } catch {
    return false;
  }
}

/** 검색 · 묶음에 쓸 수 없는 원문 id (소문자): 글이 지워졌거나 접근을 잃었거나 Slack에서 왔다 */
export function unavailableSources(sources: readonly SourceState[]): Set<string> {
  return new Set(sources.filter((s) => s.purged || s.accessLost || isSlackDerived(s)).map((s) => s.id.toLowerCase()));
}
