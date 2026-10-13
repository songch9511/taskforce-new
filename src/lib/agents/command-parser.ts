import { ALWAYS_BLOCKED_FLAGS, COMMAND_FLAGS, type AllowedCommand, type FlagKind } from "./command-flags";

export type { AllowedCommand } from "./command-flags";
export type CommandParseInput = {
  adapter: "claude-code" | "codex";
  command: string;
  cwd: string;
  workspaceRoot: string;
};
export type CommandParseFailReason =
  | "empty" | "too_long" | "too_many_words" | "bad_character" | "newline"
  | "unquoted_special" | "unterminated_quote" | "double_quote_special" | "equals_word_start"
  | "wrapper_not_supported" | "command_not_allowed" | "git_not_auto_allowed"
  | "flag_not_allowed" | "flag_always_blocked" | "missing_flag_value" | "missing_path"
  | "path_parent_reference" | "path_outside_workspace" | "cwd_outside_workspace" | "invalid_input";
export type CommandParseResult =
  | { ok: true; wrapper: "none" | "zsh_lc"; command: AllowedCommand; argv: string[];
      paths: { index: number | null; absolute: string }[]; implicitCwd: boolean }
  | { ok: false; reason: CommandParseFailReason };

type Failure = Extract<CommandParseResult, { ok: false }>;
const fail = (reason: CommandParseFailReason): Failure => ({ ok: false, reason });

function splitWords(text: string): { ok: true; argv: string[] } | Failure {
  if (text.length > 4096) return fail("too_long");
  // Unicode normalization could change a filesystem name; validate without rewriting it.
  for (const char of text) {
    if (char === "\n" || char === "\r") return fail("newline");
    const code = char.codePointAt(0)!;
    if ((code < 32 && char !== "\t") || code === 127 || (code > 127 && !/[\p{L}\p{M}\p{N}]/u.test(char))) return fail("bad_character");
  }
  const argv: string[] = [];
  let quote = "";
  let word = "";
  let started = false;
  let previous = "";
  for (const char of text) {
    const previousChar = previous;
    previous = char;
    if (quote) {
      if (char === quote) { quote = ""; continue; }
      if (quote === '"' && "$`\\!".includes(char)) return fail("double_quote_special");
      word += char;
    } else if (char === "'" || char === '"') {
      if (char === "'" && previousChar === "'") return fail("unquoted_special");
      quote = char;
      started = true;
    } else if (char === " " || char === "\t") {
      if (started) {
        argv.push(word);
        if (argv.length > 64) return fail("too_many_words");
        word = "";
        started = false;
      }
    } else {
      if (!/[\p{L}\p{M}\p{N}\-_.\/,:@%+=]/u.test(char)) return fail("unquoted_special");
      if (char === "=" && !word) return fail("equals_word_start");
      // Empty quote pairs add nothing to `word`, so they cannot hide the preceding = or : (MAGIC_EQUAL_SUBST).
      if (char === "=" && (word.endsWith("=") || word.endsWith(":"))) return fail("unquoted_special");
      word += char;
      started = true;
    }
  }
  if (quote) return fail("unterminated_quote");
  if (started) argv.push(word);
  if (argv.length > 64) return fail("too_many_words");
  return argv.length ? { ok: true, argv } : fail("empty");
}

const hasParent = (path: string) => path.split("/").includes("..");
const normalize = (path: string) => "/" + path.split("/").filter((part) => part && part !== ".").join("/");
const inside = (path: string, root: string) => path === root || path.startsWith(root + "/");
const isAbsoluteInput = (value: unknown): value is string => typeof value === "string" && value.startsWith("/") && !hasParent(value);

export function parseReadonlyCommand(input: CommandParseInput): CommandParseResult {
  if (!input || (input.adapter !== "claude-code" && input.adapter !== "codex") || typeof input.command !== "string"
    || !isAbsoluteInput(input.cwd) || !isAbsoluteInput(input.workspaceRoot)) return fail("invalid_input");
  const cwd = normalize(input.cwd);
  const root = normalize(input.workspaceRoot);
  if (root === "/") return fail("invalid_input");
  if (!inside(cwd, root)) return fail("cwd_outside_workspace");

  let words = splitWords(input.command);
  if (!words.ok) return words;
  const wrapper = input.adapter === "codex" ? "zsh_lc" : "none";
  if (wrapper === "zsh_lc") {
    if (words.argv.length !== 3 || words.argv[0] !== "/bin/zsh" || words.argv[1] !== "-lc") return fail("wrapper_not_supported");
    words = splitWords(words.argv[2]);
    if (!words.ok) return words;
    if (words.argv[0] === "/bin/zsh") return fail("wrapper_not_supported");
  }
  const argv = words.argv;
  const name = argv[0];
  if (name === "git") return fail("git_not_auto_allowed");
  if (!Object.hasOwn(COMMAND_FLAGS, name)) return fail("command_not_allowed");
  const command = name as AllowedCommand;
  const flags = COMMAND_FLAGS[command];
  const blocked = (flag: string) => (ALWAYS_BLOCKED_FLAGS[command] ?? []).some((entry) => entry.endsWith("*") ? flag.startsWith(entry.slice(0, -1)) : flag === entry);
  const paths: { index: number | null; absolute: string }[] = [];
  const positionals: number[] = [];
  let endFlags = false;
  let findExpression = false;
  let explicitPattern = false;
  let recursiveGrep = false;

  const addPath = (index: number): Failure | undefined => {
    const value = argv[index];
    if (!value) return fail("missing_path");
    if (hasParent(value)) return fail("path_parent_reference");
    const absolute = normalize(value.startsWith("/") ? value : `${cwd}/${value}`);
    if (!inside(absolute, root)) return fail("path_outside_workspace");
    paths.push({ index, absolute });
  };

  for (let i = 1; i < argv.length; i++) {
    const word = argv[i];
    if (word === "-" || (command === "tail" && !endFlags && word.startsWith("+"))) return fail("flag_not_allowed");
    const afterPositional = command !== "find" && positionals.length > 0;
    if (!endFlags && word === "--") {
      if (positionals.length || findExpression) return fail("flag_not_allowed");
      endFlags = true;
      continue;
    }
    // find's initial '--' ends global options, never its expression primaries.
    if ((endFlags && command !== "find" && !afterPositional) || !word.startsWith("-")) {
      if (command === "pwd" || findExpression) return fail("flag_not_allowed");
      positionals.push(i);
      continue;
    }
    if (command === "find") findExpression = true;
    if ((command === "head" || command === "tail") && /^-\d+$/.test(word)) {
      if (afterPositional) return fail("flag_not_allowed");
      continue;
    }

    const consumeValue = (flag: string, kind: FlagKind, attached: string | undefined): Failure | undefined => {
      if (afterPositional) return fail("flag_not_allowed");
      if (kind === "bool") return attached === undefined ? undefined : fail("flag_not_allowed");
      // BSD optional long values bind only with '='; consuming the next word would hide a path.
      if (attached === undefined && (command === "ls" || command === "grep") && (flag === "--color" || flag === "--colour")) return;
      const value = attached ?? argv[++i];
      if (value === undefined || (value === "" && flag !== "-e" && flag !== "--regexp")) return fail("missing_flag_value");
      if (flag === "-e" || flag === "--regexp") explicitPattern = true;
      if (kind === "path_value") return addPath(i);
    };

    if (command === "find" || word.startsWith("--")) {
      const equals = word.indexOf("=");
      const flag = equals < 0 ? word : word.slice(0, equals);
      if (blocked(flag)) return fail("flag_always_blocked");
      if (!Object.hasOwn(flags, flag) || (command === "find" && equals >= 0)) return fail("flag_not_allowed");
      const error = consumeValue(flag, flags[flag], equals < 0 ? undefined : word.slice(equals + 1));
      if (error) return error;
    } else {
      for (let j = 1; j < word.length; j++) {
        const flag = `-${word[j]}`;
        if (blocked(flag)) return fail("flag_always_blocked");
        if (!Object.hasOwn(flags, flag)) return fail("flag_not_allowed");
        const kind = flags[flag];
        if (command === "grep" && (flag === "-r" || flag === "-R")) recursiveGrep = true;
        if (kind === "bool") continue;
        const error = consumeValue(flag, kind, word.slice(j + 1) || undefined);
        if (error) return error;
        break;
      }
    }
    if (afterPositional) return fail("flag_not_allowed");
  }

  if (command === "find" && !positionals.length) return fail("missing_path");
  if ((command === "grep" || command === "rg") && !explicitPattern) positionals.shift();
  for (const index of positionals) {
    const error = addPath(index);
    if (error) return error;
  }
  paths.sort((a, b) => a.index! - b.index!);
  const implicitCwd = (command === "ls" || command === "rg" || recursiveGrep) && !paths.length;
  if (implicitCwd) paths.push({ index: null, absolute: cwd });
  return { ok: true, wrapper, command, argv, paths, implicitCwd };
}
