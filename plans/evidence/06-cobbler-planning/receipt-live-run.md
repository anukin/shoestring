# One live model-plan execution: receipt

VERIFIED (user direction): after discussing the remaining semantic execution
proof, the user asked, "can you do the evidence backed run once?" Existing
authorization selects `chatgpt/gpt-6-luna` through the subscription without a
spending cap. That request authorized this selected, previously exported
receipt plan and its recorded execution limits. Approval is attributed to
`human:user`, not to a fictional reviewer. Main/direct-push authorization
overrides the standing isolation/PR workflow. Baseline: `b72693a6867a6e82507de2b960645565d466352c`.

## Result: failed safely, not complete

VERIFIED: one real provider task ran through production-configured Shoestring
admission, claim, lease, durable Oban dispatch, `ElfEffect`, the Codex app-server
adapter and an allocated Git worktree. The requested saved model was
`gpt-6-luna`. The provider completed and changed only `total_cents` in `pantry.py`.
Its named unittest passed. No implementation commit was created: Shoestring's
real task acceptance rejected the dirty worktree and recorded `needs_user`.
The dependent receipt task never dispatched. There are **0 accepted tasks,
1 consumed attempt and 1 provider run**, with **0 active Elves**.

VERIFIED: restart preserved the selected canonical execution snapshot
byte-for-byte, including the gate failure and consumed counters. The public
`ExecutionControl.continue/2` returned `needs_user` with no job. The source
fixture's HEAD remains `84876c7022c9712aedd38cbc1f767cb58156be17` and its checkout
is clean. The failed worktree and its uncommitted change are preserved. No
reset, cleanup, manual implementation commit, acceptance override, additional
attempt, amendment or provider retry was used to make the run look successful.

UNVERIFIED: successful model-plan task acceptance, receipt execution, final
global acceptance, and restart between accepted tasks. This run does not close
iteration 6. It demonstrates live failure containment and restart preservation.

## Plan and execution boundaries

VERIFIED: the imported plan is the unchanged
[bound receipt proposal](luna-evaluation/receipt/bound-plan.json), digest
`13ba4b39f66d01dd9d1e37a119803e73f85caebdb3792181d134843138d8decd`.
It retains the earlier disclosed base-revision substitution and all model task
content. The plan permits **1 attempt / 300 seconds per task**, **2 attempts /
600 seconds per goal**, in order `implement-total` → `render-receipt`.
The proposal and approval entered through the normal `Cobbler` plan APIs;
execution entered through `ExecutionControl.start/3`, the same domain boundary
used by the execution CLI. Goal creation and saved profile setup used production
changesets/context APIs. No test helper, fake transport, fake capacity reading,
injected admission function, simulated provider or injected gate runner was used.

REPO-INSPECTION: [the explicit live driver](../../../tools/live_eval/iter6_receipt.exs)
boots with `MIX_ENV=prod` and a disposable state directory, and suppresses raw
diagnostic logging. Only the Codex capacity monitor is enabled. Queues start
paused and the driver explicitly resumes plan execution and dispatch. It pauses
dispatch after the first delivery so a dependent could be held for restart;
in this run the dependent was never allocated. The driver does not call worker
`perform/1` directly or write lifecycle/projector rows to force progress.
Pruning plugins are disabled in this disposable node; nothing is deleted.

REPO-INSPECTION: execution requests ephemeral provider history, disables the
shared daemon and reasoning summaries, and disables delegation, hooks, plugins,
apps and web search. Saved agent instructions require only the assigned task,
unchanged tests, no packages/network, a configured-author commit without
attribution trailers and a clean worktree. No shared Git writable roots were
added. Provider storage behavior was not independently audited.

VERIFIED: commands were foreground Python `subprocess.run` invocations with
closed stdin, fresh in-memory endpoint secrets and external deadlines. The
entrypoint was `mix run --no-start tools/live_eval/iter6_receipt.exs PHASE`.
Phases were `preflight`, `setup`, `first` (admission-held), `first` (one live
attempt), and `failure-audit`. `failure-audit` passed again after command
execution in the driver was changed to the bounded `GateProcess` helper; that
repeat made no model inference. State directories, database and provider IDs
are not committed.

REPO-INSPECTION: before committing the driver, its failure handler was changed
to await any still-active owned Elf rather than automatically cancel it. A
verification deadline alone must not interrupt useful work. This change did
not rerun provider inference; the observed run had already terminated normally.

## Findings and changes

VERIFIED: read-only production monitor preflight on installed CLI **0.162.0**
completed initialize/account/rate-limit reads and observed both windows. The
registry correctly classified that previously untested version as degraded.
The observed protocol established compatibility for these capacity operations,
so this change adds exactly `0.162.0`, retaining `0.150.1`; other versions remain
degraded. It does not declare every future CLI compatible.

VERIFIED: the first execution delivery was blocked with
`require_confirmation / missing_window_five_hour`, with **0 runs and 0 consumed
task attempts**. Codex's normalized windows retained `primary` and `secondary`,
but admission expected `five_hour` and `weekly`, and normalization discarded the
reported `windowDurationMins`. The corrected normalizer retains positive integer
durations in namespaced extensions. Admission now binds these provider labels
to policy windows using **300** and **10080** reported minutes. Missing, malformed
or other durations are not inferred from window position. Provider labels and
the observed usage/reset facts remain unchanged in evidence. The existing
Claude `seven_day` twin now reaches the weekly reserve check too.

VERIFIED: after that fix, the same durable intent received automatic admission
from actual observed capacity. Immediately before the task, the readings were
**20% primary / 10% secondary**, with reported durations **300 / 10080 minutes**.
These are account-level readings, not a measured cost attributable to this task.
The failed attempt consumed **20,077 ms provider time + 98 ms gate time =
20,175 ms**, retained across restart. Reported model token usage is unverified.

VERIFIED: the provider's public final message reports that shared Git metadata
access was denied. The observed worktree remains dirty at the original base;
the recorded gate failure is `gate_worktree_dirty`, with retry state `escalate`.
The independent local audit reran the total unittest: **1 test, OK**. The
baseline total/receipt gate had **2 tests, 2 assertion failures**; after the
model's change its combined invocation had **2 tests, 1 failure**, on the still
unimplemented receipt. No tests were edited.

REPO-INSPECTION: the session requests `workspace-write` at the owned worktree,
without an explicit shared Git metadata writable root. This is consistent with
the reported inability to commit. UNVERIFIED: a retained kernel-level Git denial
or attempted Git commit command. Normalized command evidence contains no
executed `git add`/`git commit`; a refusal before execution is not independently
established by those command records. A controlled commit-access fix must be
verified while preserving source-checkout protection. It is not implemented by
this change, and no broader filesystem permission was granted to force success.

VERIFIED: an initial direct Python subprocess probe showed a non-group-leader
Codex process. That was incorrectly generalized to Erlang's stdio transport in
a progress update. The actual production-port hermetic check passed against the
unchanged baseline: it is a group leader and preserves JSON-RPC stdin. The
finding was corrected, and no process ownership fix was made. That check is
capability evidence, not a regression lock.

## Retained evidence

VERIFIED: [receipt-live-run/](receipt-live-run/) contains the original structured
preflight/setup/outcome captures, both admission-stage captures, failed-state
snapshots, selected domain events, baseline/local test outputs, the unaccepted
code patch and public agent messages. A [SHA-256 manifest](receipt-live-run/sha256.json)
binds those files. Raw provider frames, hidden reasoning, credentials, absolute
home paths, machine process IDs and provider-generated session/item IDs are not
exported. Selected domain-event exports retain their payloads and application
identities; they are not presented as a raw provider transcript.

VERIFIED: [before restart](receipt-live-run/failed-before-restart.json) and
[after restart](receipt-live-run/failed-after-restart.json) are byte-identical.
[The failure audit](receipt-live-run/failure-audit.json) records blocked
continuation, unchanged source and no active Elf.
[The patch](receipt-live-run/unaccepted-total.patch) is unaccepted material work.
The normalized stream summary records **271 events**: **19 lifecycle,
241 output, 8 command, 2 tool and 1 result**. These counts are observations,
not token counts or a reasoning transcript.

VERIFIED: all **15** manifest hashes match and the artifact privacy scan passed.
`git diff --cached --check` reports four trailing-space lines inside the retained
Git patch: they are the patch's original blank context lines. The check passes
when that captured patch is excluded. Those evidence bytes were not altered to
silence a source whitespace check.

## Hermetic verification

VERIFIED: the first four new provider-window checks failed **4/4** because their
fixtures omitted the required observation timestamp. After correcting that
construction error, **4 tests, 3 failures** showed the actual behavior: healthy
Codex capacity required confirmation and known Codex/Claude reserve breaches did
not reach their hard reserve branch. A later development run had **84 tests,
2 failures** because the test incorrectly expected `defer` instead of the
existing `defer_until` result. That expectation was corrected, not widened.

VERIFIED: the corrected checks were verified against exact baseline production
sources from `b72693a`, loaded only into a separate test VM. The proof command
`MIX_ENV=test mix test /private/tmp/shoestring-window-regression/provider_window_admission_test.exs`
reported **4 tests, 3 behavioral failures**, seed **482220**. The checkout was
not reset or edited for that proof. The initial timestamp failures are not
claimed as the regression evidence. The final secondary-duration/swapped-order
case was added afterward and is not claimed as a pre-fix regression lock.

VERIFIED: the focused current-code command
`MIX_ENV=test mix test test/shoestring/cobbler/provider_window_admission_test.exs test/shoestring/cobbler/admission_evaluation_test.exs test/shoestring/harness/capacity_test.exs test/shoestring/harness/capacity/codex/stdio_transport_group_test.exs`
reported **84 tests, 0 failures**, seed **718058**, in **0.4 seconds**
(0.4 seconds async, 0.05 seconds sync). The final additional duration case is
included in the full gate below. All automated tests remain hermetic; the
provider run and capacity reads are separate, explicitly invoked manual work.

VERIFIED: the first `mix precommit` run reported **4 doctests, 1919 tests,
1 failure, 1 skipped (6 excluded)**, seed **412511**. The failure was the
registry matrix test still expecting only `0.150.1`; its exact version-list
assertion was updated to include the newly verified `0.162.0`. Both Node suites
passed (**52/52** and **8/8**). This is a deterministic expectation update,
not an intermittent failure or a relaxed compatibility check.

VERIFIED: the final `mix precommit` exited **0**. ExUnit reported **4 doctests,
1919 tests, 0 failures, 1 skipped (6 excluded)**, seed **607493**, in
**173.2 seconds** (9.0 seconds async, 164.2 seconds sync). Node suites reported
**52 tests, 52 pass, 0 fail** and **8 tests, 8 pass, 0 fail**, with zero skips.
The manual driver's failure handling changed while the hermetic tests ran;
no production module or test changed after the gate began. A subsequent
`mix format --check-formatted` first flagged one required blank line in that
driver, then exited **0** after it was added. No provider inference was repeated.

## Remaining closeout

REPO-INSPECTION: a successful repeat requires controlled commit access and a
new explicitly approved execution allowance. The failed task's one allowed
attempt is consumed; it must not be silently reset or retried. Success still
needs accepted material commits for both tasks, task/global gates and restart
between accepted tasks. The production subscription planner adapter is separate
integration work: this run imports a saved model proposal and makes no planner
call. Existing planner admission/allowance contracts are not relaxed.
