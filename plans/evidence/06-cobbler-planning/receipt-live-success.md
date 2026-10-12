# Receipt execution with controlled commit access

VERIFIED (2026-10-12): the newly authorized receipt evaluation completed through
real production admission, Oban workers, the Codex subscription harness,
independent owned Git worktrees and task/global gates. Both tasks have accepted
material commits. A full node stop/restart between tasks preserved the canonical
snapshot and continued the dependent task without a planner call.

## Authority and scope

VERIFIED (user direction): the user authorized fixing controlled commit access
and trying a new execution allowance. Existing direct-main instructions override
the standing worktree/PR workflow for this implementation; no additional branch
or PR is created. The live fixture itself remains isolated from its source.

VERIFIED: this evaluation has a new goal and approval, attributed to `human:user`.
It permits **one attempt / 300 seconds per task**, **two total attempts / 600
seconds per goal**, using exactly `chatgpt/gpt-6-luna`. The previous failed
[evaluation packet](receipt-live-run.md) is retained. Its temporary runtime
directory was unavailable in this session; I did not reverify that old database.
No old counters, worktree or evidence were reset or rewritten.

VERIFIED: only the original model plan's repository base binding changed for
the new disposable fixture. Task contracts, dependency order, gates and budgets
are unchanged. The original digest is
`13ba4b39f66d01dd9d1e37a119803e73f85caebdb3792181d134843138d8decd`;
the [new approved plan](receipt-live-success/bound-plan.json) digest is
`11886648ba7c6fc2cc5c6b6add0985a963fe9ebe924f311f4911c21a2f795399`.
Its base is `9123be25bb0a940044a9ab19fc628cac779e6890`.
Goal/profile setup, proposal and approval use production changesets/context APIs;
execution uses `ExecutionControl.start/3`, the CLI's domain entry point. Workers
are delivered by real queues. No provider, capacity, admission, gate or Elf
effect is faked, and lifecycle/projection rows are not edited to force progress.

## Controlled Git storage

REPO-INSPECTION: new plan task worktrees use independent per-run bare Git storage
outside the source checkout. A bounded local fetch copies only the pinned base;
no source object hardlinks, alternates, remote or repository configuration is
shared. The configured author name/email are copied. A dependent task copies
its base from the last accepted task's owning worktree, including when the
accepted run was a quota continuation sharing that worktree.

REPO-INSPECTION: Codex receives writable roots for the registered worktree,
its private index/HEAD directory, objects and branch/ref logs. The private common
directory itself, its hooks/configuration, other runs, and the source repository
are not granted write access. Temporary-root and network writes are disabled.
Physical path aliases are resolved; mismatched workspace bindings, redirected
common metadata, alternates and symlinked roots are refused. Existing shared
source worktrees retain the default sandbox and receive no extra Git roots.
Fresh and resumed turns use the same derived policy.

VERIFIED: a local `command/exec` probe used the production Erlang stdio transport
and this exact sandbox policy, with no inference call. It committed successfully
and left its disposable worktree clean. The operating system denied opening both
the fixture source file and source `.git/HEAD` for writing. See
[the native probe result](receipt-live-success/sandbox-probe.json).
This establishes the new policy's capability; it does not retroactively establish
the kernel cause of the earlier model-reported denial.

VERIFIED: the installed CLI is **0.162.1**. Read-only initialize/account/rate-limit
operations observed both 300- and 10080-minute windows. This exact version was
added to the capacity registry; previously verified versions remain listed and
future versions remain degraded. The pre-registration degraded result and the
later compatible observation are both retained. The old `sandbox macos` command
and a direct `sandbox` invocation without a required permission profile failed
before executing the probe; the successful check used the installed app-server
`command/exec` schema instead. No broader sandbox was substituted.

REPO-INSPECTION: independent storage trades additional local object copies for
source isolation. Failed/private storage is preserved; no new cleanup or GC is
introduced. Existing worktrees are not migrated. General large-repository disk
and performance costs were not measured.

## Execution evidence

VERIFIED: [the live driver](../../../tools/live_eval/iter6_receipt.exs) booted with
`MIX_ENV=prod` and disposable state. It requests ephemeral provider history,
disables the shared daemon, delegation, hooks/plugins/apps, web search and
reasoning summaries, and suppresses raw diagnostic logging. No provider-side
storage audit or provider token-cost claim is made. Planning imports a saved
model proposal; this is not a production subscription planner inference call.

VERIFIED: phase commands were foreground `mix run --no-start
tools/live_eval/iter6_receipt.exs PHASE` invocations with closed stdin and fresh
in-memory endpoint secrets. Setup/preflight used 120-second external bounds;
live phases use the driver's bounded verification waits. The repository's
stronger active-work rule takes precedence over killing a useful Elf on an
outer verification timer: a timed-out verification waits for an owned Elf's
terminal state. No deadline cancelled or duplicated useful work in this run.

VERIFIED: the first driver invocation failed before dispatch with `KeyError`
because an unstarted status has no `total_attempts` key. The corrected entry
checks a zero default **and an empty run list** before starting. Those guards
passed; this pre-dispatch failure consumed no model task attempt. Its failure
capture is retained. The first successful phase stopped the application/node
with task two allocated but dispatch paused. A separate node boot compared the
canonical snapshot for equality before resuming dispatch.

| Task | Accepted commit | Production gate |
| --- | --- | --- |
| `implement-total` | `fa0b1c41e9baec460ec427c13d3a8ab6f1d0bf2a` | 1 test, OK |
| `render-receipt` | `7359c17895741bef07bfda9ca8f718528758a00e` | 2 tests, OK |

VERIFIED: task two's base is task one's accepted commit. The global receipt/total
gate passed **2 tests** at task two's commit. Both worktrees are clean, only
`pantry.py` changed, and every supplied test file remains byte-identical to the
source. The source remains clean at its original base and has only its own
registered worktree. The independently rerun baseline fails **2 tests / 2
behavioral assertions**; the first local gate passes **1 test**, and the final
local gate passes **2 tests**. See [the audit](receipt-live-success/audit.json),
[accepted changes](receipt-live-success/result.json) and
[domain gate events](receipt-live-success/domain-events.json).

VERIFIED: final plan status is `completed? = true`, with both required tasks
accepted, **two attempts**, **two completed runs**, no active plan run, and
**zero planner requests**. Total charged duration is **86,298 ms**: **85,543 ms
provider intervals + 755 ms gates**. Remaining goal duration is **513,702 ms**.
Account windows were 16%/15% before task one and 18%/15% before task two; these
are account readings, not measured per-task usage. Token usage is unverified.
The audit explicitly retains the generic goal row's `active` status and the
two lease rows' `checkpoint_required` status; it does not claim those rows were
rewritten to terminal values. Completion here is the canonical plan-execution
fact and projection, with no active run, rather than a manually edited goal row.

VERIFIED: normalized observations total **449** events: **34 lifecycle, 393
output, 16 command, 4 tool, 2 result**. Selected command records contain executed
`git add`/`git commit`, their exit codes, and no provider-generated IDs. Public
completed commentary/final messages are retained separately. Raw provider
frames, hidden reasoning, provider identifiers, credentials, process identifiers
and machine diagnostic output are not exported. Paths identifying the disposable
evaluation are substituted with `$EVALUATION`; other retained content is unchanged.
Command stdout diagnostics are deliberately outside this selected export;
the task/global gate outputs are preserved. The [manifest](receipt-live-success/sha256.json)
binds **22 artifacts**, whose hashes and privacy checks passed.

## Verification

VERIFIED: the initial focused run had **37 tests, 3 failures**: fresh/resumed
policies mismatched macOS physical aliases, and successor allocation looked up
a continuation run instead of its original owning worktree. Correcting those
paths produced **13 tests, 0 failures**. After the additional storage guards
and exact capacity-version assertion, the focused command below reported
**74 tests, 0 failures**, seed **424183**, **16.9 seconds**
(6.4 async, 10.5 sync):

```sh
mix test test/shoestring/harness/codex_app_server/git_sandbox_test.exs test/shoestring/harness/codex_app_server/session_history_test.exs test/shoestring/harness/capacity_test.exs test/shoestring/harness/capacity/registry_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs
```

VERIFIED: baseline `0f8b256` modules were loaded in separate test VMs without
editing/resetting the checkout. With baseline `Worktrees`, the full source-byte
isolation assertion failed for changed source Git metadata: **1 test, 1 failure
(6 excluded)**, seed **915308**. The first line selector accidentally excluded
all tests (**0 tests, 7 excluded**) and is not regression evidence. With baseline
`Session`, both fresh/resumed turn assertions failed because `sandboxPolicy`
was absent: **2 tests, 2 failures (5 excluded)**, seed **617909**. Newly added
private-storage guard checks are additional protection, not claimed as pre-fix
regression locks. The native sandbox probe is capability evidence.

VERIFIED: `mix precommit` exited **0**: **4 doctests, 1928 tests, 0 failures,
1 skipped (6 excluded)**, seed **67961**, **175.8 seconds**
(8.8 async, 167.0 sync). Node suites passed **52/52** and **8/8**, zero skips.
All automated tests are hermetic. The capacity reads and real subscription
execution were separate, explicitly invoked manual phases.

## Semantic scope and closeout

VERIFIED: this run closes the missing successful two-task receipt execution and
restart proof. It establishes execution of this saved, approved model proposal
under Shoestring, rather than only a reference implementation smoke check.
It does not erase the failed first evaluation or demonstrate universal planner
quality. Greeting execution and a catalog repair were not run under this allowance.
The production subscription planner adapter remains separate integration work.
Human semantic review across the evaluation pack and the iteration's final
acceptance/closure record remain open. Official protocol references used for
the implementation are [App Server](https://learn.chatgpt.com/docs/app-server)
and [Permissions](https://learn.chatgpt.com/docs/permissions); the installed
0.162.1-generated schema and successful native probe established the concrete
policy shape used here.
