# Working with a coordinator

Iteration 14 lets a coding CLI you chat with — Claude Code, Codex or opencode
— act as a coordinator: it plans with you and hands tasks to Shoestring,
which runs each one as a sandboxed Elf on the harness and model it chose.
This page covers what exists so far: `shoestring chat`, grants, IMPLEMENT
dispatches, `wait` and `runs`. EXPLORE and REVIEW dispatches, `capacity` and
advice are still to come ([the milestone](../plans/milestones/14-coordinator-orchestration.md)).

## Start a coordinator

```sh
cd ~/code/my-project
shoestring chat                            # the default agent's Coordinator role
shoestring chat --coordinator codex:MODEL  # another CLI or model, this session only
shoestring chat --session ID               # continue an earlier session under its grant
shoestring chat list                       # sessions, their grants and dispatches
```

A new session first shows the grant it proposes — the agent's Worker,
Reviewer and other roles' models, every purpose, and `shoestring grant`'s
default limits — and starts only after you confirm it. Then it starts the
coordinator CLI in your terminal with instructions on handing tasks to
Shoestring (`priv/coordinator/instructions.md`, plus the session, its
grant, the agent's roles and its instructions). How each CLI receives them:

| Coordinator | Model | Instructions | Status |
| --- | --- | --- | --- |
| Claude Code | `--model` | `--append-system-prompt-file` | REPO-INSPECTION of `claude --help` 2.1.310 |
| Codex | `-m` | `-c developer_instructions='''...'''` | UNVERIFIED in a live session |
| opencode | `OPENCODE_CONFIG_CONTENT` `model` | its `instructions` | UNVERIFIED in a live session |

The coordinator is your own session of that CLI, under its own permission
prompts; Shoestring does not sandbox it, and its instructions tell it not to
edit your checkout. Shoestring's own guarantee that your checkout is never
changed covers Shoestring and its Elves, not the coordinator CLI. `--session`
starts a new conversation in the CLI; the coordinator reads what was already
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

| Limit | Default | Meaning |
| --- | --- | --- |
| `--models` | required | the only models it may dispatch to (enabled ones) |
| `--purposes` | all | `explore`, `implement`, `review` |
| `--max-dispatches` | 10 | attempts in total, retries included |
| `--max-parallel` | 3 | dispatches queued or running at once |
| `--max-hours` | 4 | the time its dispatches may reserve in total |
| `--max-dispatch-minutes` | 60 | the most one dispatch may reserve |
| `--unread-usage` | 0 | dispatches it may start when a provider's remaining usage cannot be read |

Nothing is estimated: each limit is a count or a time Shoestring checks
before it records a dispatch. The standing usage reserves still apply to
every dispatch. `shoestring grants list|show` print each grant, its use and
its history; `grants extend` widens one and `grants revoke` stops new
dispatches (running work continues) — both ask you, in a terminal.

## 2. The coordinator dispatches

```sh
shoestring dispatch --purpose implement --worker codex:gpt-6-luna \
  --title "Make add() return the sum of its arguments" --brief brief.md \
  --file calc.py --stay-out test/ --test test/test_calc.py
```

The task becomes ordinary Shoestring work: a goal, a one-task plan authored
and approved under the grant (recorded as `grant:ID`, with
`author_kind: grant`), and an execution the service runs in a private copy
of the repository at its `HEAD`. The checks decide acceptance; the result is
a verified commit to fetch and merge, and your checkout is never changed.
The worker reads the brief under "Coordinator brief". Dispatched work is not
cross-reviewed automatically even with `:plan_review` enabled; the
coordinator reviews it with a REVIEW dispatch from another vendor once that
exists.

A dispatch outside the grant is refused with the limit it would cross and
nothing is queued. A retry with the same request id (by default derived from
the session, purpose, worker, title and brief) returns the same dispatch.
`--batch LABEL --batch-size N` declares a strategy of N dispatches; one more
is refused. `--dry-run` checks the grant and the plan and records nothing.

A grant identity is accepted only through a dispatch: `shoestring plans
approve --by grant:…` is refused, a grant can approve only the exact plan
its dispatch recorded, never reject one, and cannot cancel another session's
dispatch. Review waivers, scope decisions, integration and handoffs stay
yours.

A session id is not a secret: any program on your machine that knows it can
dispatch under its grant. The grant's repository, models and limits are what
bound that.

## 3. Wait and inspect

```sh
shoestring wait DISPATCH... [--timeout MINUTES]   # first one to settle, or exit 3
shoestring runs list                              # this session's dispatches
shoestring runs show DISPATCH                     # state, use, and the result
shoestring runs cancel DISPATCH --reason TEXT     # this session's own dispatch
```

States: `starting`, `queued`, `running`, `held` (its provider's remaining
usage could not be confirmed; you confirm it with `shoestring follow GOAL`),
`needs_you` (you decide, with `shoestring follow GOAL`), `completed`,
`cancelled`, `failed_to_start`.
`wait` reads Shoestring's records every few seconds and makes no model call;
a coordinator can run it in the background to be woken when it exits. `runs
show` of a completed dispatch includes the commit, its checks and the
`git fetch`/`git merge` commands.
