# Claude Code sequential receipt verification

## Registration before provider execution

VERIFIED (user direction): after the proposed two-task Claude test, the user said
they have Codex and Claude Code subscriptions, not to worry about budgets, and
"Just run it". This authorizes the live Claude subscription verification without
a spending cap. The reviewed receipt contract still limits execution to one
attempt/300 seconds per task and two attempts/600 seconds per goal. No automated
test calls a provider. Direct-main development/push remains explicitly authorized.

REPO-INSPECTION: the test imports the same receipt proposal as the Codex proof,
changes only its repository base for a new disposable fixture, and binds a saved
Claude Worker role with explicit model alias `opus` (the user's configured choice).
Runtime initialization must identify the actual model/version; configuration alone
is not evidence of the resolved model. Previous Codex failures/successes remain
unchanged. This evaluates orchestration through another harness, not a new planner.

VERIFIED: read-only preflight found Claude Code **2.1.296**, authenticated through
`claude.ai`, subscription type `pro`. The first sandboxed authentication check
reported no login; the keychain-access check succeeded. Only authentication method,
login status and subscription type were retained; no credential contents were
exposed or exported.
The unmodified Python fixture baseline fails **2 tests / 2 behavioral assertions**.

REPO-INSPECTION: Claude's real passive monitor starts with unknown capacity and
`conservative_partial` support; it cannot establish automatic admission. The
production plan path previously had no operator-confirmation entry point, although
handoffs did. The new `confirm-capacity` CLI/domain operation binds one human
confirmation to one execution, approved revision/digest, dependency-ready task,
attempt, provider/adapter and account scope. A resulting admission decision consumes
it, even when a hard stop refuses admission. Another task/retry needs another
explicit confirmation. Admission still reads the real Observatory, records the
unknown reading honestly and enforces hard reserve/quota/compatibility/occupancy
checks. A deterministic decision identity/idempotency key prevents concurrent
evaluators from minting multiple decisions using the same confirmation.

REPO-INSPECTION: the manual driver uses production `ExecutionControl`,
`PlanExecutionWorker`, `DispatchWorker`, Elf and `ClaudeHeadless` transport. It
configures a local launcher that preserves the adapter's pinned model and task
prompt, then execs the real CLI. The launcher adds safe/restricted mode, empty
optional settings sources/MCP, disabled skills/session persistence, medium effort,
and an enforced Bash sandbox. Permission bypass and unsandboxed fallback are off.
Only Bash is exposed. Writes are configured for the owned worktree/private index,
objects and branch-ref/log roots; source writes and Bash reads of the home
directory are denied; Bash network domains are empty. This is explicit evaluation
launch configuration, not a claim about the adapter's default permission policy.
The default adapter still enables permission bypass unless configured otherwise.
Claude's default temporary-directory access remains; the configured extra roots
must not be described as an exhaustive OS write allowlist. Source isolation is
checked against the complete fixture bytes after execution.

Protocol/configuration sources: [CLI reference](https://code.claude.com/docs/en/cli-reference)
and [Bash sandbox configuration](https://code.claude.com/docs/en/sandboxing).
Installed help confirms the options. `--bare` is deliberately unused because the
installed version disables OAuth/keychain access in that mode; safe mode preserves
normal subscription authentication.

## Registered acceptance

1. Task one produces a material, clean commit implementing integer-cent totals;
   its production gate passes without changing supplied tests.
2. The application/node stops with task one accepted, no active Elf and task two
   unstarted. A separate boot reproduces the exact canonical snapshot.
3. After a separate task-two capacity confirmation, normal workers execute the
   dependent task from task one's commit and accept exact receipt formatting.
4. Both task gates and the global gate pass. Exactly two attempts/runs are charged;
   the approved plan, provider/model binding and accepted evidence persist.
5. The complete source fixture remains byte-identical, including Git metadata;
   supplied tests remain unchanged. No planner call occurs.
6. Retain failures and configuration differences. Export only selected canonical
   facts, public answers, diffs, gate results and safe numeric observations; no raw
   frames, hidden reasoning, credentials, provider IDs or home paths.

REPO-INSPECTION: this does not test resuming the same Claude session, real quota
refusal, cross-provider transfer, live planner inference or provider-side history
retention. Restart between completed tasks is distinct from harness-session resume.
An elapsed verification deadline alone must not kill an owned useful Elf; the driver
waits for terminal ownership before exiting on failure. No cleanup or GC is added.

## Pre-live verification and results

VERIFIED: the focused matrix passed **16 tests, 0 failures**, seed **261291**,
**11.7 seconds**. A full gate then reported **4 doctests, 1937 tests, 1 failure,
1 skipped (6 excluded)**, seed **207843**, **188.1 seconds**; Node **52/52** and
**8/8** passed. The failing new reserve fixture used wall time without pinning
the admission clock. It now explicitly uses the same fixed clock for snapshot,
ingestion, reset timestamps and admission, restoring the prior setting on exit.
No policy assertion, reserve or retry behavior was relaxed. The corrected focused
matrix passed **16 tests, 0 failures**, seed **508747**, **12.1 seconds**.
An earlier development matrix reported **13 tests, 1 failure** (seed **256135**)
before the reserve fixture supplied captured/reset timestamps, followed by
**14 tests, 0 failures** (seed **115364**) after the CLI case was added.

VERIFIED: loading only `ExecutionAdmission` from exact pre-fix `7e19ed7` in a
separate VM left the new confirmation schema/API intact. The positive admission
assertion failed behaviorally with `support_tier_conservative_partial` rather
than a missing module/signature: **1 test, 1 failure (6 excluded)**, seed **939337**.
The checkout was not reset or changed for this proof. Launcher checks are new
capability protection, not claimed as pre-fix regression locks.

VERIFIED: the same pre-fix proof with the final fixed-clock test also failed for
`support_tier_conservative_partial`: **1 test, 1 failure (6 excluded)**, seed
**497816**, **0.4 seconds**. The single confirmed decision is the regression lock;
the additional scope, hard-stop and concurrency cases are capability protection.

VERIFIED: corrected full gate `mix precommit` exited **0**: **4 doctests,
1937 tests, 0 failures, 1 skipped (6 excluded)**, seed **784719**, **190.6 seconds**
(10.5 async, 180.0 sync); wall time **194.140 seconds**. Node suites passed
**52/52** and **8/8**, zero skips. The gate had closed stdin and a 480-second
foreground bound. No production/test/launcher changes followed this gate.
The manual launch environment suppresses global/system Git configuration,
interactive Git prompts and optional Git index writes; private copied author
configuration remains available. Shell commands inside Claude use its enforced
Bash sandbox. The exact privacy-scoped artifacts will accompany the result.

UNVERIFIED (at registration commit time): live execution was pending. The
registration above was committed and pushed in `f24aef16b1cf424bd9a9a140c20dfb849daa13bb`
before either provider task started. The following results are subsequent.

## Live results (2026-10-13)

VERIFIED: both phases ran the registered commit with no tracked changes. Each
phase was a foreground `MIX_ENV=prod mix run --no-start
tools/live_eval/iter6_claude_receipt.exs PHASE` process with closed stdin and a
fresh in-memory endpoint secret. The disposable state and source fixture were
separate from the application checkout. Provider, transport, admission policy,
Observatory, workers and gates were real; no snapshot, terminal event, lifecycle
row or worker result was injected to force success.

VERIFIED: the new bound plan digest is
`61c26213cbbb82ac13698ba58058bbfad6b928949382936b491c9879ca3bb67b`, with base
`2a68bd7c087f05f31dac6c98ff2c1dd0894f0105`. Only that base differs from the
previously bound proposal; tasks, dependencies, gates and budgets are unchanged.
Its immutable approval and saved Claude role are retained in
[domain-events.json](claude-receipt-live/domain-events.json).

| Task | Accepted commit | Production gate |
| --- | --- | --- |
| `implement-total` | `8daa96e36516336398482b44dbaf4c455dc794bb` | 1 test, OK; 266 ms |
| `render-receipt` | `c0ec06161393e462eea8e0b608a8ad5eae5d2867` | 2 tests, OK; 279 ms |

VERIFIED: the first phase ended with task one accepted, one completed run and
task two unstarted. The node exited. A separate process boot reproduced the
exact canonical snapshot before the second confirmation and dispatch. Task two
started from task one's accepted commit. The global gate then passed **2 tests**,
exit 0, **273 ms**, at task two's commit. See [restart](claude-receipt-live/restart.json),
[accepted diffs](claude-receipt-live/result.json), and
[final canonical state](claude-receipt-live/final.json).

VERIFIED: each CLI's initialization reported **`claude-opus-5-5`**, CLI **2.1.296**,
permission mode **`dontAsk`**, and tools **`[Bash]`**. This is runtime-reported
model identity, not the model's prose self-identification or a hardware audit.
The saved profile retains the explicit `opus` alias across restart. Both CLI
processes used the registered isolated launcher and enforced-sandbox settings;
the requested configurations are retained. No separate kernel write-denial
probe was performed for Claude. The complete **38 source-fixture files**, including
Git metadata, remain byte-identical. Both task worktrees are clean, change only
`pantry.py`, and retain every supplied test byte. Independent local reruns pass
**1 test** at the first commit and **2 tests** at the second. Commit messages have
no authorship/contributor trailers. [Runtime](claude-receipt-live/runtime.json),
[audit](claude-receipt-live/audit.json),
[source hashes](claude-receipt-live/source-before.json).

VERIFIED: two distinct human confirmations admitted exactly two task decisions
with reason `confirmed_support_tier_conservative_partial`; both observations
retain confidence `none`, unknown capacity and degraded version compatibility.
The unconfirmed dependent was refused between them with
`support_tier_conservative_partial`, allocating no run until its own confirmation.
The registry was not widened to claim verified Claude 2.1.296 capacity telemetry.
This is explicitly confirmed execution, not automatic capacity admission.

VERIFIED: final canonical plan status is completed, with **2 accepted tasks,
2 attempts, 2 completed runs, no active plan run and 0 planner requests**.
Charged duration is **47,565 ms**: **46,747 ms provider intervals + 818 ms gates**;
remaining goal allowance is **552,435 ms**. Phase wall times were **37.612 seconds**
and **54.450 seconds**, including boot/delivery waits. Subscription usage/cost
attribution is not measured. The generic goal row remains `active`; canonical
plan completion is authoritative. Both lease rows are `checkpoint_required`,
which the lease state machine defines as terminal. Those distinctions remain
recorded rather than rewriting rows.

VERIFIED: **25 normalized events** were observed: **7 lifecycle, 14 command,
2 output and 2 result**. Seven command start/end pairs and two normalized public
output previews are exported separately without tool stdout/stderr diagnostics.
Registration item 6 is partial for public answers: the existing Claude normalizer
caps public text at **500 characters**; both
recorded previews reach that cap. They are not complete final answers, and the
discarded text cannot be recovered from this packet. Acceptance relies on actual
commits and gate evidence. This existing diagnostic-text limitation is retained
for follow-up; the transport's oversized-frame refusal is a separate boundary.
No provider IDs,
raw frames, credential contents, process IDs or hidden reasoning are exported.
Disposable fixture paths are substituted with `$EVALUATION`; the home-directory
deny rule is substituted with `$USER_HOME`. Other selected content is unchanged.
The first export attempt selected UUIDs as binary against SQLite's text UUID
columns and stopped before producing an audit; selection was corrected to text,
and the final export asserts both runs and both confirmed admissions are present.
The [manifest](claude-receipt-live/sha256.json) binds **28 artifacts**, whose hashes
and privacy scans passed. Historical failure captures and Codex packets are unchanged.

REPO-INSPECTION: this closes the missing successful iteration-6 sequential
execution/restart proof through Claude Code, alongside the Codex proof. Human
iteration acceptance remains separate. Same-session Claude resume, real quota
refusal classification and subscription planner inference remain unverified;
the generic goal-row status difference and default adapter permission policy
and bounded diagnostic-output behavior remain explicit follow-ups. No additional
provider run is implied by closure.
