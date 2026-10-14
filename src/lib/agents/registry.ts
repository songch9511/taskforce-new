import type { AgentCapability } from "@/lib/api/contract";
import { flagEnabled } from "@/lib/flags";

// Server evidence, never bridge-reported permissions: Assistant contract v3 §4.4 overrides S0 capability.json.
export const AGENT_REGISTRY: Record<"agent:claude-code" | "agent:codex", AgentCapability> = {
  "agent:claude-code": {
    adapter: "agent:claude-code",
    display_name: "Claude Code",
    transport: "local_bridge",
    sign_in: "user_terminal",
    version_range: ">=2.1.241 <2.2",
    session: { list: false, attach_existing: false, create: true, workspace_scoped: false },
    dispatch: { ack_level: "agent", max_instruction_chars: 20000 },
    events: "push",
    question: { receive: true, answer: true, structured: true },
    cancel: "confirmed",
    cancel_scope: "turn_and_processes",
    resume: "supported",
    enforcement: {
      approval_gate: { channel: "PreToolUse", verified: true, evidence: "S0 CC-3 CC-9 CC-10 CC-12; manual" },
      target_scope: { channel: null, verified: false },
      revocation: { channel: null, verified: false },
      read_only: { channel: null, verified: false },
      budget: { channel: null, verified: false },
    },
    cost: "unknown",
    artifacts: [],
  },
  "agent:codex": {
    adapter: "agent:codex",
    display_name: "Codex",
    transport: "local_bridge",
    sign_in: "user_terminal",
    version_range: ">=0.162.1 <0.163",
    session: { list: false, attach_existing: false, create: true, workspace_scoped: true },
    dispatch: { ack_level: "agent", max_instruction_chars: 20000 },
    events: "push",
    question: { receive: true, answer: true, structured: true },
    cancel: "confirmed",
    cancel_scope: "turn",
    resume: "supported",
    enforcement: {
      approval_gate: { channel: "approvalPolicy", verified: true, evidence: "S0 CX-8a; Manual mapping" },
      target_scope: { channel: "sandboxPolicy", verified: true, evidence: "S0 CX-5b" },
      revocation: { channel: null, verified: false },
      read_only: { channel: "never + readOnly", verified: true, evidence: "S0 CX-8" },
      budget: { channel: null, verified: false },
    },
    cost: "unknown",
    artifacts: [],
  },
};

export function adapterEnabled(adapter: string, env: Record<string, string | undefined> = process.env): boolean {
  if (adapter === "agent:claude-code") return flagEnabled("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", env);
  return adapter === "agent:codex" && flagEnabled("AGENT_ADAPTER_CODEX_ENABLED", env);
}
