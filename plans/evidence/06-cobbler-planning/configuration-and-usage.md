# Configuration and usage implementation

REPO-INSPECTION: This product follow-up implements Usage, Agents and Settings,
persisted agent definitions, immutable revisions and CLI snapshot lookup.
It does not implement CLI approval, executor binding or amendment/replan.

## Recovery and regressions

VERIFIED: The earlier temporary worktree disappeared. The pushed checkpoint
`78b3425` survived and was restored into a new isolated worktree. Later fixes
were reconstructed; earlier screenshots and uncommitted documentation were
not recovered. Earlier gate counts are not used to certify this reconstruction.

VERIFIED: Against application code at `78b3425`, the six-file targeted command
reported **27 tests, 4 failures**, seed **844314**. The existing legacy-redaction
and invalid-default-agent tests failed on their behavioral paths. One failure
was a fixture clock captured before observations were written; another was a
new test fixture violating a database CHECK constraint. Neither was hidden.
After correcting the new fixture, `mix test test/shoestring/usage_test.exs:88`
reported **1 test, 1 failure (4 excluded)**, seed **426471**, because the stored
snapshot decoder rejected the redacted credential marker. This is behavioral
regression evidence against `78b3425`.

VERIFIED: `node --test test/ui_live_socket.test.js` against checkpoint browser
code reported **1 test, 0 pass, 1 fail**: no LiveSocket construction or connection
occurred. The reconstructed browser bootstrap reports **1 test, 1 pass, 0 fail**.

VERIFIED: After fixes, the bounded targeted command below passed with
**30 tests, 0 failures**, seed **821263**:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/agent_profiles_test.exs test/shoestring/usage_test.exs test/shoestring_web/live/configuration_live_test.exs test/shoestring_web/live/usage_live_test.exs test/mix/tasks/shoestring_agents_test.exs test/shoestring_web/live/health_live_test.exs test/shoestring_web/live/browser_client_test.exs < /dev/null
```

VERIFIED: Redaction tests assert sensitive text is absent, allowance values and
safe scope labels remain, and stored evidence is unchanged. Tests cover create,
edit, duplicate, stale drafts, provider/model changes and settings validation.

## Acceptance status

VERIFIED: Native Firefox saved a synthetic Builder agent revision through the
connected LiveView form. A separate CLI process read revision 2 with the exact
saved purpose and digest. Restarting the local server retained that edit;
`show builder --revision 1` retained the original purpose. The fresh-state
`list` command also initialized successfully without starting provider inference.
The final save used for review captures created revision 3.

VERIFIED: All eight final desktop/mobile full-page captures were opened and
inspected. The fresh finish reviewer found insufficient inner-label contrast
and a mobile success toast covering the brand. One corrective batch made labels
opaque and moved mobile flashes to the bottom. The reviewer reopened all eight
captures and confirmed both findings resolved; computed label contrast is
14.31:1. This was a scoped UI verdict, not repository-wide certification.
The single detector run produced `[]`.

VERIFIED: Captures are repository-owned synthetic preview evidence under
`.impeccable/review/`: Agents, Editor, Settings and Usage each have a desktop and
mobile `-final-fullpage.png`. They show the Focus navigation, editable named
roles, shared observed allowance, explicit stale/unknown states and recorded
history with gaps. No live provider call or entitlement check was performed.

VERIFIED: The fresh documenter opened all eight captures and added `DESIGN.md`
and `.impeccable/design.json`; YAML/JSON validation reported 23 resolved token
references, seven scoped component previews and eight canonical sections.
Provisional creative language and preview-only ramps are labelled separately
from extracted source tokens.

## Full-gate failure and transaction boundary correction

VERIFIED: The first gate attempt stopped on formatting in the standalone CLI
repository setup; that formatting was corrected. The next completed gate passed:
**4 doctests, 1720 tests, 0 failures, 1 skipped, 6 excluded**, seed **951776**.
After the UI review correction, the next completed run reported **4 doctests,
1720 tests, 1 failure, 1 skipped, 6 excluded**, seed **345459**. Both runs passed
the Node suites: **52 capacity tests** and **8 UI tests**. The observed test-suite
failure was **intermittent, 1 of 2 completed runs before the backend correction**.
The red result is retained rather than replaced by a rerun.

VERIFIED: The failing concurrent decision replay returned a bare
`{:error, :rollback}`. The locked DBConnection source documents that sentinel
for an aborted transaction or closed connection; `Plans.run_transaction/2`
previously passed it through despite promising structured storage refusals.
The shared proposal/approve/reject boundary now returns `:database_conflict`
with `kind: transaction_aborted` and an instruction to reread durable state.
It does not infer contention from a sentinel whose cause is unknown. Existing
identical proposal replay still resolves from durable content and digest.

VERIFIED: New boundary fault-injection tests against production code at
`d93a488` reported **4 tests, 3 failures**, seed **98835**. Proposal, approve and
reject failed because the actual result was the bare sentinel; the durable
proposal replay already passed. After the correction, this focused command
passed **41 tests, 0 failures**, seed **82646**, including the unchanged real
SQLite approval race tests:

```sh
perl -e 'alarm 240; exec @ARGV' mix test test/shoestring/cobbler/plan_transaction_abort_test.exs test/shoestring/cobbler/plan_approval_race_test.exs test/shoestring/cobbler/plans_test.exs < /dev/null
```

REPO-INSPECTION: The new repo double injects DBConnection's documented result
without executing writes. Assertions defend unchanged revisions, decisions and
event counts and no publication; it is boundary fault injection, not a new
proof of real connection loss. The full-suite failure itself observed the real
concurrent path. This backend correction expands the UI slice to repair its
required gate; no race assertion, timeout or retry policy was widened.

VERIFIED: The final full gate after the correction completed with exit 0:
**4 doctests, 1724 tests, 0 failures, 1 skipped, 6 excluded**, seed **269623**,
in **154.4 seconds** for ExUnit. The Node capacity suite reported **52 tests,
52 pass, 0 fail**; the Node UI suite reported **8 tests, 8 pass, 0 fail**.
The exact command was:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

VERIFIED: `git diff --check` passed. Existing test-source warnings and expected
fault-injection logs were present; this is not a claim of warning-free output.

## Integration authority and remaining limits

VERIFIED (explicit user instruction): direct integration into `main` without a
new PR is authorized. This overrides the standing branch-PR / never-merge rule.
All implementation edits remain in an isolated worktree; the source checkout
is not used for implementation or integration.

UNVERIFIED: Live model entitlement, live provider inference, screen-reader
and full keyboard coverage, and binding these profiles to approved execution
were not verified.
Saving configuration never authorizes inference. Execution binding remains a
separate contract even though immutable snapshot lookup is implemented.
