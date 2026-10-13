import type { AgentCapability } from "@/lib/api/contract";

export type AgentPolicyMode = "manual" | "auto" | "full";
export type AgentAccess = "write" | "read_only";

export function agentAccess(capability: AgentCapability, mode: AgentPolicyMode): AgentAccess | null {
  const gates = capability.enforcement;
  if (gates.approval_gate.verified && gates.revocation.verified && (mode === "manual" || gates.target_scope.verified)) return "write";
  return gates.read_only?.verified ? "read_only" : null;
}

export function directChat(capability: AgentCapability, mode: AgentPolicyMode): "supported" | "unsupported" {
  return capability.session.create && capability.resume === "supported" && capability.events !== "none"
    && capability.question.receive && capability.cancel !== "unsupported" && agentAccess(capability, mode) !== null
    ? "supported" : "unsupported";
}
