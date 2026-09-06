# Claude headless execution events — live capture (WP D feasibility)

Date: 2026-09-06 UTC. CLI: `claude 2.1.261 (Claude Code)` (VERIFIED —
`claude_code_version: "2.1.261"` in both committed `init` frames).
Branch `polly/iter4-spike-claude`.

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
   variadic: the space-separated form swallows the positional prompt as
   a second tools value, producing `Input must be provided…`
   (VERIFIED — attempt 1 live-observed; committed fixture
   `fixtures/claude/tools-gobble-input-error.stderr.txt`). The `=` form
   binds only `Bash` and leaves the prompt positional. Same flag, same
   value, unambiguous binding — minimal repair, intent preserved.
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

### (a) Does stream-json exit 0 on 2.1.261? (PART-1 ANSWER SUPERSEDED — see correction; original retained below)

**Correction (Part 2):** the "NO in every observed case" answer below
was written before the successful capture and is now false. The
accurate answer (VERIFIED): exit 1 when `--verbose` is missing (usage
error, committed stderr fixture) or when credentials are absent (error
`result` frame, committed fixtures); **exit 0 on a working
authenticated capture** — operator-reported, corroborated by the
committed 8-frame `stream-json-tool-exec.jsonl` ending in a
`terminal_reason: "completed"` result frame, empty stderr, and
`hello.txt` created.

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
- With `--verbose` and working auth: exit 0 (SUPERSEDES the
  UNVERIFIED below — Part 2 operator capture: 8 frames,
  `terminal_reason: "completed"`, `hello.txt` created).
- (Original Part-1 bullet, retained: With `--verbose` and working auth:
  UNVERIFIED — no successful turn was possible from this sandbox; see
  environment note below.)
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

Everything else — partial-message chunks, hook events, subagent
frames — is UNVERIFIED (no such frame was ever emitted on this
machine). (`user` frames and assistant tool-use content blocks were
UNVERIFIED when this was written; Part 2 has since VERIFIED both —
see (c revisited).)

### (c) TOOL/COMMAND BOUNDARY frames — UNVERIFIED in Part 1 (ANSWERED by Part 2 — see (c revisited); original retained below)

No tool executed in Part 1: the 401 arrived before any assistant turn, so no
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

### (e) Final-result frame shape — VERIFIED for the error path below (success path VERIFIED in Part 2)

Error-path `result` frame (committed, line 3): `is_error: true`,
`subtype: "success"`, `terminal_reason: "api_error"`,
`stop_reason: "stop_sequence"`, `stop_sequence: ""`, `result: <human
error text>`, `num_turns: 1`, `duration_ms` / `duration_api_ms`,
`total_cost_usd: 0`, zeroed `usage`, empty `modelUsage` / subagent
stats, `permission_denials: []`, `queued_turn_count: 0`.
**Normalizer warning (VERIFIED quirk): `subtype` stays `"success"`
while `is_error` is true — completion classification must key on
`is_error`/`terminal_reason`, never on `subtype`.** The success-path
result shape was UNVERIFIED when this was written; Part 2 has since VERIFIED it (see Result frame, success path).

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

## Environment note (why no tool ran in Part 1 — Part 2 ran operator-side under working auth)

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
UNVERIFIED). Area 2 was **blocked** on tool-boundary frames (c) when
this was written; Part 2 has since VERIFIED the boundary pair (see (c
revisited)).
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
  protocol does not emit. `Ecto.UUID.cast/1` accepts both. (Recorded as
  baseline in `README.md` §1 — not a convention fork.)
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

## Verdict for WP D dispatch (ORIGINAL — SUPERSEDED by Part 2 below; retained as the auth-blocked record)

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

## Part 2: successful tool-exercising capture (operator-run, 2026-09-06)

My sandbox cannot authenticate (401 — environment limitation, not the
account), so per instruction I ran no further live `claude` invocation.
The operator ran the vetted capture from an authenticated shell:
prompt as vetted, `hello.txt` really created, **exit=0** (operator
report; `capture.stderr` is 0 bytes), 8 stream-json frames, 8931 raw
bytes. I verified every claim below against
`/tmp/claude-cap-0s49/capture.jsonl` myself; nothing is taken on trust.
Committed redacted fixture:
`fixtures/claude/stream-json-tool-exec.jsonl` (6781 bytes).

Baseline note (corrected): the true baseline at fafa7ba is **692
tests, 0 failures** — the 675 figure in my original brief was the
2288ca4 baseline. My Part 1 "discrepancy" note was wrong; 692/0 is the
expected gate.

### Frame ordering (exactly as captured — VERIFIED)

`system/init` → `rate_limit_event` → `assistant/tool_use` →
`assistant/tool_use` → `user/tool_result` → `user/tool_result` →
`assistant/text` → `result`. Both STARTs precede both ENDs — a
normalizer must **not** assume start/end alternation; per-tool
correlation is by id, not by adjacency.

### (c revisited) TOOL BOUNDARY EXISTS (VERIFIED — the blocking unknown is answered)

- START: `assistant` frame, content block `{type: "tool_use",
  id: "toolu_…", name: "Bash", input: {command, description}}`
  (2 observed: `printf 'hello\n' > …/hello.txt && cat …/hello.txt`
  and `printf ok`). Each block also carries `caller: {type: "direct"}`
  (recorded, uninterpreted).
- END: `user` frame, content block `{type: "tool_result",
  tool_use_id: "toolu_…", content, is_error: false}`, **plus** a
  frame-level `tool_use_result: {stdout, stderr, interrupted,
  isImage, noOutputExpected}` carrying the captured stdio verbatim
  (`stdout: "hello"` / `"ok"`, `stderr: ""`).
- Correlation: `tool_result.tool_use_id` ↔ `tool_use.id` exact match on
  both pairs (verified programmatically raw and redacted). This is the
  safe-boundary signal the lease rule needs: a command's completion —
  with its failure flag (`is_error`) and output — is identifiable per
  tool call.
- Framing subtlety (VERIFIED): lines 2–3 share one `message.id` and one
  `request_id` while carrying different `tool_use` blocks — a single
  assistant message spans multiple frames, one tool-use block per frame.
  Message identity ≠ frame identity; correlate tool calls by `toolu_`
  id, not by frame or message id. Line 6 (final text) has a new
  `message.id`/`request_id`; `num_turns: 3` (recorded verbatim).
- Scope: Bash only. Any other tool's boundary shape is UNVERIFIED.

### Quota status signalling observed (status frame VERIFIED; refusal shape and classifier UNVERIFIED)

`rate_limit_event` frame carries `rate_limit_info: {status:
"allowed", resetsAt, rateLimitType: "five_hour", overageStatus,
overageDisabledReason, isUsingOverage, unifiedWindows: {five_hour:
{utilization, resetsAt}, seven_day: {utilization, resetsAt}}}`.
This overturns Gate 0A's `unsupported` classification for quota
*status*. Structurally similar to the Codex account/rateLimits signal,
but whether the iteration-3 classifier applies unchanged is
**UNVERIFIED** — establishing that is work package D's job. Quota
**refusal** shape is UNVERIFIED (captured status was `"allowed"` only);
the map-to-`unknown` rule stands until a refusal is live-observed.

### Result frame, success path (VERIFIED)

`is_error: false`, `terminal_reason: "completed"`, `subtype:
"success"`, `stop_reason: "end_turn"`, `num_turns: 3`,
`permission_denials: []`, plus `duration_ms/api_ms`,
`time_to_request_ms`, `ttft_ms/ttft_stream_ms`,
`first_content_frame_ms`, `total_cost_usd: 0.0847545` (the actual
spend of this capture — future capture budgeting evidence),
per-model `modelUsage`, zeroed `subagent_stats`,
`queued_turn_count: 0`. Part 1's warning holds and stays prominent:
**key completion classification on `is_error` / `terminal_reason`,
never on `subtype`** (the error path proved `subtype` lies).

### Session id (VERIFIED, unchanged)

Same UUIDv4 `session_id` top-level on all 8 frames. Init confirms
`claude_code_version: "2.1.261"`, `model: "claude-opus-5"`,
`tools: ["Bash"]` (`--tools` restriction honored),
`permissionMode: "bypassPermissions"`, `apiKeySource: "none"`.

### Still UNVERIFIED (explicitly)

Resume completion, cancellation semantics (no in-band interrupt
equivalent to Codex `turn/interrupt` was exercised or observed),
quota refusal shape, any tool other than Bash.

### Redaction record, second fixture

Same convention: session id → `aaaaaaaa-…-0002` (global 1:1; …-0001 is
Part 1's session), 8 frame `uuid` → `bbbbbbbb-…-0008–0015` (all
observed v4), `message.id` → `msg_…01–02`, `toolu_…` → shape-preserving
`toolu_`-prefixed synthetics (prefix + 24 alphanumerics, correlation
re-verified after substitution), `request_id` likewise (`req_` + 24).
Operator path `/private/tmp/claude-cap-0s49` → `/tmp/claude-exec-spike`
consistently in all 5 occurrences (cwd, both tool commands, both result
texts — internal consistency preserved). Emptied: `slash_commands`,
`terminal_slash_commands`, `agents`, `skills`, `plugins`,
`mcp_servers` (non-empty here — operator-local servers),
`memory_paths`; socket → `REDACTED`. Timestamps, `resetsAt` epochs,
costs, usage counters, and model names kept verbatim. No
thinking/reasoning blocks were emitted. Key-set parity raw-vs-redacted
verified programmatically.

### Verdict for WP D dispatch (revised — supersedes Part 1)

WP D is unblocked for its two load-bearing inputs: tool boundary
frames (start/end pair, id-correlated, with per-command completion
status) and quota status frames are now committed evidence. Remaining
UNVERIFIED items (resume completion, cancel, refusal shape, non-Bash
tools) are bounded follow-ups, not feasibility blockers.
