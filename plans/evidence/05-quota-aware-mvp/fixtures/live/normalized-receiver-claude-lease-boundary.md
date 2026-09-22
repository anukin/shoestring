# receiver-claude-lease-boundary

Canonical trajectory material for one live run, redacted. Provider- and
Shoestring-generated identifiers are replaced by deterministic,
format-valid synthetic substitutes (UUIDv7 keeps version nibble 7 and
variant nibble 8; UUIDv4-shaped ids keep version 4 and variant 9/a;
`exec-`/`msg_` keep prefix, length and character class). Absolute paths
collapse to `$WORKSPACE` / `$REDACTED_PATH`. No credential, no raw
provider output, no hidden reasoning.

## Run lifecycle and terminal events (14)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000006
  lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000013
  lease.granted	lease-granted:55555555-0000-4000-9000-000000000013
  lease.active	lease-active:55555555-0000-4000-9000-000000000013
  handoff.created	handoff:55555555-0000-4000-9000-000000000006
  dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000006
  run.starting	elf-starting:55555555-0000-4000-9000-000000000006
  run.running	elf-running:55555555-0000-4000-9000-000000000006
  lease.renewal_due	lease-renewal-due:55555555-0000-4000-9000-000000000013
  lease.expired	lease-expired:55555555-0000-4000-9000-000000000013
  lease.checkpoint_required	lease-checkpoint-required:55555555-0000-4000-9000-000000000013
  checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000014
  run.pausing	elf-pausing:55555555-0000-4000-9000-000000000006
  run.suspended	elf-suspended:55555555-0000-4000-9000-000000000006
```

## Normalized events (2): ordinal, kind, detail

```
1	lifecycle	{"claude-headless:claude_code_version":"2.1.278","claude-headless:frame_type":"system","claude-headless:model":"claude-opus-5","claude-headless:permission_mode":"bypassPermissions","claude-headless:subtype":"init","claude-headless:tools":["Bash","mcp__claude_ai_Claude_Docs__batch","mcp__claude_ai_Claude_Docs__create","mcp__claude_ai_Claude_Docs__delete","mcp__claude_ai_Claude_Docs__export","mcp__claude_ai_Claude_Docs__guide","mcp__claude_ai_Claude_Docs__query","mcp__claude_ai_Claude_Docs__read","mcp__claude_ai_Claude_Docs__update"]}
  2	output	I'll start by looking at the existing `game` package to see what API I'm reusing.
```
