# Existing beta Mac agents

`AGENT_BETA_USER_IDS` is a private deployment snapshot of the approved existing beta accounts. Record the cohort count and verification time in private deployment evidence; do not put account IDs or email addresses in source. Exclude review, deleting and unconfirmed accounts. New signups are never added automatically.

Use comma-separated UUIDs with no whitespace or empty entries. Missing, empty or malformed configuration denies the entire cohort. `CONVERSATIONS_V2_ENABLED`, the selected adapter flag, agent execution permissions, provider controls, policy, AI consent, leases and approvals still apply. This setting grants none of those permissions. Billing seed/notice state is unrelated.

Denied users cannot create agent conversations, start or resume a turn, lease a new execution, approve a tool, answer a question or resolve a path conflict. Review and return summaries omit agent decisions. Existing heartbeat, completion events, acknowledgement settlement, cancellation, Stop and delivery readback remain available; any next-turn kick is checked again. Conversation global-off behavior remains unchanged: no authentication or database calls.

Rollback by clearing the snapshot or disabling the adapter. Do not delete agent records or prevent cancellation. Verify an allowed account and an outsider before broadening any deployment permission. Do not enable Codex, billing, automatic/full execution or Taskforce v1 actors as a side effect.

The agent-only database permission is `agent_execution_allowed(user_id, adapter)`. Bridge redelivery uses this exact-adapter helper rather than querying generic `execution_actors`; provider/global/mode/tool checks still follow. Apply its separately reviewed migration before deploying the caller. No grant rows are seeded by the migration.

Claude Code registry evidence (D3a-s, 2026-10-21): real `claude` 2.1.241 R1 runs verified `revocation`, `read_only` and `target_scope` in `src/lib/agents/registry.ts`, so the registry now grades Claude Code `write` in all policy modes (R1-04 revocation was a scripted decider, not a live server policy change; budget stays unverified). This changes only what the registry can grant. The adapter flag, beta cohort, `execution_controls`, AI consent, leases and approvals still decide whether anything runs, and nothing here enables them. Roll back by setting those three `verified` values back to `false`.
