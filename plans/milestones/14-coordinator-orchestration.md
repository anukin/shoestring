# Iteration 14: coordinator-driven orchestration

**Status:** proposed — next planned iteration; not implemented or accepted.
**Hard dependencies:** iterations 6, 7, 7A, 8, 12 and 13 (durable plans,
fan-out, CLI work loop, verification/review, installed CLI and the opencode
adapter).
**Independent of:** iteration 10's deferred calibration and forecast routing.
Iteration 9's browser PTY is optional for watching runs, not a prerequisite.
**Product direction recorded:** 2026-10-25. This replaces the native
conversational-terminal proposal first committed as `00e9a41`, after the user
decided that the conversation belongs to an existing coding CLI rather than to
a chat engine inside Shoestring.

## Mission

Give Shoestring an Omnigent-style orchestrator. The developer chats with a
coordinator — Claude Code, Codex or opencode, at a model they choose — in their
repository. The coordinator investigates, plans and splits the work, then hands
IMPLEMENT, EXPLORE and REVIEW tasks to Shoestring. Shoestring runs each one as
a sandboxed Elf on the harness and model the coordinator picked, within the
usage limits it already enforces and an allowance the human granted. The
coordinator is woken when Elves finish, sends each change to a different vendor
for review, and reports verified results.

Shoestring is the runtime, not the brain. It builds no chat UI, turn engine or
model tool layer: the coordinator CLI already provides the conversation, its
context, repository reading and tool calls.

## Prior art

REPO-INSPECTION of the user's local Omnigent 0.10.0 install, 2026-10-25:

- Polly is a prompt plus three skills (`investigate`, `fanout`,
  `cross-review`) running on a Claude Agent SDK brain. The orchestration comes
  from runtime tools: `sys_session_send` hands a brief to a sub-agent, the
  brain is woken and reads `sys_read_inbox` when one finishes, and
  `sys_session_get_history`, `sys_cancel_task` and `sys_list_models` inspect,
  stop and choose sub-agents. Per-turn spawn caps and a UI to watch or take
  over sub-agents complete it.
- `omnigent setup` records accounts and defaults; harnesses are built in. Its
  model catalog (`omnigent/model_catalog.py`) uses live discovery only for
  Cursor and API gateways. Claude and Codex subscriptions get a curated static
  list marked `verified: false`.
- Polly's workers run with approvals bypassed (its Codex worker sets
  `yolo: true`) and each opens a PR. Shoestring keeps its sandboxed Elves and
  hands back a commit to fetch and merge.

REPO-INSPECTION of `google-research/harness2` at HEAD, 2026-10-25 (README,
`core/ledger.py`, `core/library.py`, `core/selection.py`, `core/proposer.py`;
the paper was not read):

- Its improvement comes from LLM "improver sessions" (the Claude CLI or
  OpenCode) that read earlier runs and write files, not from training. Code
  only counts runs and stores files.
- Taken here: learn what works as well as what it costs, from recorded runs
  (package I); budgets declared by strategy and checked as they are spent
  (its ledger asserts "R = 4k rollouts"; package D's declared batches); a dry
  run that previews without model calls (package D).
- Left for the follow-on iteration: an experience library whose entries need
  a `cue`, a `lesson` and `evidence`; trying one task with several setups;
  choosing among candidates labelled by a seeded, stable shuffle.
- Not taken: unrestricted executor network, Codex with its sandbox disabled,
  per-call API spend, and a model judging correctness.

## Decisions recorded with the user on 2026-10-25

1. **The coordinator is an existing coding CLI.** Claude Code, Codex or
   opencode, chosen per session. Shoestring adds commands the coordinator
   calls, not a conversation of its own. This drops the `00e9a41` proposal's
   terminal UI, conversation store and dialogue-call accounting.
2. **Roles are harness-neutral.** Any harness may coordinate, implement,
   explore or review when its adapter declares, and the contract suite
   verifies, the capabilities that role needs. The opencode worker-only rule
   (`Shoestring.AgentProfiles.worker_only/0` and the Coordinator/Reviewer check
   in `Shoestring.AgentProfiles.Definition`) is removed.
3. **Models are discovered, not typed.** Each harness reports its models.
   Discovered Claude and Codex subscription models are enabled automatically.
   Discovered opencode models stay disabled until the human enables them,
   because opencode can also reach providers that charge per token.
   `shoestring models add` remains for a model a harness does not report.
4. **Review independence compares the model's vendor, not the harness.**
   opencode running `openai/…` is OpenAI, the same as Codex; iteration 13
   already treats them as sharing one ChatGPT subscription.
5. **Authority is a session grant.** The human gives each coordinator session
   an allowance from a real terminal. Dispatches inside it need no further
   approval and are recorded as the coordinator acting under the grant;
   anything outside it is refused until the human extends the grant.
6. **No estimates up front; learn from runs.** A new kind of task runs under
   the grant's counts, time and usage-floor limits only. Shoestring records
   every finished run and, after about 10 runs of the same kind, shows plain
   statistics as advice, always with the sample count. Advice never changes
   admission. Enforcing a usage budget from estimates keeps iteration 10's
   bar (100 training and 100 later evaluation runs with attested isolation)
   and belongs to a later iteration.
7. **Grants may pre-approve unread usage.** Where remaining usage cannot be
   read (opencode always, Claude when its reading is stale), a grant may
   pre-approve a stated number of dispatches, counted and shown separately.
   Beyond that number each one asks the human, as today.

Decisions 5–7 were accepted as proposed on 2026-10-25 ("all of this makes
sense"), as was the split between this iteration and the follow-on.

## Target experience

PROPOSED interface; none of these commands exist yet:

```sh
shoestring setup                           # probe harnesses, discover models, choose defaults
cd path/to/project
shoestring chat                            # the default agent's coordinator
shoestring chat --agent heavy              # another saved team
shoestring chat --coordinator codex:MODEL  # override for this session only
```

The human grants the session an allowance (PROPOSED; refuses without a TTY):

```sh
shoestring grant --models codex:MODEL,claude:MODEL --purposes explore,implement,review \
  --max-dispatches 10 --max-parallel 3 --max-hours 4 --unread-usage 5
```

Inside the session the coordinator calls (PROPOSED; each prints JSON):

```sh
shoestring capacity --json                 # which harness:models have headroom now
shoestring advice --json                   # what past runs of each kind looked like
shoestring dispatch ... --dry-run          # admission, grant use and advice, nothing started
shoestring dispatch --purpose explore   --worker opencode:PROVIDER/MODEL --brief question.md
shoestring dispatch --purpose implement --worker codex:MODEL --effort high --brief task.md
shoestring dispatch --purpose review    --worker claude:MODEL --of RUN --brief contract.md
shoestring wait RUN... --timeout 30m       # returns when the first listed run finishes or needs you
shoestring runs list --session SESSION
shoestring runs show RUN
shoestring runs cancel RUN
```

PROPOSED walkthrough, not captured output:

```text
You:          The importer drops rows with quoted commas. Find out why and fix it.
Coordinator:  [dispatches an EXPLORE Elf, reads its report]
              The splitter ignores quotes (lib/import.ex:41). I'll give one
              IMPLEMENT task to Codex and have Claude review it.
You:          Go ahead.
Coordinator:  [dispatches within the session allowance, is woken when it
              finishes, dispatches the review, then shows the verified commit
              and the git fetch / git merge commands]
```

## Architecture

```text
you ⇄ coordinator CLI (Claude Code | Codex | opencode), in your repository
          │  shoestring dispatch / wait / runs / capacity   (--json)
          ▼
Shoestring service — allowance + admission, sandboxed Elves, checks, review, trajectory
          ├── Elf  IMPLEMENT  any capable harness:model → verified commit
          ├── Elf  EXPLORE    read-only → structured report
          └── Elf  REVIEW     read-only, diff + contract → findings
```

The coordinator's conversation is not Shoestring state. Shoestring records the
coordinator session's identity, each dispatch and its brief, the allowance it
ran under, and its outcome, through versioned trajectory events as usual. Raw
coordinator transcripts are neither stored nor canonical.

## Preflight

- Read the master plan, the dependency completion records and the actual
  `Shoestring.CLI.Main`, `WorkLoop`, `Follow`, dispatcher, `PlanFanoutDriver`,
  admission, `ExecutionProfile`, adapter and review code before freezing a
  grammar or schema.
- Freeze the command grammar and the brief schema. Start from the
  `IMPLEMENT | REVIEW | EXPLORE` brief format in the standing agent contract.
- Decide how a dispatch maps onto goals, tasks and runs: a goal with one
  coordinator-authored task, or a new stream type. Do not invent executable
  tasks to hold conversation.
- Record, without inference, what each installed harness returns when asked
  for models. VERIFIED 2026-10-25: Codex 0.164.0's app-server schema has
  `model/list`, returning `id`, `displayName`, `isDefault`,
  `supportedReasoningEfforts` and `defaultReasoningEffort`. REPO-INSPECTION:
  opencode's ACP `session/new` reply carries `configOptions` with the model and
  effort choices; `opencode models` lists the same but leaves a detached
  `opencode serve --service` running (stop it with `opencode service stop`).
  UNVERIFIED: the Claude 2.1.310 binary contains `supportedModels`, suggesting
  its SDK control protocol can report models; nothing has called it.
- Record how each coordinator CLI is launched with a model, extra instructions
  and skills, how it resumes a session, and how it can be woken when a
  background command exits. Never assume a flag.
- Use the standing agent contract. This document authorizes no provider
  inference and no live budget.

## Required work packages

### A. Capability-based roles

- Extend adapter capabilities (today `:resume`, `:send`, `:cancel` and
  `:interactive`; see `docs/adapter-contract-suite.md`) with what roles need,
  for example `:coordinate` (an interactive CLI with a shell that can be
  launched with instructions), `:read_only` (a sandboxed run that cannot
  write), `:structured_report` and `:effort`. The contract suite verifies every
  declared capability against Fake or scripted transports.
- Role validation checks capabilities, not provider names. A role whose
  harness lacks one refuses at save time and names the missing capability.
- Saved agent revisions stay immutable and keep running as they did.
- A reviewer's model vendor must differ from the reviewed run's model vendor.
  Derive the vendor from the model, not the harness; an unknown vendor refuses
  rather than guesses.
- Adding a harness (Antigravity, Cursor, Pi and so on) takes an adapter and a
  passing contract suite, with no role rules to edit. This iteration adds no
  new adapters.

### B. Model discovery

- Each adapter lists its models — id, display name, default flag, supported
  efforts and source (`live` or `fallback`) — without inference. Codex uses
  app-server `model/list`. opencode uses its ACP `configOptions`, which
  `OpencodeAcp.Session` receives on every run today and discards. Claude uses
  its SDK control protocol if preflight confirms it, otherwise a documented
  alias fallback labelled as such.
- Store the catalog with its source and `fetched_at`. Refresh it at `setup`,
  `doctor --probe-providers` and `shoestring models refresh`. The service
  refreshes at start only when the catalog is more than a day old and its
  configuration enables it (off in tests). No other command queries a
  provider. Show staleness; never act on it alone.
- Enable policy: per decision 3. Change it with `shoestring models enable` /
  `disable` or in Settings.
- A model that drops out of a listing is marked unavailable. It is never
  silently removed from saved agents, and a dispatch naming it refuses with a
  clear message rather than substituting another model.
- `models add PROVIDER MODEL` stays and is recorded as a manual entry.
- Effort choices come from the listing; an effort the model does not offer
  refuses, as opencode runs already do.

### C. `shoestring setup`

- One guided command in both the installed release and the checkout wrapper.
  Today `init` and `doctor` exist only in `rel/overlays/bin/shoestringctl`, and
  the checkout's `bin/shoestring` rejects both; make them work there too or
  document why not.
- Steps: create the state directory if needed; probe each harness (`ready`,
  `binary_missing`, `needs_sign_in`, `version_untested`); discover models;
  apply the enable policy; choose a default coordinator, worker and reviewer;
  save the default agent through the existing `models`/`agents` code, which
  creates immutable revisions.
- Show what would change before saving. Re-running it is idempotent.
- Non-interactive flags for scripts. Without a TTY and without those flags it
  refuses before changing anything.
- Sign-in stays with each vendor CLI. Shoestring never stores, reads or copies
  credentials, and adds no paid API path.

### D. Dispatch runtime

- `dispatch` takes a purpose (`implement`, `explore` or `review`), a worker
  `PROVIDER:MODEL`, an optional effort, the repository and base commit, a brief
  (task, scope, paths to stay out of, acceptance contract), checks through
  `--gate`/`--test` as in iteration 7A (the coordinator cannot invent
  commands), and a client request id. All of it is validated before anything
  runs. The planner is not called: the coordinator wrote the plan.
- Dispatch is idempotent on the request id. Retries, reconnects and restarts
  never create a second run.
- Admission is unchanged: support tiers, reserves, holds and confirmations
  apply to every dispatch. An unknown-capacity hold is visible in `runs show`
  and ends a `wait`.
- IMPLEMENT uses the existing sandboxed Elf path in a private copy and ends in
  a verified commit with fetch/merge instructions. Shoestring never modifies
  the user's checkout.
- EXPLORE is read-only. It cannot write (or its writes are discarded), its
  shell has no network, and it returns a bounded structured report: findings
  with file:line evidence and open questions. An oversized report fails; it is
  never truncated.
- REVIEW receives the reviewed run's diff from its base, the contract and the
  check results. It is read-only, may rerun the declared checks in the check
  sandbox, and returns structured findings. Code, not the reviewer, decides
  acceptance, as in iteration 8. Vendor independence (package A) is enforced.
- `wait RUN...` returns when the first listed run finishes or needs a human,
  or when the caller's timeout passes. Returning changes nothing about any run.
  Waiting makes no model calls.
- `runs list/show/log`, `capacity --json` and `runs cancel` complete the set.
  Cancel affects exactly its target and reaps that run's process group.
- Concurrency uses the existing fan-out policy. Dispatches beyond the admitted
  limit queue visibly.
- `dispatch --dry-run` validates the dispatch and reports the admission
  decision, the grant limits it would use and any advice, without recording a
  dispatch, calling a model or starting anything.
- Declared batches: a coordinator may declare a strategy before spending it
  (`--batch LABEL --batch-size N`, for example three implements and one
  review). A dispatch beyond the declared size is refused, `runs list` shows
  declared against used, and a dry run says whether the grant has room for
  the whole batch.
- `do`, `follow`, `result`, `review`, `checks` and `plans` keep their
  arguments, output streams and exit statuses.

### E. Session grants

- Today each plan needs a human decision recorded as `--by human:NAME`. A
  coordinator must never record a human decision.
- `shoestring grant` creates a grant for one coordinator session. It refuses
  without an interactive terminal, so a coordinator cannot grant itself, and
  saves only after the human confirms the grant it displays. The grant is
  recorded as `human:NAME`.
- A grant names the repository; the allowed `harness:model`s; the purposes;
  the maximum number of dispatches (every attempt counts, retries included);
  the maximum running at once; total hours and a per-dispatch duration; an
  optional usage floor per provider window, stricter than the standing
  reserves; and `--unread-usage N` (decision 7).
- A dispatch inside the grant is recorded as `agent:SESSION` under the grant
  id. Outside it, `dispatch` refuses and names the limit it would cross;
  nothing is queued. The human may extend the grant (`shoestring grant
  extend`), after which the coordinator dispatches again.
- Durations use the existing duration budgets: when time is used up no new
  attempt starts, and a running Elf is never interrupted. The standing
  reserves (automatic admission stops at 80% of the 5-hour window and 90% of
  the weekly one) apply to every dispatch, grant or not.
- A dispatch whose remaining usage cannot be read uses one pre-approved
  unread-usage dispatch instead of asking; when none are left it asks the
  human as today.
- Grants are durable and inspectable (`shoestring grants list/show`), and the
  human can revoke one. Revoking or exhausting a grant stops new dispatches; it
  never interrupts running Elves. A new session or a restart does not
  replenish it.

### F. `shoestring chat` and the orchestrator package

- `chat` reads the agent's Coordinator role and starts that CLI in the current
  repository with its model, the agent's instructions and the orchestrator
  skills, and passes the session id and service location in its environment.
  `--agent` and `--coordinator PROVIDER:MODEL` choose; the model must be
  enabled and the harness must have `:coordinate`.
- The orchestrator skills (investigate, fan-out and cross-review equivalents)
  and the routing guidance derived from the agent's roles ship with the
  release, versioned with Shoestring, in each supported coordinator CLI's
  format.
- If the service is unreachable or uses different state, refuse before
  launching and say how to start it. Never start or duplicate a service.
- The coordinator runs as the user's own CLI session under that CLI's own
  permission prompts; Shoestring does not sandbox it. Its instructions tell it
  to delegate code changes rather than edit the checkout. Document that the
  never-modify-your-checkout guarantee covers Shoestring and its Elves, not the
  coordinator CLI. Preflight decides whether to launch the coordinator
  read-only where its CLI supports that.
- Reattaching uses the coordinator CLI's own resume, re-linked by session id.
  `chat list --json` shows sessions and their dispatches without inference.

### G. Visibility

- `/cobbler` shows each coordinator session with its dispatches as a tree:
  purpose, harness:model, status, holds and outcome, linked to the run pages
  and, where the adapter is interactive, to the iteration 9 terminal.
- `shoestring runs list --session` shows the same in the CLI.

### H. Packaging, documentation and evidence

- The installed release includes `setup`, `chat`, the dispatch commands and
  the orchestrator package, with no build tools or source checkout.
- Document setup, chat, the brief format, authority, model discovery and the
  enable policy, capability rules and compatibility with existing commands.
- Save a reproducible hermetic demo and the exact gate results under
  `plans/evidence/14-coordinator-orchestration/`; document the fixture
  identifier convention there before committing evidence.
- A live demo needs separate authorization naming the coordinator, worker and
  reviewer harnesses and their call ceilings. Without it, live acceptance stays
  UNVERIFIED; a scripted transcript is not live proof.

### I. Run records and advice

- For every finished run, derive from canonical events: its kind (harness,
  model, effort, purpose, task class), the tokens the harness reported, its
  duration and attempts, whether its checks passed on the first attempt,
  whether review blocked it, and the usage readings around it with whether it
  ran alone.
- Token sources: Codex `thread/tokenUsage/updated` and opencode's completion
  usage are kept today. Claude's final `result` message carries `usage` and
  `total_cost_usd` (VERIFIED in
  `plans/evidence/04-single-elf/fixtures/claude/stream-json-smoke-live.jsonl`).
  `ClaudeHeadless.EventNormalizer` keeps `total_cost_usd` but drops the
  `usage` token counts (corrected 2026-10-25); keep them.
- `shoestring advice [--json]`: for each kind with at least 10 finished runs,
  the median and 90th-percentile tokens, the first-try pass rate, mean
  attempts, median duration, and usage per run from the runs that ran alone
  (with their own count). Below 10 runs it says "no estimate yet" with the
  count. Every figure carries its sample count and date range.
- Arithmetic only — counts, medians and percentiles. No model call and no
  training.
- Advice reaches the coordinator through `advice --json` and `dispatch
  --dry-run`, and a grant shows its estimated usage so far. It never changes
  admission, dispatch or checks.
- Prompt text, paths and transcripts are excluded, as in iteration 10's
  measurements.

## Required hermetic evals

| Case | Required outcome |
| --- | --- |
| Capability roles | opencode saves as Coordinator, Worker and Reviewer when it declares the capabilities; a harness missing one refuses and names it; old revisions still run. |
| Review independence | An `opencode:openai/…` reviewer of a Codex run refuses; a Claude reviewer is accepted; an unknown vendor refuses. |
| Model discovery | Fake listings fill the catalog with source and time; Claude/Codex enabled, opencode disabled; a vanished model is marked unavailable without editing agents; no inference is recorded. |
| Setup | Fresh state reaches a ready default agent through non-interactive flags; a rerun changes nothing; non-TTY without flags refuses; no credential is read or written. |
| Dispatch idempotency | The same request id twice, or a restart mid-dispatch, yields one run. |
| Authority | Inside the grant runs as `agent:SESSION`; outside it waits; an agent can never record a `human:` decision; revoked or exhausted grants hold new work and leave running work alone. |
| Explore read-only | Writes fail or are discarded; the report is kept; an oversized report fails. |
| Review packet | The reviewer gets diff, contract and checks, cannot write, and its findings decide acceptance as in iteration 8. |
| Wait | Returns on the first finished or waiting run; a timeout changes no run; no model calls while waiting. |
| Concurrency | Dispatches beyond the admitted limit queue visibly; no duplicate claim. |
| Cancel | Cancels exactly its target and reaps its process group; siblings keep running. |
| Capacity | Unknown or stale capacity holds visibly; exhaustion holds with no fallback model or provider. |
| Chat launch | Each coordinator gets the right CLI, model and instructions (scripted); an unreachable or mismatched service refuses; no service is started. |
| CLI compatibility | Existing commands keep their arguments, stdout/stderr and exit statuses. |
| Privacy | Briefs and reports are redacted under the existing artifact rules AND their useful content remains; no coordinator transcript is stored. |
| Grant creation | Without a TTY `grant` refuses and saves nothing; with one it saves only after confirmation and records `human:NAME`. |
| Grant limits | Each limit (model, purpose, repository, dispatches, concurrency, hours) refuses the dispatch that would cross it and queues nothing; `extend` lets it through; running work is untouched. |
| Unread usage | Unreadable capacity uses a pre-approval while any remain, then asks as today; both are counted. |
| Dry run and batches | A dry run records and starts nothing; a dispatch beyond a declared batch size refuses; a dry run reports whether the grant has room for the batch. |
| Token capture | Claude's final `usage` is kept on run events alongside Codex and opencode tokens; malformed or missing usage is recorded as unknown, never zero. |
| Advice | Below 10 runs: no estimate and the count. With fixtures: exact median, 90th percentile, first-try rate and counts. Admission decisions are identical with and without advice. |

Use Fake/scripted local transports and trivial local commands. Label
new-feature tests honestly; regression claims must fail behaviourally on the
recorded pre-fix commit. No provider CLI or network in the ordinary gate.

## Demo and acceptance gate

1. From fresh state, `shoestring setup` discovers models (Fake in the hermetic
   demo) and saves a default agent.
2. `shoestring chat` starts the coordinator (a scripted coordinator in the
   hermetic demo) in a scratch repository, and the human grants an allowance
   from a terminal.
3. The coordinator runs an EXPLORE and an IMPLEMENT on different harnesses at
   the same time, waits, has a different vendor REVIEW the change, and presents
   the verified commit with merge instructions.
4. A dispatch outside the allowance waits for the human. Cancelling one run
   leaves the other running.
5. Restarting the service mid-run loses nothing: `wait` and `runs show` resume
   with no duplicate run.
6. After seeded finished runs, `advice` shows statistics for a kind with 10
   or more runs and "no estimate yet" for one with fewer.
7. `do`, `follow`, `result`, `review` and `checks` still work.

Acceptance requires all required evals and the hermetic demo, a green full
`mix precommit` with exact counts, an installed-release check, and a recorded
live session with a real coordinator and at least two worker harnesses within a
separately authorized budget. Missing live evidence leaves acceptance open.

## Carried over from the `00e9a41` proposal

- Approvals bind to the exact revision and digest shown, and are never
  inferred from prose or an ambiguous acknowledgement.
- Detaching or losing the terminal leaves work running. Silence, a missed
  response or a timer never interrupts, replaces or duplicates work.
- An uncertain in-flight call stays fenced and visible instead of being
  retried automatically.
- Model text shown in Shoestring's own CLI or UI cannot inject control
  sequences or forge an approval prompt.
- Oversized output fails; it is never silently truncated.

## Out of scope

A chat UI or turn engine inside Shoestring; browser chat; remote or multi-user
sessions; automatic merging; opening PRs (results stay commits to fetch and
merge); new harness adapters; paid API paths; enabled forecasts; enforcing
usage budgets from estimates (it keeps iteration 10's evaluation bar).

## Follow-on iteration

Recorded 2026-10-25 for the iteration after this one; nothing here is
authorized by this milestone.

- **MCP server:** a thin layer over the same commands, so a coordinator can be
  allowed Shoestring's tools without a general shell.
- **Lessons library:** per repository, each lesson has a `cue` (when it
  applies), the `lesson` and its `evidence` (run ids, checks, review
  findings); a lesson missing any of them is rejected. The coordinator writes
  them and sees matching ones before similar dispatches. A lesson enters an
  agent's instructions only when the human approves it, as a new revision.
- **Try several:** one brief dispatched to two or three harness:models at
  once; checks decide which pass, and a reviewer from another vendor picks
  among the passing ones. Same-task comparisons also feed package I.
- **Blind comparison:** candidates shown to the selecting reviewer as A, B, C
  in a seeded, stable order, with the mapping recorded separately.

## Progress

- 2026-10-25, package A first slice. `Shoestring.Harnesses` records each
  harness's capabilities by the module that provides them (`:plan`,
  `:implement`, `:review`; `:coordinate` is descriptive until package F).
  Role validation uses it, so the opencode worker-only rule is gone: opencode
  may coordinate, and is refused as Reviewer until it has a review path.
  Cross-review compares model vendors (`Harnesses.vendor/2`), so opencode
  tasks are now reviewable instead of always `implementer_unknown`.
  `shoestring do` names a Coordinator that cannot plan. Still open in A:
  capability declarations for the contract suite (`:read_only`,
  `:structured_report`, `:effort`) arrive with packages B and D.

- 2026-10-25, package B. Preflight probes ran with the user's authorization
  (evidence: `plans/evidence/14-coordinator-orchestration/README.md`):
  Codex `model/list` (7 models with per-model efforts), opencode ACP
  `session/new` `configOptions` (150 models, no efforts before a model is
  chosen) and Claude Code's `initialize` `models` (13, with efforts and the
  model each alias resolves to; no inference frame). The Claude listing is
  therefore VERIFIED, not a fallback. `Shoestring.Harnesses.ModelListing`
  runs those exchanges and reaps the CLI's process groups;
  `Shoestring.ModelCatalog` records them in `harness_models` with the enable
  policy of decision 3; `shoestring models refresh|show|enable|disable` drive
  it; roles and the agents form use per-model efforts while saved revisions
  keep resolving with the provider's set. Provider model lists now hold up to
  64. Deferred: refresh from `setup`, `doctor --probe-providers` and service
  start (package C); refusing a dispatch that names an unavailable model
  (package D); a discovered-model view in the web Settings page.

- 2026-10-25, package C. `shoestring setup` probes each CLI (the
  `doctor --probe-providers` commands only), refreshes the installed ones'
  models, suggests a Coordinator, a Worker and a Reviewer of another vendor
  (or keeps the agent's current ones), shows what it would save and asks.
  Without a terminal it refuses unless given `--worker` and `--yes`, before
  changing anything; a rerun with the same choices saves nothing. Terminal
  detection is OTP's `:io.getopts(:standard_io)[:stdin]` (`Shoestring.CLI.Terminal`):
  VERIFIED false without a terminal; the true case is UNVERIFIED, because
  this environment cannot open a pseudo-terminal. `shoestring doctor` now
  also runs from the checkout (agents, git, python3, recorded models); the
  release keeps its fuller doctor. In the checkout, `mix setup` remains the
  equivalent of `init`. The service refreshes stale catalogs once at start
  (`Shoestring.ModelCatalog.StartupRefresh`, off in tests). Deviation:
  `doctor --probe-providers` does not refresh models — it stays read-only;
  `setup`, `models refresh` and the start-up refresh do.

- 2026-10-25, packages D (IMPLEMENT) and E. Dispatch mapping decided: a
  dispatch is an ordinary goal with a one-task plan, authored and approved
  under the grant and executed by the existing executor, so sandboxing,
  admission, checks, cancellation and `follow` are reused unchanged. Grant
  authority: `grant:UUID` identities (`Shoestring.Authority`) are accepted by
  `Plans` (author and approve only), `ExecutionControl.start` and
  `PlanCancellation` only when the dispatch code passes the dispatch record,
  and only for that dispatch's goal and exact plan digest; replay accepts
  them with `author_kind: grant`. The `author_kind = 'human'` CHECK on
  `cobbler_plan_revisions` became `IN ('human', 'grant')` through a table
  rebuild (VERIFIED on a populated copy: identical rows, integrity and
  foreign-key checks clean). The execution binding of a dispatch resolves
  from the dispatch row (worker, model, effort, brief). Grants live in
  `coordinator_grants` with an append-only `coordinator_grant_events`;
  limits are counts and reserved times checked in the same immediate
  transaction that records the dispatch. Commands: `grant`, `grants
  list|show|extend|revoke` (extend, revoke and grant refuse without a
  terminal), `dispatch` (with `--dry-run` and declared batches), `wait`,
  `runs list|show|cancel`. Deviations: a dispatch outside its grant is
  refused rather than left waiting; dispatched work skips iteration 8's
  automatic cross-review (the coordinator's REVIEW dispatch replaces it);
  a session id is not a secret, so any local program that knows it can
  dispatch under its grant, bounded by the grant's repository, models and
  limits. A usage hold surfaces as the dispatch state `held`. Still open in D: EXPLORE and REVIEW dispatches, `capacity`, the dry run's
  admission preview, and using unread-usage pre-approvals in admission.

- 2026-10-25, package F (first slice). `shoestring chat` validates the
  coordinator (the agent's Coordinator role or `--coordinator`; it must be
  able to coordinate, be enabled and be on PATH), needs a terminal and a
  running service, proposes and asks for the session's grant when it has
  none, renders `priv/coordinator/instructions.md` with the session, grant,
  roles and agent instructions, and writes a launch script that
  `bin/shoestring` / `shoestringctl` exec so the coordinator's TUI owns the
  terminal. Delivery: Claude Code `--model` + `--append-system-prompt-file`
  (REPO-INSPECTION of its help); Codex `-m` + `-c developer_instructions`;
  opencode `OPENCODE_CONFIG_CONTENT` — the last two UNVERIFIED until a live
  session. The release wrapper's `chat` path is tested against a stub
  runtime; the checkout wrapper's identical branch is REPO-INSPECTION only.
  Deviations: one instructions file instead of separate skills for all three
  CLIs; a continued session starts a new CLI conversation (no CLI resume id
  is kept) and re-reads Shoestring's records.

- 2026-10-25, package D, review. REVIEW is delivered as `dispatch
  --reviewer PROVIDER:MODEL` on an IMPLEMENT dispatch rather than a separate
  read-only review Elf: iteration 8's tool-free cross-review (diff, contract
  and checks; no tools) runs before acceptance whenever the dispatch names a
  reviewer, regardless of `:plan_review`, with the dispatch's reviewer
  overriding any configured adapter. The reviewer must be another vendor's
  enabled model, and the grant must allow REVIEW and that model. A held
  review shows as the dispatch state `held`; `runs show` lists review
  rounds. Still open: a stand-alone REVIEW of an already finished dispatch,
  EXPLORE, `capacity`, the dry run's admission preview, and spending
  unread-usage pre-approvals.

- 2026-10-25, decision 7 in use. `Dispatches.advance/2`, called by `wait`
  and `runs show`, spends one pre-approved unread-usage dispatch on a task
  held with `:require_confirmation` (stale or unreadable usage only; reserve
  breaches defer instead) or a held review call, then confirms it under the
  grant (`PlanCapacityConfirmation` and `PlanReview.confirm` accept the grant
  identity only with the dispatch record; events carry `actor: grant`). A
  hold is spent once, its confirmation id is derived from it so a retry
  replays, and a failed confirmation is refunded. Without pre-approvals left
  the hold waits for a person. Confirmation happens when the coordinator
  polls, not in the service.

- 2026-10-25, package I. Claude's result `usage` token counts are kept on
  the run's result event (regression test fails on the previous normalizer).
  `Shoestring.Advice` derives per-kind statistics from targeted queries of
  canonical events — run requests, starts and ends, task dispatches and
  acceptances, and token-bearing harness events — rather than iteration 10's
  dataset, whose 10,000-event limit a real store soon exceeds. Codex tokens
  are read from its namespaced `codex-app-server:token_usage` running total
  (a test against the real normalizer caught the un-namespaced key).
  `shoestring advice` prints it; `dispatch --dry-run` includes the worker's
  line. Deviation: usage per run as a share of a provider's window is not
  reported yet — it needs the bracketed, ran-alone attribution only the
  measurement dataset does; tokens, first-try pass rate, mean attempts and
  median duration are.

- 2026-10-25, package D, capacity. `shoestring capacity` prints each
  provider's latest reading (`Shoestring.Usage.cards/1`) with an outlook
  against `AdmissionPolicy.default/0`'s reserves: admits, deferred (until the
  latest reset among windows over a reserve), asks (unknown, stale, or
  opencode, which reports none) or refused; it is labelled as the start of
  admission, not its decision. `dispatch --dry-run` adds the worker
  provider's entry, which closes the dry run's admission preview.

- 2026-10-25, package G. `/cobbler` lists each coordinator session (in local
  mode, as goals are; grants are not owner-scoped) with its grant's
  attempts, concurrency and unread-usage use, and each dispatch's title,
  worker, reviewer and state, linked to its goal page. Tested with
  LiveViewTest; not checked visually in a browser (a dev server would start
  the live provider monitors).

## Completion record

- Final status/date: not implemented; fill only at acceptance.
- Dispatch mapping and schema decisions: to be recorded.
- Per-harness model listing and coordinator launch findings: to be recorded.
- Exact automated commands/counts and pre-fix regression evidence: to be recorded.
- Installed-release demo and separately budgeted live receipt: to be recorded.
- Budget usage, deviations, unresolved limits and next preflight: to be recorded.
