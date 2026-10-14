import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { bridgeV1EventSchema, agentTaskStateSchema } from "@/lib/api/contract";

export const agentEventSchema = bridgeV1EventSchema;
export type AgentEvent = z.infer<typeof agentEventSchema>;

export const applyAgentEventResultSchema = z.discriminatedUnion("applied", [
  z.object({ status: z.literal("applied"), applied: z.literal(true), task_state: agentTaskStateSchema.optional() }),
  z.object({ status: z.enum(["duplicate", "late", "step_not_calling", "conflict", "question_conflict", "reconcile_conflict", "not_found", "invalid_state", "ignored", "wrong_bridge"]), applied: z.literal(false), task_state: agentTaskStateSchema.optional() }),
]);
export type ApplyAgentEventResult = z.infer<typeof applyAgentEventResultSchema>;
const taskSchema = z.object({ id: z.guid(), run_id: z.guid(), turn_seq: z.number().int().positive().nullable() });
const storedEventSchema = z.object({
  payload: z.object({ event_type: z.string(), status: z.string(), agent_task_id: z.guid() }),
  turn_seq: z.number().int().positive().nullable(),
});
const eventCopy = { unreachable: "Connection lost · progress unknown", reconcile: "Connection restored", cancelled: "Agent stopped" } as const;
const appendResultSchema = z.array(z.object({ status: z.enum(["created", "duplicate"]), message_id: z.guid(), seq: z.number().int().positive() })).length(1);

/** SQL owns application; idempotent append retries repair a partially completed session fanout. */
export async function applyAgentEvent(admin: SupabaseClient, input: {
  userId: string; event: unknown; bridgeId: string;
}): Promise<ApplyAgentEventResult> {
  const event = agentEventSchema.parse(input.event);
  const { data } = await admin.rpc("apply_bridge_event", { p_user_id: input.userId, p_event: event, p_bridge_id: input.bridgeId }).throwOnError();
  const result = applyAgentEventResultSchema.parse(data);
  if ((result.status !== "applied" && result.status !== "duplicate") || !(event.type in eventCopy)) return result;

  let taskId = event.agent_task_id;
  if (!taskId && !event.external_task_id) {
    // Recover the original task even if a later turn has started since a partial fanout.
    let originalQuery = admin.from("execution_events")
      .select("payload,turn_seq,execution_runs!inner(agent_session_id)")
      .eq("user_id", input.userId).eq("bridge_id", input.bridgeId).eq("type", "agent").eq("external_event_id", event.event_id)
      .eq("execution_runs.agent_session_id", event.session_ref.agent_session_id)
      .eq("payload->>event_type", event.type);
    if (event.turn_seq !== undefined) originalQuery = originalQuery.eq("turn_seq", event.turn_seq);
    const { data: original } = await originalQuery.order("at", { ascending: true }).order("id", { ascending: true }).limit(1).maybeSingle().throwOnError();
    if (!original) return result;
    taskId = storedEventSchema.parse(original).payload.agent_task_id;
  }
  let taskQuery = admin.from("agent_tasks").select("id,run_id,turn_seq")
    .eq("user_id", input.userId).eq("agent_session_id", event.session_ref.agent_session_id);
  if (taskId) taskQuery = taskQuery.eq("id", taskId);
  if (event.external_task_id) taskQuery = taskQuery.eq("external_task_id", event.external_task_id);
  const { data: taskData } = await taskQuery.maybeSingle().throwOnError();
  if (!taskData) return result;
  const task = taskSchema.parse(taskData);
  const { data: storedData } = await admin.from("execution_events").select("payload,turn_seq")
    .eq("user_id", input.userId).eq("bridge_id", input.bridgeId).eq("type", "agent").eq("run_id", task.run_id)
    .eq("external_event_id", event.event_id).maybeSingle().throwOnError();
  if (!storedData) return result;
  const stored = storedEventSchema.parse(storedData);
  if (stored.payload.status !== "applied" || stored.payload.event_type !== event.type || stored.payload.agent_task_id !== task.id
    || stored.turn_seq !== task.turn_seq || (event.turn_seq !== undefined && event.turn_seq !== stored.turn_seq)) return result;

  const { data: conversations } = await admin.from("conversations").select("id")
    .eq("user_id", input.userId).eq("target_kind", "agent").eq("agent_session_id", event.session_ref.agent_session_id).throwOnError();
  for (const conversation of z.array(z.object({ id: z.guid() })).parse(conversations)) {
    const eventId = "agent-event:" + createHash("sha256").update(JSON.stringify([task.run_id, event.event_id, conversation.id])).digest("hex");
    const { data: appended } = await admin.rpc("conversation_append_agent_message", {
      p_user_id: input.userId, p_conversation_id: conversation.id, p_agent_task_id: task.id,
      p_turn_seq: stored.turn_seq, p_event_id: eventId,
      p_text: eventCopy[event.type as keyof typeof eventCopy], p_kind: "event",
    }).throwOnError();
    appendResultSchema.parse(appended);
  }
  return result;
}
