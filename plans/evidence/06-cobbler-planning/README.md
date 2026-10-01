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

The bounded hermetic task does not reopen iteration-5 acceptance.

REPO-INSPECTION: `plan-foundation.md` records the subsequent inert manual-plan
foundation. Its feature tests establish new APIs; they do not claim a behavioral
regression against a predecessor that lacked those APIs. The exact allowlist adds
only that evidence file; the supplied planning milestone remains ignored.
