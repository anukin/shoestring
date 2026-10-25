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

**Open decision** (confirm with the user in preflight, before package E): how a
coordinator obtains authority to dispatch without a human approving each task.
Package E proposes a human-granted session allowance.

## Target experience

PROPOSED interface; none of these commands exist yet:

```sh
shoestring setup                           # probe harnesses, discover models, choose defaults
cd path/to/project
shoestring chat                            # the default agent's coordinator
shoestring chat --agent heavy              # another saved team
shoestring chat --coordinator codex:MODEL  # override for this session only
```

Inside the session the coordinator calls (PROPOSED; each prints JSON):

```sh
shoestring capacity --json                 # which harness:models have headroom now
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
- Confirm the authority decision (package E) with the user.
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
  `doctor --probe-providers`, service start and `shoestring models refresh`;
  no other command queries a provider. Show staleness; never act on it alone.
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
- `do`, `follow`, `result`, `review`, `checks` and `plans` keep their
  arguments, output streams and exit statuses.

### E. Coordinator authority (pending user confirmation)

- Today each plan needs a human decision recorded as `--by human:NAME`. A
  coordinator must never record a human decision.
- PROPOSED: the human grants a coordinator session an allowance, typed by the
  human in the way calibration windows are attested. It names the allowed
  harness:models and purposes, the repository, the maximum number of
  dispatches, maximum concurrency and attempt ceilings. Dispatches inside it
  are recorded as `agent:SESSION` acting under that grant. Anything outside it
  waits for an explicit human decision through the existing approval paths.
- Grants are durable and inspectable (`shoestring grants list/show`), and the
  human can revoke one. Revoking or exhausting a grant stops new dispatches; it
  never interrupts running Elves. A new session or a restart does not
  replenish it.
- Alternative if the user prefers it: each IMPLEMENT dispatch waits for a human
  `shoestring approve`, while EXPLORE and REVIEW run under a smaller standing
  allowance.

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

Use Fake/scripted local transports and trivial local commands. Label
new-feature tests honestly; regression claims must fail behaviourally on the
recorded pre-fix commit. No provider CLI or network in the ordinary gate.

## Demo and acceptance gate

1. From fresh state, `shoestring setup` discovers models (Fake in the hermetic
   demo) and saves a default agent.
2. `shoestring chat` starts the coordinator (a scripted coordinator in the
   hermetic demo) in a scratch repository, and the human grants an allowance.
3. The coordinator runs an EXPLORE and an IMPLEMENT on different harnesses at
   the same time, waits, has a different vendor REVIEW the change, and presents
   the verified commit with merge instructions.
4. A dispatch outside the allowance waits for the human. Cancelling one run
   leaves the other running.
5. Restarting the service mid-run loses nothing: `wait` and `runs show` resume
   with no duplicate run.
6. `do`, `follow`, `result`, `review` and `checks` still work.

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
merge); new harness adapters; paid API paths; enabled forecasts. An MCP server
is the next step after this iteration: a thin layer over the same commands, so
a coordinator can be allowed Shoestring's tools without a general shell.

## Completion record

- Final status/date: not implemented; fill only at acceptance.
- Authority decision, dispatch mapping and schema decisions: to be recorded.
- Per-harness model listing and coordinator launch findings: to be recorded.
- Exact automated commands/counts and pre-fix regression evidence: to be recorded.
- Installed-release demo and separately budgeted live receipt: to be recorded.
- Budget usage, deviations, unresolved limits and next preflight: to be recorded.
