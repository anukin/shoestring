# cancellation-codex

Canonical trajectory material for one live run, redacted.

Redaction is applied to the REASSEMBLED text of the run, not to each event
in isolation: Codex emits `item/agentMessage/delta` frames one fragment at
a time, so a path spelled across many deltas must be caught after the
fragments are joined. Every substitution is **same-length**, and the joined
stream is sliced back with the original per-fragment lengths, so ordinals,
event counts, kinds and statuses are unchanged.

Substitutions, applied 1:1 and deterministically:

- a Shoestring-managed worktree path (however it was spelled) becomes
  `$WORKSPACE`, padded with `x` to the original length;
- any other absolute host path — including the macOS per-user temp shard —
  becomes `$REDACTED_PATH`, padded the same way;
- UUIDs become format-valid synthetic UUIDs of the same 36 characters
  (Codex UUIDv7 keeps version nibble `7` and variant `8`; everything else
  uses a `55555555-0000-4000-9000-…` / `aaaaaaaa-0000-4000-a000-…` series
  with version `4` and a valid variant);
- `exec-…` keeps its prefix and length; `msg_…` and `pgid:…` are reduced to
  their prefix plus `x` padding.

Per-event `provider_session_id` and `source_event_id` are omitted entirely
rather than substituted, as are `claude-headless:session_id`,
`claude-headless:cwd` and `codex-app-server:item_id`. No credential, no raw
provider transport frame, no hidden reasoning.

The `x` runs are padding, not data.

## Run lifecycle and terminal events (7)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000016
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000016
run.starting	elf-starting:55555555-0000-4000-9000-000000000016
run.running	elf-running:55555555-0000-4000-9000-000000000016
run.cancelling	elf-cancelling:55555555-0000-4000-9000-000000000016
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000017
run.cancelled	elf-terminal:55555555-0000-4000-9000-000000000016
```

## Normalized events (2): ordinal, kind, detail

```
1	lifecycle	{"codex-app-server:method":"thread/status/changed","codex-app-server:status":"active"}
2	lifecycle	{"codex-app-server:method":"turn/started","codex-app-server:status":"inProgress","codex-app-server:turn_id":"01950000-0000-7000-8000-000000000002"}
```
