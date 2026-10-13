import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import type { AgentCapability } from "@/lib/api/contract";
import { MAX_LIVE_EXTERNAL_TASKS } from "@/lib/execution/limits";
import { agentAccess, directChat, type AgentPolicyMode } from "./capability";
import { adapterEnabled, AGENT_REGISTRY } from "./registry";

const notSentReason = z.enum(["write_gate_closed", "not_connected", "sign_in_needed", "unsupported", "session_closed", "invalid_referent", "not_found", "already_dispatched"]);
export const startAgentTurnResultSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("started"),
    // Deterministic message-derived Action ids are UUID-shaped, with no random UUID version requirement.
    action_id: z.guid(), run_id: z.guid(), agent_task_id: z.guid(), step_id: z.guid(),
    turn_seq: z.number().int().positive(), created_action: z.boolean(),
  }),
  z.object({ status: z.literal("queued"), reason: z.enum(["session_busy", "session_external", "live_limit", "queue_order", "question_open"]) }),
  z.object({ status: z.literal("not_sent"), reason: notSentReason }),
  z.object({ status: z.enum(["not_found", "wrong_target", "already_dispatched", "expired"]) }),
  z.strictObject({ status: z.enum(["answered", "duplicate"]), step_id: z.guid() }),
  z.strictObject({ status: z.enum(["question_stale", "invalid_answer", "secret_requires_local"]) }),
  z.object({ status: z.literal("needs_referent"), candidates: z.array(z.guid()).max(3) }),
]);
export type StartAgentTurnResult = z.infer<typeof startAgentTurnResultSchema>;

/** Server-resolved capability and policy only; bridge reports cannot establish verified boundaries. */
export async function startAgentTurn(admin: SupabaseClient, input: {
  userId: string;
  messageId: string;
  capability: AgentCapability;
  mode: AgentPolicyMode;
  connectionStatus: "active" | "not_connected" | "sign_in_needed" | "unsupported";
  actionIds?: string[];
  contextIds?: string[];
}, env: Record<string, string | undefined> = process.env): Promise<StartAgentTurnResult> {
  const access = agentAccess(input.capability, input.mode);
  const reason = input.connectionStatus !== "active" ? input.connectionStatus
    : access === null ? "write_gate_closed"
    : !adapterEnabled(input.capability.adapter, env) || directChat(input.capability, input.mode) !== "supported" ? "unsupported" : null;
  if (reason) {
    const { data } = await admin.rpc("mark_agent_message_not_sent", {
      p_user_id: input.userId, p_message_id: input.messageId, p_reason: reason,
    }).throwOnError();
    return startAgentTurnResultSchema.parse(data);
  }

  const { data } = await admin.rpc("route_agent_message", {
    p_user_id: input.userId, p_message_id: input.messageId,
    p_action_ids: input.actionIds ?? [], p_context_ids: input.contextIds ?? [], p_access: access,
    p_live_limit: MAX_LIVE_EXTERNAL_TASKS,
  }).throwOnError();
  return startAgentTurnResultSchema.parse(data);
}

const queuedChipsSchema = z.object({
  action_ids: z.array(z.guid()).default([]),
  context_ids: z.array(z.guid()).default([]),
});

/** Call without holding session/task locks; SQL alone owns admission and turn creation. */
export async function startNextQueuedTurn(admin: SupabaseClient, input: {
  userId: string;
  sessionId: string;
}, env: Record<string, string | undefined> = process.env): Promise<StartAgentTurnResult | null> {
  const { data: next } = await admin.rpc("next_queued_agent_message", {
    p_user_id: input.userId, p_session_id: input.sessionId,
  }).throwOnError();
  const messageId = z.guid().nullable().parse(next);
  if (messageId === null) return null;

  const { data: sessionData } = await admin.from("agent_sessions").select("connection_id")
    .eq("user_id", input.userId).eq("id", input.sessionId).maybeSingle().throwOnError();
  if (!sessionData) return { status: "not_found" };
  const session = z.object({ connection_id: z.guid() }).parse(sessionData);
  const { data: connectionData } = await admin.from("agent_connections").select("adapter,status")
    .eq("user_id", input.userId).eq("id", session.connection_id).maybeSingle().throwOnError();
  if (!connectionData) return { status: "not_found" };
  const connection = z.object({ adapter: z.string(), status: z.enum(["active", "error", "revoked"]) }).parse(connectionData);
  const adapter = z.enum(["agent:claude-code", "agent:codex"]).safeParse(connection.adapter);
  if (!adapter.success) {
    const { data } = await admin.rpc("mark_agent_message_not_sent", {
      p_user_id: input.userId, p_message_id: messageId, p_reason: "unsupported",
    }).throwOnError();
    return startAgentTurnResultSchema.parse(data);
  }
  const { data: policyData } = await admin.from("execution_policies").select("mode")
    .eq("user_id", input.userId).maybeSingle().throwOnError();
  const mode = policyData === null ? "manual" : z.object({ mode: z.enum(["manual", "auto", "full"]) }).parse(policyData).mode;
  const { data: messageData } = await admin.from("conversation_messages").select("refs,selected")
    .eq("user_id", input.userId).eq("id", messageId).maybeSingle().throwOnError();
  if (!messageData) return { status: "not_found" };
  const message = z.object({
    refs: z.object({ agent_turn: queuedChipsSchema.optional() }),
    selected: queuedChipsSchema.nullable(),
  }).parse(messageData);
  const chips = message.refs.agent_turn ?? message.selected ?? { action_ids: [], context_ids: [] };
  const result = await startAgentTurn(admin, {
    userId: input.userId, messageId, capability: AGENT_REGISTRY[adapter.data], mode,
    connectionStatus: connection.status === "active" ? "active" : "not_connected",
    actionIds: chips.action_ids, contextIds: chips.context_ids,
  }, env);
  if (result.status === "not_found" || result.status === "already_dispatched") {
    const { data } = await admin.rpc("mark_agent_message_not_sent", {
      p_user_id: input.userId, p_message_id: messageId, p_reason: result.status,
    }).throwOnError();
    return startAgentTurnResultSchema.parse(data);
  }
  return result;
}
