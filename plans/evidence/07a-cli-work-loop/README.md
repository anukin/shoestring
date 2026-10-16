# Iteration 7A: CLI work loop — evidence

Date: 2026-10-15. Milestone: [07a-cli-work-loop](../../milestones/07a-cli-work-loop.md).
Started from `788413d`. Direct-main development, as for iteration 7.

## What was built

| Package | Commit | Summary |
| --- | --- | --- |
| A. CLI configuration | `4962141` | `shoestring.models list/add`; `shoestring.agents create/set-role/default` through the web form's validation |
| B. Repository intake | `55f12ef` | `Cobbler.Intake`: clean `HEAD` base, deterministic gates, goal contract, bounded repository map in the planner projection |
| C. Claude planner | `c2ba1ac` | `Planner.ClaudeHeadless`: one tool-free `claude --print --json-schema` call on the subscription scope; confirmation per call |
| D. Sandboxed Elves | `53f79a2` | plan-run Claude Elves launch sandboxed by default (GitSandbox roots, `dontAsk`, no bypass, home-free Git); fail closed |
| E-G. do, follow, result | `01051d7` | `shoestring.do`, `follow`, `result`; `/health` database fingerprint |
| H. Entry point, docs, driver | this commit | `bin/shoestring`, README quick start, `docs/cli-work-loop.md`, `tools/live_eval/iter7a_work_loop.exs` |

## Verification

VERIFIED: `mix precommit` exited 0: **4 doctests, 2209 tests, 0 failures,
1 skipped (6 excluded)**, seed 440093, 443.1 s. JavaScript **52/52** and **8/8**.
Earlier, after packages A-C: 4 doctests, 2186 tests, 0 failures, 1 skipped,
6 excluded (seed 450409).

Hermetic tests added (no provider, no network): configuration tasks, intake
over real temporary Git repositories, the repository map in planner replay,
the Claude planner adapter against a scripted stand-in executable (flags,
empty working directory, own process group, token cap, results, failures,
oversized output, and a hung child killed by the adapter's own deadline),
Claude planner admission (blocked until confirmed; executable binds the
request), the sandbox on real private and shared worktrees, `do` with the
fixture planner (approve, decline, edit, held planning call, refusals),
`follow` (progress, held confirmation once, needs-user, cancellation), the
service check, task argument handling, and `bin/shoestring` with a stub `mix`.

## Full loop rehearsal (required eval)

VERIFIED: `tools/live_eval/iter7a_work_loop.exs` in rehearsal mode (fixture
planner, Fake Elves, real Oban queues, executor and gates in a prod-configured
node; no provider call) passed **3 of 3** runs: request, held planning call
confirmed, plan shown and approved, execution queued, task held and confirmed,
run, task accepted, all checks passed, result printed. Each: 1 run, 1 planner
attempt, about 68 s, fixture source unchanged; the printed fetch and merge in a
disposable clone gave passing tests. Run 3's record is in
[rehearsal-3](rehearsal-3/) (transcript, domain events, result).

The rehearsal starts from a passing implementation because Fake changes no
files, so it proves the loop, not a code change. The service check is not
exercised by the driver (the service runs in the same node).

## Real command smoke (dev, no provider call)

VERIFIED: `bin/shoestring models add`, `agents create ... --default` and
`do` against a scratch state directory and a real repository:

- The first `do` crashed in Req: the CLI starts only the repository, so Req's
  HTTP pool was not running. Fixed by starting `:req` in the service check.
  Not regression-locked: the test environment always runs Req.
- After the fix, `do` reached the developer's running service on port 4000,
  which uses a different database, and refused: "The running service uses a
  different state directory than this command." No goal was recorded.
- A dirty repository and a non-repository were refused with directions.

## Unverified until the live verification

- The Claude result shape for `--json-schema` (the adapter accepts
  `structured_output` or JSON text in `result`).
- That the Claude sandbox's `allowRead` for the run's paths wins over
  `denyRead` for the home directory when the state directory is under it.
- Plan quality from a real planner call, and the sandboxed Elf completing the
  task with Claude Code.

Proposed live bound (needs the user's authorization): one disposable fixture
repository under the home directory, at most **two planner calls** and **two
Claude Elf runs**, driven only through the work loop modules.

## Limits

- Manual `/runs/new` Claude runs share Git storage and keep their previous,
  unsandboxed launch.
- Amendment projections do not carry the repository map.
- `follow` asks only for capacity confirmations; failures, scope blockers and
  integration stop it with the command to run.
