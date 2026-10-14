import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { agentSessionSchema, type AgentSession } from "@/lib/api/contract";

import { adapterEnabled, AGENT_REGISTRY } from "./registry";
import { startNextAgentMessage } from "./next-turn";
import { retryOnConflict } from "./retry";

// 에이전트 세션 (Assistant 계약 v3 3.8, OA D1d-s): 이름 바꾸기 · Open in Terminal · Resume here. 세션은 모두 사용자 id로 좁혀 읽는다.
// 규칙은 SQL(rename_agent_session · open_agent_session_external · resume_agent_session_here)에 있고 여기는 부르기만 한다. 이름 · 글은 로그에 남기지 않는다.

type Env = Record<string, string | undefined>;
const COLUMNS = "id, connection_id, display_name, status, last_turn_seq, updated_at";

/** 응답용 세션 한 줄 (내 것만) */
export async function loadAgentSession(admin: SupabaseClient, userId: string, id: string): Promise<AgentSession | null> {
  const { data } = await admin.from("agent_sessions").select(COLUMNS).eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  if (!data) return null;
  const row = data as Record<string, unknown>;
  return agentSessionSchema.parse({ ...row, updated_at: new Date(String(row.updated_at)).toISOString() });
}

/** 세션 → 연결 → adapter와 그 adapter gate (OD-2). 세션이 없거나 연결이 없거나 registry 밖 adapter면 null (route는 404) */
export async function loadSessionAdapter(admin: SupabaseClient, userId: string, sessionId: string, env: Env = process.env): Promise<{ adapter: string; enabled: boolean } | null> {
  const { data: sessionData } = await admin.from("agent_sessions").select("connection_id").eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
  if (!sessionData) return null;
  const { data: connectionData } = await admin
    .from("agent_connections")
    .select("adapter")
    .eq("user_id", userId)
    .eq("id", (sessionData as { connection_id: string }).connection_id)
    .maybeSingle()
    .throwOnError();
  const adapter = (connectionData as { adapter: string } | null)?.adapter;
  if (!adapter || !Object.hasOwn(AGENT_REGISTRY, adapter)) return null;
  return { adapter, enabled: adapterEnabled(adapter, env) };
}

export type RenameAgentSessionResult = { status: "renamed" | "unchanged"; session: AgentSession } | { status: "not_found" };

const renameSchema = z.object({ status: z.enum(["renamed", "unchanged", "not_found"]) });

/**
 * PATCH /api/v2/agent-sessions/{id}: 이름을 바꾼다. SQL(rename_agent_session)이 이름 변경과 지표 session_renamed(adapter뿐, 이름 글 0)를 같은 트랜잭션에서 쓴다 (검토 반영 7-5).
 * 같은 이름이면 쓰지 않는다(unchanged, 지표 0). 없거나 남의 세션은 not_found — 대상은 사용자 id로 좁힌다
 */
export async function renameAgentSession(admin: SupabaseClient, userId: string, id: string, displayName: string): Promise<RenameAgentSessionResult> {
  const { data } = await retryOnConflict(async () => await admin.rpc("rename_agent_session", { p_user_id: userId, p_session_id: id, p_display_name: displayName }).throwOnError());
  const { status } = renameSchema.parse(data);
  if (status === "not_found") return { status };
  const session = await loadAgentSession(admin, userId, id);
  return session ? { status, session } : { status: "not_found" };
}

const externalSchema = z.object({ status: z.enum(["external", "unchanged", "busy", "not_started", "not_bound", "not_found"]) });
export type OpenAgentSessionExternalResult = { status: "external" | "unchanged"; session: AgentSession } | { status: "busy" | "not_started" | "not_bound" | "not_found" };

/** POST …/open-external: bound 세션을 external로 (SQL이 진행 중 턴 · pending 세션 · 상태를 본다). 바뀐 세션을 다시 읽어 돌려준다 */
export async function openAgentSessionExternal(admin: SupabaseClient, userId: string, id: string): Promise<OpenAgentSessionExternalResult> {
  const { data } = await retryOnConflict(async () => await admin.rpc("open_agent_session_external", { p_user_id: userId, p_session_id: id }).throwOnError());
  const { status } = externalSchema.parse(data);
  if (status !== "external" && status !== "unchanged") return { status };
  const session = await loadAgentSession(admin, userId, id);
  return session ? { status, session } : { status: "not_found" };
}

const resumeSchema = z.object({ status: z.enum(["bound", "unchanged", "not_external", "not_found"]) });
export type ResumeAgentSessionResult = { status: "bound" | "unchanged"; session: AgentSession; startedMessageId: string | null } | { status: "not_external" | "not_found"; startedMessageId: null };

/**
 * POST …/resume-here: external을 bound로 되돌리고, commit 뒤(잠금 없이) 대기 메시지를 보낸 순서대로 첫째부터 시작해 본다 (자동 전달 계기 ④, 계약 3.2).
 * 이미 bound여도 한 번 확인한다: 앞선 시작이 실패했을 때 다시 눌러 이어 갈 수 있다. 시작이 실패해도 상태 전이는 끝났으니 bound로 답한다(다음 계기가 이어 간다).
 * 시작된 메시지 id는 그 작업의 message_id다
 */
export async function resumeAgentSessionHere(admin: SupabaseClient, userId: string, id: string, env: Env = process.env): Promise<ResumeAgentSessionResult> {
  const { data } = await retryOnConflict(async () => await admin.rpc("resume_agent_session_here", { p_user_id: userId, p_session_id: id }).throwOnError());
  const { status } = resumeSchema.parse(data);
  if (status === "not_external" || status === "not_found") return { status, startedMessageId: null };
  let startedMessageId: string | null = null;
  try {
    const next = await startNextAgentMessage(admin, { userId, sessionId: id }, env);
    if (next?.status === "started") {
      const { data: task } = await admin.from("agent_tasks").select("message_id").eq("user_id", userId).eq("id", next.agent_task_id).maybeSingle().throwOnError();
      startedMessageId = (task as { message_id: string | null } | null)?.message_id ?? null;
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "agent_start_next_failed", error: error instanceof Error ? error.name : "unknown" }));
  }
  const session = await loadAgentSession(admin, userId, id);
  return session ? { status, session, startedMessageId } : { status: "not_found", startedMessageId: null };
}
