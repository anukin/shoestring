# Native chat context and usability fixes

Scope: the iteration 15 review at `afde248`; hermetic tests only. No live
provider calls, captured provider transcripts, credentials or hidden model
reasoning were used. All session and secret values in fixtures are synthetic.
The user's source checkout is untouched. Direct publication to main is
explicitly authorized by the user, overriding the usual branch/PR workflow.

## Behaviour

REPO-INSPECTION:

- Both the original implementation brief and an explicit review brief enter
  the immutable, redacted review packet. The built-in reviewer receives the
  dispatch's frozen brief too. Packet digests cover these requirements.
- Text fragments are assembled before redaction or storage. Logical message
  boundaries survive Codex streaming; empty fragments create no messages.
  The 256 KiB reply cap counts the entire turn, including text around tools.
- Queued human input and delivered turn input are bounded at 128 KiB.
  Visible conversation text is bounded at 4 MiB, rebuilt from events after
  restart. Refusals are explicit. Provider tokens, tool-result context and
  compaction remain managed by the coding CLI; these byte bounds do not
  estimate the provider's context window or introduce automatic compaction.
- Inbox entries distinguish successive decisions and review calls on one
  dispatch. A completed worker no longer hides its review's hold as running.
  Legacy inbox entries are compared with the cause's durable time so an
  upgrade does not deliver or charge an already-delivered hold again.
  Interrupted creations still show starting and then a failed start.
- Claude refuses a changed session identity during resume. No uncertain
  turn is retried, and a refused start retains the provider session binding.

## Regression evidence

VERIFIED on original production code `afde248` with only the new tests and
scripted test fixtures copied into a separate baseline worktree:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/conversations/engine_test.exs test/shoestring/cobbler/plan_review_test.exs test/shoestring/dispatch_integration_test.exs test/shoestring/conversations/native_chat_acceptance_test.exs test/shoestring/harness/claude_headless/conversation_test.exs < /dev/null
```

Result: exit 2, **64 tests, 13 failures**. `git diff --name-only -- lib` was
empty in the baseline worktree. Failures include:

- Missing implementation and review briefs (`packet["briefs"]` was nil),
  including the requirement planted only in an explorer report.
- A built-in review hold displayed as `running` instead of `held`.
- The second held decision created one inbox entry instead of two.
- Split synthetic credentials retained, and cumulative output limits ignored.
- Context and pending-input limits ignored. Redaction expansion exceeded the
  proposed visible-context bound.
- Claude resumed onto a substituted session instead of closing it.
- The two character-stream transport cases failed on whitespace fragments:
  the old engine tried to persist blank messages. These defend assembled
  message handling; the separate chunk-redaction test proves the leak itself.

VERIFIED separately for the final message-boundary/context-exhaustion case:

```sh
perl -e 'alarm 60; exec @ARGV' mix test test/shoestring/conversations/engine_test.exs:286 < /dev/null
```

Result on `afde248`: exit 2, **1 test, 1 failure (30 excluded)**. It ended
`interrupted` instead of failing for the exhausted context.

VERIFIED again after adding the legacy inbox fixture to the second-hold test:

```sh
perl -e 'alarm 60; exec @ARGV' mix test test/shoestring/conversations/engine_test.exs:765 < /dev/null
```

Result on `afde248`: exit 2, **1 test, 1 failure (31 excluded)**. The old
entry remained deduplicated, but the later hold still left one entry instead
of two. On the fixed implementation the same test also verifies grant turn
counts before upgrade, after the second hold, and after restart.

## Coverage added beyond regression locks

VERIFIED by targeted hermetic runs: scripted context persists across adapter
and engine restarts, fresh sessions cannot recall another session's value,
and missing scripted history refuses without a fresh call. The refused
engine turn is refunded. These add coverage for existing protocol behaviour;
they are not claimed as regression locks against broken recall code.

The integrated dispatch story plants a requirement in an explorer report,
passes it explicitly into the worker brief, checks the actual scripted worker
prompt, then checks the review input. The native acceptance story now includes
the built-in reviewer as well as the separate REVIEW dispatch.

UNVERIFIED: real-model recall quality, semantic handling of contradictory
findings, and provider-managed compaction over a long live conversation.
The scripted fixtures prove context delivery and isolation, not model quality.
No live provider budget was authorized for this change.

## Final gate

The exact command is:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

VERIFIED: exit 0 on the final implementation. **16 partitions in 120.4 s:
4 doctests, 2801 tests, 0 failures, 1 skipped, 6 excluded**.

- Rust terminal: 4 unit and 5 PTY tests passed.
- Rust chat: 26 library, 4 binary and 6 stub-channel tests passed; format and
  clippy with warnings denied passed.
- JavaScript: 52/52 and 14/14 passed.
- `git diff --cached --check` passed. Added lines contain no machine-specific
  home paths or attribution trailers.

Earlier full gates passed before the last edge safeguards (2799 and then
2800 tests respectively). The final gate above covers all code being shipped.
