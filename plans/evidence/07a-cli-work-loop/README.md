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
| H. Entry point, docs, driver | `7f3393c` | `bin/shoestring`, README quick start, `docs/cli-work-loop.md`, `tools/live_eval/iter7a_work_loop.exs` |

## Verification

VERIFIED: `mix precommit` exited 0: **4 doctests, 2209 tests, 0 failures,
1 skipped (6 excluded)**, seed 440093, 443.1 s. JavaScript **52/52** and **8/8**.
After the live verification (driver edit path added): `mix precommit` exited
0: **4 doctests, 2209 tests, 0 failures, 1 skipped (6 excluded)**, seed
707858, 455.5 s; JavaScript 52/52 and 8/8.
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

## Live verification (authorized: at most two planner calls, two Claude Elf runs)

The user authorized it on 2026-10-15 ("yes run the live verification run")
against the proposed bound: one disposable fixture under the home directory,
at most **two planner calls** and **two Claude Elf runs**. Used: **two planner
calls, one Elf run**. Claude Code 2.1.301, model `claude-opus-5-5`, Git 2.50.1.
Each run's fixture and state directory was a new directory under the home
directory, so the sandbox's home `denyRead` covered the worktree's parent.
Records were exported by the driver with the evaluation root and home
directory substituted; no session or message identifiers, raw provider frames
or reasoning are exported.

### Attempt 1: planner call, plan declined (no Elf run)

VERIFIED ([live-1](live-1/)): the held planning call was confirmed and one
`claude --print --json-schema` call returned a plan that parsed and passed the
contract on the first try (826 output tokens, about 7 s for the whole command).
The result shape question is closed: the adapter accepted Claude's reply as is.
The plan was sound (one task, `calc.py`, the detected gate, criteria that keep
the tests unchanged) but asked for a budget of **3 attempts**, above the
authorized two runs, so the scripted terminal declined it and nothing ran.

The driver was then given the human's other option: on a plan within the
fixture but over budget, answer `e`, cap every attempt limit at two and submit
the edit as a new revision (`Iter7aShell.edit/1`). Checked offline against
attempt 1's stored plan before spending the second call: the capped plan
passed `PlanContract.new/1` and the answers were `e`, then `y`, and `n` for an
over-budget or out-of-fixture plan.

### Attempt 2: plan, edit, approve, sandboxed Elf, result (passed)

VERIFIED ([live-2](live-2/), `transcript.json`, `domain-events.json`):

- One planner call (878 output tokens): one task `fix-add` on `calc.py`, budget
  3 attempts and 30 minutes. The terminal pressed `e`; revision 2 carried
  budget 2 and task `max_attempts` 2, was shown and approved.
- The task was held for capacity (`conservative_partial`), confirmed once by
  `human:user`, admitted and run: **one** Claude Elf run, 6 turns, 27.6 s,
  0.0845 USD reported by the CLI, `terminal_reason` `completed`.
- Runtime: tools `Bash` only, permission mode `dontAsk` (the bypass mode is no
  longer used for plan runs).
- The Elf read `calc.py` and the tests, replaced `raise NotImplementedError`
  with `return a + b`, ran the tests, committed, and removed its
  `__pycache__` directories, all inside its worktree under the home directory.
- Shoestring accepted the task at `f47ae6e`, ran the final gate
  (`python3 -B -m unittest test/test_calc.py` exit 0) and printed the result:
  `calc.py | 2 +-`, with the fetch and merge commands.
- The fixture source was unchanged by the run. The printed `git fetch` and
  `git merge FETCH_HEAD`, run as printed in the fixture source afterwards,
  fast-forwarded to `f47ae6e`, and the tests ran 2, OK. The driver's clone
  check gave the same.
- Whole loop: 100.4 s from request to result.

Sandbox findings:

- VERIFIED: with the state directory under the home directory, the sandboxed
  Elf could read and write its worktree and private Git directories; the
  run-path `allowRead` was not overridden by the home `denyRead`. That the
  rest of the home directory was unreadable was **not** probed live (the Elf
  never tried); the hermetic tests cover only the settings derived.
- VERIFIED: the sandbox confined writes. The Elf reported that `git commit`
  printed "Unable to create ... packed-refs.lock: Operation not permitted";
  the commit still landed and the branch pointed at it. Reproduced without
  Claude on Git 2.50.1 with the private store laid out as Shoestring builds it
  (`init --bare`, fetch, `worktree add`) and its top directory read-only: a
  worktree commit prints the same error, exits 0 and records the commit,
  whether or not `packed-refs` exists. It is Git's own non-fatal lock attempt
  on a branch update, refused because the store's top directory is outside
  the writable roots by design. It is noise, not a failure; a future Git that
  made it fatal would stop Elf commits under the sandbox.
- Claude reported `allowed_warning` with five-hour utilization **0.90 → 0.91**
  and seven-day 0.71 during the run.

Not verified live: planner cost (the planner records output tokens, not
cost); a repair call; a failing or scope-blocked attempt; the service check
against a separate service process (the driver runs the service in its own
node, as in the rehearsal).

## Limits

- Manual `/runs/new` Claude runs share Git storage and keep their previous,
  unsandboxed launch.
- Checks (gates) run unsandboxed (REPO-INSPECTION: `Cobbler.GateProcess`
  spawns the command with no file or network confinement and the service's
  environment). A gate runs code the Elf wrote, so it can do what the Elf's
  sandbox refuses. Planned as iteration 8 work package 0. (Addressed on
  2026-10-16 by that package on macOS, with its own limits: see the
  [iteration 8 evidence](../08-verification-cross-review/README.md). This
  record of the 7A state is unchanged.)
- Amendment projections do not carry the repository map.
- `follow` asks only for capacity confirmations; failures, scope blockers and
  integration stop it with the command to run.
- The planner chose a budget of 3 attempts in both live calls. `do` has no
  budget option; a human lowers it with `[e]dit`.
- Git prints a harmless `packed-refs.lock` error on every sandboxed Elf
  commit (see the live findings).
