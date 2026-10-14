import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { bridgeV1EventSchema, bridgeV1EventsResponseSchema } from "@/lib/api/contract";
import { applyAgentEvent } from "@/lib/agents/events";
import { kickBridgeSessions } from "./triggers";

export async function appendBridgeSessionEvent(admin: SupabaseClient, input: { userId: string; sessionId: string; taskId: string; turnSeq: number; eventId: string; text: string; originatingOnly?: boolean }) {
  let query = admin.from("conversations").select("id").eq("user_id", input.userId).eq("target_kind", "agent").eq("agent_session_id", input.sessionId);
  if (input.originatingOnly) {
    const { data: task } = await admin.from("agent_tasks").select("message_id").eq("user_id", input.userId).eq("id", input.taskId).maybeSingle().throwOnError();
    if (!task?.message_id) return;
    const { data: message } = await admin.from("conversation_messages").select("conversation_id").eq("user_id", input.userId).eq("id", task.message_id).maybeSingle().throwOnError();
    if (!message) return;
    query = query.eq("id", message.conversation_id);
  }
  const { data } = await query.throwOnError();
  for (const conversation of z.array(z.object({ id: z.guid() })).parse(data)) {
    const { data: appended } = await admin.rpc("conversation_append_agent_message", { p_user_id: input.userId, p_conversation_id: conversation.id, p_agent_task_id: input.taskId,
      p_turn_seq: input.turnSeq, p_event_id: "bridge-event:" + createHash("sha256").update(JSON.stringify([input.eventId, conversation.id])).digest("hex"), p_text: input.text, p_kind: "event",
    }).throwOnError();
    z.array(z.object({ status: z.enum(["created", "duplicate"]), message_id: z.guid(), seq: z.number().int().positive() })).length(1).parse(appended);
  }
}
/** Retry committed lifecycle fanout; a partial append leaves the durable descriptor pending. */
export async function drainBridgeSessionEvents(admin: SupabaseClient, scope: { userId?: string; bridgeId?: string } = {}, limit = 50) {
  if (!scope.userId || !scope.bridgeId) {
    const { data } = await admin.from("execution_events").select("user_id,bridge_id")
      .eq("type", "agent").eq("payload->>fanout_pending", "true")
      .in("payload->>event_type", ["bridge_restored", "bridge_unreachable"])
      .order("at", { ascending: true }).order("id", { ascending: true }).limit(50).throwOnError();
    const owners = z.array(z.object({ user_id: z.guid(), bridge_id: z.guid() })).parse(data);
    const scopes = [...new Map(owners.map((owner) => [JSON.stringify(owner), owner])).values()];
    let errors = 0;
    for (const owner of scopes) errors += await drainBridgeSessionEvents(admin, { userId: owner.user_id, bridgeId: owner.bridge_id }, Math.floor(50 / scopes.length));
    return errors;
  }
  let query = admin.from("execution_events").select("id,user_id,bridge_id,external_event_id,payload")
    .eq("type", "agent").eq("payload->>fanout_pending", "true")
    .in("payload->>event_type", ["bridge_restored", "bridge_unreachable"]);
  if (scope.userId) query = query.eq("user_id", scope.userId);
  if (scope.bridgeId) query = query.eq("bridge_id", scope.bridgeId);
  const { data } = await query.order("at", { ascending: true }).order("id", { ascending: true }).limit(limit).throwOnError();
  const rows = z.array(z.object({ id: z.guid(), user_id: z.guid(), bridge_id: z.guid(), external_event_id: z.string(),
    payload: z.object({ event_type: z.enum(["bridge_restored", "bridge_unreachable"]), agent_session_id: z.guid(), agent_task_id: z.guid(), turn_seq: z.number().int().positive(), fanout_pending: z.literal(true) }),
  })).parse(data);
  let errors = 0;
  for (const row of rows) {
    try {
      await appendBridgeSessionEvent(admin, { userId: row.user_id, sessionId: row.payload.agent_session_id, taskId: row.payload.agent_task_id,
        turnSeq: row.payload.turn_seq, eventId: row.external_event_id,
        text: row.payload.event_type === "bridge_restored" ? "Connection restored" : "Connection lost · progress unknown" });
      await admin.from("execution_events").update({ payload: { ...row.payload, fanout_pending: false } })
        .eq("user_id", row.user_id).eq("bridge_id", row.bridge_id).eq("id", row.id).throwOnError();
    } catch { errors++; }
  }
  return errors;
}
export async function applyBridgeEvents(admin: SupabaseClient, input: { userId: string; bridgeId: string; events: unknown[] }) {
  const result: z.infer<typeof bridgeV1EventsResponseSchema> = { results: [], accepted_event_ids: [], retry_event_ids: [], rejected: [] };
  const blocked = new Set<string>();
  const finished = new Set<string>();
  for (const raw of input.events) {
    const parsed = bridgeV1EventSchema.safeParse(raw);
    if (!parsed.success) {
      const identity = z.object({ event_id: z.string() }).safeParse(raw);
      result.rejected.push({ event_id: identity.success ? identity.data.event_id : "", code: "invalid" });
      continue;
    }
    const event = parsed.data;
    const sessionId = event.session_ref.agent_session_id;
    if (blocked.has(sessionId)) { result.retry_event_ids.push(event.event_id); continue; }
    try {
      const applied = await applyAgentEvent(admin, { userId: input.userId, bridgeId: input.bridgeId, event });
      result.results.push({ event_id: event.event_id, status: applied.status, ...(applied.task_state ? { task_state: applied.task_state } : {}) });
      result.accepted_event_ids.push(event.event_id);
      if (applied.task_state && ["idle", "failed", "cancelled", "completed"].includes(applied.task_state)) finished.add(sessionId);
    } catch (error) {
      if (typeof error === "object" && error !== null && "code" in error && error.code === "22023") result.rejected.push({ event_id: event.event_id, code: "invalid" });
      else { result.retry_event_ids.push(event.event_id); blocked.add(sessionId); }
    }
  }
  await kickBridgeSessions(admin, input.userId, [...finished]);
  return bridgeV1EventsResponseSchema.parse(result);
}
