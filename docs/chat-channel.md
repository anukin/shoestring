# Chat channel

The native chat screen (`shoestring chat`, a Rust terminal client) talks to
the running service over one Phoenix channel. The service owns the
conversation (`Shoestring.Conversations`); the client renders what the
channel sends and sends back what the person types. Losing the client loses
nothing.

## Transport

- `ws://localhost:PORT/chat/socket/websocket`, the endpoint's existing
  listener. The service binds loopback only; there is no other listener and
  no Erlang distribution.
- A connection is refused unless its peer address is loopback, the request
  names a local host (`localhost`, `127.0.0.1` or `::1`, so DNS rebinding
  cannot reach it), it carries no `Origin` or a local one (a web page on
  another site cannot open it), and it presents the conversation's token.
- Frames are at most 128 KiB. A message the person sends is at most 32 KiB
  (`Shoestring.Conversations.Engine`).
- Queued human text and each delivered turn are bounded at 128 KiB. An
  overflowing human message is refused with `pending_input_too_large` and
  may be sent again once the queue drains. Inbox entries are delivered in
  bounded batches, preserving every entry and charging each actual turn.
- Coordinator output is bounded at 256 KiB across the entire turn, including
  separate messages around tool calls. Text chunks are assembled until the
  message ends (or a tool call or turn ends it), then redacted together before
  persistence and display. Busy state and dispatch progress continue to update.
- Retained visible human and coordinator text is bounded at 4 MiB. It is
  counted from events again after restart. `context_limit_reached` refuses
  new text or fails an overflowing reply explicitly; `/handoff` continues the
  session in a fresh conversation (see Handoff). No history is deleted or
  compacted.
  This is a byte bound on visible text, not a provider token estimate: the
  provider CLI manages its own context, including tool results and compaction.

## Authentication: the token file

Each conversation has one token, in a file only the person can read:

    STATE_ROOT/chat/SESSION/chat-token     (directory 0700, file 0600)

- `Shoestring.Conversations.ChatToken.ensure/1` creates it (32 random bytes,
  base64url) the first time and returns the same token afterwards, so a
  client that reattaches presents the same token. It makes the directory
  0700 first, then writes a temporary file, makes it 0600 and renames it into
  place, so no one else can reach the token, even briefly.
- Connecting sends `session` and `token`. The service reads the file and
  compares in constant time. It refuses if the file is missing, is not a
  regular file, or can be read or written by anyone but its owner. The
  token is never logged, stored in the database or sent back.
- Whoever can read the file is the person: the state root is already theirs
  alone. Removing the file refuses every later connection until a new one is
  made; connections already open stay open.

## Channel: `conversation:SESSION`

Joining needs the socket's own session. Join parameters: `after`, the last
event sequence the client has (0 for none), and `conversation_id`, the
conversation those sequences belong to (optional). The join reply names the
session's current conversation (`conversation_id`); when the client named
another, the service ignores `after` and sends the current one from its first
event.

On join the service starts the conversation's engine if it is not running,
subscribes to the conversation's events, and only then reads the stored
events after `after` and pushes them in order. Live events that arrive
before the backlog is out are left to the backlog. An event committed while the
backlog is read is in the backlog or arrives afterwards, never both shown;
the client also drops any sequence it has already seen. Delivery is at least
once; a reconnect with the last acknowledged sequence resumes with no gap.

Pushed to the client:

| Event | Payload |
| --- | --- |
| `events` | Up to 100 conversation events in sequence order, each with `id`, `sequence`, `type`, `actor`, `occurred_at` and `payload` (already redacted; never reasoning, tool inputs or provider frames). The backlog comes in such batches; a live event comes alone. |
| `state` | A snapshot, pushed when it changes and at most once a second: the engine (`idle` or `in_turn`, pending counts, hold, `context` bytes used and limit, `handoff` status), the grant (limits, room, turns) and each dispatch of the session as `shoestring runs list` prints it. |
| `detached` | `reason: "slow_consumer"`, then the channel closes. The client reconnects with `after`. |

Sent by the client, each answered with `ok` or `error` and a `reason`:

| Event | Payload | Does |
| --- | --- | --- |
| `say` | `message_id` (a UUID the client picks), `text` | Records the message; it is sent to the coordinator when it is idle. A resent `message_id` records nothing twice. |
| `cancel_turn` | — | Interrupts the coordinator's running turn. |
| `cancel_dispatch` | `dispatch_id`, `reason` | Cancels one dispatch of this session, recorded as the person's request. The client confirms with the person first. |
| `handoff` | `note` (boolean, default true) | Continues the session in a fresh conversation (see Handoff). Refused with `turn_running` during a turn and `handoff_in_progress` while one is under way, except that `note: false` skips a note turn that is held. |

## Handoff

`/handoff` (or `/handoff facts`, without a note) continues the session in a
fresh coordinator conversation: same session, grant, dispatches and
instructions; the coordinator's context starts again. Nothing starts one
automatically; the screen shows how much of the text bound is used from
half full and suggests `/handoff` from 90%.

1. `conversation.handoff.requested` names the successor. With a note, one
   charged turn delivers only Shoestring's handoff instruction, after any
   handoff this conversation received and never delivered. It may use 64 KiB
   past the text bound, so a conversation at its limit can still hand off.
   No other turn starts in this conversation afterwards; messages sent
   meanwhile are carried over.
2. `conversation.handoff.prepared` records what carries over: the facts
   (from Shoestring's records only: the grant's remaining room and every
   dispatch with its state, commit, take commands, review rounds and next
   step; at most 24 KiB, older dispatches counted when they do not fit), the
   note (at most 16 KiB; a longer one, an empty one, or a turn that did not
   complete is not carried and the reason is recorded), the person's
   undelivered messages, and the inbox entries already delivered.
3. In one transaction the old conversation is marked handed off and gets
   `conversation.handed_off`; the successor is created in the same session
   and gets `conversation.opened` and `conversation.handoff.received`.
   The old engine starts the successor's and stops; the old conversation
   never runs again. A restart at any step continues it without repeating a
   turn or creating a second successor.

The successor delivers the received handoff with the person's next message
(or at once, when messages were carried over); the handoff starts no turn
by itself. Inbox entries the old coordinator was given are not announced
again; any other is. A joined client gets the old conversation's
`conversation.handed_off`, then the successor's events from its first.

## Backpressure

Conversation events come at the rate of turns, and the state snapshot is
coalesced to one a second, so a client's normal load is small (spike 5 saw
1–2 Elf events a second; Elf events reach the client only as snapshot
changes). A client that stops reading cannot block anything: the channel
checks its connection's outgoing queue before each push and, past 1,000
waiting messages, detaches it. Nothing is lost, since the client resumes from
the trajectory with `after`.

## Engines without a client

`/exit` or a lost terminal leaves the conversation and every Elf running.
At boot the service starts the engine of each conversation whose session
still has an active grant, so a dispatch that settles while no client is
attached still wakes the coordinator. Starting an engine makes no model
call.

## Dispatch inspection

Inbox deduplication identifies the particular admission decision or review
call, as well as its dispatch and state. A later hold or wait on the same
dispatch creates another entry; polling and restarting do not repeat the
same entry. Older entries without a settlement reference remain readable.

`state.dispatches` contains the session's dispatch rows: `dispatch_id`, purpose,
worker, reviewer, state, title, elapsed_seconds, waiting_until, latest_step, next,
run_id and terminal. Terminal is `/runs/RUN/terminal` only for an interactive
harness; headless Elves cannot be steered. Rows derive from `runs show` and
incremental canonical `runs log`, never raw provider output. Final rows are
cached for this channel connection.

Send `watch_dispatch` with `dispatch_id`. A dispatch outside this session is
indistinguishable from a missing dispatch (`dispatch_not_found`). The reply
contains dispatch_id, lines, terminal and steps. Steps contains entries
(sequence, at, line), last_sequence and omitted. It retains the latest 500
rendered entries, reporting earlier omissions. Each state tick pushes `dispatch`
when detail changes or entries arrive; sequence cursors suppress duplicates.
Call histories without a goal have null sequences and replace the previous
snapshot. `unwatch_dispatch` stops those pushes. Rejoining must watch again.
Inspection never advances, confirms or cancels execution.

In the native client, Tab focuses agents; arrows select; Enter opens details;
Escape closes them. Arrows scroll details; PgUp and PgDn scroll the conversation. `c` asks for confirmation for the
selected dispatch using service state; only `y` sends `cancel_dispatch`. It
names that exact dispatch and records the person's request. Cancels are never
resent after a reconnect; only unanswered messages are. An open detail is
watched again after reconnecting. Service text is cleaned before display,
including detail, waiting reasons, review findings and terminal links.
