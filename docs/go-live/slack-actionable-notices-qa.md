# Slack actionable notices verification — 2026-10-07

Implementation: `extract-v7`, `judge-v2-slack`, based on main `3e342c8`.
This is code and synthetic-model verification, not a production rollout or a live Slack installation test.

## Behavior

- External app/bot messages may enter the existing authorized, AI-consented Slack intake scope. Actual channel-wide mentions also qualify; channel links and literal mention-shaped text do not.
- A broadcast alone does not subscribe the entire thread. Taskforce-authored messages and unauthorized installations remain excluded.
- Concrete personal app reminders and individual broadcast duties enter Review. General information, optional suggestions, another person's work, app-owned work, and declined requests remain excluded.
- The Flex example produces a self-evaluation/peer-reviewer task in Review with no inferred due date when the original time zone is unknown.
- An existing Gmail task repeated in Slack keeps one action, adds Slack evidence, and preserves its existing due date.

## Local verification

| Check | Result |
| --- | --- |
| ESLint | Passed, no warnings |
| Typecheck | Passed |
| Full automated tests | 182 files / 2,340 tests passed, including DB tests |
| Focused Slack DB persistence tests | 11 passed |
| Next.js production build | Passed |
| Independent code review | No unresolved introduced findings |
| Diff whitespace check | Passed |

The first build invocation propagated Node's `--env-file` flag into a Next.js worker and failed with `ERR_WORKER_INVALID_EXEC_ARGV`. Running `npm run build` with the same environment inherited by a child process passed; no application change was needed.

## Real-model evaluation

Models: `z-ai/glm-5.3-flash` and `typesafe/jev-1.13` (response version `1.13-20260917`). The baseline used 87 fixtures; the final run used 95, adding seven single-source cases and one Gmail/Slack sequence. Precision/recall below count automatic and Review candidates together.

| Cohort | Baseline | Final |
| --- | --- | --- |
| Common 59 single-source cases | 69 TP / 3 FP / 4 FN; precision 95.83%, recall 94.52% | 68 TP / 3 FP / 5 FN; precision 95.77%, recall 93.15% |
| Existing 19 message single-source cases | 21 TP / 1 duplicate FP / 0 FN | Same |
| Seven new single-source cases | Not present | 5 TP / 0 FP / 0 FN; owner and due accuracy 100% |
| All final single-source cases | — | 73 TP / 3 FP / 5 FN; precision 96.05%, recall 93.59%; owner and due accuracy 100% |
| All final sequences | — | 29/30 expected actions; one miss, one Review-only extra; no splits, overmerges, or field errors |
| Gmail then Slack reminder | Not present | One action, two source quotes, unchanged October 9 due date |
| Answering questions | 8/8 | 7/8; one answer-language/wording expectation failed |

The final Slack-tagged single-source cases scored 14 TP / 0 FP / 0 FN. Flex and an alternate app reminder each also passed a separate targeted model run with Review and null due. Explicit human acceptance remained eligible for automatic intake; the broadcast and uncertain `@here` examples stayed in Review. Model API failures: zero. Final full-run cost: approximately $0.182.

### Failures and limits retained

- The first implementation missed the Flex conditional reminder. Connecting adjacent task/deadline and required-next-step lines in the Slack-specific extraction/Jev policy fixed it; the final full and targeted runs passed.
- Independent review found that literal mention-shaped text in structured Slack fields could manufacture an intake trigger. Literal fields are now escaped before detection, with focused regressions.
- The final full run missed `seq-slack-heldout-cancel-hearsay`: no initial action existed, so the later cancellation was unmatched. An unchanged-code targeted rerun passed 1/1 and ended in `dropped`. The aggregate failure artifact does not retain the initial extraction/Jev response, so the exact first-stage cause is unresolved. A successful rerun is not a stability guarantee.
- Remaining single-source failures concern group ownership in meetings, an email contract request, a namesake meeting assignment, tentative meeting/email promises, and the pre-existing duplicate in `launch-channel-long-thread`. Meeting/email prompt content and rules were not changed. Their run-to-run differences do not establish causality or a quality improvement from this change.
- One meeting sequence produced an extra tentative Review item; one unchanged ask case answered in Korean and failed its expected English wording. These are reported rather than counted as passes.
- No real workspace event, live user action reprocessing, OAuth setting, production DB write, native binary replacement, or production deployment was performed.

## Evidence and rollout

Local logs and comparisons: `/Users/daniel/.codex/qa-artifacts/taskforce-slack-notices-20261007/`.
Ignored model result files:

- Baseline: `2026-10-07T06-27-54-218Z-extract-v5-judge-v5+judge-v6-meeting+judge-v7-document+judge-v7-document-self.json`
- Final full: `2026-10-07T06-48-41-096Z-extract-v7-judge-v2-slack+judge-v5+judge-v6-meeting+judge-v7-document+judge-v7-document-self.json`
- Cancellation rerun: `2026-10-07T06-49-56-650Z-extract-v7-judge-v2-slack.json`

Before production rollout, align the native pre-connection disclosure and bilingual published scope with [the prepared scope copy](../legal/slack-notices-scope-draft.md). Current policy version/date and native UI are unchanged. Merge deploys production, per [HANDOFF](../HANDOFF.md#2-작업-규칙-저장소-소유자와-합의).
