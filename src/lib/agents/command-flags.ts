export type AllowedCommand = "ls" | "cat" | "head" | "tail" | "wc" | "pwd" | "stat" | "file" | "grep" | "rg" | "find";

export type FlagKind = "bool" | "value" | "path_value";
export const COMMAND_FLAGS: Readonly<Record<AllowedCommand, Readonly<Record<string, FlagKind>>>> = {
  // Local macOS man 1 ls (2026-10-14): display/sort flags only; --color takes an optional attached value.
  ls: { "-a": "bool", "-A": "bool", "-l": "bool", "-h": "bool", "-d": "bool", "-F": "bool", "-G": "bool", "-i": "bool", "-n": "bool", "-P": "bool", "-R": "bool", "-r": "bool", "-S": "bool", "-t": "bool", "-1": "bool", "-D": "value", "--color": "value" },
  // Local macOS man 1 cat: formatting only; omit the blocking stdout lock (-l).
  cat: { "-b": "bool", "-e": "bool", "-n": "bool", "-s": "bool", "-t": "bool", "-u": "bool", "-v": "bool" },
  // Local macOS man 1 head: byte/line limits; historic -<digits> additionally required by WP §2.2.
  head: { "-n": "value", "-c": "value", "--lines": "value", "--bytes": "value" },
  // Local macOS man 1 tail: bounded output; never follow files.
  tail: { "-n": "value", "-c": "value", "-b": "value", "-q": "bool", "-v": "bool", "-r": "bool", "--lines": "value", "--bytes": "value", "--blocks": "value", "--quiet": "bool", "--silent": "bool", "--verbose": "bool" },
  // Local macOS man 1 wc: counts only.
  wc: { "-L": "bool", "-c": "bool", "-l": "bool", "-m": "bool", "-w": "bool" },
  // Local macOS man 1 pwd: logical/physical display, no operands.
  pwd: { "-L": "bool", "-P": "bool" },
  // Local macOS man 1 stat: display formats only; -L would follow symlinks.
  stat: { "-F": "bool", "-l": "bool", "-n": "bool", "-q": "bool", "-r": "bool", "-s": "bool", "-x": "bool", "-f": "value", "-t": "value" },
  // Local macOS man 1 file: display only; -p mutates timestamps, -m/-M/-f read extra files.
  file: { "-b": "bool", "-h": "bool", "-I": "bool", "-n": "bool", "-N": "bool", "-F": "value", "--brief": "bool", "--mime-type": "bool", "--mime-encoding": "bool", "--extension": "bool", "--separator": "value" },
  // Local macOS man 1 grep: -e consumes dash-leading patterns; recursion defaults to not following symlinks.
  grep: { "-E": "bool", "-F": "bool", "-G": "bool", "-H": "bool", "-h": "bool", "-I": "bool", "-i": "bool", "-L": "bool", "-l": "bool", "-n": "bool", "-o": "bool", "-p": "bool", "-q": "bool", "-r": "bool", "-R": "bool", "-s": "bool", "-v": "bool", "-w": "bool", "-x": "bool", "-e": "value", "-A": "value", "-B": "value", "-C": "value", "-m": "value", "--regexp": "value", "--color": "value", "--colour": "value", "--include": "value", "--exclude": "value", "--exclude-dir": "value" },
  // No local man entry for rg; installed rg --help (2026-10-14) confirms these search/display flags.
  rg: { "-i": "bool", "--ignore-case": "bool", "-n": "bool", "--line-number": "bool", "-e": "value", "--regexp": "value", "-g": "value", "--glob": "value", "--color": "value" },
  // Local macOS man 1 find: exact primaries; -newer reads a reference path, -name/-path take patterns.
  find: { "-print": "bool", "-print0": "bool", "-empty": "bool", "-prune": "bool", "-xdev": "bool", "-name": "value", "-iname": "value", "-path": "value", "-ipath": "value", "-type": "value", "-size": "value", "-mtime": "value", "-maxdepth": "value", "-mindepth": "value", "-newer": "path_value" },
};

// Contract §13.4/13.4.1-6 wins even if a future edit adds an unsafe flag to COMMAND_FLAGS.
export const ALWAYS_BLOCKED_FLAGS: Readonly<Partial<Record<AllowedCommand, readonly string[]>>> = {
  ls: ["-L", "-H"],
  stat: ["-L"],
  tail: ["-f", "-F", "--follow"],
  file: ["-C", "--compile", "-L", "--dereference", "-z", "-Z", "--uncompress", "--uncompress-noreport", "-m", "-M", "--magic-file", "-f", "--files-from", "-p", "--preserve-date"],
  grep: ["-S", "-O", "-Z", "-z", "-J", "-X", "-M", "--decompress", "--null-data", "--bz2decompress", "--xz", "--lzma", "-f", "--file"],
  rg: ["--pre", "--pre-glob", "--hostname-bin", "-z", "--search-zip", "-L", "--follow", "-f", "--file", "--ignore-file"],
  find: ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint*", "-fls", "-L", "-H", "-follow"],
};

for (const flags of Object.values(COMMAND_FLAGS)) Object.freeze(flags);
Object.freeze(COMMAND_FLAGS);
for (const flags of Object.values(ALWAYS_BLOCKED_FLAGS)) Object.freeze(flags);
Object.freeze(ALWAYS_BLOCKED_FLAGS);
