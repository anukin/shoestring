# Explicit task retirement

VERIFIED: implementation follows the user's instruction to commit and push
directly on main without a branch or PR, overriding the standing workflow rule.

REPO-INSPECTION: an optional `retirements` list records stable task ID and a
reason of at most 500 characters. Full approved task contracts remain in the
new immutable revision. Only unaccepted identities from approved history may
retire. Required tasks cannot depend on retired tasks, and at least one task
remains required. Approved retirement entries cannot be removed or rewritten.
Historical contracts without this field retain their original canonical JSON
and digest; no default field is injected during replay.

REPO-INSPECTION: the CLI edit/show/approve flow exposes retirement reasons and
required task IDs. A proposal is inert; exact digest approval and separate
execution activation are required. Proposal, approval and activation each
recheck accepted evidence. An unresolved run still blocks replacement. Direct
run intent creation refuses a retired task binding. The executor skips retired
work while retaining all original identities, evidence and lifetime counters;
global acceptance must still pass against the accepted integrated worktree.

VERIFIED: focused final command:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_retirement_test.exs test/shoestring/cobbler/plan_contract_test.exs test/shoestring/cobbler/plan_amendment_test.exs test/mix/tasks/shoestring_plans_test.exs < /dev/null
```

76 tests, 0 failures; seed 641522; 0.9 seconds (0.2 async, 0.6 sync). This
includes all three evidence boundaries, active-run preservation, direct intent
refusal, initial-history rejection, immutable reasons/contracts, dependency and
input validation, CLI visibility, evidence/counter carryover and canonical
revision replay. An initial test compilation failed due to an imported helper
name conflict; it was corrected before the focused and full gates.

VERIFIED: isolated pre-change source is
`28c8cb15a161e46ba53c765895b165d8648fd009`. With the new retirement file copied
into that archive:

```sh
cd "$REGRESSION"
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_retirement_test.exs --only retirement_capability < /dev/null
```

1 test, 1 failure, 7 excluded; seed 12589; 0.2 seconds. The old contract
refuses the new retirement representation at proposal, before any new accessor
is used. This proves the new capability was absent. It is not claimed as a
regression reproduction of an old unsafe retirement path; no such path existed.

VERIFIED: final full gate:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0. 4 doctests, 1840 tests, 0 failures, 1 skipped, 6 excluded; seed 135688;
171.5 seconds (9.5 async, 162.0 sync). JavaScript: 52/52 and 8/8, zero failures.

UNVERIFIED: model-assisted replan remains separate. No live provider or network
was used for retirement verification.
