# Taskforce-managed Codex conversations

Codex sessions open in the native agent tree with the selected conversation and a composer. The first message forks the source history into a separate conversation owned by Taskforce. Subsequent messages resume that managed conversation. The original Codex runtime is never resumed or sent a turn.

Taskforce owns a dedicated `codex app-server --listen stdio://` process. The source-to-managed mapping is stored locally per Taskforce account. Closing the panel keeps its run alive; account changes and app termination close the owned clients. Managed roots are omitted from the imported session list so reopening the source reaches the same continuation.

## Interaction

- Main accepts messages directly. A child composer attaches the selected task ID and title and sends to managed Main. The source child is historical context, not an independently resumed runtime.
- The tree preserves original child context and includes children of the managed conversation.
- Stop interrupts the managed turn. Execution approvals and structured questions appear in Taskforce and require an explicit response.
- Owned sessions request workspace-write, on-request approvals and a human reviewer. The effective policy is validated before starting a turn. Forking history uses the existing workspace, not a new worktree.
- Failed delivery retains the draft. An uncertain acknowledgement blocks automatic retry to avoid duplicate turns.
- The secondary Open in Codex action targets the managed conversation once created.
- Opening a Codex conversation focuses its panel. During a turn the composer shows activity, including a separate preparing-history state while Codex compacts imported history; Stop remains available.

## Transport

The stdout reader consumes available pipe bytes with POSIX `read` and assembles bounded JSONL frames. Foundation's filling `read(upToCount:)` can wait for its entire requested buffer even when a complete short response has arrived and the server keeps the pipe open. A real open-pipe regression protects against that stall. History compaction is separately reported by provider events and must not be mistaken for failed delivery or automatically retried.

## Scope

This uses the installed and authenticated Codex CLI. It does not attach to a desktop-owned stdio server or claim parity with every Codex desktop plugin. Unsupported client-tool requests fail explicitly. Local history is read through the existing bounded reader; credentials and transcripts are not written to diagnostic logs.

Fixture tests cover protocol routing, approval responses, interruption, uncertain acknowledgements, account isolation, draft retention and historical child context. Installed-build provider verification is recorded separately in the pull request after it is performed.
