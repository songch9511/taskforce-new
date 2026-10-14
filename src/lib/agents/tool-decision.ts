import type { BridgeV1ToolDecisionRequest, BridgeV1ToolDecisionResponse, ToolDecisionReason } from "@/lib/api/contract";
import type { AgentAccess, AgentPolicyMode } from "./capability";
import { parseReadonlyCommand, type CommandParseFailReason } from "./command-parser";

export const TOOL_SENSITIVE_PATH_PATTERN = String.raw`/(\.git|\.claude|\.codex|\.vscode|\.idea|\.husky|\.githooks|\.cargo)(/|$)|/(\.envrc|\.mcp\.json|\.gitattributes|\.gitmodules|\.yarnrc\.yml|\.npmrc|\.pre-commit-config\.yaml|lefthook\.yml)$`;
const toolSensitivePath = new RegExp(TOOL_SENSITIVE_PATH_PATTERN);

export type ToolCallDecision = {
  decision: "allow" | "deny" | "defer"; reason: ToolDecisionReason; leaseOp: "none" | "reserve" | "acquire";
  cardFlags: BridgeV1ToolDecisionResponse["card_flags"]; parse?: BridgeV1ToolDecisionResponse["parse"]; parseReason?: CommandParseFailReason;
};
export const TOOL_DECISION_NOTES: Partial<Record<ToolDecisionReason, string>> = {
  write_gate_closed: "Tool access is disabled. Do not retry this tool.",
  read_only: "This agent is read-only. Do not run this tool.",
  permission_mode: "Only the default permission mode is supported.",
  background: "Background commands are not allowed.",
  sandbox_disabled: "Disabling the sandbox is not allowed.",
  outside_workspace: "This file is outside the workspace.",
  workspace_mismatch: "The workspace does not match this session.",
  not_live: "This task is no longer running.",
  rate_limited: "Too many tool requests. Wait before trying again.",
  path_in_use: "This file is being changed by another task. Do other work first or wait.",
};
export function decideToolCall(input: { call: BridgeV1ToolDecisionRequest["call"]; access: AgentAccess | null; mode: AgentPolicyMode; workspace_real_path: string }): ToolCallDecision {
  const { call, access, mode } = input;
  const result = (decision: ToolCallDecision["decision"], reason: ToolDecisionReason, leaseOp: ToolCallDecision["leaseOp"] = "none", sandbox = false): ToolCallDecision => ({ decision, reason, leaseOp, cardFlags: sandbox ? ["runs_without_sandbox"] : [] });
  if (access === null) return result("deny", "write_gate_closed");
  if ("permission_mode" in call && call.permission_mode !== "default") return result("deny", "permission_mode");
  if (call.kind === "claude_bash" && call.run_in_background) return result("deny", "background");
  if (call.kind === "claude_bash" && call.dangerously_disable_sandbox) return result("deny", "sandbox_disabled");
  if (access === "read_only") return result("deny", "read_only");
  const targets = call.kind === "claude_write" ? [call.target] : call.kind === "codex_file_change" ? call.targets : [];
  if (targets.some(({ real_path }) => toolSensitivePath.test(real_path.normalize("NFC").replace(/ſ/g, "s").replace(/[A-Z]/g, (char) => char.toLowerCase())))) return result("defer", "tool_config_write", "reserve", call.kind === "codex_file_change" && (mode !== "manual" || !call.first_for_item));
  if (call.kind === "claude_write") return mode === "manual" ? result("defer", "manual_write", "reserve") : result("allow", "policy_auto", "acquire");
  if (call.kind !== "claude_bash") {
    if (mode !== "manual") return result("defer", "runs_without_sandbox", "none", true);
    if (!call.first_for_item) return result("defer", "not_first_request", "none", true);
    if (call.kind === "codex_file_change") return result("defer", "manual_write", "reserve");
    if (!call.command_actions.length || call.command_actions.some((action) => !["listFiles", "read", "search"].includes(action))) return result("defer", "actions_not_read");
  }
  const parsed = parseReadonlyCommand({ adapter: call.kind === "claude_bash" ? "claude-code" : "codex", command: call.command, cwd: call.cwd, workspaceRoot: input.workspace_real_path });
  if (!parsed.ok) return { ...result("defer", "command_not_readonly"), parseReason: parsed.reason };
  return { ...result("allow", "readonly_command"), parse: { wrapper: parsed.wrapper, argv: parsed.argv, paths: parsed.paths, implicit_cwd: parsed.implicitCwd } };
}
