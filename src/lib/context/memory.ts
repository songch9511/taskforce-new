import { z } from "zod";

import {
  MEMORY_STATEMENT_MAX_CHARS,
  agentAdapterIdSchema,
  memoryKindSchema,
  memoryOriginSchema,
  memorySourceRefSchema,
  type MemorySourceRef,
} from "@/lib/api/contract";

// 기억 항목 (memory_items, 아키텍처 5.3)의 순수 규칙. DB 쓰기는 store.ts(remember_memory_item), 읽을 때의 해석은 retrieve.ts.
//
// 정정 규칙 (사용자 결정 2026-10-10, docs/context-layer.md):
// - 같은 범위(scope_kind + 대상) · 같은 사실(kind + subject)의 명시적 정정만 이력(superseded_at)을 남긴다. DB 트리거가 막는다.
// - 범위 사이의 우선(좁은 범위가 이긴다)은 읽을 때 그 범위 안에서만 정한다: 프로젝트의 예외가 다른 프로젝트 · 전체 기본값을 지우지 않는다.
// - kind가 같다는 것만으로는 덮지 않는다: subject가 없는 항목은 아무것도 덮지 않고 덮이지도 않는다.

export type MemoryScopeKind = "global" | "context" | "action" | "counterpart" | "agent";
export type MemoryOrigin = z.infer<typeof memoryOriginSchema>;
export type MemoryKind = z.infer<typeof memoryKindSchema>;

type Time = string | Date;

/** 해석 · 묶음에 필요한 기억 행의 모양 (DB 행 · 계약 MemoryItem 모두 맞는다. 시각은 문자열 또는 Date) */
export type MemoryLike = {
  id: string;
  kind: string;
  scope_kind: MemoryScopeKind;
  context_id: string | null;
  action_id: string | null;
  person_id: string | null;
  agent_adapter: string | null;
  subject?: string | null;
  statement: string;
  origin: MemoryOrigin;
  source_ref: { source_id?: string; [key: string]: unknown } | null;
  observed_at: Time;
  valid_from: Time | null;
  valid_until: Time | null;
  superseded_at: Time | null;
  revoked_at: Time | null;
  source_purged: boolean;
};

/** subject 길이 상한 (DB CHECK memory_items_subject_shape와 같다) */
export const MEMORY_SUBJECT_MAX_CHARS = 200;

/**
 * "같은 사실"의 열쇠로 정규화한다: NFKC · 소문자 · 앞뒤 공백 제거 · 공백(줄바꿈 포함)은 하나로 · 제어 문자 제거.
 * 비면 null (주제 없음 = 아무것도 덮지 않는다). 상한을 넘으면 자른다 (코드 포인트 기준).
 */
export function normalizeMemorySubject(raw: string | null | undefined): string | null {
  if (raw == null) return null;
  const normalized = raw
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\p{Cc}/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  if (!normalized) return null;
  return [...normalized].slice(0, MEMORY_SUBJECT_MAX_CHARS).join("").trim();
}

/** 기억의 범위: 전체 · 범위(work_context) · 할 일 · 상대(person) · 에이전트 */
export type MemoryScope =
  | { kind: "global" }
  | { kind: "context"; contextId: string }
  | { kind: "action"; actionId: string }
  | { kind: "counterpart"; personId: string }
  | { kind: "agent"; agentAdapter: string };

/** 범위를 DB 열(scope_kind + 대상 열 하나)로 */
export function scopeColumns(scope: MemoryScope) {
  return {
    scope_kind: scope.kind,
    context_id: scope.kind === "context" ? scope.contextId : null,
    action_id: scope.kind === "action" ? scope.actionId : null,
    person_id: scope.kind === "counterpart" ? scope.personId : null,
    agent_adapter: scope.kind === "agent" ? scope.agentAdapter : null,
  };
}

/** 두 행이 같은 범위(종류와 대상까지)인가 */
export function sameScope(a: Pick<MemoryLike, "scope_kind" | "context_id" | "action_id" | "person_id" | "agent_adapter">, b: typeof a): boolean {
  return (
    a.scope_kind === b.scope_kind &&
    a.context_id === b.context_id &&
    a.action_id === b.action_id &&
    a.person_id === b.person_id &&
    a.agent_adapter === b.agent_adapter
  );
}

/** 같은 범위 · 같은 사실인가 (정정이 허용되는 쌍, DB memory_items_keep_history와 같은 조건). 주제가 없으면 false */
export function sameFact(a: MemoryLike, b: MemoryLike): boolean {
  return Boolean(a.subject) && a.subject === b.subject && a.kind === b.kind && sameScope(a, b);
}

const memoryScopeSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("global") }).strict(),
  z.object({ kind: z.literal("context"), contextId: z.uuid() }).strict(),
  z.object({ kind: z.literal("action"), actionId: z.uuid() }).strict(),
  z.object({ kind: z.literal("counterpart"), personId: z.uuid() }).strict(),
  z.object({ kind: z.literal("agent"), agentAdapter: agentAdapterIdSchema }).strict(),
]);

const timestampSchema = z.iso.datetime({ offset: true });

/**
 * 서버가 기억 하나를 쓸 때의 입력 (B2의 inform · correct · 자료 관찰이 이 모양으로 부른다).
 * observed는 출처(source_ref)가, inferred는 confidence가 반드시 있다 (DB CHECK와 같다). subject는 정규화해서 넣는다
 */
export const memoryWriteSchema = z
  .object({
    kind: memoryKindSchema,
    scope: memoryScopeSchema,
    subject: z.string().max(1000).nullable().optional(),
    statement: z.string().trim().min(1).max(MEMORY_STATEMENT_MAX_CHARS),
    value: z.record(z.string(), z.unknown()).optional(),
    origin: memoryOriginSchema,
    source_ref: memorySourceRefSchema.nullable().optional(),
    observed_at: timestampSchema.optional(),
    valid_from: timestampSchema.nullable().optional(),
    valid_until: timestampSchema.nullable().optional(),
    confidence: z.number().min(0).max(1).nullable().optional(),
  })
  .strict()
  .refine((w) => w.origin !== "observed" || Boolean(w.source_ref), { message: "observed 기억은 출처가 필요합니다", path: ["source_ref"] })
  // 'memory:<id>' 주제는 정정이 만든다 (DB remember_memory_item도 막는다)
  .refine((w) => !normalizeMemorySubject(w.subject)?.startsWith("memory:"), { message: "memory:로 시작하는 주제는 정정에만 씁니다", path: ["subject"] })
  .refine((w) => (w.origin === "inferred") === (w.confidence != null), { message: "confidence는 inferred에만, inferred에는 반드시", path: ["confidence"] })
  .refine((w) => !w.valid_from || !w.valid_until || Date.parse(w.valid_from) <= Date.parse(w.valid_until), {
    message: "valid_from이 valid_until보다 늦습니다",
    path: ["valid_until"],
  });
export type MemoryWrite = z.input<typeof memoryWriteSchema>;

/** remember_memory_item에 넘기는 p_item (DB 열 이름) */
export function memoryWriteRow(input: MemoryWrite) {
  const write = memoryWriteSchema.parse(input);
  return {
    kind: write.kind,
    ...scopeColumns(write.scope),
    subject: normalizeMemorySubject(write.subject),
    statement: write.statement,
    value: write.value ?? {},
    origin: write.origin,
    source_ref: (write.source_ref ?? null) as MemorySourceRef | null,
    observed_at: write.observed_at ?? null,
    valid_from: write.valid_from ?? null,
    valid_until: write.valid_until ?? null,
    confidence: write.confidence ?? null,
  };
}
