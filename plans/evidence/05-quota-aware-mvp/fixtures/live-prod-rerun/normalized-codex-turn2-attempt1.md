# normalized-codex-turn2-attempt1

Canonical trajectory material for one live run on the production-configured
node, redacted. Redaction is applied to the REASSEMBLED delta stream and then to
each whole detail line; every substitution is same-length, so ordinals and
counts are unchanged. Worktree paths become `$WORKSPACE`, other host paths
`$REDACTED_PATH`, UUIDs map 1:1 to the synthetic `01950000-0000-7000-8000-…`
(UUIDv7) and `55555555-0000-4000-9000-…` series, `pgid:` numbers become `x`.
Per-event provider session ids, source event ids, item ids and cwd are omitted.
Details are capped at 600 characters. The `x` runs are padding, not data.

## Run lifecycle and terminal events (5)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000006
lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000007
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000006
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000008
run.failed	elf-terminal:55555555-0000-4000-9000-000000000006
```

## Normalized events (0): ordinal, kind, detail

```
```
