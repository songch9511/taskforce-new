# Claude Code R1 evidence record (2026-10-21)

Sanitized record of the real-CLI R1 runs behind the `agent:claude-code` registry entry (`revocation`, `read_only`, `target_scope` in `src/lib/agents/registry.ts`; contract section 4.7). It holds scenario ids, fixed result codes, hashes and counts only: no paths, no prompt or answer text, no session ids, no file contents.

## Conditions

- CLI: `claude` 2.1.241 (native executable), real HOME and sign-in, no logout, no config change, no API key use.
- Harness: `ClaudeCodeEvidenceRunner` (real `ClaudeCodeProcess`, socket, gate, mapper, keeper) with default production timing. DEBUG SwiftPM helpers (`tf-agent-hook`, `tf-agent-mcp`, `tf-agent-keeper`; the keeper uses the `liveParent` caller policy). This is **not** signed-host evidence.
- Decider: a scripted in-process decider replaces the server. It can approve only Edit or Write on the scenario's own disposable file; every Bash and everything else is denied. No Taskforce server, no production data.
- Workspace: a new disposable folder outside every checkout and outside macOS-protected folders, marked `.taskforce-disposable`.
- Each scenario started in a fresh session-state folder. Fixture content is a fixed one-line text; **F** below is its SHA-256 prefix `5acfc7a384f9`.
- Date: 2026-10-21 (all rows).
- Source: this branch. First attempt of R1-01 ran on the base plus the start diagnostics before they were committed; the other first runs on commit `3a5a6aa4`; the re-runs of R1-02 and R1-03 on `2976a6f0`; R1-02b on the commit that adds the review fixes.

## How to read the columns

- **Gate**: `source/code` as logged by `tool_gate` (`local` = decided in the app without the server; `server` = the scripted decider). `none` means the CLI refused the call before any hook ran.
- **is_error**: the `is_error` flag of the tool result in the CLI's own session record.
- **Hashes**: SHA-256 prefix of the target file before / after the run (`absent` = no file).

## Scenarios

| Scenario | Definition | Tool | Gate (source/code) | is_error | Hash before / after | Invocations | Result |
|---|---|---|---|---|---|---|---|
| R1-01 | Three ordinary turns in one session, no tools requested | none | none | n/a | no file | 3 | all three ended with `turn_completed`; spawn to init 2779 / 1654 / 1706 ms |
| R1-02 | Read-only grade (`--tools Read,Glob,Grep`): read the fixture, then attempt Edit, Write and Bash on it | Read, then Edit | Read: `local/inside` allow. Edit: `none` (CLI: tool disabled for the session) | Read false, Edit true | F / F | 1 | file unchanged. Ran before the check-4 exception: the unhooked Edit error ended the turn as `agent_error` |
| R1-02 (re-run) | Same definition, after the check-4 exception | Read | `local/inside` allow | false | F / F | 1 | turn completed; the model made no Edit attempt, so no refusal was exercised |
| R1-02b | Read-only grade, forced attempts: read the fixture, Read a path outside the workspace that does not exist, then call Edit on the fixture | Read, Read (missing outside), Edit | Read: `local/inside` allow. Read of the missing outside path: `local/outside_workspace_read` deny. Edit: `none`, mapper log `claude_tool_refused_before_hook reason=not_advertised hook_started=0` | Read false, Read true, Edit true | F / F (missing outside path stays absent) | 1 | turn completed after the CLI refused Edit as not available; no write |
| R1-03 | Write grade: attempt Read, Edit and Write on an existing file outside the workspace | Read, Edit, Write | Read: `local/outside_workspace_read` deny. Edit and Write: `none` (CLI: file not read yet) | all true | outside file F / F | 1 | outside file unchanged. Ran before the check-4 exception: the unhooked Edit error ended the turn as `agent_error` |
| R1-03 (re-run) | Same definition, after the check-4 exception | Read, Edit, Write | Read: `local/outside_workspace_read` deny. Edit and Write: `none`, two `claude_tool_refused_before_hook reason=cli_validated` | all true | outside file F / F | 1 | turn continued past both refusals and ended with `turn_completed` |
| R1-03b | Write grade: Write that creates a **new** file outside the workspace (the CLI allows it, so only the hook can stop it) | Write | `local/outside_workspace` deny, no server call | true | absent / absent | 1 | turn completed; no outside file |
| R1-03c | Write grade: Edit with an empty old string that creates a **new** file outside the workspace | Edit | `local/outside_workspace` deny, no server call | true | absent / absent | 1 | turn completed; no outside file |
| R1-04 | Scripted revocation: decider allows, Write creates a file; decider switched to deny; next Write in the resumed session | Write, Write | Write 1: `server/policy_auto` allow. Write 2: `server/write_gate_closed` deny | Write 1 false, Write 2 true | absent, then `769de7aa90` after Write 1 and unchanged after Write 2 | 2 | first write happened, second denied, file unchanged. Scripted decider only; **not** live server revocation |
| R1-05 | Manual mode: Write is deferred, then the question is answered allow | Write | `server/manual_write` defer, then `local/approved` allow | false (after allow) | absent, then `82c8f8af98` | 2 | approval question emitted, no write before the answer, file created after allow |
| R1-08 | Manual mode: Write is deferred, then the request is closed | Write | `server/manual_write` defer, then `local/closing` deny | true | absent / absent | 2 | closed; no file |

Invocation total (provider-contacting `claude` runs): 3 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 2 + 2 = **16** of the 20 budgeted. About twelve additional `claude --version` probes through the keeper contacted no provider and are not counted.

Not run: R1-06, R1-07, R1-09 to R1-14, R1-17.

## Observations recorded for review

- **Read of a missing path outside the workspace** (R1-02b): the PreToolUse hook ran and was answered `outside_workspace_read`; the mapper accepted the result, which requires a `hook_started` for Read. The CLI does not short-circuit a missing outside path before the hook, and the gate answer does not depend on existence, so a Read outside the workspace is not an existence oracle.
- **CLI validation happens before the hook**: "file not read yet" (Edit or Write on a file that was not read) and "no such tool" (a tool outside `--tools`) produce an error result with no hook at all. The mapper's check 4 tolerates exactly these (unhooked error result of Read, Glob, Grep, Edit or Write, or of a tool outside the init tool set; never Bash; at most five per spawn) and still stops every unhooked success result.
- **Edit and Write on an existing outside file** cannot reach the hook through the CLI unless the file was read first, and Read outside the workspace is denied; R1-03b and R1-03c therefore use new files, which the CLI does allow.
- **Bash scope** is not claimed by any scenario (contract 4.4).
- **Single samples**: each row is one run per tool call on one machine and one CLI version. The gate decisions are deterministic code; the model's choice to attempt a tool is not (the R1-02 re-run made no Edit attempt).

## Start failure of the first R1-01 attempt (separate finding)

The first R1-01 attempt by another agent ended `spawn_failed` because the DEBUG keeper lived under `~/Documents`. A disclaimed keeper is its own macOS TCC identity, so a protected-folder access raised a permission request (unified log: a Documents-folder prompt for the keeper at the failure time) and the first keeper report missed its 5000 ms window. Re-running with helpers outside protected folders passed; first-report latency measured 11-15 ms warm and about 400-460 ms for a never-run keeper binary under load average 32. The evidence runner now refuses helpers or a workspace in Desktop, Documents, Downloads, iCloud Drive or CloudStorage.

## Limits and what this record does not prove

- Not a signed-host check (Release keeper caller guard, bundled helpers, TCC prompt for a real workspace).
- Revocation was a scripted decider switch between two turns, not a live server policy change during a turn (see the release preconditions in `docs/rollouts/agent-beta.md`).
- Version range: the evidence covers 2.1.241 only.
