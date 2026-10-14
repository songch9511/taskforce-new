import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { bridgeV1ToolDecisionRequestSchema, bridgeV1ToolDecisionResponseSchema, type BridgeV1ToolDecisionRequest } from "@/lib/api/contract";
import { decideToolCall, TOOL_SENSITIVE_PATH_PATTERN } from "./tool-decision";
import { codexCommand, codexFile, decisionRequest, parserCases, writeCall } from "./tool-decision.fixtures";

type Call = BridgeV1ToolDecisionRequest["call"];
const calls: Call[] = [decisionRequest.call, writeCall, { ...codexCommand, command_actions: [...codexCommand.command_actions] }, { ...codexFile, targets: [...codexFile.targets] }];
const decide = (call: Call, mode: "manual" | "auto" | "full" = "manual", access: "write" | "read_only" | null = "write") => decideToolCall({ call, mode, access, workspace_real_path: "/w/proj" });
describe("U1 decision table", () => {
  for (const mode of ["manual", "auto", "full"] as const) {
    for (const call of calls) {
      it(`${mode}/${call.kind}: null closes every call`, () => expect(decide(call, mode, null)).toMatchObject({ decision: "deny", reason: "write_gate_closed", leaseOp: "none" }));
      it(`${mode}/${call.kind}: read_only never approves tool requests`, () => expect(decide(call, mode, "read_only")).toMatchObject({ decision: "deny", reason: "read_only", leaseOp: "none" }));
    }
    it(`${mode}: Claude read-only command allowed, shell writes deferred`, () => {
      expect(decide(decisionRequest.call, mode)).toMatchObject({ decision: "allow", reason: "readonly_command", leaseOp: "none", parse: { argv: ["ls"], implicit_cwd: true } });
      expect(decide({ ...decisionRequest.call, command: "echo x > a" }, mode)).toMatchObject({ decision: "defer", reason: "command_not_readonly", leaseOp: "none", parseReason: "unquoted_special" });
    });
    it(`${mode}: writes reserve in Manual and acquire in Auto/Full`, () => expect(decide(writeCall, mode)).toMatchObject(mode === "manual" ? { decision: "defer", reason: "manual_write", leaseOp: "reserve" } : { decision: "allow", reason: "policy_auto", leaseOp: "acquire" }));
    for (const call of calls.slice(0, 2)) it(`${mode}/${call.kind}: permission mode outranks read_only`, () => expect(decide({ ...call, permission_mode: "acceptEdits" } as Call, mode, "read_only")).toMatchObject({ decision: "deny", reason: "permission_mode" }));
    for (const [field, reason] of [["run_in_background", "background"], ["dangerously_disable_sandbox", "sandbox_disabled"]] as const) it(`${mode}: ${field} denied before parser`, () => expect(decide({ ...decisionRequest.call, [field]: true }, mode)).toMatchObject({ decision: "deny", reason, leaseOp: "none" }));
  }
  it("P12 requires independent actions, parser and first-request agreement", () => {
    const call = { ...codexCommand, command_actions: ["read", "search", "listFiles"] };
    expect(decide(call)).toMatchObject({ decision: "allow", reason: "readonly_command", leaseOp: "none" });
    expect(decide({ ...call, command: "/bin/zsh -lc 'rm a'" })).toMatchObject({ decision: "defer", reason: "command_not_readonly" });
    for (const command_actions of [[], ["unknown"], ["read", "write"]]) expect(decide({ ...call, command_actions })).toMatchObject({ decision: "defer", reason: "actions_not_read" });
    expect(decide({ ...call, first_for_item: false })).toMatchObject({ decision: "defer", reason: "not_first_request", cardFlags: ["runs_without_sandbox"], leaseOp: "none" });
    for (const mode of ["auto", "full"] as const) for (const candidate of calls.slice(2)) expect(decide(candidate, mode)).toMatchObject({ decision: "defer", reason: "runs_without_sandbox", cardFlags: ["runs_without_sandbox"], leaseOp: "none" });
  });
  it("7-06 file change reserves; repeated request does not", () => {
    const call = { ...codexFile, targets: [...codexFile.targets] };
    expect(decide(call)).toMatchObject({ decision: "defer", reason: "manual_write", leaseOp: "reserve" });
    expect(decide({ ...call, first_for_item: false })).toMatchObject({ reason: "not_first_request", leaseOp: "none" });
  });
  for (const fixture of parserCases) for (const adapter of ["claude", "codex"]) it(`parser integration ${fixture.id}/${adapter}`, () => {
    const call: Call = adapter === "claude" ? { ...decisionRequest.call, command: fixture.command } : { ...codexCommand, command_actions: ["read"], command: `/bin/zsh -lc '${fixture.command}'` };
    expect(decide(call)).toMatchObject({ decision: fixture.allowed ? "allow" : "defer", reason: fixture.allowed ? "readonly_command" : "command_not_readonly" });
  });
});
describe("U2 strict DTO", () => {
  it("accepts all four kinds", () => { for (const call of calls) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call }).success).toBe(true); });
  for (const field of ["content", "old_string", "new_string"]) it(`rejects write body ${field}`, () => expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...writeCall, [field]: "private" } }).success).toBe(false));
  for (const kind of ["NotebookEdit", "MultiEdit", "Agent", "Task", "Skill", "mcp__evil__ask_user", "mcp__tf__ask_user", "item/permissions/requestApproval", "Read", "Glob", "Grep"]) it(`rejects local-only kind ${kind}`, () => expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { kind } }).success).toBe(false));
  it("rejects unknown root and target fields", () => {
    expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, policy: "full" }).success).toBe(false);
    expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...writeCall, target: { ...writeCall.target, content: "private" } } }).success).toBe(false);
  });
  for (const real_path of ["relative", "/w/proj//a", "/w/proj/./a", "/w/proj/a/../b", "/w/proj/a/", "/w/proj/a\u0000", "/w/proj/a\u007f"]) it(`9-04 rejects malformed real path ${JSON.stringify(real_path)}`, () => expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...writeCall, target: { real_path, rel_path: "a" } } }).success).toBe(false));
  it("enforces exact command/actions/targets bounds", () => {
    for (const [length, expected] of [[4096, true], [4097, false]] as const) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...decisionRequest.call, command: "x".repeat(length) } }).success).toBe(expected);
    for (const [length, expected] of [[32, true], [33, false]] as const) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...codexCommand, command_actions: Array(length).fill("read") } }).success).toBe(expected);
    for (const [length, expected] of [[0, false], [20, true], [21, false]] as const) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...codexFile, targets: Array(length).fill(writeCall.target) } }).success).toBe(expected);
  });
  it("7-07 accepts only bounded decision enum and never raw command", () => {
    const response = { decision: "allow", reason: "readonly_command", card_flags: [], server_time: new Date().toISOString() };
    expect(bridgeV1ToolDecisionResponseSchema.safeParse(response).success).toBe(true);
    for (const decision of ["accept", "acceptForSession", "cancel"]) expect(bridgeV1ToolDecisionResponseSchema.safeParse({ ...response, decision }).success).toBe(false);
    expect(bridgeV1ToolDecisionResponseSchema.safeParse({ ...response, command: "ls" }).success).toBe(false);
  });
});

it("response parser evidence and agent notes remain decision-scoped", () => {
  const response = { decision: "deny", reason: "read_only", card_flags: [], server_time: new Date().toISOString() };
  expect(bridgeV1ToolDecisionResponseSchema.safeParse({ ...response, parse: { wrapper: "none", argv: ["ls"], paths: [], implicit_cwd: true } }).success).toBe(false);
  expect(bridgeV1ToolDecisionResponseSchema.safeParse({ ...response, decision: "defer", agent_note: "denied" }).success).toBe(false);
});
it("U2 validates identities, workspace and required booleans", () => {
  for (const patch of [{ bridge_id: "invalid" }, { agent_session_id: "invalid" }, { agent_task_id: "invalid" }, { turn_seq: 0 }, { turn_seq: 1.5 }, { workspace_real_path: "relative" }, { workspace_real_path: "/" + "a".repeat(500) }]) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, ...patch }).success).toBe(false);
  for (const patch of [{ tool_use_id: "" }, { tool_use_id: "a".repeat(201) }, { permission_mode: "" }, { permission_mode: "a".repeat(51) }, { cwd: "relative" }, { cwd: "/" + "a".repeat(4096) }, { run_in_background: "false" }, { dangerously_disable_sandbox: undefined }]) expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...decisionRequest.call, ...patch } }).success).toBe(false);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...codexCommand, command_actions: ["x".repeat(51)] } }).success).toBe(false);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...codexFile, first_for_item: undefined } }).success).toBe(false);
});
it("U1 fail-closed precedence is stable for overlapping guards", () => {
  const call = { ...decisionRequest.call, permission_mode: "bypassPermissions", run_in_background: true, dangerously_disable_sandbox: true };
  expect(decide(call, "manual", null)).toMatchObject({ reason: "write_gate_closed" });
  expect(decide(call)).toMatchObject({ reason: "permission_mode" });
  expect(decide({ ...call, permission_mode: "default" }, "manual", "read_only")).toMatchObject({ reason: "background" });
  expect(decide({ ...call, permission_mode: "default", run_in_background: false }, "manual", "read_only")).toMatchObject({ reason: "sandbox_disabled" });
});

// Section 8: sensitive configuration always needs a user decision.
it("defers tool configuration writes in every policy mode", () => {
  for (const path of [".GIT/config", ".claude/settings.json", ".codex/config.toml", ".vscode/tasks.json", ".idea/workspace.xml", ".husky/pre-commit", ".envrc", ".mcp.json", ".gitattributes", ".gitmodules"]) {
    for (const mode of ["manual", "auto", "full"] as const) {
      const target = { real_path: `/w/proj/${path}`, rel_path: path };
      expect(decide({ ...writeCall, target }, mode)).toMatchObject({ decision: "defer", reason: "tool_config_write", leaseOp: "reserve" });
      expect(decide({ ...codexFile, targets: [target] }, mode)).toMatchObject({ decision: "defer", reason: "tool_config_write", leaseOp: "reserve" });
    }
  }
  expect(decide({ ...writeCall, target: { real_path: "/w/proj/.github/config", rel_path: ".github/config" } }, "auto")).toMatchObject({ decision: "allow" });
});
it("D10 precedes D11 when Codex is Auto/Full and not first", () => {
  for (const mode of ["auto", "full"] as const) for (const call of calls) {
    if (!("first_for_item" in call)) continue;
    expect(decide({ ...call, first_for_item: false }, mode)).toMatchObject({ reason: "runs_without_sandbox", leaseOp: "none" });
  }
});
it("Claude bash parser resolves the actual cwd and rejects an outside cwd", () => {
  expect(decide({ ...decisionRequest.call, cwd: "/w/proj/sub", command: "cat file" })).toMatchObject({ decision: "allow", parse: { paths: [{ index: 1, absolute: "/w/proj/sub/file" }] } });
  expect(decide({ ...decisionRequest.call, cwd: "/other" })).toMatchObject({ decision: "defer", parseReason: "cwd_outside_workspace" });
});
it("accepts SQL path_too_long denial for a path expanded by NFC", () => {
  const path = "/w/proj/" + "\u0958".repeat(600);
  expect(path.length).toBeLessThan(1000);
  expect(path.normalize("NFC").length).toBeGreaterThan(1000);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...writeCall, target: { real_path: path, rel_path: "a" } } }).success).toBe(true);
  expect(bridgeV1ToolDecisionResponseSchema.safeParse({ decision: "deny", reason: "path_too_long", card_flags: [], server_time: new Date().toISOString() }).success).toBe(true);
});

it("TS and SQL use the identical tool configuration path list", () => {
  const sql = readFileSync("supabase/migrations/20261123000000_agent_path_leases.sql", "utf8");
  expect(sql).toContain(`~ '${TOOL_SENSITIVE_PATH_PATTERN}'`);
});

it("leaves target length to SQL after NFC and measures workspace NFC codepoints", () => {
  const real_path = "/w/proj/" + "e\u0301".repeat(600);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, call: { ...writeCall, target: { real_path, rel_path: "a" } } }).success).toBe(true);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, workspace_real_path: "/w/" + "e\u0301".repeat(400) }).success).toBe(true);
  expect(bridgeV1ToolDecisionRequestSchema.safeParse({ ...decisionRequest, workspace_real_path: "/w/" + "\u0958".repeat(300) }).success).toBe(false);
});

// Section 9: repeated Codex requests still disclose their sandbox policy.
it.each(["manual", "auto", "full"] as const)("config writes preserve sandbox flags in %s", (mode) => {
  for (const first_for_item of [true, false]) {
    expect(decide({ ...codexFile, first_for_item, targets: [{ real_path: "/w/proj/.git/config", rel_path: ".git/config" }] }, mode)).toMatchObject({
      decision: "defer", reason: "tool_config_write", cardFlags: mode !== "manual" || !first_for_item ? ["runs_without_sandbox"] : [],
    });
  }
});
it("folds long s before matching sensitive configuration names", () => {
  expect(decide({ ...writeCall, target: { real_path: "/w/proj/.huſky/pre-commit", rel_path: ".huſky/pre-commit" } }, "auto")).toMatchObject({ decision: "defer", reason: "tool_config_write" });
});
it.each([".githooks/pre-commit", ".cargo/config.toml", ".yarnrc.yml", ".npmrc", ".pre-commit-config.yaml", "lefthook.yml"])("asks before writing additional config %s", (path) => {
  const target = { real_path: `/w/proj/${path.toUpperCase()}`, rel_path: path };
  for (const mode of ["manual", "auto", "full"] as const) {
    expect(decide({ ...writeCall, target }, mode)).toMatchObject({ decision: "defer", reason: "tool_config_write", leaseOp: "reserve" });
    expect(decide({ ...codexFile, targets: [target] }, mode)).toMatchObject({ decision: "defer", reason: "tool_config_write", leaseOp: "reserve" });
  }
});
