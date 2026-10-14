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

/**
 * 에이전트 입력(Review · 복귀 요약 · 경로 충돌 해소)을 읽을 수 있는 adapter 목록 (OA D4b-s). 에이전트 대화 route의 gate와 같은 조건이다:
 * CONVERSATIONS_V2_ENABLED가 정확히 "true"이고 그 adapter 플래그가 켜져 있다. 하나도 없으면 빈 배열 — 호출한 쪽은 에이전트 입력을 읽지 않는다.
 */
export function openAgentAdapters(env: Record<string, string | undefined> = process.env): string[] {
  if (!flagEnabled("CONVERSATIONS_V2_ENABLED", env)) return [];
  return Object.keys(AGENT_REGISTRY).filter((adapter) => adapterEnabled(adapter, env));
}
