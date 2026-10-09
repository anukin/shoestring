# Execute an approved plan

REPO-INSPECTION: `mix shoestring.execution` queues work for a running Shoestring
service. It starts only the repository and a queue client. Use the same state
directory as the service. The service owns Elves and their process groups;
closing the CLI leaves their work running.

```sh
mix shoestring.execution start "$GOAL" \
  --revision 1 --digest "$PLAN_DIGEST" --repo "$REPOSITORY" \
  --agent "$AGENT_ID" --agent-revision 1 --agent-digest "$AGENT_DIGEST" \
  --role Worker --by human:operator

mix shoestring.execution status "$GOAL"
mix shoestring.execution continue "$GOAL" --execution-id "$EXECUTION_ID"
```

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
interface.

REPO-INSPECTION: Tasks execute sequentially in owned Git worktrees. Successful
provider completion still requires the task gates before dependents unlock.
The next worktree starts from accepted evidence; the source checkout is preserved.
The final task's integrated worktree must pass global acceptance too.

REPO-INSPECTION: Continue repairs delivery of the same execution intent. Startup
also performs one delivery repair pass. Neither resets counters, approves an
amendment, replaces an active Elf, nor overrides a task's needs-user state.
After editing and approving an amendment, use Start with its new exact revision
and digest; the domain enforces the one-amendment activation limit.

REPO-INSPECTION: same-provider quota wakes retain the task attempt, model and
worktree through canonical checkpoint lineage. Status lists the current run
and its ancestor run IDs. Continuation cannot replace a still-active parent,
fork an attempt, switch its bindings, or bypass a recorded gate failure.

UNVERIFIED: cross-provider plan handoff and full run-duration budget accounting
remain separate iteration-6 work. No live provider integration is claimed by
the hermetic CLI proof.
