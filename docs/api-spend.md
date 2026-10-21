# API spend guard foundation

API execution is disabled when configuration is absent. Enabling it still
requires a positive operator-configured monthly cap and explicit acceptance of
a compatible, effective pricing version. Run requests cannot select those
values. This guard is the first part of iteration 10D; connecting and validating
the optional adapter is separate work. No live API execution is claimed here.

All money is represented as integer micro-US dollars (`1 USD = 1,000,000
microusd`), with charges rounded upward. Reservations cover the model's full
documented context bound plus the configured output maximum, rather than a
character-to-token heuristic. The built-in entry is text-only GPT-6 Luna via a
single standard Responses request, with a 1,050,000-token context bound and up
to 128,000 output tokens. Those limits come from the [official model
documentation](https://developers.openai.com/api/docs/models/gpt-6-luna).

Price version `openai-standard-upper-2026-10-20-v1` is an explicitly conservative
upper schedule: $0.30 per million input tokens and $1.00 per million output
tokens. These are rounded upper rates inferred from the documented standard,
long-context/cache-write and regional rates, not OpenAI's quoted base prices or
an invoice estimate. The entry expires after 2026-11-20. It supports no tools,
media, fast tier, background work, conversation continuation or retries.
Pricing is never fetched during a run; see the [official pricing
reference](https://developers.openai.com/api/docs/pricing). A commercial price
change outside the frozen assumptions cannot be controlled by local code.

An operator may supply a separately versioned, dated `price_override` through
application configuration. Overrides must retain the supported model, at least
the documented context bound, and at least the built-in upper rates. Lower
rates require an explicitly reviewed code/table update. Expired, unaccepted,
incompatible or malformed pricing refuses dispatch.

## Durable allowance

Each reservation is keyed by the durable dispatch ID and tied to the exact run,
goal, task and workspace. The row stores its immutable price quote, maximum,
cap, UTC month and status. An immediate SQLite transaction checks the occupied
allowance and creates the reservation together, before an external effect is
allowed. Independent application instances use the same database lock; a
duplicate dispatch cannot authorize a second call.

Bounded reported input/output counters reconcile under the original quote,
using conservative upper rates even if configuration later changes. This is a
usage-based upper amount, not a precise bill. Identical reconciliation is
idempotent; conflicting counters cannot rewrite an existing settlement.

Missing/out-of-bound usage, transport uncertainty and restart preserve the full
reserved maximum. There is no timeout, expiry or reaper that frees it. Unresolved
reservations occupy allowance in every later month. A call crossing a month
boundary is conservatively counted in both its start and reconciliation months;
the ledger does not pretend to reproduce a provider's billing calendar. Lowering
the cap exposes the occupied amount and blocks new calls without evicting work.

Deleting a measurement cache cannot delete this ledger. Manual database deletion
or destructive schema rollback loses spend authority along with other state;
the app does not perform either operation. Upgrade and backup tooling must
preserve the ledger. No live request, billing reconciliation, credentials or
account access has been verified in this foundation.
