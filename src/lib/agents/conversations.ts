import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { conversationWithTargetSchema, type ConversationTargetKind, type ConversationWithTarget } from "@/lib/api/contract";
import { flagEnabled } from "@/lib/flags";

import { adapterEnabled, AGENT_REGISTRY } from "./registry";

// 에이전트 대상 대화 만들기 · 읽기 (Assistant 계약 v3 3.1, OA D1d-s). 대화 모듈(src/lib/conversation)은 이 파일을 가져오지 않는다 — 주입된 delegate로만 부른다 (I04, OD-27).
// 연결 · 세션은 모두 사용자 id로 좁혀 읽는다. 어떤 검사든 실패하면 어떤 행도 쓰지 않는다 (Action · 세션 · run 0).

type Env = Record<string, string | undefined>;

const COLUMNS = "id, title, context_id, created_at, last_message_at, last_read_at, archived_at, text_purged_at, target_kind, agent_connection_id, agent_session_id";

export type ConversationTargetInfo = { id: string; targetKind: ConversationTargetKind; connectionId: string | null; sessionId: string | null };

/** 내 대화의 대상 · 연결 · 세션 (없거나 남의 대화면 null) */
export async function readConversationTarget(admin: SupabaseClient, userId: string, id: string): Promise<ConversationTargetInfo | null> {
  const { data } = await admin.from("conversations").select("id, target_kind, agent_connection_id, agent_session_id").eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  if (!data) return null;
  const row = data as { id: string; target_kind: ConversationTargetKind; agent_connection_id: string | null; agent_session_id: string | null };
  return { id: row.id, targetKind: row.target_kind, connectionId: row.agent_connection_id, sessionId: row.agent_session_id };
}

async function readWithTarget(admin: SupabaseClient, userId: string, id: string): Promise<ConversationWithTarget | null> {
  const { data } = await admin.from("conversations").select(COLUMNS).eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  return data ? conversationWithTargetSchema.parse(data) : null;
}

export type CreateAgentConversationResult =
  | { status: "created" | "existing"; conversation: ConversationWithTarget }
  | { status: "id_taken" | "context_not_found" | "context_off" | "target_mismatch" | "not_found" };

const lower = (value: string | null | undefined) => value?.toLowerCase() ?? null;

/** 같은 id의 기존 대화가 요청한 대상과 같은가: 대상 종류 · 연결이 같고, 요청 세션이 있으면 기존의 (null 아닌) 세션과 같아야 한다 */
function sameTarget(existing: ConversationWithTarget, connectionId: string, sessionId: string | undefined): boolean {
  if (existing.target_kind !== "agent" || lower(existing.agent_connection_id) !== lower(connectionId)) return false;
  return !(sessionId && existing.agent_session_id && lower(existing.agent_session_id) !== lower(sessionId));
}

/**
 * POST /api/v2/conversations의 target.kind='agent' (계약 2.1 · OD-21). 앱이 정한 id로 멱등이다: 같은 사용자의 같은 id · 같은 대상이면 기존 대화를 그대로 돌려준다.
 * - 연결은 내 것이어야 하고 revoked가 아니며 registry의 adapter여야 하고 adapter gate가 켜져 있어야 한다 (아니면 not_found = 404). 상태 error는 허용한다.
 * - 세션은 내 것 · 같은 연결 · closed 아님. 대화의 세션은 첫 전달 때 묶인다(요청 세션은 만들 때 한 번 묶는다).
 * - 같은 id의 기존 대화가 다른 대상이면 target_mismatch. 범위는 MEMORY_ENABLED일 때만, 내 범위여야 한다 (store.ts createConversation과 같은 규칙).
 */
export async function createAgentConversation(
  admin: SupabaseClient,
  userId: string,
  input: { id?: string; title?: string; contextId: string | null; connectionId: string; sessionId?: string },
  env: Env = process.env,
): Promise<CreateAgentConversationResult> {
  const { data: connectionData } = await admin.from("agent_connections").select("adapter, status").eq("user_id", userId).eq("id", input.connectionId).maybeSingle().throwOnError();
  const connection = connectionData as { adapter: string; status: "active" | "error" | "revoked" } | null;
  if (!connection || connection.status === "revoked" || !Object.hasOwn(AGENT_REGISTRY, connection.adapter) || !adapterEnabled(connection.adapter, env)) return { status: "not_found" };

  if (input.sessionId) {
    const { data } = await admin.from("agent_sessions").select("connection_id, status").eq("user_id", userId).eq("id", input.sessionId).maybeSingle().throwOnError();
    const session = data as { connection_id: string; status: string } | null;
    if (!session || lower(session.connection_id) !== lower(input.connectionId) || session.status === "closed") return { status: "not_found" };
  }

  const id = input.id ?? randomUUID();
  const existing = await readWithTarget(admin, userId, id);
  if (existing) return sameTarget(existing, input.connectionId, input.sessionId) ? { status: "existing", conversation: existing } : { status: "target_mismatch" };

  if (input.contextId) {
    if (!flagEnabled("MEMORY_ENABLED", env)) return { status: "context_off" };
    const { data } = await admin.from("work_contexts").select("id").eq("user_id", userId).eq("id", input.contextId).maybeSingle().throwOnError();
    if (!data) return { status: "context_not_found" };
  }

  const { data } = await admin
    .from("conversations")
    .upsert(
      { id, user_id: userId, title: input.title ?? null, context_id: input.contextId, target_kind: "agent", agent_connection_id: input.connectionId, agent_session_id: input.sessionId ?? null },
      { onConflict: "id", ignoreDuplicates: true },
    )
    .select(COLUMNS)
    .throwOnError();
  const created = ((data ?? []) as unknown[])[0];
  if (created) return { status: "created", conversation: conversationWithTargetSchema.parse(created) };
  // 같은 id가 그 사이 생겼다: 내 것이면 대상을 견주고, 아니면 다른 사용자의 id
  const raced = await readWithTarget(admin, userId, id);
  if (!raced) return { status: "id_taken" };
  return sameTarget(raced, input.connectionId, input.sessionId) ? { status: "existing", conversation: raced } : { status: "target_mismatch" };
}
