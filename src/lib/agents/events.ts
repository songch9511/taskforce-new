import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { agentAdapterIdSchema, agentTaskStateSchema } from "@/lib/api/contract";

const boundedText = (max: number) => z.string().refine((value) => Array.from(value).length <= max);
const identity = boundedText(200).refine((value) => value.length > 0);
const questionSchema = z.strictObject({
  provider_request_id: identity, kind: z.enum(["input", "approval"]), structured: z.boolean(),
  questions: z.array(z.strictObject({
    id: boundedText(200), header: boundedText(200), text: boundedText(4000),
    options: z.array(z.strictObject({ label: boundedText(500), description: boundedText(1000) })).max(10),
    multi_select: z.boolean(), allow_other: z.boolean(), secret: z.boolean(),
  })).min(1).max(4).refine((questions) => new Set(questions.map((question) => question.id)).size === questions.length),
});
const emptyPayload = z.strictObject({}).optional();
const envelope = {
  adapter: agentAdapterIdSchema,
  session_ref: z.strictObject({ agent_session_id: z.guid() }),
  agent_task_id: z.guid().optional(), external_task_id: identity.optional(),
  event_id: identity, seq: z.number().int().positive().optional(),
  turn_seq: z.number().int().positive().optional(), observed_at: z.iso.datetime({ offset: true }),
  text: z.string().optional(),
};
const sessionTypes = ["session_bound", "unreachable", "reconcile"];

// Match JSONB's spaces at structural separators, including nested question metadata.
function jsonbText(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(jsonbText).join(", ") + "]";
  if (value !== null && typeof value === "object") {
    return "{" + Object.entries(value).map(([key, item]) => `${JSON.stringify(key)}: ${jsonbText(item)}`).join(", ") + "}";
  }
  return JSON.stringify(value);
}

/** Internal server envelope; the existing bridge DTO is a separate contract. */
export const agentEventSchema = z.discriminatedUnion("type", [
  z.strictObject({ ...envelope, type: z.enum(["accepted", "progress", "turn_completed", "cancelled", "unreachable"]), payload: emptyPayload }),
  z.strictObject({ ...envelope, type: z.literal("message"), text: z.string(), payload: emptyPayload }),
  z.strictObject({ ...envelope, type: z.literal("question"), text: z.string(), question: questionSchema, payload: emptyPayload }),
  z.strictObject({ ...envelope, type: z.literal("artifact"), payload: z.strictObject({ path: boundedText(1000).refine((value) => value.length > 0), hash: identity, summary: boundedText(2000) }) }),
  z.strictObject({ ...envelope, type: z.literal("failed"), payload: z.strictObject({ reason: z.enum(["sign_in_needed", "usage_limited", "spawn_failed", "version_unsupported", "agent_error"]).optional() }).optional() }),
  z.strictObject({ ...envelope, type: z.literal("session_bound"), payload: z.strictObject({ external_session_id: identity.refine((id) => !id.startsWith("pending:")), workspace_ref: boundedText(500).refine((value) => value.length > 0).optional() }) }),
  z.strictObject({ ...envelope, type: z.literal("reconcile"), payload: z.strictObject({ state: z.enum(["dispatched", "accepted", "running", "awaiting_answer", "idle", "failed", "cancelled"]).optional() }).optional() }),
]).superRefine((event, ctx) => {
  if (!sessionTypes.includes(event.type) && !event.agent_task_id && !event.external_task_id) {
    ctx.addIssue({ code: "custom", message: "Task identity is required", path: ["agent_task_id"] });
  }
  if (event.text !== undefined && event.type !== "message" && event.type !== "question") {
    ctx.addIssue({ code: "custom", message: "Text belongs only to messages and questions", path: ["text"] });
  }
  if (event.type === "question") {
    const pending = { ...event.question,
      question_key: [event.agent_task_id ?? "00000000-0000-0000-0000-000000000000", event.question.provider_request_id],
      asked_at: event.observed_at,
    };
    if (Buffer.byteLength(jsonbText(pending), "utf8") > 32768) {
      ctx.addIssue({ code: "custom", message: "Pending question exceeds 32768 UTF-8 bytes", path: ["question"] });
    }
  }
  const payloadText = jsonbText(event.payload ?? {});
  if (Buffer.byteLength(payloadText, "utf8") > 4096) {
    ctx.addIssue({ code: "custom", message: "Payload exceeds 4096 UTF-8 bytes", path: ["payload"] });
  }
});
export type AgentEvent = z.infer<typeof agentEventSchema>;

export const applyAgentEventResultSchema = z.discriminatedUnion("applied", [
  z.object({ status: z.literal("applied"), applied: z.literal(true), task_state: agentTaskStateSchema.optional() }),
  z.object({ status: z.enum(["duplicate", "late", "step_not_calling", "conflict", "question_conflict", "reconcile_conflict", "not_found", "invalid_state", "ignored"]), applied: z.literal(false), task_state: agentTaskStateSchema.optional() }),
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
  userId: string; event: unknown;
}): Promise<ApplyAgentEventResult> {
  const event = agentEventSchema.parse(input.event);
  const { data } = await admin.rpc("apply_agent_event", { p_user_id: input.userId, p_event: event }).throwOnError();
  const result = applyAgentEventResultSchema.parse(data);
  if ((result.status !== "applied" && result.status !== "duplicate") || !(event.type in eventCopy)) return result;

  let taskId = event.agent_task_id;
  if (!taskId && !event.external_task_id) {
    // Recover the original task even if a later turn has started since a partial fanout.
    let originalQuery = admin.from("execution_events")
      .select("payload,turn_seq,execution_runs!inner(agent_session_id)")
      .eq("user_id", input.userId).eq("type", "agent").eq("external_event_id", event.event_id)
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
    .eq("user_id", input.userId).eq("type", "agent").eq("run_id", task.run_id)
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
