# Claude headless execution events — live capture (WP D feasibility)

Date: 2026-09-06 UTC. CLI: `claude 2.1.261 (Claude Code)` (VERIFIED —
`claude --version`, this machine). Branch `polly/iter4-spike-claude`.

Parent doc: `plans/evidence/04-single-elf/claude-headless.md` (zero-token
probe). That doc is not redesigned here; this file records what the
authorized live capture observed, and overturns one of its verdicts on
live evidence.

## Turn budget accounting (brief authorized up to 3 tiny turns, /tmp only)

| Attempt | Command shape | Reached model? | Outcome |
| --- | --- | --- | --- |
| 1 (validation) | vetted shape verbatim (`--tools "Bash"` + positional prompt) | No — arg-parse error, zero tokens | exit 1, stderr `Input must be provided…` (fixture `tools-gobble-input-error.stderr.txt`) |
| 2 (validation) | `--tools="Bash"`, no `--verbose` | No — flag-validation error, zero tokens | exit 1, stderr `…requires --verbose` (fixture `no-verbose-usage-error.stderr.txt`) |
| 3 (live) | `--tools="Bash"` + `--verbose`, tool-exercising prompt | API contacted, model never reached (HTTP 401, OAuth expired) | exit 1, 4 stream-json frames, empty stderr (fixture `stream-json-auth-failure.jsonl`) |
| 4 (live resume) | `--resume <id> --print --verbose --output-format stream-json`, trivial prompt | API contacted, model never reached (same 401) | exit 1, 3 frames, empty stderr (fixture `stream-json-resume-auth-failure.jsonl`) |

Model turns consumed: **0**. Cost: **$0** (`total_cost_usd: 0`, all usage
counters 0 in both result frames — VERIFIED). Raw captures remain under
`/tmp/shoestring-claude-probe-A28wrH/` and `/tmp/shoestring-claude-evidence/`;
only redacted fixtures are committed here.

## Deviations from the vetted command (all forced by observed errors)

1. `--tools "Bash"` → `--tools="Bash"`. `--tools <tools...>` is
   **variadic** (VERIFIED — `claude -p --help`; attempt 1 live-observed):
   the space-separated form swallows the positional prompt as a second
   tools value, producing `Input must be provided…`. The `=` form binds
   only `Bash` and leaves the prompt positional. Same flag, same value,
   unambiguous binding — minimal repair, intent preserved.
2. Added `--verbose`. `--print` + `--output-format stream-json` without
   `--verbose` exits 1 (VERIFIED, attempt 2, reproduced twice). There is
   no non-verbose variant to compare against; the doc's framing
   comparability concern is moot.
3. Ran from the worktree cwd instead of `cd "$FIXTURE_DIR"`. Consequence:
   the persisted session transcript landed under the worktree's project
   slug dir (`~/.claude/projects/…-iter4-spike-claude/`), and `init.cwd`
   carried the worktree path (redacted to `$WORKSPACE` in fixtures).
   Prompts were credential-free throughout, so the residue is inert.

## Answers

### (a) Does stream-json exit 0 on 2.1.261? — NO in every observed case (VERIFIED)

- Without `--verbose`: exit 1 with `Error: When using --print,
  --output-format=stream-json requires --verbose` on stderr and empty
  stdout (VERIFIED — reproduced 2/2, zero tokens).
- **This settles the Gate 0A status-1 failure.** Gate 0A's invocation
  (`tools/gate_0a/provider_probe.js:250-264`) used `--print` +
  `--output-format stream-json` with **no `--verbose`**, and recorded
  exactly this signature: exit 1, zero structured stdout messages,
  ~1 s fast fail, stderr discarded. The failure was an argument
  validation error, not a provider/protocol failure. The 2.1.261 half of
  this claim is VERIFIED by reproduction; the 2.1.251 half is inference
  (2.1.251 is no longer installed), rated high-confidence on signature
  match.
- **Correction to the parent doc:** its "Lead hypothesis — verdict:
  KILLED" is OVERTURNED. Its probe #3 (`claude --output-format
  stream-json` without `-p`) never entered the `--print` validation
  path, so the identical error with/without `--verbose` proved nothing
  about the `--print` combination. The `--verbose` coupling is real,
  just scoped to `--print` exactly as the error text says.
- With `--verbose` and working auth: UNVERIFIED (no successful turn was
  possible — see environment note below).
- With `--verbose` and expired OAuth: exit 1 with an error `result`
  frame, empty stderr (VERIFIED — attempts 3 and 4).

### (b) Event-envelope vocabulary — PARTIAL (VERIFIED where listed)

Live-observed frame types (committed frames in
`fixtures/claude/stream-json-auth-failure.jsonl`, 4 lines):

| # | `type` | `subtype` | Notes |
| --- | --- | --- | --- |
| 0 | `system` | `init` | Carries `session_id`, `uuid`, `cwd`, `model` (`claude-opus-5`), `tools`, `permissionMode`, `capabilities`, `claude_code_version`, `output_style`, `apiKeySource`, `fast_mode_*`, plus machine-local inventory (redacted, see below). |
| 1 | `system` | `api_retry` | `attempt: 1`, `max_retries: 10`, `retry_delay_ms: 560`, `error_status: 401`, `error: "authentication_failed"`. Only in attempt 3; attempt 4 failed with no retry frame (recorded, not interpreted). |
| 2 | `assistant` | (absent) | Error message shape: `is_api_error_message: true`, `error: "authentication_failed"`, `message.content: [{type: "text", text: "Failed to authenticate: …"}]`, all usage counters 0, `parent_tool_use_id: null`. `message.model` is the verbatim string `"<synthetic>"` — CLI-emitted bytes on the error path (no model backed it), preserved as-is. |
| 3 | `result` | `success` (!!) | See (e). |

VERIFIED sub-observations: `capabilities: ["interrupt_receipt_v1",
"interrupt_cancel_queued_v1", "msg_lifecycle_v1"]` is advertised in
`init` — bare vocabulary strings only (SCHEMA-ONLY for any interrupt
mechanism; no interrupt was tested). `--tools="Bash"` restricts the
`init.tools` array to `["Bash"]`; without it the default 26-tool list is
advertised (VERIFIED — attempt 4 init). `permissionMode:
"bypassPermissions"` confirms `--dangerously-skip-permissions` was
honored (VERIFIED).

Everything else — `user` frames, assistant tool-use content blocks,
partial-message chunks, hook events, subagent frames — is UNVERIFIED
(no such frame was ever emitted on this machine).

### (c) TOOL/COMMAND BOUNDARY frames — UNVERIFIED (the spike's load-bearing question is still open)

No tool executed: the 401 arrived before any assistant turn, so no
`tool_use` content block, no start/end pair, no correlation id, no
completion status was observed. **On current evidence the lease
safe-boundary rule cannot be honored for Claude at all** — there is
still no known frame that marks where a command starts/ends. WP D
remains blocked on one successful tool-exercising capture under working
credentials. This question is answered (negatively) either way per the
contract: the answer is UNVERIFIED, not absent.

### (d) Session id exposure — YES (VERIFIED)

`session_id` is a top-level field on **every** observed frame (init,
api_retry, assistant, result) and is identical across all of them within
a run. Shape: UUIDv4 (`7d74c43c-…` real; version nibble `4`, variant
`a` — hence the v4-preserving synthetic substitution, see redaction
record). Satisfies the `RunIdentity.provider_session_id` need
(ContractSuite area 3) at the frame level.

### (e) Final-result frame shape — VERIFIED for the error path only

Error-path `result` frame (committed, line 3): `is_error: true`,
`subtype: "success"`, `terminal_reason: "api_error"`,
`stop_reason: "stop_sequence"`, `stop_sequence: ""`, `result: <human
error text>`, `num_turns: 1`, `duration_ms` / `duration_api_ms`,
`total_cost_usd: 0`, zeroed `usage`, empty `modelUsage` / subagent
stats, `permission_denials: []`, `queued_turn_count: 0`.
**Normalizer warning (VERIFIED quirk): `subtype` stays `"success"`
while `is_error` is true — completion classification must key on
`is_error`/`terminal_reason`, never on `subtype`.** The success-path
result shape is UNVERIFIED.

### Resume (step 3 of the brief — condition met, turn spent)

A session id did appear, so one resume turn was spent:
`claude --resume 7d74c43c-… --print --verbose --output-format
stream-json --dangerously-skip-permissions "Reply with exactly OK."`
Result (fixture `stream-json-resume-auth-failure.jsonl`, 3 lines):
`system/init` re-emitted the **same** `session_id` (VERIFIED — the CLI
accepted the id and bound the turn to the persisted local transcript;
that transcript exists on disk at
`~/.claude/projects/…-iter4-spike-claude/7d74c43c-….jsonl`,
REPO-INSPECTION of the local fs), then the same 401 error assistant +
result frames, exit 1. Whether a resumed turn can *complete* is
UNVERIFIED (auth blocked the model call, deterministically — see
environment note).

## Environment note (why no tool ran)

`ANTHROPIC_API_KEY` is unset in this environment and the cached OAuth
session is expired (`apiKeySource: "none"` in init;
`OAuth session expired and could not be refreshed`; HTTP 401 on both
live attempts — VERIFIED, persistent across attempts, not transient).
No credential was sought, minted, or injected — per contract, auth
repair is out of scope for this task. The next capture attempt needs a
working credential and nothing else changed.

## Contract mapping delta (Codex parity checklist)

Against `Shoestring.Harness.Adapter` / ContractSuite areas: area 3
(resume binding) advances to **VERIFIED-mechanics / UNVERIFIED-completion**
(session id in stream VERIFIED; `--resume` re-binds VERIFIED; completion
UNVERIFIED). Area 2 stays **blocked** on tool-boundary frames (c).
Area 4 rule stands and extends: both `authentication_failed` (401) and
any future generic error map to `unknown` + checkpoint — **never
`:quota_refused`** (no refusal shape observed; unchanged). Area 6
(secret-free) pattern holds: this capture's redaction record is below.

## Fixture redaction record (README.md convention, exactly followed)

- Synthetic identifiers are format-valid and preserve the **observed**
  UUIDv4 shape (version nibble `4`, variants from the observed
  `{8,9,a,b}` set): session id →
  `aaaaaaaa-0000-4000-a000-000000000001` (stable across both fixtures,
  preserving the cross-frame/cross-run correlation that is itself
  evidence); per-frame `uuid` → `bbbbbbbb-0000-4000-8000-…0001–0007`
  (global order, 1:1); `message.id` → `cccccccc-0000-4000-9000-…0001–0002`.
  Rationale for deviating from the README's v7 baseline pattern: the
  README's v7 rule was written for Codex; Claude emits v4, and the
  standing contract forbids reshaping an id into something the real
  protocol does not emit. `Ecto.UUID.cast/1` accepts both.
- `cwd` → `$WORKSPACE` (README placeholder rule).
- Emptied machine-local inventory (arrays/objects replaced with `[]`/`{}`,
  key sets otherwise identical — verified programmatically raw-vs-redacted):
  `slash_commands` (59/56 items), `terminal_slash_commands`, `agents`,
  `skills` (24), `plugins` (3, contained cache paths), `memory_paths`,
  `messaging_socket_path` → `"REDACTED"`.
- Nothing else changed: all types/subtypes, error strings, counters,
  timings, `model` values (including verbatim `"<synthetic>"`), and the
  `timestamp` are byte-identical to the capture.
- No reasoning/thinking/scratchpad content was emitted, so nothing was
  stripped on that rule (all content blocks are `type: "text"`).
- Sizes: 3074 + 3133 + 74 + 94 bytes — far under the 50 KB bound.
- Fixture path follows the brief (`plans/evidence/04-single-elf/fixtures/claude/`),
  not the parent doc's `test/fixtures/…` suggestion; evidence-only change,
  `lib/` and `test/` untouched.

## Verdict for WP D dispatch

WP D still cannot be built: the normalizer's load-bearing input (tool
boundary frames) remains unobserved, and no successful turn of any kind
has been captured. The unblock is now precisely scoped — one
tool-exercising capture under working credentials (the `--verbose` and
`--tools=` repairs documented above are required for the command to
reach the model at all) — plus a resumed-turn completion to settle area
3 fully. Gate 0A's `unsupported` classification for stream-json is
overturned as a mechanism (it was the missing `--verbose` flag), but
`unsupported` remains the correct *effective* status until a successful
capture lands.
