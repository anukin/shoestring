# Acceptance gap follow-up — 2026-10-25

Status: local implementation and verification follow-up. This is not a claim
of real calibration, paid/local adapter inference or all-platform acceptance.

VERIFIED: baseline `2149d58`; work on branch `codex/acceptance-gap-closure` in an
isolated worktree. The user's source checkout was not edited. GitHub CI is
excluded at the user's direction. No new provider call or quota budget was used.

## Changes

REPO-INSPECTION: the product layout now has a visible-on-focus skip link and a
focusable, named main landmark. Agent actions include their agent name; role
editors use native fieldsets and legends. Adding/removing a role announces its
outcome and transfers focus to the new name field or Add role. Submitted form
errors focus a summary and retain the draft.

REPO-INSPECTION: text, textarea, select and checkbox errors expose
`aria-invalid` and point to one error group while preserving existing help
references. Valid fields retain help without invalid/error attributes. Settings
help has stable IDs. Usage refresh has a dedicated polite status region;
history has a native date/value table alongside decorative hidden bars.

REPO-INSPECTION: flash dismissal now uses a native button's plain
`lv:clear-flash` event and a button-scoped hook that restores main-landmark
focus only after an explicit dismissal. The hook removes its own listener.
Navigation that destroys a flash does not steal focus. There is no document
click handler, clickable message container or encoded command JSON in flash
markup; the existing flash-sanitization invariant is retained.

VERIFIED: the native browser check found a previously untested production path:
HTTP pages at `127.0.0.1` rendered but LiveView rejected their origin because
the default endpoint host was `localhost`. Runtime configuration now explicitly
allows the configured HTTP host and exact localhost/IPv4/IPv6 loopback origins
at the configured port. Origin checks remain enabled. Foreign hosts, deceptive
localhost subdomains, wrong ports and wrong schemes are rejected by the real
Phoenix transport check.

REPO-INSPECTION: README now describes the implemented supervisor, installed CLI,
concurrency, review, terminal, usage and opencode work. A central acceptance
status and concrete calibration runbook retain the deferred scope. No collection
window was opened, no attestation was made by an agent, and routing stays disabled.

## Regression evidence

VERIFIED against unchanged baseline `2149d58`:

- Initial new LiveView suites: 7 tests, 7 behavioral failures, seed 469500.
- Final configuration/input suites: 7 tests, 7 behavioral failures, seed 861279.
- Origin suite: 3 tests, 1 behavioral failure, seed 893301; the failure is the
  observed rejection of `http://127.0.0.1:4018`.
- Browser bootstrap tests against the original JavaScript: 3 tests, 1 pass,
  2 behavioral failures (focus transfer and dynamic-flash focus restoration).
  No missing module or changed signature is used.

VERIFIED: final focused accessibility/input/origin suite: 12 tests, 0 failures,
seed 18344.
Earlier combined configuration/usage suite: 19 tests, 0 failures. The earlier
custom flash-delegation approach was replaced by the native button event and
scoped hook. The first full gate caught a legacy assertion against braces in
flash HTML after an encoded-JS version was tried. The assertion was preserved;
the final flash/configuration/legacy run-page focused run passed 34 tests,
0 failures, seed 566971. Node's final focused browser suite passed 3/3.

## Native Firefox acceptance

VERIFIED with synthetic local state and provider automation disabled:

- The first page Tab stop exposed a visible Skip to content link. Keyboard
  entry populated the agent fields and reached Save in document order.
- Firefox exposed native labels and role-group names. A submitted invalid
  slug kept the draft; a temporary local console diagnostic observed the
  pushed error-summary ID equal the actual focused element ID. That diagnostic
  is not shipped or retained as a fixture.
- After the origin fix, the IPv4 loopback page completed actual LiveView role
  add/remove round trips. Keyboard removal focused Add role; Space added the
  role and focused the new name field. Status text included each change.
- Settings save inserted its success message. Tab/Enter dismissed its close
  button; the message disappeared and focus returned to the main container.
  This was repeated against the final button-scoped-hook implementation, not
  only the earlier encoded-command version.
- The 390 × 844 form stacked fields and role controls without horizontal
  overflow in the inspected viewport. Desktop focus styling was also inspected.

VERIFIED: Firefox's All Issues scan reported a generic body keyboard warning,
not a clean audit. REPO-INSPECTION: the application has no body click action;
Phoenix LiveView's locked client delegates clicks at `window` and returns
without an action when no `phx-click` target exists
(`deps/phoenix_live_view/assets/js/phoenix_live_view/live_socket.js`,
`bindClick/2`). This framework-delegation diagnostic is retained; no fake
button role or extra Tab stop was added to the body to silence it.

VERIFIED: the Impeccable mechanical detector reported exactly three advisory
type-ramp findings: the existing 18px wordmark, 11px history dates and 16px
mobile inputs. REPO-INSPECTION: all three are explicitly documented exceptions
in DESIGN.md and were not introduced by this change. No detector suppression
or design-system metadata rewrite was made.

VERIFIED: the user requested the Firefox Inspector/keyboard alternative after
VoiceOver access could not be established. UNVERIFIED: actual spoken
announcements, a human screen-reader evaluation, long-duration load/RSS, fresh
live provider inference, real calibration and optional API/local inference.
These checks were not silently promoted by the local results.

## Full gate and release

VERIFIED: the first full gate exited 2: 4 doctests, 2555 tests, 1 failure,
1 skipped, 6 excluded; seed 902895; 562.6 seconds (12.6 async, 549.9 sync).
The single failure was the flash-markup braces assertion described above.
Rust passed 4 unit and 5 integration tests; Node passed 52/52 and 16/16.
This result is retained as red. The final hook was fixed and focused-checked
before the subsequent same-seed full gate; this is not an intermittent retry.

The final exact gate command, counts and release verification will be recorded
after completion. Raw logs stay local; only aggregate synthetic evidence is
committed. No provider payload, account identifier, credential or screenshot of
unrelated browser tabs is part of this evidence.
