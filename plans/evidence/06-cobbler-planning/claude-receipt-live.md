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

UNVERIFIED: live execution is pending at registration commit time.
