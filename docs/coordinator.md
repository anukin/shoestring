# Working with a coordinator

Iteration 14 lets a coding CLI you chat with — Claude Code, Codex or opencode
— act as a coordinator: it plans with you and hands tasks to Shoestring,
which runs each one as a sandboxed Elf on the harness and model it chose.
This page covers `shoestring chat`, grants, EXPLORE, IMPLEMENT and REVIEW
dispatches (an IMPLEMENT can also be cross-reviewed), `wait`, `runs`, `advice`
and `capacity`.

## Context between agents

The native coordinator retains a provider session; Shoestring records visible
conversation events and resumes that same session after a restart. Rebuilding
the screen makes no model call. Missing provider history refuses a resume;
Shoestring does not silently replace it with a fresh conversation. Provider
history and compaction are managed by the coding CLI, separately from the
visible history in Shoestring.

Workers receive their own brief, task contract and repository snapshot, not
the chat or other workers' transcripts. The coordinator must read an
explorer's report with `runs_show` and put relevant findings and requirements
in the next brief. Review packets carry the original implementation brief
and, for an explicit REVIEW dispatch, its review brief as labelled data,
alongside the contract, diff and checks. Secret-looking values are redacted.
Changing a brief changes the immutable packet digest.

Every dispatch works on a private copy of the repository at `HEAD`, so
uncommitted paths of your checkout are never in it. EXPLORE and REVIEW go
ahead anyway and name those paths in `left_out`, so the coordinator can tell
you when one matters. IMPLEMENT refuses while tracked files are changed (its
commit would not build on what you see) and goes ahead with untracked files,
naming them the same way. Notes you never commit can go in
`.git/info/exclude`.

Completing one IMPLEMENT does not automatically give the next dispatch its
code: dispatches snapshot the repository's current HEAD. Integrate the
accepted commit before dispatching dependent work. No shared cross-session
lessons library is supplied by native chat.

A long conversation continues with `/handoff`: the session, grant and
dispatches stay; a fresh coordinator conversation starts with Shoestring's
facts (the grant's remaining room and every dispatch with its state and
commit) and the old coordinator's note (intent, decisions, open questions),
written in one charged turn. `/handoff facts` skips the note. Details are in
`docs/chat-channel.md` (Handoff).

Hermetic tests cover report-to-worker-to-review delivery, scripted provider
context across process and engine restarts, session isolation, missing
history, and visible input/output limits. These prove protocol and context
delivery, not real-model recall quality. No live semantic memory eval has
been run for these changes.

## Start a coordinator

```sh
cd ~/code/my-project
shoestring chat                            # Shoestring's chat screen, the default agent's Coordinator
shoestring chat --coordinator claude:MODEL # another model, this session only
shoestring chat --session ID               # reattach an earlier session
shoestring chat --external                 # the coordinator's own CLI instead (below)
shoestring chat list                       # sessions, their grants and dispatches
```

A new session first shows the grant it proposes — the agent's Worker,
Reviewer and other roles' models, every purpose, and `shoestring grant`'s
default limits, including 20 coordinator turns — and starts only after you
confirm it.

### The chat screen (iteration 15)

`shoestring chat` opens a terminal screen: the conversation, an Agents pane
with every dispatch of the session, an input line, and a status line with
the grant's turns and each provider's usage. The service drives the
coordinator headlessly (Claude Code, Codex or opencode) with
instructions on using Shoestring's tools (`priv/coordinator/conversation.md`),
read-only in your checkout: it can read files and nothing else, and hands
every change to Shoestring. It is never sent a message mid-turn; when a
dispatch settles Shoestring wakes it with an inbox message.

- Enter sends; Alt+Enter or Ctrl+J adds a line; pasting keeps line breaks.
- The input edits like a shell: Ctrl+A / Ctrl+E (Cmd+Left / Cmd+Right) go to
  the line's start and end, Option+Left / Option+Right (or Ctrl) move by word,
  Up and Down move between lines, Ctrl+W deletes a word back and Ctrl+K /
  Ctrl+U delete to the line's end / start.
- Typing `/` lists the commands that match; Up and Down choose, Tab
  completes and Enter runs the highlighted one. A message with a space in it
  is sent as typed.
- PgUp and PgDn scroll the conversation back and forward; new lines leave
  what you are reading in place, and sending a message returns to the latest.
- `/cancel` interrupts the coordinator's turn, `/status` shows the session
  from Shoestring's own state, `/help` lists the keys, `/exit` or Ctrl+C
  leaves.
- Leaving, or losing the terminal, leaves the conversation and every
  dispatch running; `shoestring chat --session ID` shows it all again. The
  service starts the conversation again when it restarts, and a turn whose
  end it never saw is shown as such and never sent twice.
- Each coordinator turn counts against the grant (`--max-turns`, wake-ups
  included) and goes through admission like any call to its provider.
- Model and agent text is shown with terminal control sequences removed.

The screen is a separate program (`native/chat_client`, built by
`mix chat_client.check` in a checkout and shipped in the release). It
connects to the service on loopback with a token only you can read
(`docs/chat-channel.md`).

### Your own coordinator CLI (`--external`)

`--external` starts the coordinator CLI in your terminal with instructions
on handing tasks to Shoestring (`priv/coordinator/instructions.md`, plus the
session, its grant, the agent's roles and its instructions). How each CLI
receives them:

| Coordinator | Model | Instructions | Status |
| --- | --- | --- | --- |
| Claude Code | `--model` | `--append-system-prompt-file` | in the request 2.1.310 sends |
| Codex | `-m` | `-c developer_instructions='''...'''` | a developer message in the request 0.164.0 sends |
| opencode | `OPENCODE_CONFIG_CONTENT` `model` | its `instructions` | in the request 2.0.31 sends |

Each was checked offline against a local stand-in for the model API, in the
CLI's non-interactive mode (`plans/evidence/14-coordinator-orchestration`);
the interactive start `chat --external` uses is not yet checked in a live
session.

That coordinator is your own session of that CLI, under its own permission
prompts; Shoestring does not sandbox it, and its instructions tell it not to
edit your checkout. Shoestring's own guarantee that your checkout is never
changed covers Shoestring and its Elves, not that CLI. `--session` starts a
new conversation in the CLI; the coordinator reads what was already
dispatched with `shoestring runs list`. From the source checkout use
`bin/shoestring chat`; `mix shoestring.chat` prints the launch instead of
starting it.

## 1. Grant the session an allowance

`shoestring chat` asks for this when a session starts. To grant one yourself:

A grant is your decision, so you make it yourself, in a terminal:

```sh
cd ~/code/my-project
shoestring grant --models codex:gpt-6-luna,claude:opus \
  --max-dispatches 10 --max-parallel 3 --max-hours 4
```

It shows the grant and asks before saving, and prints the session id to give
the coordinator (`export SHOESTRING_SESSION=…`). Without a terminal it
refuses: a coordinator, which runs commands without one, cannot grant
itself. The grant covers one repository and these limits:

Pass `--team builder` (or another saved team name) to record that team's
agents, per-agent time limits and lesson switches, as chat does. The model
allowlist still comes from `--models`; choosing a team does not widen it.

| Limit | Default | Meaning |
| --- | --- | --- |
| `--models` | required | the only models it may dispatch to (enabled ones) |
| `--purposes` | all | `explore`, `implement`, `review` |
| `--max-dispatches` | 10 | attempts in total, retries included |
| `--max-parallel` | 3 | dispatches queued or running at once |
| `--max-hours` | 4 | the time its dispatches may reserve in total |
| `--max-dispatch-minutes` | 60 | the most one dispatch may reserve |
| `--unread-usage` | 0 | dispatches it may start when a provider's remaining usage cannot be read |
| `--max-turns` | 20 | turns of a coordinator conversation in the chat screen, wake-ups included |

Nothing is estimated: each limit is a count or a time Shoestring checks
before it records a dispatch. The standing usage reserves still apply to
every dispatch. `shoestring grants list|show` print each grant, its use and
its history; `grants extend` widens one (`--turns N` adds coordinator
turns) and `grants revoke` stops new dispatches and turns (running work
continues) — both ask you, in a terminal.

### Teams and agents (iteration 16)

An agent is one job done one way: a Coordinator, Explorer, Implementer or
Reviewer, with its model, effort and the most minutes one of its dispatches
may take (none of its own by default; the grant's per-dispatch limit still
applies). A team, such as `builder`, names an agent for each role, and an
agent may serve in several teams; editing it saves a new revision of each.
The Implementer's role keeps its earlier name, Worker.

`shoestring chat` records the team on the session's grant when it creates
it, and shows its agents and their limits before you confirm. The
coordinator then dispatches by agent (`agent: "explorer"`, or the agent's
slug) and sizes `minutes` within the agent's limit. A limit bounds every
dispatch of that job on that model, however it is named; asking for more is
refused and the coordinator is told to ask you. A session started before
keeps working without a team: its dispatches name a worker.

**Permissions beyond the sandbox.** Every worker runs sandboxed: it writes
only its own worktree and private Git storage, cannot read the rest of your
home folder, and has no network. On an Implementer's page (Agents → Edit)
you may add folders it may also read, folders it may also read and write,
and network hosts, one per line. Your home folder itself, anything above it
and Shoestring's own state are refused. A session records them with its
team when it starts, so later edits reach new sessions only.

| | Folders | Network |
| --- | --- | --- |
| Claude | added to its sandbox's read and write lists | the hosts you list (`github.com`, `*.npmjs.org`) |
| Codex | added to the run's permission profile | all or nothing: `*` turns it on for every host |
| opencode | fixed; nothing can be added | fixed |

Codex cannot limit its network to some hosts (a host list let every host
through, checked offline with Codex 0.166.0), so the page only takes `*`
for it. Claude lets a listed host through and refuses one not listed
(checked with a real HTTPS request through its sandbox, Claude Code 2.1.316).

**Asks while it works.** An Implementer whose "may ask" is on (the default)
can ask you, mid-run, to run one command outside its sandbox. Its worker
waits; you answer in the chat screen's popup (`y` allow once, `n` deny, `r`
deny with a reason) or with `shoestring asks`, `shoestring asks allow ASK`
and `shoestring asks deny ASK --note "..."` in a terminal. Nothing answers
an ask on a timer, and the coordinator cannot answer for you; `runs show`
tells it the worker is waiting on you. Allowing runs that one command with
full access to your files, anywhere you can write. A Codex command's network
stays as the agent's settings allow; a Claude command runs with no sandbox
at all, network included. A denial's reason is passed to the worker. Codex
workers ask through `approvalPolicy: on-request`, Claude workers through
Claude Code's permission requests (only a command it wants to run outside
the sandbox asks; commands inside it run as before). A Claude worker also
asks when one of its commands tries to reach a host not on the agent's
list: allowing it lets its commands reach that host for the rest of the run
(Claude remembers it; it does not ask again), and to allow a host for every
run you add it to the agent's hosts. A denial's reason is not passed on for
a host; the worker sees the refused connection, so the popup offers no `r`
there. opencode workers do not ask. An ask whose worker stops (a cancel, a restart) ends unanswered.

**Allow for this agent.** For one plain command, `a` in the popup (or
`shoestring asks allow ASK --for-agent`) allows it and lets that agent's
workers run exactly the same command again without asking; the ask is
recorded as decided by `rule:<agent>`. Only the exact text matches, never a
prefix: a different URL or one more flag asks again. A file change, or a
command joined with `;`, `&`, `|`, backquotes, `$(` or a line break, is
never offered and always asks. The agent's page lists these commands under
"Commands it may run outside its sandbox without asking" (at most 20); you
can type one there or delete its line to remove it. They are read each time
a worker asks, so a change applies at once, also to workers already
running.

## 2. The coordinator dispatches

```sh
shoestring dispatch --purpose implement --worker codex:gpt-6-luna \
  --reviewer claude:opus \
  --title "Make add() return the sum of its arguments" --brief brief.md \
  --file calc.py --stay-out test/ --test test/test_calc.py
```

The task becomes ordinary Shoestring work: a goal, a one-task plan authored
and approved under the grant (recorded as `grant:ID`, with
`author_kind: grant`), and an execution the service runs in a private copy
of the repository at its `HEAD`. The checks decide acceptance; the result is
a verified commit to fetch and merge, and your checkout is never changed.
The worker reads the brief under "Coordinator brief". Secret-looking values
in the title or brief (`api_key=…`, `token: …`, `sk-…`) are recorded, and
given to the worker, as `[REDACTED]`; `dispatch` says so on stderr.

`--reviewer` names a model from another vendor than the worker's (the grant
must allow REVIEW and that model). Iteration 8's cross-review then runs
before the task is accepted, whatever `:plan_review` says: the reviewer gets
the task contract, the diff and the check results and no tools; blocking
findings send the task back to the worker once, and if they remain the
dispatch waits for you (`needs_you`). `runs show` lists every review round
and its findings. Without `--reviewer`, dispatched work is not reviewed.

A dispatch outside the grant is refused with the limit it would cross and
nothing is queued. A retry with the same request id (by default derived from
the session, purpose, worker, title and brief) returns the same dispatch.
`--batch LABEL --batch-size N` declares a strategy of N dispatches; one more
is refused. `--dry-run` checks the grant and the plan and records nothing.

### One task after another (iteration 16 C1)

```sh
shoestring dispatch --purpose implement --agent implementer \
  --title "Add sub()" --brief sub.md --after DISPATCH
```

`--after DISPATCH` (the tool's `after`) makes an IMPLEMENT follow another
IMPLEMENT of the same session and repository. It is recorded `chained`: its
attempts and minutes are reserved in the grant, it does not take a parallel
place, and nothing runs. Once DISPATCH completes (its checks passed, and its
review, if it had one), it starts by itself, within half a minute, from
DISPATCH's verified commit instead of `HEAD`. That commit lives only in
Shoestring's worktree; your checkout is still never changed. Its checks and
review see only its own change, and its `take` commands bring both commits.

It waits as long as DISPATCH does, a person deciding included; waiting is
never a reason to give up. It is called off, its room released, if DISPATCH
is cancelled or never started, or the grant is revoked (`runs show` says
which). Cancelling it while it waits does the same. Only an IMPLEMENT can
follow, and only an IMPLEMENT can be followed. A chain may be longer than
two; parallel work on separate files is a later package (C2).

A grant identity is accepted only through a dispatch: `shoestring plans
approve --by grant:…` is refused, a grant can approve only the exact plan
its dispatch recorded, never reject one, and cannot cancel another session's
dispatch. Review waivers, scope decisions, integration and handoffs stay
yours.

A session id is not a secret: any program on your machine that knows it can
dispatch under its grant. The grant's repository, models and limits are what
bound that.

### Tasks side by side (iteration 16 C2)

Work that splits into tasks changing separate files can go as one batch
IMPLEMENT: `tasks` (the tool) or `--tasks FILE` (a JSON list), 2 to 8 tasks,
each `{"title", "brief", "files"}`. `files` declares the files or directories
the task changes; `brief` (at most 1000 characters) is its own part, and the
coordinator's brief, checks and reviewer are shared.

- **Refused before anything is queued** when the tasks could not run side by
  side: two tasks naming the same path (or a directory and a file in it), a
  shared surface (lockfiles, `mix.exs`, `package.json`, `config/`, migrations,
  generated code), or a symlink. Split the files apart, or use `after`.
- **Whether they run at once is yours**: Settings, "IMPLEMENT tasks that may
  run at once" (default 1: one after another, as before). With more, each task
  runs in its own worktree from the same base, under iteration 7's
  reservations; that setting changes only while nothing is running or waiting.
  It also lets a `shoestring do` plan's tasks that change separate files run
  at once.
- **The grant**: a batch takes one parallel place per task, its attempts and
  minutes count per task, and it reserves the fan-out's worst-case
  verification time too; only the time actually taken counts afterwards.
- **Enforced**: a task's change outside its own `files` blocks it for you
  (`shoestring execution resolve-scope`), with its checks kept.
- **Result**: one commit per task, then one merged commit (C3). When all
  have passed, Shoestring merges the task commits one after another, in task
  order, onto the base in a worktree of its own (never your checkout), records
  that merge, and runs the global checks there. The batch completes with one
  commit, and `result.take` fetches and merges just that one. `runs show`
  lists each task and `batch.integration` (`merging`, then `merged`). A batch
  that completes can be followed with `after` like any IMPLEMENT.
- **Review and follow**: `shoestring dispatch --purpose review --of DISPATCH` can review a completed
  batch's merged commit against every task contract and its final checks.
  A batch can itself use `after`; all its children start from the
  predecessor's verified commit in private storage. It waits until the
  grant has a parallel place for every task.
- **A conflict is never resolved for you.** If a task's commit conflicts
  with those merged before it, the merge is aborted and recorded, and the
  dispatch is `needs_you`: `batch.integration` names the task and the files,
  and `batch.take` lists the commands to merge each commit in your checkout
  (resolving the conflict yourself), record that merge (`shoestring execution
  integrate`) and `continue`; the global checks then run there. A merge that
  fails for another reason waits for you the same way. Failed global checks
  also wait for you, as for any IMPLEMENT.

### Lessons (iteration 16 B)

A lesson is one rule for work in one repository, shared by every agent and
vendor that works there: "run unittest with `-B`; the bare runner finds no
tests", "never edit `priv/gen`, regenerate it". Lessons belong to the
repository (its root path): none is ever shown or cited in another.

After moving a repository, run `shoestring lessons move --from OLD_PATH --repo NEW_PATH`.
This is a person's decision in a terminal: it shows both
paths and asks before moving all lesson states, preserving codes and
provenance. The new path must be a Git repository with a commit and no
lessons of its own. Existing grants keep their original repository scope;
start a new session for the new location.

**Who proposes.** Any agent whose "may propose lessons" is on (the Agents
page; by default every job but the explorer):

- the coordinator, with `lessons_propose`, naming a dispatch of its session
  or quoting your words in its chat exactly;
- an IMPLEMENT worker, by writing `.shoestring/lessons.md` in its worktree
  (one `- ` line each, at most three). Shoestring's private storage excludes
  that path, so it is never committed or taken; Shoestring reads it when the
  dispatch settles;
- an EXPLORE or REVIEW worker, in its report's `lessons`.

A worker is told how only when its agent may propose; a call whose agent may
not is recorded exactly as before.

**Checks**, on every proposal: a source Shoestring can find, at most 1024
bytes, secret-looking values removed, not a repeat of a lesson already
proposed or approved, and room in the repository's space limit (Settings,
default 200 MB). One with much the same words as another is marked similar.

**Who approves.** The coordinator. Its own proposal is approved when it
passes the checks, unless it is much like an approved lesson; that one, and
every worker's, waits for `lessons_decide`: approve (optionally reworded),
reject, or replace the older lesson. `runs_show` lists what a dispatch's worker
proposed, and the inbox message says so.

**You** see every lesson, and have the last word, on the Lessons page or in a
terminal (agents cannot run these):

```sh
shoestring lessons list                  # this repository, proposals first
shoestring lessons show L-7F3K9Q         # source, proposer, approver, similar lessons
shoestring lessons approve|reject L-7F3K9Q [--text TEXT | --note TEXT]
shoestring lessons replace L-7F3K9Q --replaces L-2B4C6D
shoestring lessons edit L-7F3K9Q --text "reworded"
shoestring lessons retire L-7F3K9Q [--note TEXT]
shoestring lessons space                 # count and bytes, per repository and total
```

In the chat screen each lesson approved during the session is a green popup
(`o` opens it on the Lessons page, `r` retires it).

**Use.** A coordinator sees the repository's approved lessons in its
instructions (the newest 20, within 8 KiB, each time it starts) and finds the
rest with `lessons_search`. A worker sees a lesson only when its dispatch
cites it (`lessons`, or `--lesson CODE`, at most 5): its text follows the
brief, the dispatch records its code, and the lesson counts the citation.

Storage and retrieval sit behind `Shoestring.Lessons.Store` (default: this
database, matching by shared words), so a semantic or shared memory store can
replace it by configuration without changing these rules.

## 3. Wait and inspect

```sh
shoestring wait DISPATCH... [--timeout MINUTES]   # first one to settle, or exit 3
shoestring runs list                              # this session's dispatches
shoestring runs show DISPATCH                     # state, use, and the result
shoestring runs log DISPATCH [--after SEQUENCE]   # what happened, oldest first
shoestring runs cancel DISPATCH --reason TEXT     # this session's own dispatch
```

`runs log` prints the lines `follow` prints for the dispatch's goal (task
started, checks, review, acceptance), never the worker's transcript or the
brief, up to 500 events a time; pass its `last_sequence` back as `--after`
for what happened since. An EXPLORE or REVIEW dispatch has no goal, so its
log is its record and its call's times: dispatched, confirmed, admitted,
started, finished. An EXPLORE's log also shows what the explorer did while it
ran, as it happens: each command Codex starts, each file Claude reads or
search it makes (redacted, at most 200 characters each; the last 50 are
kept and earlier ones counted).

When a dispatch's task or review is held because its provider's remaining
usage cannot be confirmed — always for opencode, which reports none; always
for Claude, whose own usage reports can defer work but never admit it alone;
for Codex when its last reading is stale (a decision that finds it stale, or
within a minute of going stale, asks the running Codex app server for a fresh
reading, at most once a minute and without starting a turn, so the next
check usually admits it); never when a reserve is breached,
which defers it — `wait` and `runs show` spend one of the grant's
`--unread-usage` pre-approvals on it. Each hold is paid for once, a failed
confirmation is refunded, and the grant's history records every spend. A
confirmed hold reads `queued` until the service starts it, and wakes no
coordinator. With none left the dispatch stays `held` for you. So a grant whose Worker or
Reviewer is a Claude model needs `--unread-usage` at least the number of
Claude tasks and reviews you want to start without being asked.

EXPLORE and REVIEW are one model call each, made by the service, not a
worker run. `dispatch --purpose explore` has Claude Code (only its `Read`,
`Grep` and `Glob` tools) or Codex (its read-only sandbox, without network or
web search) read a private copy of the repository at `HEAD` and answer the
brief with a report: a summary, findings each citing files and lines, and
open questions. Code checks the report: a citation of a file the copy does
not track, or of a line past its end, is marked `supported: false`; a report
over 64 KiB fails; secret-looking text is redacted; and a copy that changed
fails the call. `dispatch --purpose review --of DISPATCH` has a model of
another vendor review a completed IMPLEMENT of the session with iteration
8's packet (its diff from its base, its contract and its checks) and
findings rules: `report.outcome` is `changes_requested` exactly when a
supported blocking finding remains. Claude calls are held until confirmed,
which a grant's `--unread-usage` pre-approval can do; a Codex call starts by
itself on a fresh reading within its reserves. `runs show` has the report
or the error. Neither changes anything.

A call takes as long as it needs, up to its time: the `--minutes` the
coordinator asked for, else the grant's per-dispatch limit. There is no
output-token allowance: the call's tokens are recorded (`runs show`) and
never fail it. It runs in its own process, not inside its job, so a long
call is not mistaken for a lost one; the service checks on it every half
minute. Cancelling a running call ends it: the CLI's whole process group is
terminated and the report is discarded. A finished dispatch counts the time
it took against the grant's total, an unfinished one all the time it may
still take.

A dispatch deferred until a usage window resets (a reserve breached, or a
worker that stopped at its limit) is `waiting`: `runs show` gives the reset
time and the reason (`waiting.until`, `waiting.reason`), and it starts again
by itself after the reset. `wait` returns when a dispatch starts waiting,
not while it already was, so the coordinator can tell you and offer another
model.

Once a task is running, its allowance is renewed against fresh usage
readings. A task admitted on a confirmation (yours, or a grant's
pre-approval) keeps it for those renewals while its provider's reading is
fresh and has both its five-hour and weekly windows. That is how a Claude
worker, whose reports alone never admit, keeps going. A stale or incomplete
reading gets no confirmation, and a breached reserve stops renewal whatever
was confirmed. A run is never cut off mid-turn for its allowance: an
allowance that is not renewed is recorded, and the turn's result stands.

States: `starting`, `queued`, `running`, `waiting` (until its provider's
usage resets; it starts by itself then), `held` (its provider's remaining
usage could not be confirmed; you confirm it with `shoestring follow GOAL`),
`needs_you` (you decide, with `shoestring follow GOAL`), `completed`,
`cancelled`, `failed_to_start`. The web dashboard (`/cobbler`) lists each
coordinator session with its grant's use and its dispatches, each linked to
its goal.
`wait` reads Shoestring's records every few seconds and makes no model call;
a coordinator can run it in the background to be woken when it exits. `runs
show` of a completed dispatch includes the commit, its checks and the
`git fetch`/`git merge` commands.

## 4. Capacity

```sh
shoestring capacity
```

Each provider's latest usage reading (as on the Usage page) and an outlook
for a new dispatch against the standing reserves: `admits` (fresh and under
80% of the 5-hour and 90% of the weekly window), `deferred` (over a reserve,
until its reset), `asks` (unknown, stale or, for opencode, never readable:
you confirm, or the grant spends an unread-usage pre-approval) or `refused`.
It is where admission starts, not its decision. `dispatch --dry-run`
includes the worker's provider.

## 5. Advice from past runs

```sh
shoestring advice
```

For each kind of run — harness, model, effort, purpose and task class (the
checks its task cites) — what its finished runs looked like: the median and
90th-percentile tokens the harness reported, the share of first attempts
that were accepted, mean attempts per task and the median duration, with the
sample count and date range. A kind needs 10 finished runs before any of
this is shown. It is plain arithmetic over Shoestring's records, makes no
model call, and never changes admission or dispatch. `dispatch --dry-run`
includes the line for the worker it names, so a coordinator can pick a
cheaper model where it does as well.

Tokens come from what each harness reports: Codex's running total, opencode's
completion usage, and Claude's result usage including cache reads and
writes. A run that reported none is counted apart, never as zero.

The usage share is how much of its provider's shortest usage window a run
used, as a median and 90th percentile per window length. Only runs the
measurement dataset can attribute have one: Codex runs with readings taken
just before and after them, inside a collection window you opened with
`mix shoestring.measurements collection open` (an agent never opens one),
with no other Codex run, EXPLORE/REVIEW call or plan review overlapping
them in any goal and no unexplained change between runs. Every other run is counted apart.
A Codex coordinator's own turns are not recorded, so close the window, or
use another coordinator, while measuring. Past the dataset's 10,000-event
limit the share says `usage_share_unavailable`.

### Native dispatch inspection and Codex coordinator

The chat screen's agents pane shows purpose, worker, reviewer, domain state,
elapsed time, reset time when waiting, and latest progress. Tab focuses it,
arrows select, Enter opens the Elf's canonical progress, checks and review
findings. Escape closes detail. `c`, then `y`, requests cancellation of exactly
the selected dispatch. Leaving the screen leaves agents running. Interactive
Elves show their `/runs/RUN/terminal` link; a headless Elf cannot be steered.
The `/cobbler` dispatch rows also link to Run and, where supported, Terminal.

Claude Code, Codex and opencode can coordinate the native screen with an
explicit model.
Codex uses app-server's initialize, model/list, thread/start or thread/resume,
and turn/start; all repository access is read-only with approvals refused.
From codex-cli 0.166.0 every tool, Shoestring's included, is offered only
through code mode's `exec` (JavaScript with nested shell, patch and MCP
tools, and no `fetch`), so the code-mode host stays enabled for the
coordinator and the Codex explorer. Checked offline against 0.166.0 with a
scripted model: under the read-only sandbox and never-approve policy, writes
and patches inside and outside the repository were refused, a shell request
to a reachable local listener never arrived, an escalated command was
rejected, and the Shoestring dispatch tool was reached.
The engine queues messages while a turn runs. MCP bearer tokens travel through
the child environment, not argv. Model listing verifies catalog membership,
not account entitlement. These paths are tested with scripted local transports;
real subscription execution remains unverified without a separately authorized
live budget.

opencode (2.0.31 or later) runs `opencode acp` with a private configuration
directory and no project or Claude Code configuration. Its agent,
`shoestring-coordinator`, denies every tool but read, glob, grep and
Shoestring's, and the Shoestring MCP server is set `codemode: false`, so the
tools are offered directly and Code Mode's `execute` (whose `fetch` reached
the network with no permission request in Phase 0) is never offered. The
agent, model and effort are each selected and read back before the first
prompt; a refusal or a silent fallback to opencode's default model closes the
session instead. Verified offline against opencode 2.0.31 with a scripted
model: the model was offered only read, glob, grep and `shoestring_dispatch`;
`execute`, `edit`, `write`, `bash`, `webfetch` and `task` were "not
available"; the file was unchanged; resume kept the session. Configuration
an opencode organisation pushes to a signed-in account was not exercised.

opencode's own check refuses reads outside the checkout (`..`, absolute
paths) but follows a symlink inside it: a link to a file in your home folder
was read, and its contents reached the model (checked offline, 2.0.31). So
the coordinator also runs under macOS `sandbox-exec`: your home folder is
unreadable except the checkout and its Git directories, opencode's own data,
state, cache and install folders and its private configuration, and nothing
in the checkout is writable. The system decides on a link's target, so the
same link now reads as "Unable to read" (checked offline through Shoestring's
own launch, 2.0.31). Without `sandbox-exec` (not macOS) the opencode
coordinator does not start.

Native macOS arm64 releases build `priv/bin/shoestring-chat` during assets.deploy
and include it alongside the terminal helper. `shoestring chat` resolves that
binary from the installed application's priv directory; cargo is a build-time
dependency. `tools/release/smoke.py` verifies the relocated chat binary and its
instructions using a PATH that refuses provider and build-tool invocations.
