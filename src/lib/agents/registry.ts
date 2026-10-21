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
    session: {
      list: false,
      attach_existing: true,
      create: true,
      workspace_scoped: false,
      evidence:
        "external-session resume probes R1 R2 R3 R8 R9 2026-10-21, real claude 2.1.306 (app bundle 2.1.304 for R8), see docs/rollouts/claude-code-r1-evidence.md section 'Re-run on 2.1.306': R1 a resume from the original folder appends to the original record with a consistent cwd (a resume from another folder also works but mixes cwds, so the Mac resumes from the original folder); R2 an empty --setting-sources keeps repo settings, repo hooks, repo env and user hooks out while the --settings hook is called for all 7 tool calls including ask_user; R3 --system-prompt-snapshot off applies the appended instruction on resume (4 of 4); R8 a record written by the app bundle 2.1.304 is continued by 2.1.306 and the reverse (CLI-level proxy, not the desktop app); R9 init session_id equals the original in 12 of 12 resume runs, no fork; the R1-01 to R1-04 safety scenarios pass 7 of 7 on 2.1.306; R4 R5 R6 R7 are partial or need the user and are not claimed; list is not claimed (the server receives no session list)",
    },
    dispatch: { ack_level: "agent", max_instruction_chars: 20000 },
    events: "push",
    question: { receive: true, answer: true, structured: true },
    cancel: "confirmed",
    cancel_scope: "turn_and_processes",
    resume: "supported",
    enforcement: {
      approval_gate: { channel: "PreToolUse", verified: true, evidence: "S0 CC-3 CC-9 CC-10 CC-12; manual" },
      target_scope: {
        channel: "PreToolUse",
        verified: true,
        evidence: "R1-03 R1-03b R1-03c 2026-10-21, real claude 2.1.241, see docs/rollouts/claude-code-r1-evidence.md: Read outside the workspace denied at the hook (R1-03); Write and Edit creating a new outside file denied at the hook with no server call (R1-03b, R1-03c); Edit and Write on an existing outside file refused by the CLI before the hook; outside files unchanged; Bash scope not claimed",
      },
      revocation: {
        channel: "PreToolUse",
        verified: true,
        evidence: "R1-04 2026-10-21, real claude 2.1.241, see docs/rollouts/claude-code-r1-evidence.md: Write allowed and file created, scripted decider switched to deny, next Write denied (write_gate_closed), file hash unchanged; scripted decider between two turns, not live server revocation",
      },
      read_only: {
        channel: "--tools Read,Glob,Grep + PreToolUse",
        verified: true,
        evidence: "R1-02 R1-02b 2026-10-21, real claude 2.1.241, see docs/rollouts/claude-code-r1-evidence.md: init tools exactly Read Glob Grep + ask_user (self-check); Read allowed at the hook; Edit refused by the CLI as not available (disabled for the session in the first R1-02 run, not_advertised in R1-02b); file hash unchanged; Write and Bash absence rests on the exact init tool set",
      },
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
 * 이 adapter의 세션을 Taskforce 밖에서 시작한 것까지 이어받을 수 있는가 (OA 외부 세션 PR2s, ES-16): registry가 session.attach_existing true인 adapter이고 그 adapter 플래그가 켜져 있어야 한다.
 * registry 밖 이름(`__proto__` · `toString` 포함)은 허용하지 않는다. 새 세션 flag(AGENT_ATTACH_EXISTING_ENABLED) · 대화 v2 · 베타 명단은 route가 따로 본다.
 */
export function attachExistingAllowed(adapter: string, env: Record<string, string | undefined> = process.env): boolean {
  return Object.hasOwn(AGENT_REGISTRY, adapter) && AGENT_REGISTRY[adapter as keyof typeof AGENT_REGISTRY].session.attach_existing === true && adapterEnabled(adapter, env);
}

/**
 * 에이전트 입력(Review · 복귀 요약 · 경로 충돌 해소)을 읽을 수 있는 adapter 목록 (OA D4b-s). 에이전트 대화 route의 gate와 같은 조건이다:
 * CONVERSATIONS_V2_ENABLED가 정확히 "true"이고 그 adapter 플래그가 켜져 있다. 하나도 없으면 빈 배열 — 호출한 쪽은 에이전트 입력을 읽지 않는다.
 */
export function openAgentAdapters(env: Record<string, string | undefined> = process.env): string[] {
  if (!flagEnabled("CONVERSATIONS_V2_ENABLED", env)) return [];
  return Object.keys(AGENT_REGISTRY).filter((adapter) => adapterEnabled(adapter, env));
}
