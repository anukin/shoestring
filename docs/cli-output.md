# CLI output contract

Both installations run the same `shoestring` commands (`Shoestring.CLI.Main`):
the Homebrew/release command, and `bin/shoestring` in a source checkout. They
take the same arguments and print the same output. The release command
`shoestring start | init | doctor | version | text | diagnostics-*` manages the
service; everything else is a work command:

| Command | What it does |
| --- | --- |
| `do "REQUEST"` | plan, approve and run a request in the current Git repository |
| `follow GOAL` | follow a goal and answer what it waits for |
| `result GOAL` | a completed goal's verified result and how to take it |
| `review list\|show\|accept\|reject\|retry` | cross-reviews and your decisions on them |
| `checks GOAL [--output N]` | the checks a goal ran, or one check's stored output |
| `goals`, `plans`, `execution`, `agents`, `models`, `reservations` | the step-by-step commands |

`shoestring COMMAND --help` prints a command's usage on stdout.

## Streams

- **stdout carries data only**: IDs, results, JSON. Redirecting it gives you
  something to parse or keep.
- **stderr carries everything else**: the plan you are asked to approve,
  questions, progress, notes and errors. Log output from the runtime goes to
  stderr as well.

Examples: `shoestring do "..." --no-follow` prints only the goal id on stdout.
`shoestring checks GOAL --output 3 > out.txt` writes exactly the recorded
(redacted) output bytes; the line describing the check and its digest goes to
stderr. Questions are asked on stderr and answered on stdin.

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | done (for `do --no-follow`: queued) |
| 1 | refused: one line on stderr says why and what to do |
| 2 | invalid arguments: `Invalid arguments. See shoestring COMMAND --help` |
| 3 | `do` or `follow` ended without completing: declined, held, cancelled, or waiting for you |

A refusal is never a stack trace.

## Which state the command uses

The command uses the same state directory as the service: the default for
the installation, or `SHOESTRING_STATE_DIR`. The installed command opens the
database only when its schema is exactly the installed release's, and never
creates or migrates it:

- no database: `No Shoestring database in the state directory. Run shoestring
  init, or set SHOESTRING_STATE_DIR to the service's.`
- pending migrations (a newer release installed over older state): `The state
  database needs an upgrade. Stop the service, then run shoestring init (it
  backs the database up first).`
- a database from a newer release: `The state database is newer than this
  shoestring command. Use the newer release.`

The checkout's `bin/shoestring` opens state the way the Mix tasks always have.

Commands that need the running service say so and how to start it, and never
start one: `do` before it records anything, and `follow` for a goal that has
not finished (`The Shoestring service is not running. Start it in another
terminal: shoestring start`). `do` also refuses a service that uses a
different database.

## `--json`

Every command that prints data accepts `--json` and then prints exactly one
JSON document on stdout. Messages still go to stderr. `goals`, `plans`,
`execution`, `models`, `reservations` and `agents show|create|set-role|default`
always print JSON; for them `--json` changes nothing. `doctor` prints JSON and
accepts `--json` too.

Shapes (fields may be added; existing fields keep their meaning):

### `do --json`, `follow --json`

```json
{
  "goal_id": "UUID",
  "state": "queued | completed | declined | held | needs_user | cancelled | stopped",
  "execution_id": "only from do, once queued",
  "revision": 1,
  "result": { "...": "the result --json object, when completed" },
  "result_error": "only when the goal completed but its result could not be read"
}
```

### `result --json`

```json
{
  "goal_id": "UUID",
  "commit": "final commit SHA",
  "base": "approved base SHA",
  "worktree": "private worktree holding the commit",
  "repository": "your repository",
  "checks": [{"argv": "...", "exit_status": 0, "required": true, "last_line": "OK"}],
  "reviews": [{"plan_task_id": "...", "attempt": 1, "reviewer": "codex", "model": "...",
               "unavailable": null, "state": "approved", "blocking": 0, "findings": []}],
  "diff_stat": ["calc.py | 2 +-", " 1 file changed, ..."],
  "take": ["cd REPOSITORY", "git fetch WORKTREE COMMIT", "git merge FETCH_HEAD"]
}
```

`diff_stat` is `null` when `git diff` failed. Shoestring never runs the
`take` commands.

### `checks --json`

```json
{
  "goal_id": "UUID",
  "checks": [{
    "number": 1, "scope": "task | final", "plan_task_id": "alpha", "attempt": 1,
    "gate": "python_unittest", "kind": "test", "required": true,
    "spec": "python_unittest@1:sha256:HEX",
    "result": "passed", "exit_status": 0, "duration_ms": 412, "commit": "SHA"
  }]
}
```

`result`, `exit_status`, `duration_ms` and `commit` are `null` when no
completion was recorded. With `--output N --json`:

```json
{
  "goal_id": "UUID", "check": { "...": "as above" },
  "output": "the recorded bytes", "encoding": "utf-8 | base64",
  "bytes": 1234, "sha256": "hex digest of the bytes",
  "partial": false, "truncated": false
}
```

Output that is not valid UTF-8 is base64-encoded.

### `review --json`

`review list GOAL --json` prints `{"goal_id", "reviews": [REVIEW]}` and
`review show GOAL TASK --json` prints `{"goal_id", "review": REVIEW}`, where
REVIEW is:

```json
{
  "review_id": "...", "plan_task_id": "alpha", "attempt": 1, "round": 1,
  "state": "escalated", "reviewer": "codex", "model": "...", "unavailable": null,
  "commit": "SHA", "calls": 1, "needs_user": true, "reason": "...",
  "findings": [{"id": "F1", "severity": "blocking", "path": "calc.py", "line": 2,
                "claim": "...", "correction": "..."}]
}
```

`review accept|reject|retry ... --json` prints `{"goal_id", "plan_task_id",
"review_id", "decision", "state": "recorded"}`.

### `agents list --json`

`[{"slug": "builder", "name": "Builder", "revision": 3}]`. Without `--json`,
one tab-separated line per agent.

## `doctor` agent readiness

`shoestring doctor` reports `agents`: for each supported agent CLI (Claude,
Codex and opencode) its readiness for task work, the CLI version, its worker
mode and the versions that mode was tested with:

| Readiness | Meaning |
| --- | --- |
| `binary_missing` | the CLI is not on `PATH` |
| `not_checked` | installed; the passive doctor runs no provider command |
| `needs_sign_in` | the CLI's own status command reports it is not signed in |
| `version_untested` | outside the versions its worker mode was tested with |
| `ready` | installed, signed in by its own report, a tested version |
| `unknown` | the probe could not tell |

Only `shoestring doctor --probe-providers` runs the provider CLIs, and only
for `--version`, `claude auth status` and `codex login status`, never a model
prompt (see [releases](releases.md#first-run-and-doctor)). Reported sign-in is
not proof that a later run will succeed. opencode is asked only for its
version: its status commands start a background server, so its sign-in is not
detectable and a tested opencode is `unknown`, never `ready`
([opencode worker](opencode-worker.md)).
