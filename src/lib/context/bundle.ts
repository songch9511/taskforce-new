import { createHash } from "node:crypto";

import type { MemoryKind, MemoryLike, MemoryOrigin } from "./memory";
import { effectiveMemory, unavailableSources, type ScopeTarget, type SourceState } from "./retrieve";

// 맥락 묶음(context bundle)의 맥락 부분 (아키텍처 6.3, 런타임 계약 5장). 순수 함수: 보내지 않는다(dispatch는 D3).
// 런타임 계약 5장의 goal · acceptance · constraints · permissions · marker 등은 묶음을 쓰는 쪽(C2 · D3)이 더한다.
// 이 함수가 만드는 것에는 실행 모드 · 대상 · 예산 · 권한이 없다: 기억 · 선호는 권한이 되지 않는다(I04 · I11).
//
// 포함 규칙 (6.3 · 6.5):
// - 기억: 요청 범위에서 지금 쓰는 것만(effectiveMemory). 추정(inferred) · 다른 범위 · 정정 · 잊은 · 글이 지워진 항목,
//   접근을 잃었거나 글이 지워졌거나 Slack에서 온 원문의 observed 기억은 넣지 않는다.
// - 사람: 이름이 있는 사람만, 이메일은 넣지 않는다(필요한 단계만 따로). role은 그 사람 범위의 relationship 기억.
// - 자료: 상태를 아는 쓸 수 있는 원문(글 있음 · 접근 가능 · Slack 아님)의 조각만, 등급 T1(원문 인용).
// - manifest: 넣은 것의 id만 (글 없음). 이미 보낸 묶음은 회수할 수 없으므로 "어디까지 나갔는지"를 이것으로 남긴다(ARCH08).

export type BundlePerson = { id: string; display_name: string | null };
export type BundleChunk = { id: string; source_id: string; source_revision: string | null; seq: number; text: string };

export type ContextBundleInput = {
  /** 범위 (null = All work) */
  context: { id: string; context_version: number } | null;
  /** "나": 수신자 · 작성자 서명용 최소 정보 (loadIdentity의 이름 · "나"로 치는 주소) */
  me: { display_name: string; emails: string[] };
  /** 요청 범위의 할 일 · 상대 · 에이전트 (context는 위에서) */
  target?: Omit<ScopeTarget, "contextId">;
  /** 후보 기억 (다른 범위 · 이력이 섞여 있어도 된다: 여기서 고른다) */
  memory: readonly MemoryLike[];
  people: readonly BundlePerson[];
  chunks: readonly BundleChunk[];
  /** 기억 · 조각이 가리키는 원문들의 상태. 여기 없는 원문의 조각 · observed 기억은 넣지 않는다 (상태를 모르는 원문을 쓸 수 있는 것으로 보지 않는다) */
  sources: readonly SourceState[];
  now: Date;
  limits?: { memory?: number; materials?: number };
};

export type ContextBundle = {
  context_id: string | null;
  context_version: number | null;
  identity: { me: { display_name: string; emails: string[] } };
  memory: { id: string; kind: MemoryKind; statement: string; origin: MemoryOrigin; observed_at: string }[];
  people: { id: string; display_name: string; role: string | null }[];
  materials: { ref: string; source_id: string; version: string | null; tier: "T1"; text: string }[];
};

/** 묶음에 무엇이 들어갔는지 (id만, 글 없음). execution_steps.args.bundle_manifest에 남긴다 (D3) */
export type BundleManifest = {
  context_id: string | null;
  context_version: number | null;
  memory_item_ids: string[];
  person_ids: string[];
  source_ids: string[];
  chunk_ids: string[];
};

const DEFAULT_LIMITS = { memory: 40, materials: 12 };

const iso = (value: string | Date) => (value instanceof Date ? value : new Date(value)).toISOString();

/** 키 순서를 고정한 JSON (hash용) */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical((value as Record<string, unknown>)[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function buildContextBundle(input: ContextBundleInput): { bundle: ContextBundle; manifest: BundleManifest; hash: string } {
  const limits = { ...DEFAULT_LIMITS, ...input.limits };
  const unavailable = unavailableSources(input.sources);
  const known = new Set(input.sources.map((source) => source.id.toLowerCase()));
  const target: ScopeTarget = { ...input.target, contextId: input.context?.id ?? null };
  const personIds = new Set(input.people.map((p) => p.id));
  const memoryTarget: ScopeTarget = { ...target, personIds: [...new Set([...(target.personIds ?? []), ...personIds])] };
  const effective = effectiveMemory(input.memory, memoryTarget, { now: input.now, unavailableSourceIds: unavailable, knownSourceIds: known });

  // 상대의 역할: 그 사람 범위의 relationship 기억 (좁은 범위 우선 해석을 거친 것)
  const roles = new Map<string, string>();
  for (const item of effective) {
    const person = item.person_id?.toLowerCase();
    if (item.scope_kind === "counterpart" && item.kind === "relationship" && person && !roles.has(person)) roles.set(person, item.statement);
  }

  const memory = effective.slice(0, limits.memory).map((item) => ({
    id: item.id,
    kind: item.kind as MemoryKind,
    statement: item.statement,
    origin: item.origin,
    observed_at: iso(item.observed_at),
  }));
  const people = input.people
    .filter((person): person is BundlePerson & { display_name: string } => Boolean(person.display_name))
    .map((person) => ({ id: person.id, display_name: person.display_name, role: roles.get(person.id.toLowerCase()) ?? null }));
  const chunks = input.chunks
    .filter((chunk) => known.has(chunk.source_id.toLowerCase()) && !unavailable.has(chunk.source_id.toLowerCase()))
    .slice(0, limits.materials);
  const materials = chunks.map((chunk) => ({
    ref: `source:${chunk.source_id}#${chunk.seq}`,
    source_id: chunk.source_id,
    version: chunk.source_revision,
    tier: "T1" as const,
    text: chunk.text,
  }));

  const bundle: ContextBundle = {
    context_id: input.context?.id ?? null,
    context_version: input.context?.context_version ?? null,
    identity: { me: { display_name: input.me.display_name, emails: [...input.me.emails] } },
    memory,
    people,
    materials,
  };
  const manifest: BundleManifest = {
    context_id: bundle.context_id,
    context_version: bundle.context_version,
    memory_item_ids: memory.map((m) => m.id),
    person_ids: people.map((p) => p.id),
    source_ids: [...new Set(materials.map((m) => m.source_id))],
    chunk_ids: chunks.map((chunk) => chunk.id),
  };
  return { bundle, manifest, hash: createHash("sha256").update(canonical(bundle)).digest("hex") };
}
