# Subscription production-path verification preparation

VERIFIED (user direction): the user asked to verify Shoestring planning and
production execution after the standalone subscription evaluation. Existing
authorization selects `chatgpt/gpt-6-luna`, without a spending cap. Work and
pushes are directly on main at the user's instruction; this overrides the
standing isolation and branch/PR workflow. Implementation base:
`0a2d2f009425cc60701e791adfd4aafd52e26592`.

## Findings and implemented preparation

REPO-INSPECTION: the domain planner registers only fixture and Ollama adapters.
The standalone Codex capture utility does not enter its durable admission,
claim or allowance transaction. A subscription planner adapter is still needed
before claiming production subscription planning. The current planner contract
requires a precharged output-token allowance and a provider output bound; see
[the planner contract](../../../docs/planner-boundary.md#configuration).

UNVERIFIED: an enforceable output-token cap in the installed subscription CLI.
No such cap was established in this run. Time/output-byte bounds and checking
reported usage after completion do not prove that cap. A user decision about a
separate subscription limit contract is pending; no existing token contract
has been relaxed and no live inference was made during this preparation.

REPO-INSPECTION: the production dispatch effect already selects
`Shoestring.Harness.CodexAppServer` with `live: true`. Saved model selection
flows through dispatch into the adapter options. This is a code-path trace,
not evidence of a live iteration-6 execution.

REPO-INSPECTION: fresh Codex sessions previously always requested
`ephemeral: false`; provider history can contain reasoning outside Shoestring's
canonical evidence. Fresh sessions now accept an explicit boolean `ephemeral`
option. `true` requests no provider history and refuses provider-history resume
before opening a transport. Invalid values fail before opening a transport.
Omitting the option preserves the existing resumable behavior. There is no
new retention, deletion or cleanup policy.

VERIFIED: hermetic transport checks inspect actual `thread/start` and
`turn/start` frames for both boolean values and the omitted default, preserving
the model, workspace, sandbox and task prompt. Additional checks refuse
ephemeral resume through both session and public adapter entry points, and
reject invalid history options. These are capability checks for a new option,
not a claimed regression lock against the base commit.

UNVERIFIED: the live provider's history behavior for this option. Sending the
flag through a fake transport is not proof about provider storage. The option
is not enabled globally. It does not make ephemeral executions resumable from
provider history or establish full-path live restart behavior.

## Required live evidence

REPO-INSPECTION: the intended proof must retain these distinct outcomes:

1. A normal planner request, actual provider/scope admission, durable charge and
   model call, followed by strict candidate validation.
2. Human review/adoption and approval of the exact immutable plan revision.
3. A saved execution profile selecting the authorized model, current capacity
   admission, owned worktree binding and real harness delivery.
4. The resulting code commit, task gates and final acceptance gates. Model
   completion alone cannot accept a task.
5. Restart between accepted tasks, retaining accepted evidence, dependencies
   and lifetime counters without another planning call or duplicate dispatch.

UNVERIFIED: all five live outcomes above. The earlier standalone proposal
packet and existing hermetic executor proof remain separate evidence. The two
bound model plans in [the earlier packet](luna-evaluation.md#concrete-plans-for-execution-review)
still need exact human approval before dispatch; reference-scope approval is
not a substituted domain approval.

## Verification

VERIFIED: the first focused command failed with **23 tests, 2 failures**, seed
**230015**. Both new fresh-session tests referenced a helper nested in another
test file before that module was loaded. They now use the compiled in-memory
`Shoestring.Harness.Capacity.Codex.FakeTransport`. This was a test construction
failure, not an intermittent provider or product result.

VERIFIED: after correction, the command
`MIX_ENV=test mix test test/shoestring/harness/codex_app_server/session_history_test.exs test/shoestring/harness/codex_app_server/session_test.exs test/shoestring/harness/codex_app_server/adapter_isolation_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs`
reported **23 tests, 0 failures**, seed **368175**, in **12.6 seconds**
(3.8 seconds async, 8.7 seconds sync). One default-compatibility case was then
added for the full gate. All checks use fake transports or local fixture
execution; no provider CLI or network is invoked by these tests.

VERIFIED: `mix precommit` exited **0**, invoked in the foreground through
`subprocess.run(["mix", "precommit"], stdin=subprocess.DEVNULL,
stdout=output, stderr=subprocess.STDOUT, timeout=420)`. ExUnit reported
**4 doctests, 1912 tests, 0 failures, 1 skipped (6 excluded)**, seed **270424**,
in **173.2 seconds** (9.2 seconds async, 163.9 seconds sync). JavaScript suites
reported **52 tests, 52 pass, 0 fail** and **8 tests, 8 pass, 0 fail**, both with
zero skips. One explanatory comment was corrected while tests were running;
formatting was checked again afterward. No runtime behavior changed after
the gate began.

VERIFIED (subsequent run): [the receipt execution packet](receipt-live-run.md)
records user approval and one real production-path attempt. Its uncommitted
implementation failed acceptance; restart preserved that failure and blocked
the dependent task. Successful acceptance/completion remains unverified.
