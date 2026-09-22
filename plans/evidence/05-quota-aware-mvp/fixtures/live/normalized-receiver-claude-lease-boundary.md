# receiver-claude-lease-boundary

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

## Run lifecycle and terminal events (14)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000006
lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000012
lease.granted	lease-granted:55555555-0000-4000-9000-000000000012
lease.active	lease-active:55555555-0000-4000-9000-000000000012
handoff.created	handoff:55555555-0000-4000-9000-000000000006
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000006
run.starting	elf-starting:55555555-0000-4000-9000-000000000006
run.running	elf-running:55555555-0000-4000-9000-000000000006
lease.renewal_due	lease-renewal-due:55555555-0000-4000-9000-000000000012
lease.expired	lease-expired:55555555-0000-4000-9000-000000000012
lease.checkpoint_required	lease-checkpoint-required:55555555-0000-4000-9000-000000000012
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000013
run.pausing	elf-pausing:55555555-0000-4000-9000-000000000006
run.suspended	elf-suspended:55555555-0000-4000-9000-000000000006
```

## Normalized events (2): ordinal, kind, detail

```
1	lifecycle	{"claude-headless:claude_code_version":"2.1.278","claude-headless:frame_type":"system","claude-headless:model":"claude-opus-5","claude-headless:permission_mode":"bypassPermissions","claude-headless:subtype":"init","claude-headless:tools":["Bash","mcp__claude_ai_Claude_Docs__batch","mcp__claude_ai_Claude_Docs__create","mcp__claude_ai_Claude_Docs__delete","mcp__claude_ai_Claude_Docs__export","mcp__claude_ai_Claude_Docs__guide","mcp__claude_ai_Claude_Docs__query","mcp__claude_ai_Claude_Docs__read","mcp__claude_ai_Claude_Docs__update"]}
2	output	I'll start by looking at the existing `game` package to see what API I'm reusing.
```
