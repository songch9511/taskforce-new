import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { bridgeV1AckRequestSchema, bridgeV1AckResponseSchema, bridgeV1AdapterReportSchema, bridgeV1CommandsResponseSchema, type BridgeV1AckRequest } from "@/lib/api/contract";
import { agentAccess, type AgentPolicyMode } from "@/lib/agents/capability";
import { adapterEnabled, AGENT_REGISTRY } from "@/lib/agents/registry";
import { executionEnabled } from "@/lib/env";
import { BRIDGE_LONG_POLL_MAX_SECONDS, BRIDGE_LONG_POLL_RECHECK_MS } from "@/lib/execution/limits";
import type { BridgeRecord } from "./auth";
import { kickBridgeSessions } from "./triggers";
import { appendBridgeSessionEvent } from "./events";

export function bridgeDeliveryAccess(adapter: string, capabilities: unknown, mode: AgentPolicyMode, env: Record<string, string | undefined> = process.env) {
  const known = z.enum(["agent:claude-code", "agent:codex"]).safeParse(adapter);
  if (!executionEnabled(env) || !known.success || !adapterEnabled(adapter, env)) return null;
  const reports = z.object({ adapters: z.record(z.string(), z.unknown()) }).safeParse(capabilities);
  const report = bridgeV1AdapterReportSchema.safeParse({ adapter, ...(reports.success ? reports.data.adapters[adapter] as object : {}) });
  if (!report.success || !report.data.installed || report.data.signed_in !== "yes" || report.data.managed_settings || !report.data.version) return null;
  const capability = AGENT_REGISTRY[known.data];
  // The registry uses bounded >=x.y.z <x.y intervals; unrecognized ranges fail closed.
  const range = capability.version_range?.match(/^>=(\d+)\.(\d+)\.(\d+) <(\d+)\.(\d+)(?:\.(\d+))?$/);
  const version = report.data.version.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!range || !version) return null;
  const actual = version.slice(1).map(Number);
  const lower = range.slice(1, 4).map(Number);
  const upper = range.slice(4, 7).map((part) => Number(part ?? 0));
  const compare = (a: number[], b: number[]) => a.map((value, index) => value - b[index]).find((difference) => difference !== 0) ?? 0;
  if (!actual.every(Number.isSafeInteger) || compare(actual, lower) < 0 || compare(actual, upper) >= 0) return null;
  return agentAccess(capability, mode);
}
export async function bridgePolicyMode(admin: SupabaseClient, userId: string): Promise<AgentPolicyMode> {
  const { data } = await admin.from("execution_policies").select("mode").eq("user_id", userId).maybeSingle().throwOnError();
  return data ? z.object({ mode: z.enum(["manual", "auto", "full"]) }).parse(data).mode : "manual";
}
function pause(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    if (signal.aborted) return resolve();
    const finish = () => { clearTimeout(timer); signal.removeEventListener("abort", finish); resolve(); };
    const timer = setTimeout(finish, milliseconds);
    signal.addEventListener("abort", finish, { once: true });
  });
}
export async function pollBridgeCommands(admin: SupabaseClient, input: { userId: string; bridgeId: string; after: number; wait: number; signal: AbortSignal }) {
  const deadline = Date.now() + Math.min(BRIDGE_LONG_POLL_MAX_SECONDS, Math.max(0, input.wait)) * 1000;
  let result;
  do {
    const { data } = await admin.rpc("list_bridge_commands", { p_user_id: input.userId, p_bridge_id: input.bridgeId, p_after: input.after, p_limit: 50 }).throwOnError();
    result = bridgeV1CommandsResponseSchema.parse({ ...data, server_time: new Date().toISOString() });
    if (result.commands.some((command) => command.cursor > input.after) || result.readbacks.length || input.signal.aborted || Date.now() >= deadline) return result;
    await pause(Math.min(BRIDGE_LONG_POLL_RECHECK_MS, deadline - Date.now()), input.signal);
  } while (!input.signal.aborted);
  return result;
}
export async function ackBridgeCommand(admin: SupabaseClient, input: { userId: string; bridge: BridgeRecord; input: BridgeV1AckRequest }, env: Record<string, string | undefined> = process.env) {
  const body = bridgeV1AckRequestSchema.parse(input.input);
  const { data: command } = await admin.from("bridge_commands").select("step_id,agent_task_id,kind")
    .eq("user_id", input.userId).eq("bridge_id", input.bridge.id).eq("id", body.command_id).maybeSingle().throwOnError();
  if (!command) return { status: "not_found" as const };
  let data: unknown;
  let disabled = false;
  if (body.op === "lease") {
    const { data: step } = await admin.from("execution_steps").select("provider").eq("user_id", input.userId).eq("id", command.step_id).maybeSingle().throwOnError();
    if (!step) return { status: "not_found" as const };
    const mode = await bridgePolicyMode(admin, input.userId);
    disabled = command.kind !== "cancel" && !adapterEnabled(step.provider, env);
    ({ data } = await admin.rpc("lease_bridge_command", { p_user_id: input.userId, p_bridge_id: input.bridge.id, p_command_id: body.command_id,
      p_access: bridgeDeliveryAccess(step.provider, input.bridge.capabilities, mode, env), p_mode: mode,
    }).throwOnError());
  } else {
    ({ data } = await admin.rpc("settle_bridge_command", { p_user_id: input.userId, p_bridge_id: input.bridge.id, p_command_id: body.command_id,
      p_op: body.op, p_result: "result" in body ? body.result : "reason" in body ? body.reason : null,
      p_process_ended: body.op === "readback" ? body.process_ended : false,
    }).throwOnError());
  }
  if (data !== null && typeof data === "object" && "status" in data && data.status === "not_found") return { status: "not_found" as const };
  const result = bridgeV1AckResponseSchema.parse(data);
  if ((result.status === "leased" || result.status === "replay") && result.command.kind === "cancel") {
    result.command.cancel_scope = AGENT_REGISTRY[z.enum(["agent:claude-code", "agent:codex"]).parse(result.command.adapter)].cancel_scope === "turn_and_processes" ? "turn_and_processes" : "turn";
  }
  if (result.status === "withdrawn" && result.reason === "write_gate_closed" && disabled) result.reason = "adapter_disabled";
  const shouldKick = (result.status === "withdrawn" && !["write_gate_closed", "not_connected", "adapter_disabled"].includes(result.reason)) || (result.status === "settled" && (body.op === "readback" && body.result === "not_received" || body.op === "complete" && body.result === "task_unknown"));
  if (shouldKick || result.status === "settled" && body.op === "request_closed") {
    const { data: task } = await admin.from("agent_tasks").select("agent_session_id,turn_seq").eq("user_id", input.userId).eq("id", command.agent_task_id).maybeSingle().throwOnError();
    if (task) {
      if (result.status === "settled" && (body.op === "request_closed" || body.op === "complete" && body.result === "task_unknown")) {
        await appendBridgeSessionEvent(admin, { userId: input.userId, sessionId: task.agent_session_id, taskId: command.agent_task_id, turnSeq: task.turn_seq,
          eventId: `bridge-ack:${body.command_id}:${body.op}`, text: body.op === "request_closed" ? "Question closed before the answer was sent" : "Agent stopped", originatingOnly: body.op === "request_closed" });
      }
      if (shouldKick) await kickBridgeSessions(admin, input.userId, [task.agent_session_id]);
    }
  }
  return result;
}
