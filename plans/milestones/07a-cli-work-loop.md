# Iteration 7A: CLI work loop

**Status:** in progress (2026-10-15), prioritized ahead of iteration 8 at the
user's direction ("yeah we need this now")
**Hard dependencies:** iteration 6 (planning, sequential execution); iteration 7
implementation (fan-out stays opt-in and is not required)
**Unlocks:** everyday use from a terminal; reconciles the iteration 9 browser
terminal with the agreed CLI work interface

## Mission

Let a developer stand in any Git repository and type one request, much as they
would with Claude Code or Codex, and have Shoestring carry it through:

```text
shoestring do "make add() return the sum of its arguments"
  -> goal + goal contract (deterministic: base commit, gates)
  -> drafted plan (Claude, tool-free, through the subscription)
  -> plan shown in the terminal, human approves (y / n / edit)
  -> bounded sandboxed Elves run it through the running service
  -> live progress, with inline prompts when a human decision is needed
  -> verified result: gate output, diff, exact commands to take it
```

It is not a chat agent. The human approves the plan before any task runs and
takes the result into their own checkout. Everything the existing step-by-step
commands record, this records the same way; it composes them rather than
bypassing them.

## Today (REPO-INSPECTION, 2026-10-15)

- A goal, a plan and an execution each need separate commands and hand-written
  JSON (`shoestring.goals`, `shoestring.plans`, `shoestring.execution`).
- The planner is disabled by default and only has a local Ollama adapter. The
  README lists subscription planning as an open integration gap.
- The planner sees only the goal and its contract, never the repository.
- Agents and their models can be configured only in the web UI.
- Outside the evaluation drivers, Claude Elves launch with
  `--dangerously-skip-permissions` and no sandbox. The reviewed sandbox
  launcher lives in `tools/live_eval/` and is used only by live evaluations.
- Progress is read by polling `execution status`; nothing prompts the human.

## Required outcomes

- `shoestring do "<request>"` from any clean Git repository runs the loop above
  end to end, and `shoestring follow GOAL` re-attaches to it at any point.
- Claude can draft plans through the subscription, with the same admission,
  charging and refusal rules as every other inference.
- Claude Elves run sandboxed by default; the unsandboxed launch is no longer the
  default path.
- Agents, roles and models can be configured from the CLI.
- The step-by-step commands keep working unchanged.

## Locked decisions

- **Approval stays human and explicit.** The plan is shown in the terminal and
  nothing runs until the human answers `y`. There is no auto-approve flag in
  this milestone. Declining leaves the goal and the draft recorded, and nothing
  else.
- **Deterministic code owns the goal contract's checks.** The base revision is
  the repository's `HEAD`; a dirty working tree is refused. Gates come from
  `--gate`/`--test` flags or deterministic detection (a Mix project: `mix_test`;
  Python with `test/**/test_*.py`: `python_unittest` over those files). If no
  gate can be determined, the command refuses and says which flag to pass. The
  model never chooses or edits gates.
- **The planner stays tool-free.** It receives a bounded, deterministic
  repository map (tracked paths only, size-capped, secret-scanned) alongside the
  goal; it never reads files, runs commands or sees file contents. Its output is
  untrusted until the existing plan contract validates it. At most the existing
  two planner calls per goal.
- **Subscription planning is admitted like execution.** Claude planning uses
  Claude's subscription capacity observations. Unknown capacity needs an
  explicit per-call confirmation from the human at the terminal; hard stops
  cannot be confirmed away. The full output allowance is charged before the
  call, as today.
- **The user's checkout is never modified.** The result is delivered as the
  accepted commit(s), the gate output, a diff summary and the exact `git`
  commands to fetch and merge it. Shoestring does not run them.
- **The CLI never starts or stops an Elf.** Work runs in the service. `do`
  checks that the service is reachable before queuing anything and refuses with
  instructions if it is not. Closing or interrupting the CLI leaves work
  running; `follow` re-attaches.
- **Waiting costs no inference.** Progress comes from reading the local database
  on a bounded interval.
- **Sandboxed by default.** A Claude Elf may write only to its own worktree and
  private Git storage, may not read the home directory, and runs without
  permission bypass. The unsandboxed launch remains available only as an explicit
  operator setting, never chosen by `do`.
- **Fan-out stays opt-in.** `do` uses whatever dispatch mode is configured;
  sequential is the default.
- Existing invariants hold: no timer or staleness alone interrupts an Elf;
  oversized output fails, never truncates; no automatic merge; no hidden
  reasoning is stored.

## Work packages (in order)

### A. CLI configuration

- `mix shoestring.models list|add PROVIDER MODEL` edits the provider model
  catalogue (Settings).
- `mix shoestring.agents create NAME --worker PROVIDER:MODEL
  [--coordinator PROVIDER:MODEL] [--default]` and `set-role`, producing the same
  immutable revisions as the web form.
- Acceptance: everything `do` needs can be configured without the web UI.

### B. Repository facts and goal contract

- A pure module that reads a repository (read-only `git` commands): clean state,
  `HEAD`, tracked paths, detected gates and test paths.
- Builds a valid goal contract from the request text, detected or flagged gates,
  and default constraints/non-goals; refusals name the missing input.
- A bounded repository map for the planner projection (versioned projection
  field; replay and digests updated; old requests still replay).

### C. Claude subscription planner adapter

- `Shoestring.Cobbler.Planner.ClaudeHeadless`: one `claude --print` call with no
  tools, JSON output constrained to the plan schema, the configured model, stdin
  closed, process-group launch, bounded output and timeout. Output tokens come
  from the reported usage.
- Configuration and admission map the planner to Claude's subscription
  capacity scope; unknown capacity follows the confirmation rule above.
- Hermetic tests use a scripted executable, never the real CLI.

### D. Sandboxed Claude Elf launch

- Promote the reviewed launcher into the product: per-run sandbox settings
  derived from the run's worktree and private store, home-free Git
  configuration, `dontAsk` instead of permission bypass.
- Make it the default for Claude Elves; refuse to dispatch if the sandbox is
  unavailable (fail closed).

### E. `shoestring do`

- Preflight: clean repository, gates, default agent with an explicit execution
  model, planner configured, service reachable.
- Goal, request, generate, then render the plan (tasks, dependencies, files,
  gates) and prompt `y / n / e`. `e` exports the plan to a file, opens `$EDITOR`,
  and proposes the edit as a new revision before asking again.
- On `y`: approve the exact digest and start execution, then hand over to
  `follow`.

### F. `shoestring follow GOAL`

- Prints task transitions, run starts and ends, gate results and admission
  decisions as they are recorded.
- Prompts inline for decisions that need the human: capacity confirmation,
  scope blockers (accept/reject), integration required (prints the merge
  commands and waits for `integrate`), task failure (stop, or amend through the
  existing bounded replan).
- Ctrl-C detaches without cancelling. `shoestring cancel GOAL` is explicit.

### G. Result and delivery

- `shoestring result GOAL`: accepted commits, gate output, changed files, diff
  stat, and the exact `git fetch`/`git merge` commands for the user's checkout.

### H. Entry point and docs

- `bin/shoestring`: runs the tasks from the Shoestring checkout against the
  caller's directory (`--repo "$PWD"`), with the service's state directory.
- README quick start rewritten around `shoestring do`.

## Required evals (hermetic)

- Full loop with the Fake planner and Fake harness: request to accepted result.
- Refusals that queue nothing: dirty repository, no gate, no default agent, no
  explicit model, planner disabled, service unreachable.
- Declining approval: goal and draft recorded, no execution, no reservation.
- Edit path: edited plan becomes a new revision; approval binds its digest.
- Capacity confirmation prompt: declining leaves the task held; confirming
  records one confirmation for that admission only.
- Interrupting `follow` leaves the run going; a second `follow` resumes output
  from durable history without duplicates.
- Claude planner adapter with a scripted executable: success, schema failure
  then one repair, oversized output, timeout, non-zero exit, quota refusal.
- Sandboxed launch: settings derived per run, home read denied, source write
  denied, dispatch refused when the sandbox is unavailable.

## Live verification

Requires explicit authorization naming the budget. Proposed: one Claude
planner call and at most two Claude Elf runs on a disposable fixture repository,
driven only through `shoestring do` and `follow`.

## Demo

In a fresh Python repository with one failing test:
`shoestring do "make add() return the sum"`, approve, watch it run, read the
result, run the printed merge commands, and see the test pass.

## Acceptance gate

All required evals pass in `mix precommit`; the live verification passes within
its registered budget; the demo transcript is recorded under
`plans/evidence/07a-cli-work-loop/`; the step-by-step commands' tests are
unchanged.

## Out of scope

Auto-approval, automatic merging, chat-style follow-up conversation, a
terminal UI beyond line output, Codex planning, and packaging (iteration 10).

## Completion record

- Final status and date:
- Decisions and deviations:
- Events, contracts and configuration introduced:
- Verification commands and results:
- Live verification and demo:
- Remaining risks:
- Preflight notes for iteration 8:
