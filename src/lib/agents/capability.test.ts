import { describe, expect, it } from "vitest";
import { agentCapabilitySchema, type AgentCapability } from "@/lib/api/contract";
import { agentAccess, directChat } from "./capability";
import { AGENT_REGISTRY, adapterEnabled, openAgentAdapters } from "./registry";

describe("S0 registry and access", () => {
  it("keeps both descriptors; Claude Code boundaries are verified only where R1 real-CLI evidence exists (2026-10-21)", () => {
    const cc = AGENT_REGISTRY["agent:claude-code"];
    const cx = AGENT_REGISTRY["agent:codex"];
    for (const capability of [cc, cx]) expect(agentCapabilitySchema.parse(capability)).toEqual(capability);
    expect(cc).toMatchObject({ display_name: "Claude Code", cancel_scope: "turn_and_processes", version_range: ">=2.1.241 <2.2", question: { structured: true } });
    // Each promoted boundary names its scenario and date; budget stays unverified (no R1 scenario covers it).
    expect(cc.enforcement.approval_gate).toMatchObject({ channel: "PreToolUse", verified: true });
    expect(cc.enforcement.revocation).toMatchObject({ channel: "PreToolUse", verified: true, evidence: expect.stringMatching(/R1-04 2026-10-21/) });
    expect(cc.enforcement.read_only).toMatchObject({ verified: true, evidence: expect.stringMatching(/R1-02 2026-10-21/) });
    expect(cc.enforcement.target_scope).toMatchObject({ channel: "PreToolUse", verified: true, evidence: expect.stringMatching(/R1-03 .*2026-10-21/) });
    expect(cc.enforcement.budget).toEqual({ channel: null, verified: false });
    expect(cx).toMatchObject({ display_name: "Codex", cancel_scope: "turn", version_range: ">=0.162.1 <0.163", enforcement: { target_scope: { verified: true }, read_only: { verified: true }, revocation: { verified: false } } });
    for (const mode of ["manual", "auto", "full"] as const) {
      expect(agentAccess(cc, mode)).toBe("write");
      expect(directChat(cc, mode)).toBe("supported");
      expect(agentAccess(cx, mode)).toBe("read_only");
      expect(directChat(cx, mode)).toBe("supported");
    }
  });
  it("Claude Code: dropping one verified boundary closes exactly the grades that need it", () => {
    const lose = (edit: (c: AgentCapability) => void) => {
      const c = structuredClone(AGENT_REGISTRY["agent:claude-code"]);
      edit(c);
      return { manual: agentAccess(c, "manual"), auto: agentAccess(c, "auto"), full: agentAccess(c, "full"), chat: directChat(c, "manual") };
    };
    // Without revocation no write grade opens; the verified read_only grade keeps a read-only chat.
    expect(lose((c) => { c.enforcement.revocation.verified = false; })).toEqual({ manual: "read_only", auto: "read_only", full: "read_only", chat: "supported" });
    // Without target_scope Manual still writes; Auto and Full fall back to read_only.
    expect(lose((c) => { c.enforcement.target_scope.verified = false; })).toEqual({ manual: "write", auto: "read_only", full: "read_only", chat: "supported" });
    // Without the approval gate nothing writes.
    expect(lose((c) => { c.enforcement.approval_gate.verified = false; })).toEqual({ manual: "read_only", auto: "read_only", full: "read_only", chat: "supported" });
    // Without read_only and revocation there is no grade at all, so no direct chat.
    expect(lose((c) => { c.enforcement.revocation.verified = false; c.enforcement.read_only!.verified = false; })).toEqual({ manual: null, auto: null, full: null, chat: "unsupported" });
  });
  it("requires the mode-specific write gates, never budget alone", () => {
    const c = structuredClone(AGENT_REGISTRY["agent:claude-code"]);
    c.enforcement.revocation.verified = false;
    c.enforcement.target_scope.verified = false;
    c.enforcement.read_only!.verified = false;
    c.enforcement.budget.verified = true;
    expect(agentAccess(c, "manual")).toBeNull();
    c.enforcement.revocation.verified = true;
    expect(agentAccess(c, "manual")).toBe("write");
    expect(agentAccess(c, "auto")).toBeNull();
    expect(agentAccess(c, "full")).toBeNull();
    c.enforcement.target_scope.verified = true;
    expect(agentAccess(c, "auto")).toBe("write");
    expect(agentAccess(c, "full")).toBe("write");
    c.enforcement.approval_gate.verified = false;
    expect(agentAccess(c, "manual")).toBeNull();
  });
  it.each(["create", "resume", "events", "question", "cancel"])("requires direct-chat %s support", (guard) => {
    const c = structuredClone(AGENT_REGISTRY["agent:codex"]);
    if (guard === "create") c.session.create = false;
    if (guard === "resume") c.resume = "unsupported";
    if (guard === "events") c.events = "none";
    if (guard === "question") c.question.receive = false;
    if (guard === "cancel") c.cancel = "unsupported";
    expect(directChat(c, "manual")).toBe("unsupported");
  });
  it("reads only the existing Claude Code flag with exact true semantics", () => {
    expect(adapterEnabled("agent:claude-code", {})).toBe(false);
    expect(adapterEnabled("agent:claude-code", { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toBe(true);
    expect(adapterEnabled("agent:claude-code", { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "TRUE" })).toBe(false);
    expect(adapterEnabled("agent:unknown", {})).toBe(false);
  });
  it("reads the Codex flag (OD-2): closed by default, exact true semantics, independent of the Claude Code flag", () => {
    expect(adapterEnabled("agent:codex", {})).toBe(false);
    expect(adapterEnabled("agent:codex", { AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe(true);
    for (const value of ["TRUE", "1", " true", ""]) expect(adapterEnabled("agent:codex", { AGENT_ADAPTER_CODEX_ENABLED: value })).toBe(false);
    expect(adapterEnabled("agent:codex", { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toBe(false);
    expect(adapterEnabled("agent:claude-code", { AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe(false);
  });
  it("allows requested-only cancellation and keeps absent legacy read_only closed", () => {
    const c = structuredClone(AGENT_REGISTRY["agent:codex"]);
    c.cancel = "requested_only";
    expect(directChat(c, "manual")).toBe("supported");
    delete c.enforcement.read_only;
    expect(agentAccess(c, "manual")).toBeNull();
    expect(directChat(c, "manual")).toBe("unsupported");
  });
  it("openAgentAdapters (D4b-s): 대화 v2가 꺼져 있으면 adapter 플래그가 켜져 있어도 빈 배열 (에이전트 대화 route의 gate와 같은 조건)", () => {
    expect(openAgentAdapters({})).toEqual([]);
    expect(openAgentAdapters({ AGENT_ADAPTER_CODEX_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toEqual([]);
    for (const value of ["TRUE", "1", " true", "true\n", "", "false"]) {
      expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: value, AGENT_ADAPTER_CODEX_ENABLED: "true" }), JSON.stringify(value)).toEqual([]);
    }
  });
  it("openAgentAdapters: 대화 v2가 켜져 있어도 adapter 플래그가 없으면 빈 배열, 하나만 켜지면 그것만, 둘 다 켜지면 registry 순서 그대로", () => {
    expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: "true" })).toEqual([]);
    expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toEqual(["agent:codex"]);
    expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toEqual(["agent:claude-code"]);
    expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toEqual(["agent:claude-code", "agent:codex"]);
    expect(openAgentAdapters({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "TRUE" })).toEqual([]);
  });
  it("openAgentAdapters의 기본 env는 process.env다 (route가 인자 없이 부른다)", () => {
    const before = { ...process.env };
    try {
      process.env.CONVERSATIONS_V2_ENABLED = "true";
      process.env.AGENT_ADAPTER_CODEX_ENABLED = "true";
      delete process.env.AGENT_ADAPTER_CLAUDE_CODE_ENABLED;
      expect(openAgentAdapters()).toEqual(["agent:codex"]);
    } finally {
      for (const key of ["CONVERSATIONS_V2_ENABLED", "AGENT_ADAPTER_CODEX_ENABLED", "AGENT_ADAPTER_CLAUDE_CODE_ENABLED"]) {
        if (before[key] === undefined) delete process.env[key];
        else process.env[key] = before[key];
      }
    }
  });
});
