# Project history

Shoestring was built in numbered iterations, each with a plan under
`plans/milestones/` and an evidence record under `plans/evidence/`. Those
records are kept as written at the time: a status or "future work" line in
them describes the project on that date, not today. For what works now, see
[support](support.md) and [limitations](limitations.md).

| Iteration | What it added | Record |
| --- | --- | --- |
| Gate 0A | Feasibility of reading subscription capacity from Claude Code and Codex | [plan](../plans/milestones/00a-capacity-feasibility.md), [evidence](../plans/evidence/00a-capacity-feasibility/) |
| 1 | The durable trajectory: per-goal append-only events in SQLite, deterministic projectors, bounded artifacts, JSONL export, the timeline view | this repository's early history |
| 2 | Harness contracts and a deterministic fake harness for hermetic tests | [plan](../plans/milestones/02-harness-contracts-fake.md) |
| 3 | The production capacity observatory | — |
| 4 | Supervised single Elf runs: process groups, cancellation, normalized live events | [evidence](../plans/evidence/04-single-elf/) |
| 5 | Admission against usage, checkpoints, sleep/resume and cross-provider handoff | [plan](../plans/milestones/05-quota-aware-mvp.md), [evidence](../plans/evidence/05-quota-aware-mvp/) |
| 6 | Cobbler planning and approval; agent configuration and Usage UI. Accepted 2026-10-13 | [plan](../plans/milestones/06-cobbler-planning.md), [evidence](../plans/evidence/06-cobbler-planning/) |
| 7 | Multi-Elf fan-out with reservations. Accepted 2026-10-16 | [plan](../plans/milestones/07-multi-elf.md), [evidence](../plans/evidence/07-multi-elf/) |
| 7A | `shoestring do`: the one-command CLI work loop. Live-verified 2026-10-15, accepted 2026-10-16 | [plan](../plans/milestones/07a-cli-work-loop.md), [evidence](../plans/evidence/07a-cli-work-loop/) |
| 8 | Deterministic sandboxed checks and cross-vendor review | [evidence](../plans/evidence/08-verification-cross-review/) |
| 9 | Interactive terminal and the Rust PTY helper | [evidence](../plans/evidence/09-interactive-terminal/) |
| 10 | Measurements, shadow forecasts, diagnostics, text adapters and release tooling (in progress) | [evidence](../plans/evidence/10-forecasting-packaging/) |
| 11 | Claude usage readings and reset-aware holds | [evidence](../plans/evidence/11-claude-usage-tracking/) |
| 12 | One installed work CLI shared by the checkout and releases | [evidence](../plans/evidence/12-installed-cli/) |
| 13 | opencode as a worker harness | [evidence](../plans/evidence/13-opencode-harness/) |
| 14 | Coordinator-driven orchestration: `shoestring chat`, grants, EXPLORE / IMPLEMENT / REVIEW dispatches | [plan](../plans/milestones/14-coordinator-orchestration.md), [evidence](../plans/evidence/14-coordinator-orchestration/) |
| 15 | The native terminal chat screen and the coordinator's MCP tool endpoint | [coordinator guide](coordinator.md#the-chat-screen-iteration-15) |
| 16 | Teams and agents, sandbox permissions and asks, lessons, chained and batched dispatches | [coordinator guide](coordinator.md#teams-and-agents-iteration-16) |
| 17 | The Sessions page | [coordinator guide](coordinator.md#the-sessions-page-iteration-17) |
| 18 | Separate IMPLEMENT dispatches side by side | [coordinator guide](coordinator.md#tasks-side-by-side-iteration-16-c2) |

Evidence records follow the labelling and fixture conventions described in
each directory's `README.md` (for example `VERIFIED` requires command output
or a committed gate result).
