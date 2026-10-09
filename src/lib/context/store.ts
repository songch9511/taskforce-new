import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { budgetFetch } from "@/lib/ai/budget";
import { agentAdapterIdSchema } from "@/lib/api/contract";
import { embed, embedConfigFromEnv } from "@/lib/ai/embed";
import { withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import { flagEnabled } from "@/lib/flags";

import { indexSourceChunks, type ChunkIndexResult, type ChunkSource } from "./chunks";
import { memberColumns, memberConflictColumns, type ContextMemberRef } from "./contexts";
import type { IdentityLinkRow } from "./identity-links";
import { memoryWriteRow, type MemoryLike, type MemoryWrite } from "./memory";
import type { PersonObservation } from "./people";
import type { ScopeTarget, SourceState } from "./retrieve";

// 맥락층의 DB 쪽 (service role). 모든 쿼리를 user_id로 좁힌다. 규칙은 순수 모듈(memory · retrieve · bundle · chunks · people · identity-links)과
// DB 함수(20261104000000_context_layer)에 있고, 여기는 부르기만 한다.
// gate: 기억 · 범위 · 사람 · 신원 링크 쓰기는 MEMORY_ENABLED, 조각 임베딩 · 검색은 SOURCE_CHUNKS_ENABLED. 꺼져 있으면 DB를 부르지 않는다
// (쓰기는 ContextGateOffError, 수집 뒤 조각 만들기는 조용히 건너뜀). 실행(src/lib/execution)은 가져오지 않는다 (boundary.test.ts).

type Env = Record<string, string | undefined>;

export class ContextGateOffError extends Error {
  constructor(readonly flag: "MEMORY_ENABLED" | "SOURCE_CHUNKS_ENABLED") {
    super(`${flag}가 꺼져 있어 맥락층에 쓰지 않았어요.`);
    this.name = "ContextGateOffError";
  }
}

function requireGate(flag: "MEMORY_ENABLED" | "SOURCE_CHUNKS_ENABLED", env: Env) {
  if (!flagEnabled(flag, env)) throw new ContextGateOffError(flag);
}

// ─── 기억 ─────────────────────────────────────────

export type RememberResult =
  | { status: "written"; id: string; superseded: string[]; supersededBy: string | null }
  | { status: "conflict" };

/**
 * 기억 하나를 쓴다 (remember_memory_item: 같은 범위 · 같은 사실의 지금 행과 견주어 진 쪽을 정정된 이력으로).
 * corrects: 사용자가 가리킨 항목의 정정 (expectedVersion이 다르거나 이미 정정 · 잊은 항목이면 conflict)
 */
export async function rememberMemory(
  admin: SupabaseClient,
  userId: string,
  input: MemoryWrite,
  options: { corrects?: { id: string; expectedVersion: number } } = {},
  env: Env = process.env,
): Promise<RememberResult> {
  requireGate("MEMORY_ENABLED", env);
  const { data } = await admin
    .rpc("remember_memory_item", {
      p_user_id: userId,
      p_item: memoryWriteRow(input),
      p_corrects: options.corrects?.id ?? null,
      p_expected_version: options.corrects?.expectedVersion ?? null,
    })
    .single<{ status: string; id: string | null; superseded: string[] | null; superseded_by: string | null }>()
    .throwOnError();
  if (data.status !== "written" || !data.id) return { status: "conflict" };
  return { status: "written", id: data.id, superseded: data.superseded ?? [], supersededBy: data.superseded_by };
}

/** 잊기 (revoked_at). 다시 보낸 요청 · 다른 version이면 false. 이미 보낸 묶음은 회수하지 못한다 (manifest에 id만 남아 있다) */
export async function forgetMemory(admin: SupabaseClient, userId: string, id: string, expectedVersion: number, env: Env = process.env): Promise<boolean> {
  requireGate("MEMORY_ENABLED", env);
  const { data } = await admin
    .from("memory_items")
    .update({ revoked_at: new Date().toISOString(), version: expectedVersion + 1 })
    .eq("id", id)
    .eq("user_id", userId)
    .eq("version", expectedVersion)
    .is("revoked_at", null)
    .select("id")
    .throwOnError();
  return (data ?? []).length > 0;
}

/** 행 삭제 (사용자가 기억을 지움). 이 행이 정정한 옛 행은 정정된 채 남는다 (포인터만 빈다) */
export async function deleteMemory(admin: SupabaseClient, userId: string, id: string, env: Env = process.env): Promise<boolean> {
  requireGate("MEMORY_ENABLED", env);
  const { data } = await admin.from("memory_items").delete().eq("id", id).eq("user_id", userId).select("id").throwOnError();
  return (data ?? []).length > 0;
}

const MEMORY_COLUMNS =
  "id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, origin, source_ref, observed_at, valid_from, valid_until, superseded_at, revoked_at, source_purged";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ids = (values: readonly string[] | undefined) => (values ?? []).filter((v) => UUID.test(v));

/** 요청 범위에 해당할 수 있는 지금 기억 행 (해석은 effectiveMemory가 한다). gate가 꺼져 있으면 빈 목록. id 모양이 아닌 값은 필터에 넣지 않는다 */
export async function loadScopeMemory(admin: SupabaseClient, userId: string, target: ScopeTarget, env: Env = process.env): Promise<MemoryLike[]> {
  if (!flagEnabled("MEMORY_ENABLED", env)) return [];
  const scopes = ["scope_kind.eq.global"];
  if (target.contextId && UUID.test(target.contextId)) scopes.push(`context_id.eq.${target.contextId}`);
  if (ids(target.actionIds).length) scopes.push(`action_id.in.(${ids(target.actionIds).join(",")})`);
  if (ids(target.personIds).length) scopes.push(`person_id.in.(${ids(target.personIds).join(",")})`);
  if (target.agentAdapter && agentAdapterIdSchema.safeParse(target.agentAdapter).success) scopes.push(`agent_adapter.eq.${target.agentAdapter}`);
  const { data } = await admin
    .from("memory_items")
    .select(MEMORY_COLUMNS)
    .eq("user_id", userId)
    .is("superseded_at", null)
    .is("revoked_at", null)
    .or(scopes.join(","))
    .throwOnError();
  return (data ?? []) as MemoryLike[];
}

// ─── 범위 ─────────────────────────────────────────

export async function createContext(
  admin: SupabaseClient,
  userId: string,
  input: { name: string; kind: "project" | "client" | "goal" | "personal" },
  env: Env = process.env,
): Promise<string> {
  requireGate("MEMORY_ENABLED", env);
  const { data } = await admin.from("work_contexts").insert({ user_id: userId, name: input.name, kind: input.kind }).select("id").single().throwOnError();
  return (data as { id: string }).id;
}

/** 코드 규칙(auto) · 모델 후보(inferred)의 멤버 추가. 이미 있으면(사용자가 넣었거나 뺀 멤버 포함) 그대로 둔다: 자동 규칙은 사용자의 선택을 덮지 않는다 */
export async function addContextMember(
  admin: SupabaseClient,
  userId: string,
  contextId: string,
  member: ContextMemberRef,
  origin: { kind: "auto" } | { kind: "inferred"; confidence: number },
  env: Env = process.env,
): Promise<void> {
  requireGate("MEMORY_ENABLED", env);
  await admin
    .from("context_members")
    .upsert(
      {
        user_id: userId,
        context_id: contextId,
        ...memberColumns(member),
        origin: origin.kind,
        confidence: origin.kind === "inferred" ? origin.confidence : null,
      },
      { onConflict: memberConflictColumns(member), ignoreDuplicates: true },
    )
    .throwOnError();
}

/** 사용자의 넣기 · 빼기 (origin user). 뺀 멤버는 행을 남겨 자동 규칙이 다시 넣지 못한다 */
export async function setContextMemberByUser(
  admin: SupabaseClient,
  userId: string,
  contextId: string,
  member: ContextMemberRef,
  included: boolean,
  env: Env = process.env,
): Promise<void> {
  requireGate("MEMORY_ENABLED", env);
  await admin
    .from("context_members")
    .upsert(
      {
        user_id: userId,
        context_id: contextId,
        ...memberColumns(member),
        origin: "user",
        confidence: null,
        removed_at: included ? null : new Date().toISOString(),
      },
      { onConflict: memberConflictColumns(member) },
    )
    .throwOnError();
}

// ─── 사람 · 신원 ───────────────────────────────────

/** 자료에서 본 계정 하나를 사람에 붙인다 (observe_person_handle). 사람 id */
export async function observePerson(
  admin: SupabaseClient,
  userId: string,
  observation: PersonObservation,
  connectionId: string | null,
  env: Env = process.env,
): Promise<string> {
  requireGate("MEMORY_ENABLED", env);
  const { data } = await admin
    .rpc("observe_person_handle", {
      p_user_id: userId,
      p_provider: observation.provider,
      p_account_ref: observation.accountRef,
      p_display_name: observation.displayName,
      p_email: observation.email,
      p_connection_id: connectionId,
    })
    .throwOnError();
  return data as string;
}

/**
 * 연결 결과(oauth)의 "나" 링크. 같은 계정의 추정(inferred) 링크가 있으면 oauth로 올린다(사용자가 그 계정으로 연결했다).
 * 사용자가 적거나 확인한 링크(profile · user_confirmed)는 바꾸지 않는다: 연결에 묶으면 연결을 끊을 때 함께 지워지기 때문이다.
 * gate가 꺼져 있으면 쓰지 않는다
 */
export async function recordOAuthIdentityLink(
  admin: SupabaseClient,
  link: { userId: string; connectionId: string; provider: string; accountRef: string; email: string | null },
  env: Env = process.env,
): Promise<void> {
  if (!flagEnabled("MEMORY_ENABLED", env)) return;
  await admin
    .from("identity_links")
    // 추정 때의 공용 계정 표시도 추정이었다: 사용자가 그 계정으로 연결했으므로 "나"의 계정으로 둔다
    .update({ verified_via: "oauth", connection_id: link.connectionId, shared_account: false, ...(link.email ? { email: link.email } : {}) })
    .eq("user_id", link.userId)
    .eq("provider", link.provider)
    .eq("account_ref", link.accountRef)
    .eq("verified_via", "inferred")
    .throwOnError();
  await admin
    .from("identity_links")
    .upsert(
      {
        user_id: link.userId,
        provider: link.provider,
        account_ref: link.accountRef,
        email: link.email,
        connection_id: link.connectionId,
        verified_via: "oauth",
      },
      { onConflict: "user_id,provider,account_ref", ignoreDuplicates: true },
    )
    .throwOnError();
}

/** 이 사용자의 신원 링크 (loadIdentity가 합친다) */
export async function loadIdentityLinks(admin: SupabaseClient, userId: string): Promise<IdentityLinkRow[]> {
  const { data } = await admin.from("identity_links").select("provider, account_ref, email, verified_via, shared_account").eq("user_id", userId).throwOnError();
  return (data ?? []) as IdentityLinkRow[];
}

// ─── 원문 조각 · 상태 ─────────────────────────────

const toPgVector = (v: number[]) => `[${v.join(",")}]`;

export async function replaceSourceChunks(
  admin: SupabaseClient,
  userId: string,
  sourceId: string,
  chunks: { text: string; embedding: number[] }[],
): Promise<{ status: string; chunks: number }> {
  const { data } = await admin
    .rpc("replace_source_chunks", {
      p_user_id: userId,
      p_source_id: sourceId,
      p_texts: chunks.map((c) => c.text),
      p_embeddings: chunks.map((c) => toPgVector(c.embedding)),
    })
    .single<{ status: string; chunks: number }>()
    .throwOnError();
  return data;
}

/** 동의 확인을 거친 임베딩 (원문 처리와 같은 모델 · 같은 AI 원가 한도) */
function gatedEmbed(admin: SupabaseClient, userId: string) {
  const config = { ...embedConfigFromEnv(), fetch: budgetFetch(admin, userId) };
  return withConsentGate({ embed: async (texts: string[]) => (await embed(config, texts)).vectors }, consentCheck(admin, userId)).embed!;
}

/**
 * 원문을 처리한 뒤 조각을 만든다 (수집 경로 ingestDeps.process가 부른다). SOURCE_CHUNKS_ENABLED가 꺼져 있으면 아무것도 부르지 않는다.
 * 실패해도 던지지 않는다: 조각은 보조 검색이라 원문 처리 · 동기화를 막지 않는다 (로그에는 원문 글 없이 오류 메시지만)
 */
export async function indexSourceAfterIngest(admin: SupabaseClient, source: ChunkSource, env: Env = process.env): Promise<ChunkIndexResult> {
  if (!flagEnabled("SOURCE_CHUNKS_ENABLED", env)) return { status: "gate_off", chunks: 0 };
  try {
    return await indexSourceChunks(
      { embed: gatedEmbed(admin, source.userId), replace: (userId, sourceId, chunks) => replaceSourceChunks(admin, userId, sourceId, chunks) },
      source,
      env,
    );
  } catch (error) {
    console.error(`원문 조각 만들기 실패 (${source.sourceId}):`, error instanceof Error ? error.message : error);
    return { status: "failed", chunks: 0 };
  }
}

/** 범위 안 조각 검색 (match_context_chunks). 질의 임베딩도 동의를 거친다. gate가 꺼져 있으면 빈 목록 */
export async function searchContextChunks(
  admin: SupabaseClient,
  userId: string,
  contextId: string,
  query: string,
  count = 8,
  env: Env = process.env,
): Promise<{ id: string; source_id: string; source_revision: string | null; seq: number; text: string; similarity: number }[]> {
  if (!flagEnabled("SOURCE_CHUNKS_ENABLED", env)) return [];
  const [vector] = await gatedEmbed(admin, userId)([query]);
  const { data } = await admin
    .rpc("match_context_chunks", { p_user_id: userId, p_context_id: contextId, p_embedding: toPgVector(vector), p_count: count })
    .throwOnError();
  return (data ?? []) as { id: string; source_id: string; source_revision: string | null; seq: number; text: string; similarity: number }[];
}

/**
 * 접근 상실(403 · 삭제 감지) 표시 · 되찾음 (set_sources_access: 같은 문서의 모든 revision을 함께). 행 · 기억 · 조각은 그대로 두고
 * 검색 · 묶음에서만 뺀다 (아키텍처 6.5). 맥락층 gate(MEMORY_ENABLED 또는 SOURCE_CHUNKS_ENABLED)가 모두 꺼져 있으면 쓰지 않는다
 */
export async function setSourcesAccessLost(
  admin: SupabaseClient,
  userId: string,
  sourceIds: string[],
  lost: boolean,
  env: Env = process.env,
): Promise<void> {
  if (sourceIds.length === 0 || !(flagEnabled("MEMORY_ENABLED", env) || flagEnabled("SOURCE_CHUNKS_ENABLED", env))) return;
  await admin.rpc("set_sources_access", { p_user_id: userId, p_source_ids: sourceIds, p_lost: lost }).throwOnError();
}

type SourceStateRow = {
  id: string;
  raw_text_purged_at: string | null;
  raw_text_purge_reason: string | null;
  access_lost_at: string | null;
  external_url: string | null;
  connections: { provider: string } | null;
};

/** 기억 · 조각이 가리키는 원문들의 상태 (retrieve.ts unavailableSources · bundle.ts가 거른다) */
export async function loadSourceStates(admin: SupabaseClient, userId: string, sourceIds: string[]): Promise<SourceState[]> {
  if (sourceIds.length === 0) return [];
  const { data } = await admin
    .from("sources")
    .select("id, raw_text_purged_at, raw_text_purge_reason, access_lost_at, external_url, connections(provider)")
    .eq("user_id", userId)
    .in("id", sourceIds)
    .throwOnError();
  return ((data ?? []) as unknown as SourceStateRow[]).map((row) => ({
    id: row.id,
    provider: row.connections?.provider ?? null,
    purged: row.raw_text_purged_at !== null,
    purgeReason: row.raw_text_purge_reason,
    accessLost: row.access_lost_at !== null,
    externalUrl: row.external_url,
  }));
}
