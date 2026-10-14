import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AGENT_REGISTRY } from "@/lib/agents/registry";
import { chipsSchema, startPinnedAgentMessage } from "@/lib/agents/next-turn";
import { executionEnabled } from "@/lib/env";
import { BRIDGE_KICK_LIMIT, BRIDGE_REDELIVERY_LIMIT } from "@/lib/execution/limits";
import { bridgeDeliveryAccess, bridgePolicyMode } from "./commands";

/** A failed kick is retried by the next heartbeat; committed bridge work remains successful. */
export async function kickBridgeSessions(admin: SupabaseClient, userId: string, sessionIds: string[]) {
  await kickSessions(admin, userId, sessionIds, false);
}
async function kickSessions(admin: SupabaseClient, userId: string, sessionIds: string[], retryGate: boolean, env: Record<string, string | undefined> = process.env) {
  for (const sessionId of [...new Set(sessionIds)].slice(0, BRIDGE_KICK_LIMIT)) {
    try {
      const { data } = await admin.from("agent_sessions").select("status,connection_id").eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
      if (data?.status !== "bound") continue;
      const { data: head } = await admin.rpc("next_bridge_agent_message", { p_user_id: userId, p_agent_session_id: sessionId, p_retry_gate: retryGate }).throwOnError();
      const messageId = z.guid().nullable().parse(head);
      if (messageId) await startSelectedMessage(admin, userId, messageId, z.guid().parse(data.connection_id), env);
    } catch { /* The durable queue is retried on heartbeat. */ }
  }
}
async function connectionContext(admin: SupabaseClient, userId: string, connectionId: string, env: Record<string, string | undefined>) {
  const { data: connection } = await admin.from("agent_connections").select("adapter,status,bridge_id").eq("user_id", userId).eq("id", connectionId).maybeSingle().throwOnError();
  if (!connection || connection.status !== "active" || !connection.bridge_id) return null;
  const adapter = z.enum(["agent:claude-code", "agent:codex"]).safeParse(connection.adapter);
  if (!adapter.success) return null;
  const { data: bridge } = await admin.from("bridges").select("status,capabilities").eq("user_id", userId).eq("id", connection.bridge_id).maybeSingle().throwOnError();
  if (!bridge || bridge.status !== "active") return null;
  const mode = await bridgePolicyMode(admin, userId);
  if (!bridgeDeliveryAccess(adapter.data, bridge.capabilities, mode, env)) return null;
  return { adapter: adapter.data, mode };
}
async function startUnbound(admin: SupabaseClient, userId: string, connectionId: string, env: Record<string, string | undefined>, onlyConversationId?: string, retryGate = false) {
  const { data } = await admin.rpc("next_unbound_agent_messages", { p_user_id: userId, p_connection_id: connectionId, p_limit: BRIDGE_KICK_LIMIT, p_retry_gate: retryGate }).throwOnError();
  for (const messageId of z.array(z.guid()).parse(data)) {
    await startSelectedMessage(admin, userId, messageId, connectionId, env, onlyConversationId);
  }
}
async function startSelectedMessage(admin: SupabaseClient, userId: string, messageId: string, connectionId: string, env: Record<string, string | undefined>, onlyConversationId?: string) {
  const context = await connectionContext(admin, userId, connectionId, env);
  if (!context) return;
  const { data: message } = await admin.from("conversation_messages").select("delivery_state,delivery_reason,refs,selected,conversation_id").eq("user_id", userId).eq("id", messageId).maybeSingle().throwOnError();
  if (!message || onlyConversationId && message.conversation_id !== onlyConversationId) return;
  const row = z.object({ delivery_state: z.string().nullable(), delivery_reason: z.string().nullable(), refs: z.object({ agent_turn: chipsSchema.optional() }).nullable(), selected: chipsSchema.nullable() }).parse(message);
  const chips = row.refs?.agent_turn ?? row.selected ?? { action_ids: [], context_ids: [] };
  await startPinnedAgentMessage(admin, {
    userId, messageId, state: row.delivery_state, reason: row.delivery_reason, chips,
    target: { capability: AGENT_REGISTRY[context.adapter], mode: context.mode, connectionStatus: "active" },
  }, env);
}
export async function kickBridgeConnections(admin: SupabaseClient, userId: string, connectionIds: string[], env: Record<string, string | undefined> = process.env, alreadyKicked: string[] = []) {
  for (const connectionId of [...new Set(connectionIds)].slice(0, BRIDGE_KICK_LIMIT)) {
    try {
      if (!await connectionContext(admin, userId, connectionId, env)) continue;
      const { data } = await admin.from("agent_sessions").select("id").eq("user_id", userId).eq("connection_id", connectionId).eq("status", "bound").limit(BRIDGE_KICK_LIMIT).throwOnError();
      await kickSessions(admin, userId, z.array(z.object({ id: z.guid() })).parse(data).map((session) => session.id).filter((sessionId) => !alreadyKicked.includes(sessionId)), false, env);
      await startUnbound(admin, userId, connectionId, env);
    } catch { /* A subsequent heartbeat retries this connection. */ }
  }
}
async function databaseGatesOpen(admin: SupabaseClient, userId: string, adapter: string, mode: string) {
  const { data: actor } = await admin.from("execution_actors").select("user_id").eq("user_id", userId).maybeSingle().throwOnError();
  if (!actor) return false;
  for (const [scope, key] of [["global", "*"], ["provider", adapter], ["mode", mode]]) {
    const { data } = await admin.from("execution_controls").select("blocked").eq("scope", scope).eq("key", key).maybeSingle().throwOnError();
    if (!data || data.blocked !== false) return false;
  }
  const { data: tool } = await admin.from("execution_tools").select("provider").eq("provider", adapter).eq("tool", "message").eq("effect_class", "external").maybeSingle().throwOnError();
  return !!tool;
}
export async function redeliverBridgeMessages(admin: SupabaseClient, env: Record<string, string | undefined> = process.env) {
  if (!executionEnabled(env)) return 0;
  const { data } = await admin.rpc("bridge_redelivery_candidates", { p_limit: BRIDGE_REDELIVERY_LIMIT }).throwOnError();
  const candidates = z.array(z.object({ user_id: z.guid(), agent_session_id: z.guid().nullable(), conversation_id: z.guid() })).parse(data);
  let attempted = 0;
  for (const candidate of candidates) {
    try {
      const { data: conversation } = await admin.from("conversations").select("agent_connection_id").eq("user_id", candidate.user_id).eq("id", candidate.conversation_id).maybeSingle().throwOnError();
      if (!conversation) continue;
      const context = await connectionContext(admin, candidate.user_id, conversation.agent_connection_id, env);
      if (!context || !await databaseGatesOpen(admin, candidate.user_id, context.adapter, context.mode)) continue;
      if (candidate.agent_session_id) await kickSessions(admin, candidate.user_id, [candidate.agent_session_id], true, env);
      else await startUnbound(admin, candidate.user_id, conversation.agent_connection_id, env, candidate.conversation_id, true);
      attempted++;
    } catch { /* Retry only this durable candidate on the next sweep. */ }
  }
  return attempted;
}
