import type { SupabaseClient } from "@supabase/supabase-js";
import { after } from "next/server";
import { z } from "zod";
import { bridgeV1ToolDecisionRequestSchema, bridgeV1ToolDecisionResponseSchema, toolDecisionReasonSchema, type BridgeV1ToolDecisionRequest, type BridgeV1ToolDecisionResponse } from "@/lib/api/contract";
import { decideToolCall, TOOL_DECISION_NOTES } from "@/lib/agents/tool-decision";
import type { BridgeRecord } from "./auth";
import { bridgeDeliveryAccess, bridgePolicyMode } from "./commands";
import { appendBridgeSessionEvent } from "./events";

const finalDecisionSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("not_found") }),
  z.object({ status: z.literal("policy_changed") }),
  z.object({ status: z.literal("decided"), decision: z.enum(["allow", "deny", "defer"]), reason: toolDecisionReasonSchema,
    lease_ids: z.array(z.guid()), run_id: z.guid(), card_flags: z.array(z.literal("runs_without_sandbox")).optional(),
    holder: z.object({ action_number: z.number().int().nullable(), rel_path: z.string().min(1).max(1000) }).optional() }),
]);
export async function decideBridgeToolCall(admin: SupabaseClient, input: { userId: string; bridge: BridgeRecord; input: BridgeV1ToolDecisionRequest; startedAt?: number }, env: Record<string, string | undefined> = process.env): Promise<BridgeV1ToolDecisionResponse | { status: "not_found" }> {
  const started = input.startedAt ?? performance.now();
  const body = bridgeV1ToolDecisionRequestSchema.parse(input.input);
  const call = body.call;
  const adapter = call.kind.startsWith("claude_") ? "agent:claude-code" : "agent:codex";
  for (let attempt = 0; attempt < 2; attempt++) {
    const mode = await bridgePolicyMode(admin, input.userId);
    const access = bridgeDeliveryAccess(adapter, input.bridge.capabilities, mode, env);
    const decision = decideToolCall({ call, access, mode, workspace_real_path: body.workspace_real_path });
    const { data } = await admin.rpc("decide_agent_tool_call", {
      p_user_id: input.userId, p_bridge_id: input.bridge.id, p_session_id: body.agent_session_id, p_task_id: body.agent_task_id,
      p_turn_seq: body.turn_seq, p_mode: mode,
      p_decision: { decision: decision.decision, reason: decision.reason, call_kind: call.kind, access,
        request_id: "tool_use_id" in call ? call.tool_use_id : call.provider_request_id, workspace_real_path: body.workspace_real_path,
        targets: call.kind === "claude_write" ? [call.target] : call.kind === "codex_file_change" ? call.targets : [],
        lease_op: decision.leaseOp, ...(decision.parseReason ? { parse_reason: decision.parseReason } : {}),
        card_flags: decision.cardFlags, server_ms: Math.max(0, performance.now() - started) },
    }).throwOnError();
    const finalized = finalDecisionSchema.parse(data);
    if (finalized.status === "not_found") return finalized;
    if (finalized.status === "policy_changed") continue;
    let note = finalized.decision === "deny" ? TOOL_DECISION_NOTES[finalized.reason] : undefined;
    const holder = finalized.holder;
    if (finalized.decision === "deny" && finalized.reason === "path_in_use" && holder) {
      const suffix = ` is being changed by another task${holder.action_number === null ? "" : ` (#${holder.action_number})`}. Do other work first or wait.`;
      note = holder.rel_path.slice(0, 300 - suffix.length) + suffix;
      const leaseId = finalized.lease_ids[0];
      if (leaseId) after(async () => {
        try {
          await appendBridgeSessionEvent(admin, { userId: input.userId, sessionId: body.agent_session_id, taskId: body.agent_task_id,
            turnSeq: body.turn_seq, eventId: `path-wait:${leaseId}:${finalized.run_id}`,
            text: `Waiting for ${holder.action_number === null ? "another task" : `#${holder.action_number}`} · ${holder.rel_path}`, originatingOnly: true });
        } catch { console.error(JSON.stringify({ event: "bridge_tool_decision_failed" })); }
      });
    }
    return bridgeV1ToolDecisionResponseSchema.parse({ decision: finalized.decision, reason: finalized.reason,
      ...(finalized.decision === "allow" && finalized.reason === "readonly_command" && decision.parse ? { parse: decision.parse } : {}),
      ...(note ? { agent_note: note } : {}), ...(holder ? { holder } : {}),
      card_flags: [...new Set([...decision.cardFlags, ...(finalized.card_flags ?? [])])], server_time: new Date().toISOString() });
  }
  return { decision: "defer", reason: "server_busy", card_flags: [], server_time: new Date().toISOString() };
}
