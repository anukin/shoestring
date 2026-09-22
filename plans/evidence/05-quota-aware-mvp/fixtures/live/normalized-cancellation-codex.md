# cancellation-codex

Canonical trajectory material for one live run, redacted. Provider- and
Shoestring-generated identifiers are replaced by deterministic,
format-valid synthetic substitutes (UUIDv7 keeps version nibble 7 and
variant nibble 8; UUIDv4-shaped ids keep version 4 and variant 9/a;
`exec-`/`msg_` keep prefix, length and character class). Absolute paths
collapse to `$WORKSPACE` / `$REDACTED_PATH`. No credential, no raw
provider output, no hidden reasoning.

## Run lifecycle and terminal events (7)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000017
  dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000017
  run.starting	elf-starting:55555555-0000-4000-9000-000000000017
  run.running	elf-running:55555555-0000-4000-9000-000000000017
  run.cancelling	elf-cancelling:55555555-0000-4000-9000-000000000017
  checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000018
  run.cancelled	elf-terminal:55555555-0000-4000-9000-000000000017
```

## Normalized events (2): ordinal, kind, detail

```
1	lifecycle	{"codex-app-server:method":"thread/status/changed","codex-app-server:status":"active"}
  2	lifecycle	{"codex-app-server:method":"turn/started","codex-app-server:status":"inProgress","codex-app-server:turn_id":"01950000-0000-7000-8000-000000000003"}
```
