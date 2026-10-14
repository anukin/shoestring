# Execute an approved plan

REPO-INSPECTION: `mix shoestring.execution` queues work for a running Shoestring
service. It starts only the repository and a queue client. Use the same state
directory as the service. The service owns Elves and their process groups;
closing the CLI leaves their work running.

REPO-INSPECTION: [reservation inspection and recovery](cli-reservations.md)
shows configured ownership and queues explicit evidence-backed reconciliation
or cancellation of provably never-started intent.

```sh
mix shoestring.execution start "$GOAL" \
  --revision 1 --digest "$PLAN_DIGEST" --repo "$REPOSITORY" \
  --agent "$AGENT_ID" --agent-revision 1 --agent-digest "$AGENT_DIGEST" \
  --role Worker --by human:operator

mix shoestring.execution status "$GOAL"
mix shoestring.execution check-scopes "$GOAL"
mix shoestring.execution continue "$GOAL" --execution-id "$EXECUTION_ID"
```

REPO-INSPECTION: `check-scopes` records deterministic scope evidence for approved,
dependency-ready unstarted tasks. Unknown/overlapping scopes, shared surfaces,
symlinks and changed source state default to sequential execution. It starts no
run and enables no parallel dispatch; its observation must be rechecked before
future fan-out.

REPO-INSPECTION: scope events retain decoded evidence in CLI responses; version 2
stores bounded canonical decision JSON so nested overlap blockers remain
recordable. Execution status also includes `children`, `active_children` and
per-child resolution/retry state. An operator blocker is visible while another
child remains active. These read views do not enable parallel workers; the
internal fan-out coordinator is not selected by this CLI yet.

REPO-INSPECTION: Start binds the exact approved plan, immutable saved agent role,
provider, explicit model and repository directory. Repeating an identical start
returns the same intent and live delivery job. Changing the approved digest,
agent selection, repository or attribution is refused. Approval and queuing do
not authorize a run without capacity admission.

REPO-INSPECTION: Before each new task the worker evaluates a current observation
from the provider/scope-specific Observatory ledger. It does not probe a provider
from this CLI or invent capacity. Missing observations hold execution with no
run allocation. Status includes cached observation availability, the latest
admission decision, accepted tasks, active task and lifetime attempts/gate time.
A recorded observation may still be stale or insufficient; the decision carries
that distinction. `last_admission` is historical and may be absent before the
first decision. Unknown/reactive capacity is not automatically confirmed by this
interface. For a dependency-ready task with no active run, the operator can
explicitly confirm one admission decision:

```sh
mix shoestring.execution confirm-capacity "$GOAL" \
  --execution-id "$EXECUTION_ID" --task-id "$TASK_ID" --attempt 1 \
  --scope subscription --command-id "$CONFIRMATION_UUID" --by human:operator
```

REPO-INSPECTION: confirmation binds the exact execution, approved revision/digest,
task attempt, saved provider/adapter and account scope. It records no run and starts
no provider; the waiting worker rechecks the real ledger on its next delivery.
One admission decision consumes it, including a hard refusal. It never carries
over to a dependent task, retry, amendment or handoff. Another decision needs a
new explicit confirmation ID. Replaying the same command is inert. Known reserve
breaches, hard quota refusals, incompatible adapters and occupied scopes remain
blocked. Capacity stays labeled unknown/partial; confirmation does not manufacture
telemetry. `human:` attribution follows the application's existing local-user
convention and is not a new authentication boundary.

REPO-INSPECTION: Tasks execute sequentially in owned Git worktrees. Successful
provider completion still requires the task gates before dependents unlock.
The next worktree starts from accepted evidence; the source checkout is preserved.
The final task's integrated worktree must pass global acceptance too.

REPO-INSPECTION: new task worktrees copy the pinned base into independent
per-run Git storage. Successors copy the last accepted owning worktree's commit;
accepted commits need not exist in the source repository. Codex receives only
registered private Git write roots, never source Git write access. Existing
shared worktrees are not migrated. Private storage is preserved for inspection;
no automatic cleanup is introduced. The real commit/restart proof is in
[the receipt evaluation](../plans/evidence/06-cobbler-planning/receipt-live-success.md).

REPO-INSPECTION: Continue repairs delivery of the same execution intent. Startup
also performs one delivery repair pass. Neither resets counters, approves an
amendment, replaces an active Elf, nor overrides a task's needs-user state.
After editing and approving an amendment, use Start with its new exact revision
and digest; the domain enforces the one-amendment activation limit.

REPO-INSPECTION: if the prior attempt is stopped at a canonical checkpoint,
Start may atomically record its supersession and activate the approved amendment.
Quota refusal, cancellation or interruption qualify only with the Elf's durable
terminal record and no live Elf or competing run intent. Suspension alone is
insufficient. A successful completion or transport
failure still needs its normal task resolution. Supersession accepts no work,
retains checkpoint/history/counters, and allocates no provider run by itself.
The next task attempt still needs fresh admission and remaining lifetime budget.

REPO-INSPECTION: same-provider quota wakes retain the task attempt, model and
worktree through canonical checkpoint lineage. Status lists the current run
and its ancestor run IDs. Continuation cannot replace a still-active parent,
fork an attempt, switch its bindings, or bypass a recorded gate failure.

REPO-INSPECTION: Duration accounting includes provider run intervals and task
and global gate time across retries, quota continuations and amendments. Queue
and quota-wait intervals consume no run time. Exhausted budgets prevent new
dispatch or continuation, and gate timeouts use the remaining allowance. Elapsed
time alone never interrupts or replaces an active Elf. Status exposes consumed
time and the remaining goal allowance. Global acceptance failure is durable and
requires a new approved amendment rather than silently repeating on restart.

REPO-INSPECTION: an explicit cross-provider continuation selects a named role
from the same immutable saved agent revision. It keeps the approved task,
worktree, plan revision and attempt counters; it does not introduce another task
or a review stage. Inspect status/checkpoint evidence and copy the exact current
decision references from `status.active_continuation` before submitting. This
read-only output includes the current saved role/provider; it does not authorize
a transfer by itself:

```sh
mix shoestring.execution handoff "$GOAL" \
  --execution-id "$EXECUTION_ID" --run-id "$RUN_ID" \
  --checkpoint-id "$CHECKPOINT_ID" \
  --decision-ref "$DECISION_ID_1" --decision-ref "$DECISION_ID_2" \
  --role Reviewer --scope "$RECEIVER_SCOPE" \
  --command-id "$COMMAND_ID" --reason "Continue after sender quota stop" \
  --by human:operator
```

REPO-INSPECTION: include each current decision reference exactly once. The role
must select another provider with an explicit model; provider/model overrides
are not CLI options. Delivery checks the canonical command, saved revision,
current approval, definitive Elf terminal and remaining duration before receiver
capacity observation. Suspension alone is retryable and does not transfer work.
Live ownership blocks transfer. Receiver admission and its own lease still apply;
a refusal creates no receiver or fallback. Replaying the identical command
converges, including after delivery. Changing its role or references conflicts.
Discarded delivery is repaired from the same durable intent on startup.

REPO-INSPECTION: `--confirm-capacity` optionally records a confirmation for this
receiver and scope, attributed to the goal's durable owner. It can lift only a
confirmation-class refusal. Hard quota/scope/compatibility stops remain blocked;
a goal without an attributable owner cannot use this option. The CLI queues
only; the service consumes its current provider/scope Observatory observation.

UNVERIFIED: no live provider integration or model plan quality is claimed by the
hermetic CLI/worker proof. See the iteration-6 handoff evidence record.
