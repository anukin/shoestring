# Claude headless execution probe (zero-token) — WP D feasibility

## Question

Can iteration 4 work package D (a Claude headless execution adapter
conforming to the same semantic contract as the merged Codex app-server
adapter) be built, and on what evidence?

## Cost boundary (strictly observed)

This probe spent **zero tokens**. No invocation reached the model.

- Ran: `claude --version`, `claude --help`, `claude -p --help`,
  `claude stop/logs/attach --help`, and invocations that fail argument
  validation and exit before contacting the API (invalid
  `--output-format` choice, missing input, unmet flag requirements).
- Read: local install metadata
  (`/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/package.json`,
  `sdk-tools.d.ts`) and repo evidence
  (`plans/evidence/00a-capacity-feasibility/`, `tools/gate_0a/`).
- Did NOT run: any `claude -p` invocation with a prompt or stdin input.
  No live capture was performed.

## Environment

| Field | Value |
| --- | --- |
| CLI | `claude 2.1.261 (Claude Code)` (`claude --version`, this machine) |
| Gate 0A CLI | `2.1.251` (Aug 2026 — older than installed) |
| Base | `main @ 97f10f1`, branch `polly/iter4-claude-probe` |

## Label convention

Per milestone convention: **VERIFIED** = live-observed with a committed
frame — the word is expensive and is reserved for provider-behavior
claims backed by a committed live frame. Static reading of this
repository (directory listings, committed code, committed fixtures) is
labeled **REPO-INSPECTION**. Anything from `--help` output, install
metadata, or bundled types is **SCHEMA-ONLY**. Anything unknown is
**UNVERIFIED**. No help-text claim below is labeled VERIFIED.

## Ground-truth inventory (what exists today)

- `plans/evidence/00a-capacity-feasibility/fixtures/claude/` contains
  **only** capacity/status-line fixtures (`auth-preflight-live.json`,
  `status-line-*-live.json`, `refusal-unverified.json`, replay/parser
  cases). There is **not one execution/event fixture**. (REPO-INSPECTION —
  directory listing.)
- Gate 0A's exact stream-json invocation is recovered from
  `tools/gate_0a/provider_probe.js:250-264` (REPO-INSPECTION — committed code):

  ```text
  claude --print --no-session-persistence --permission-mode dontAsk \
    --output-format stream-json "Reply with exactly OK."
  ```

  Outcome recorded in the committed fixture
  `test/fixtures/capacity/claude/auth-preflight-live.json` (REPO-INSPECTION —
  fixture contents):
  `outcome: process_error, exit_status: 1, message_type_counts: {}`,
  `elapsed_ms: 1056`. The sibling `json`-mode probe with the same prompt
  completed (`exit_status: 0`, one `result` message, `elapsed_ms: 2415`).
- **Evidence gap in Gate 0A:** the probe spawned with
  `stdio: ["ignore", "pipe", "ignore"]` — stdout was parsed, **stderr was
  discarded**. Whatever error text the CLI printed (usage error, quota
  refusal, crash trace) is lost. Any re-probe must capture stderr.

## Lead hypothesis — verdict: KILLED in its strong form

Hypothesis: `claude -p --output-format stream-json` fails unless
`--verbose` is also passed, so Gate 0A's status-1 was an argument error,
not a provider/protocol failure.

Against it, three SCHEMA-ONLY observations on 2.1.261:

1. `claude --help` documents `--output-format` as
   `"text" (default), "json" (single result), or "stream-json" (realtime
   streaming)` with the sole requirement `(only works with --print)`.
   No `--verbose` coupling is documented. `--verbose` is documented
   only as `Override verbose mode setting from config`.
2. The parser enumerates the valid choices itself (live-observed
   validation error, zero tokens):
   `Allowed choices are text, json, stream-json.` — no `--verbose`
   mention.
3. `claude --output-format stream-json` (no `-p`, no prompt) proceeds
   *past flag parsing* to input validation:
   `Error: Input must be provided either through stdin or as a prompt
   argument when using --print` (exit 1, zero tokens). Adding
   `--verbose` produces the identical error. The flag combination is
   accepted; nothing demands `--verbose`.

And one REPO-INSPECTION fact: Gate 0A's failing invocation was well-formed —
same arg shape as the sibling `json` probe that succeeded, with a real
prompt, and it failed fast (1056 ms) at runtime. That is not the shape
of the missing-input validation error above.

**Conclusion:** Gate 0A's `status 1, no structured messages` was a
genuine **runtime** failure on 2.1.251, not an argument error. The
`--verbose` theory does not explain it. Open causes (UNVERIFIED):
a 2.1.251-era stream-json bug since fixed, a provider/quota error whose
text went to discarded stderr (7-day usage was already 94% that day),
or a `--no-session-persistence` × `stream-json` interaction. Only a
live capture with stderr retained can distinguish these.

## Schema answers (help/docs/bundled-types only)

### 1. Headless `-p` output formats (SCHEMA-ONLY)

| Format | Meaning per `--help` | Requires |
| --- | --- | --- |
| `text` | default | `--print` |
| `json` | single result | `--print` |
| `stream-json` | realtime streaming | `--print` |

Layered flags and their documented requirements (each confirmed by a
live-observed validation error, zero tokens):

- `--include-partial-messages`: requires `--print` + `--output-format=stream-json`.
- `--forward-subagent-text`: only with `--print` + `--output-format=stream-json`.
- `--include-hook-events`: only with `--output-format=stream-json`.
- `--input-format stream-json`: requires `output-format=stream-json`.
- `--replay-user-messages`: requires both input- and output-`stream-json`.
- `--fallback-model`, `--max-budget-usd`, `--no-session-persistence`,
  `--permission-prompts`: only with `--print`.

### 2. Session id / resume (SCHEMA-ONLY for flags, UNVERIFIED for stream)

- `-c, --continue`: continue the most recent conversation in the
  current directory.
- `-r, --resume [value]`: resume by session ID, or interactive picker
  with optional search term.
- `--fork-session`: with `--resume`/`--continue`, mint a new session ID
  instead of reusing the original.
- `--session-id <uuid>`: pin a specific session ID (must be a valid
  UUID — parser-enforced shape, same constraint ContractSuite area 3
  asserts via `Ecto.UUID.cast/1`).
- Whether `session_id` is exposed inside the `stream-json` event stream
  (needed for `RunIdentity.provider_session_id`, ContractSuite area 3)
  is **UNVERIFIED** — no frame has ever been observed.

### 3. Cancellation: process-kill only (SCHEMA-ONLY)

No in-band interrupt exists in the documented surface. The only
stop mechanism is `claude stop|kill <id>`, whose help covers
**background (`--bg`) sessions only** — host-side process control, not
a turn interrupt for `-p` runs. There is no equivalent of Codex's
`turn/interrupt` (which WP C proved in-band). A Claude adapter's
`:cancel` would therefore be `SIGTERM`/`killpg` against the spawned
process group — and the milestone's lease **safe-boundary** rule (wait
for in-flight command completion, then interrupt before the next item)
additionally depends on item-boundary events that are UNVERIFIED
(see 5). ContractSuite area 2/7 cancel shapes are mappable to
kill-based cancel; safe-boundary cancel is not.

### 4. Working directory: spawned-process cwd + `--add-dir` (SCHEMA-ONLY)

The full `--help` surface contains **no `-C`/`--cd`/`--cwd` flag**.
Working directory must be pinned via the spawned process's cwd. Tool
access beyond cwd is extended with `--add-dir <directories...>`
(`Additional directories to allow tool access to`). `--tools ""`
disables all tools; `--tools "Bash,Edit,Read"` selects from the
built-in set. (Related but distinct: `-w/--worktree` creates a git
worktree for the session.)

### 5. Tool/command boundary events: UNVERIFIED (adapter blocker)

Nothing in `--help`, install metadata, or the bundled
`sdk-tools.d.ts` (which covers only tool *input/output* shapes —
`BashInput`, `FileEditInput`, `TaskCreateInput`, etc., SCHEMA-ONLY
tool vocabulary) documents the `stream-json` envelope or per-tool-use
boundary events. The layered flags *imply* a stream containing
assistant messages, partial chunks, subagent text/thinking blocks, and
hook lifecycle events (SCHEMA-ONLY inference), but no equivalent of
Codex's `item.started`/`item.completed` with process handles is
documented anywhere readable without spending quota. **Without real
frames, the normalizer cannot know where a command starts/ends, so the
lease safe-boundary rule cannot be honored for Claude.** This is the
load-bearing unknown for WP D.

### 6. Quota refusal shape: unchanged — still none (UNVERIFIED, rule stands)

Nothing in 2.1.261's help surface documents a refusal/exit-code/quota
shape, and no new local evidence contradicts Gate 0A's finding of no
reliable refusal signal. The Gate 0A rule therefore stands for any
future adapter: map exit-nonzero/stderr failures to `unknown` +
checkpoint, and **never classify a generic Claude error as quota**
(ContractSuite area 4's `:quota_refused` path must stay unwired until
a refusal shape is live-observed with a committed frame).

## Contract mapping (Codex parity checklist)

Reference: `lib/shoestring/harness/adapter.ex` callbacks,
`test/support/harness_contract_suite.ex` (7 areas),
`lib/shoestring/harness/codex_app_server/{session,event_normalizer}.ex`.

| Contract area | Claude status |
| --- | --- |
| 1 identity/capabilities | Mappable (SCHEMA-ONLY): static identity, `:resume`/`:cancel` declarable. |
| 2 start/stream/completion/failure/cancel | **Blocked (UNVERIFIED):** zero stream frames observed; kill-based cancel mappable, safe-boundary cancel not. |
| 3 resume | Flags exist (SCHEMA-ONLY); session-id-in-stream UNVERIFIED. |
| 4 quota refusal | Must map to `unknown` + checkpoint per Gate 0A rule; `:quota_refused` unwired. |
| 5 missing capacity | Mappable (same snapshot degradation pattern). |
| 6 secret-free | Mappable (Codex scrubber pattern reusable; redact per `04-single-elf/README.md`). |
| 7 terminal idempotency | Mappable for kill-based cancel. |

## Verdict: WP D needs a tool-exercising live capture — it cannot proceed hermetically, and Claude headless is not proven unusable

- **Cannot proceed hermetically:** writing the normalizer now would be
  guesswork over an unobserved event vocabulary — the exact failure
  mode this milestone has already paid for twice. Areas 2 and 5 are
  hard-blocked on real frames.
- **Not proven unusable:** `json` headless mode completed live under Gate 0A
  (VERIFIED by Gate 0A — committed frame in `auth-preflight-live.json`:
  `exit_status: 0`, one `result` message),
  `stream-json` parses as a valid `-p` combination on 2.1.261
  (SCHEMA-ONLY + validation probes), and Gate 0A's failure is pinned
  to an older version with its stderr evidence discarded. The
  `unsupported` classification may be stale.
- **One tool-exercising live capture required.** A tools-disabled
  capture provably cannot emit the tool-boundary frames that block WP D,
  so the capture must exercise tools — one file write plus one
  deterministic command, in the same shape as the Codex exec spike, in a
  disposable `/tmp` git repo. The single command (needs the human's
  explicit go-ahead; spends Claude quota — one short turn, `Bash` tool
  only, stderr retained this time, `< /dev/null` so no stdin prompt is
  ever read):

  ```text
  FIXTURE_DIR="$(mktemp -d /tmp/shoestring-claude-probe-XXXXXX)" && \
  git -C "$FIXTURE_DIR" init && \
  (cd "$FIXTURE_DIR" && claude --print --output-format stream-json \
    --dangerously-skip-permissions --tools "Bash" \
    "create a file hello.txt containing the word hello, then run: printf ok" \
    < /dev/null \
    > "$FIXTURE_DIR/claude-stream-capture.stdout.jsonl" \
    2> "$FIXTURE_DIR/claude-stream-capture.stderr.txt"; echo "exit=$?")
  ```

  Amendments and expectations (all part of the authorized plan):
  - (a) **Version pinning:** record `claude --version` at capture time
    into the evidence doc. Both hard findings on the exec spike
    (PR #23) were version-sensitive; the Gate 0A failure is already
    pinned to 2.1.251 vs 2.1.261 here, and the capture must be pinned
    the same way.
  - (b) **Permission flag:** `--dangerously-skip-permissions` is needed
    because a non-interactive `--print` run that reaches a tool
    permission prompt has no human to answer it — the run would hang or
    deny, and a denied tool call answers nothing about boundary-event
    shapes. Blast radius is confined to a disposable `mktemp -d` repo
    under `/tmp` with `--tools "Bash"` only. Whether the narrower
    `--permission-mode dontAsk` (which Gate 0A used, but only with a
    tool-free prompt, so it never proved tool auto-approval) achieves
    the same auto-approval **cannot be established from `--help`/schema
    without a live call — UNVERIFIED, not guessed.** At capture time,
    prefer attempting the narrower flag first; escalate to the bypass
    only if the run denies or hangs. Honest cost note: a denied first
    attempt still spends quota (the model turn happens before the tool
    denial), so the human may prefer authorizing the bypass up front
    rather than paying for two turns.
  - (c) **Labeled expectations:** this capture answers Q5 (tool
    boundary — EXPECTED, pending live frames), Q1 (envelope shape —
    EXPECTED), and Q2-partial (whether a session id is exposed in the
    stream — EXPECTED). It does **not** prove resume: verifying
    `--resume`/`--continue` DEFINITIONALLY requires a SECOND invocation
    against the persisted session, which is out of scope for this
    single capture and needs its own authorization.
  - (d) **Redaction plan (before capture, not after):** the resulting
    fixture must follow `plans/evidence/04-single-elf/README.md` —
    format-valid but SYNTHETIC identifiers with version/variant nibbles
    preserved, no home-directory paths, no machine metadata, < 50 KB.
    Claude `stream-json` may carry assistant reasoning content, which
    the milestone forbids persisting: at redaction time, drop every
    frame whose type/name suggests reasoning, thinking, or scratchpad
    use, and record the dropped type names in the evidence doc. The raw
    capture under `/tmp` is never committed; only the redacted fixture
    lands at `test/fixtures/claude/execution/stream-json-*.jsonl`. Only
    then can WP D be dispatched. A `--verbose` variant is a possible
    *follow-up*, not a substitute — it would change framing
    comparability with the Gate 0A invocation.
- **Session persistence is deliberately ON for this capture**
  (`--no-session-persistence` dropped): persisting session state is what
  leaves a session on disk for the later second-turn resume test, at
  zero extra token cost. Consequence stated plainly: the capture WILL
  persist a session transcript locally — the same class of
  provider-side residue documented for Codex rollouts
  (`ephemeral: false` in the app-server session). Prompts must stay
  credential-free for the same reason.
- **Capacity note (historical, not current):** the 94% seven-day figure
  is from 2026-08-29 07:34:19 UTC with `seven_day.resets_at:
  1788033600` (= 2026-08-29 20:00 UTC) — that window rolled over a week
  ago (today is 2026-09-05) and says nothing about current refusal
  risk. No current capacity reading is obtainable from our committed
  monitors without a live provider call (snapshots live only in
  `ClaudeMonitor` GenServer memory; no snapshot is persisted to the
  repo), so current capacity is **UNKNOWN**.
