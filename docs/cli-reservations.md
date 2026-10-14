# Inspect and recover reservations

REPO-INSPECTION: use the same state directory as the running Shoestring service.
The CLI starts only its repository and queue client. The service owns Elves,
process-group evidence and recovery execution; closing the CLI does not stop work.

```sh
mix shoestring.reservations list
mix shoestring.reservations list --goal "$GOAL" --all --limit 100
mix shoestring.reservations show "$RESERVATION"

mix shoestring.reservations reconcile "$RESERVATION" \
  --command-id "$COMMAND_UUID" --by human:operator

mix shoestring.reservations cancel-unstarted "$RESERVATION" \
  --command-id "$CANCEL_COMMAND_UUID" --by human:operator
```

REPO-INSPECTION: `list` defaults to outstanding owners, bounded to 100 rows;
`has_more` identifies a truncated view. `--limit` accepts 1–1000. `--all`
includes preserved settlements. `show` includes parent/task/run ownership,
configured limits and units, account/goal/global occupancy, admitted snapshot
and projected windows, dispatch state, settlement and operator requests.
Units are configured concurrency weights, not predicted provider usage.
An overdue reservation still consumes capacity. No timestamp releases it.

REPO-INSPECTION: recovery commands return a pending operation and job ID.
Use `show` to inspect the service's committed result. Repeating identical
arguments with the same command UUID replays that request/result. Changed
arguments under an existing command UUID are refused. A new observation after
an earlier retained result requires a new command UUID. Startup repair restores
lost/discarded delivery of pending requests without creating new decisions.

REPO-INSPECTION: `reconcile` releases an unused no-intent orphan or closes a
canonical terminal whose Elf and recorded process groups are verified absent.
Unknown ownership or missing process evidence remains held. The helper probes
with signal zero; it does not signal or kill the target group.

REPO-INSPECTION: `cancel-unstarted` is an explicit cancellation request. It
only releases a requested run with harmless intent/grant history, no live Elf,
and no possibly started dispatch. Cancellation, its canonical terminal,
settlement and operation result commit under the same write lock used to claim
dispatch effects. A racing worker either loses to the fence or claims first,
in which case capacity stays held. Job cancellation/status alone is never proof
that a process stopped. Existing run/worktree/evidence records are retained.

REPO-INSPECTION: live or ambiguous effects cannot be cancelled through this
command. Cancellation of live work remains the supervising Elf's responsibility;
unknown or lost process identities still require ownership evidence before
capacity can be released. Cancelling unused intent does not approve a replacement,
retry a task or clear its unresolved plan attempt. Use the existing explicit
plan review/amendment flow to decide what work should follow.

REPO-INSPECTION: the inspection view omits prompts, transcripts, provider session
identifiers and arbitrary extension/result metadata. It preserves app-domain
ownership/admission/snapshot references needed to explain capacity. Inspection
does not probe providers or start an Elf. Initial reservation-backed execution
remains opt-in; this CLI does not enable parallel execution.
