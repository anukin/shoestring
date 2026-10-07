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

UNVERIFIED: The reconstructed implementation's full gate, browser captures and
separate-process persistence proof are pending at this checkpoint.

UNVERIFIED: Live model entitlement, live provider inference, screen-reader
coverage and binding these profiles to approved execution were not verified.
Saving configuration never authorizes inference. Execution binding remains a
separate contract even though immutable snapshot lookup is implemented.
