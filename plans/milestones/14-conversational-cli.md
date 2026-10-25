# Iteration 14: conversational terminal interface

**Status:** proposed — next planned iteration; not implemented or accepted.
**Hard dependencies:** iterations 6, 7A, 8 and 12 (durable plans, CLI work loop,
verification/review and installed CLI).
**Independent of:** iteration 10's deferred calibration and forecast routing.
Iteration 9's browser PTY is neither a prerequisite nor a substitute.
**Product direction recorded:** 2026-10-25, after the user identified the missing
Omnigent-style conversational terminal experience and requested a milestone.

## Mission

Let a developer launch Shoestring in a terminal and have a continuing
conversation with Cobbler: describe a goal, answer clarifying questions, discuss
and revise a plan, approve specific work, watch Elves progress, inspect results
and give follow-up instructions without leaving the session.

The reference is [Omnigent's terminal sessions and orchestrator interaction](https://github.com/omnigent-ai/omnigent#2-start-your-first-agent).
This is a native Shoestring conversation backed by its durable supervisor.
Wrapping a vendor TUI, displaying iteration 9's browser terminal, or repeatedly
calling `shoestring do` from a shell loop does not satisfy the milestone.

## Why a new milestone

REPO-INSPECTION: iteration 7A implements one-request plan/approve/run and
explicitly excludes chat-style follow-ups and a richer terminal UI. Iteration
9 implements browser-based Claude/Codex PTY takeover. Iteration 12 installs the
existing commands. Their completion records do not establish a conversational
Cobbler terminal. This milestone adds that missing product contract without
rewriting those historical acceptance records.

## Target experience

PROPOSED interface (these commands are not implemented by this planning change):

```sh
cd path/to/project
shoestring                              # interactive session when attached to a TTY
shoestring chat --agent builder          # explicit entry point
shoestring chat --session SESSION_ID     # reattach to a saved conversation
shoestring chat list --json              # inspect saved sessions without inference
```

PROPOSED walkthrough, not captured provider output:

```text
You: Add CSV export to the report command.
Cobbler: Which columns should the export contain?
You: Use the existing report fields, and preserve their order.
Cobbler: [shows a proposed plan, checks, limits and approval prompt]
You: [explicitly approves that displayed revision]
Shoestring: [shows worker/check progress and the verified result]
You: Add a regression test for commas inside field values.
Cobbler: [uses the recorded goal/result and proposes the follow-up]
```

Discussion alone never starts implementation. Follow-ups retain the
conversation's constraints and reference completed work, with explicit new
authority for any additional work.

## Preflight and design decisions

- Read the master plan, dependency completion records, and actual
  `Shoestring.CLI.Main`, `WorkLoop`, `Follow`, planner, admission, execution,
  review and trajectory implementations before choosing a transport or schema.
- Freeze the command grammar, terminal lifecycle, conversation/goal relationship
  and first supported coordinator adapters before implementation.
- Decide how pre-goal discussion and conversations spanning multiple goals fit
  trajectory ownership, sequencing and replay. Extend the explicit stream model
  as needed; do not invent executable tasks merely to save chat text.
- Prefer the existing service/delivery boundary. Any new transport needs a
  documented local authentication design before implementation; no new public
  listener or Erlang distribution is implicitly authorized.
- Establish per-conversation model-call/output limits and how they compose with
  existing goal planning, review, attempt and subscription limits. No unlimited
  conversational allowance or paid API fallback.
- Identify coordinator capabilities honestly. An unsupported selected provider
  refuses before inference. Preserve opencode's worker-only boundary; never
  silently switch provider or model.
- Use an isolated worktree and read the standing agent contract. This document
  authorizes no provider inference or new live budget.

## Required work packages

### A. Installed entry point and terminal interaction

- Bare `shoestring` on a TTY opens the conversational interface; explicit
  `shoestring chat` behaves the same. Both use the installed release and
  checkout wrapper, preserving the caller's repository.
- Provide keyboard editing, multiline input/paste, resize handling, readable
  Unicode, clear busy/waiting states and discoverable `/help`, `/status`,
  `/exit` and `/cancel` actions. Separate human messages from worker output.
- Render incremental assistant text when the adapter supports it; otherwise
  show a truthful running state. Worker/check progress comes from domain state.
- A non-TTY chat invocation refuses before inference or state mutation and
  points to existing scriptable commands. Session listing is read-only and
  supports stdout-data/`--json`. Interactive human output goes to stderr;
  existing commands retain their arguments, output and exit contracts.
- If the service is unavailable or uses different state, explain how to start
  or select it. Do not silently start or duplicate a service.

### B. Durable conversation and context

- Persist visible human/assistant messages, turn identities, pending questions,
  selected agent revision, repository binding and goal/execution links through
  versioned, ordered, idempotent domain events. Raw provider transcripts and
  terminal logs are not canonical conversation or execution state.
- Rebuild conversation and pending decisions after CLI/service restart.
  Reattachment renders saved state without a model call or replaying side
  effects. An uncertain in-flight turn remains visibly uncertain.
- Bound input, retained output and context projections. Oversized messages fail
  explicitly. Compaction retains constraints, decisions, approved revisions,
  completed work and evidence references, with inspectable provenance.
- Persist no hidden model reasoning, credentials or authentication files.
  Define secret handling for saved visible messages; exclude conversation text
  from measurement datasets and default diagnostic exports. Use synthetic tests.
- Reject accidental cross-repository/session binding. Agent edits cannot change
  already approved work's snapshot. Rebinding needs explicit human action and
  cannot rewrite past messages or decisions.

### C. Model-backed discussion and admission

- Support genuine multi-turn questions and clarification before a plan exists.
  A command router or canned prompt sequence alone is insufficient.
- The service owns durable turn intent and model-call delivery. Charge each
  actual call once; reconcile duplicate delivery and ambiguous completion before
  retry. Reconnects, CLI restarts and session switches cannot duplicate calls.
- Apply provider policy, capacity support tiers, reserves and bounded allowances
  to conversational inference. Unknown/stale capacity gets the normal visible
  hold/confirmation path. Idle waits, progress refreshes, replay and user
  deliberation make no model calls.
- Keep dialogue, planning, review and worker budgets attributable. Conversation
  turns cannot reset a goal's planning/replan/attempt counters. A new UI or
  provider session does not replenish exhausted authority.
- Retain the existing coordinator tool/access policy. Conversation grants no
  shell execution, source writes, new repository access or provider permissions.

### D. Plans, approvals, amendments and results

- Translate conversation into validated intents using existing goal, plan,
  admission, execution and review APIs. Model prose cannot commit lifecycle
  changes, approve work, invent verification or execute arbitrary commands.
- Show the goal contract, plan revision/digest, checks and limits before asking
  for explicit human approval. Bind the answer to that displayed revision; a
  changed or stale plan needs a new decision. Never infer approval from an
  assistant message or an ambiguous conversational acknowledgement.
- Allow plan edits/clarification in the same session. Before approval, preserve
  the draft; during execution, new scope uses the bounded amendment path. A
  follow-up cannot silently alter an active worker's approved input.
- Link post-completion requests to prior goals/results while creating whatever
  fresh goal or amendment authority is needed. Completed evidence stays intact.
- Display real per-Elf/check/review state, quota holds, blockers and human
  decisions. Present the verified commit and merge instructions. Never merge
  automatically or let the conversation model approve its own work.

### E. Detach, cancellation and terminal safety

- `/exit`, terminal loss and the documented detach behavior leave useful work
  running. Status and resume do not restart or replace a worker/model call.
- `/cancel` identifies the exact target and obtains an explicit human decision
  before invoking existing cancellation APIs. Cancelling a dialogue turn does
  not implicitly cancel Elves. Goal cancellation retains owned process-group
  termination/reconciliation guarantees.
- Silence, a missed response or a UI timer never authorizes interruption,
  replacement or duplicate inference. Keep uncertainty visible and recoverable.
- Treat model/tool text as untrusted terminal content: block control-sequence
  injection, clipboard operations and forged approval UI. Separate trusted
  prompts from rendered text. Do not silently truncate oversized run output.

### F. Packaging, documentation and evidence

- Include the interface in the native installed release without build tools or
  a source checkout. Document launch, agent selection, reattachment, keyboard
  controls, limits and compatibility with existing commands.
- Save a reproducible hermetic end-to-end demo and exact gate results under
  `plans/evidence/14-conversational-cli/`; document fixture identifier conventions
  before committing evidence.
- A real-provider demo needs separate authorization naming the provider and
  dialogue/planner/worker/reviewer call ceilings. Without it, retain live
  acceptance as UNVERIFIED; a fake transcript is not live proof.

## Required hermetic evals

| Case | Required outcome |
| --- | --- |
| Clarification | At least two human/assistant turns before planning; no worker launch or premature approval. |
| Contextual follow-up | Prior constraints/result are retained; new work gets explicitly approved authority. |
| Approval race | Stale digests, changed plans and ambiguous replies start no work; the exact current revision can be approved. |
| Concurrent work | A new request cannot mutate an active Elf or duplicate dispatch; progress remains attributable. |
| Restart/reconnect | Messages, pending decisions and goal links survive CLI/service restart, with no extra call/run. |
| Uncertain call | Crash/lost acknowledgement after delivery stays fenced and visible, without automatic second inference. |
| Budget/quota | Dialogue charges once, does not replenish other budgets, and holds/refuses without fallback when required. |
| Quiet/idle | Waiting and replay make zero calls; silence alone kills or replaces nothing. |
| Detach/cancel | Detach preserves work; explicit cancellation affects only its target and reaps owned groups. |
| Privacy/terminal text | Sensitive/control content is excluded AND useful visible messages/evidence remain. |
| CLI compatibility | Existing commands, non-TTY refusal, stdout/stderr and exit contracts remain correct. |
| Installed experience | Release-only terminal workflow supports input, progress, resize, detach and resume. |

Use Fake/scripted local transports and trivial local commands. Label new-feature
tests honestly; regression claims must fail behaviorally on the recorded
pre-fix commit. No provider CLI or network in the ordinary gate.

## Demo and acceptance gate

1. From a scratch Git repository, launch the installed bare command and select
   a configured agent. Ask an underspecified task and answer its clarification.
2. Revise the proposed plan conversationally. Show that work has not started.
3. Approve the exact displayed revision, observe worker/check progress, and
   inspect a verified result with merge instructions.
4. Give a context-dependent follow-up in the same session and explicitly approve
   its new work. A fresh one-shot request without retained context is insufficient.
5. Detach/restart CLI and service at a pending decision and during work; resume
   the conversation with no duplicate calls, workers or approvals.
6. Demonstrate held/exhausted allowance and explicit cancellation, then verify
   legacy `do`, `follow`, `result`, `review` and `checks` still work.

Acceptance requires all required evals and this hermetic demo, a green full
`mix precommit` with exact counts, an installed-release terminal check, and
recorded live multi-turn acceptance within a separately authorized budget.
Missing live evidence leaves full acceptance open. A prompt screenshot,
passing backend tests or a one-shot task cannot close this milestone.

## Out of scope

Microphone input, speech recognition, text-to-speech, browser chat, remote or
multi-user sessions, automatic merging/approval, new worker providers, opencode
planning/review, enabled forecasts, and replacing existing CLI/domain APIs.

## Completion record

- Final status/date: not implemented; fill only at acceptance.
- Design/transport and durable event/schema decisions: to be recorded.
- Exact automated commands/counts and pre-fix regression evidence: to be recorded.
- Installed-terminal demo and separately budgeted live receipt: to be recorded.
- Budget usage, deviations, unresolved limits and next preflight: to be recorded.
