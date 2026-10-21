# Local diagnostic preview and export

Diagnostics are explicit and local. They do not start provider CLIs, read
authentication files, call a model, or upload data. The command opens an existing
database without running migrations. Missing state is refused rather than
initialized. SQLite may create its ordinary connection sidecar files.

First inspect the complete sanitized bundle and its manifest:

```sh
mix shoestring.diagnostics preview --limit 50
```

Optionally restrict both commands to a local goal with `--goal UUID`. The
default selection is the newest 200 events, ordered by recorded timestamp and
event ID; `--limit` accepts 1 through 200. Omitted counts are explicit. This
selection order is for diagnostics, not canonical replay order. Per-goal
sequence numbers remain visible.

Review the printed `bundle`, `manifest`, and `confirmation_sha256`. To create
the file, copy that digest and use the same selection:

```sh
mix shoestring.diagnostics export diagnostics.json --limit 50 --confirm SHA256_FROM_PREVIEW
```

Export regenerates the preview in one consistent database snapshot and requires
an exact match of its canonical bytes. A changed selected event, omitted count,
runtime/configuration summary or fixture hash requires a fresh preview and
confirmation. Changes only to excluded information do not change exported
bytes. A bare `--confirm`, missing confirmation, or mismatched digest cannot
export. No confirmation from a model response is consulted.

The file is created exclusively, set to mode 0600 before content is written,
and synced. Existing files and symlinks are refused. There is no automatic
deletion or cleanup; a failed write may leave a partial file. Export it again
to a new name after resolving the underlying error. Delete unwanted copies
using ordinary file-management tools. Sharing or deleting a copy is a separate
user action.

## Contents and exclusions

Version 1 exports a single canonical JSON object, bounded to 512 KiB. Selected
source payloads and type names are bounded to 8 MiB before loading from SQLite. Oversized input
or output is refused; it is not silently truncated into a successful export.

The projection contains:

- Numeric application, Elixir, OTP and SQLite versions, a coarse OS/architecture,
  development/release status, and expected terminal protocol.
- Only the configured API enabled flag/cap, Claude/Codex monitor enabled flags,
  and the disabled forecast-enforcement state. These are configuration summaries,
  not authorization to execute a call or evidence that monitoring is healthy.
- Passive database readability and state-directory access. Provider authentication
  and actual helper compatibility explicitly say `not_checked`.
- SHA-256 hashes of two compatibility fixtures compiled with the application:
  Codex initialize v1 and Claude capacity v1. They identify fixture bytes, not
  local accounts or source repositories. They are not a complete fixture inventory.
- Selected event types/schema versions, goal/run aliases, sequence numbers and
  relative millisecond timing. Capacity events retain allowlisted provider,
  adapter, numeric CLI version, support tier and compatibility/state labels.
  Those observations are historical; they do not establish the currently
  installed CLI version or current authentication.
- Allowlisted admission result/reason codes with local explanation templates,
  waiting attempts, typed harness error categories, and gate result/kind,
  duration, exit status and required flag. Unknown codes become `unknown`.

Original goal/task/run/event IDs, provider session/account IDs, timestamps,
process IDs, paths, prompts, source, hidden reasoning, terminal/gate output,
auth files, credential fields, arbitrary configuration, extensions and stored
free-text errors/explanations are excluded. The boundary projects known fields
instead of attempting to make arbitrary transcripts safe with pattern matching.
Unexpected strings in enum/version slots are also excluded.

Unknown event types become `unregistered`. Unknown schema versions retain their
bounded version number without interpreting the payload. `schema_registered`
only says that the type/version pair is known; it does **not** certify that
the stored payload is valid. The bundle is deliberately lossy and cannot be
used to replay history or reconstruct original identities.

Counts, versions, event patterns and relative timing can still reveal operational
information. Inspect the full preview before sharing. No export is a guarantee
of anonymity, and no upload or remote-support service is included.

## Verification status

Hermetic tests cover seeded credentials and synthetic absolute home paths in
payloads/metadata, while asserting that required versions, enums, sequence and
timing remain. Tests also cover exact-byte confirmation, changed history and
configuration, bounded/goal-scoped selections, oversized input, private files,
overwrite/symlink refusal, absent-state inspection, history preservation and
provider-CLI guards. These are new-feature tests, not regression locks against
the pre-feature commit. Real user bundles are not shared by this workflow.

Iteration 10 release packaging and its doctor command are separate work. Until
they are implemented, use this Mix command from a development installation.
