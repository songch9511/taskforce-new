import { describe, expect, it } from "vitest";
import { agentCapabilitySchema } from "@/lib/api/contract";
import { agentAccess, directChat } from "./capability";
import { AGENT_REGISTRY, adapterEnabled } from "./registry";

describe("S0 registry and access", () => {
  it("keeps both descriptors and S0 conservative boundaries", () => {
    const cc = AGENT_REGISTRY["agent:claude-code"];
    const cx = AGENT_REGISTRY["agent:codex"];
    for (const capability of [cc, cx]) expect(agentCapabilitySchema.parse(capability)).toEqual(capability);
    expect(cc).toMatchObject({ display_name: "Claude Code", cancel_scope: "turn_and_processes", version_range: ">=2.1.241 <2.2", question: { structured: true }, enforcement: { approval_gate: { verified: true }, target_scope: { verified: false }, read_only: { verified: false }, revocation: { verified: false } } });
    expect(cx).toMatchObject({ display_name: "Codex", cancel_scope: "turn", version_range: ">=0.162.1 <0.163", enforcement: { target_scope: { verified: true }, read_only: { verified: true }, revocation: { verified: false } } });
    for (const mode of ["manual", "auto", "full"] as const) {
      expect(agentAccess(cc, mode)).toBeNull();
      expect(directChat(cc, mode)).toBe("unsupported");
      expect(agentAccess(cx, mode)).toBe("read_only");
      expect(directChat(cx, mode)).toBe("supported");
    }
  });
  it("requires the mode-specific write gates, never budget alone", () => {
    const c = structuredClone(AGENT_REGISTRY["agent:claude-code"]);
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
});
