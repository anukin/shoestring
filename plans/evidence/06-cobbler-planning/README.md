# Iteration 6 evidence

REPO-INSPECTION: This directory follows the iteration-5 identifier and evidence
conventions. UUID fixtures must preserve their version and variant; synthetic
UUIDv7 example: `01950000-0000-7000-8000-000000000001`.

No credentials, provider-generated identifiers, machine identifiers, absolute
home paths, or hidden model reasoning are stored here. Commands use `$WORKTREE`
for the implementation worktree and `$REGRESSION` for its owned proof worktree.

Claim labels: VERIFIED means command output from this run or a committed
artifact; REPO-INSPECTION means inspected repository code; SCHEMA-ONLY means a
schema without runtime integration; UNVERIFIED means not verified.

## Documents

- `hermetic-lifecycle.md` — the iteration-5 follow-up end-to-end lifecycle
  test. The bounded hermetic task does not reopen iteration-5 acceptance.
- `plan-foundation.md` — work package A (goal and task contracts) plus the
  durable plan revision / approval / rejection foundation and its event
  replay. No executor, no model planner, no amendment orchestration, no
  approval UI.
