# JSON Duality Views reference

_Written in Phase 5._

Will document each duality view (`order_dv`, `catalog_dv`, `customer_dv`):
purpose, consumer, the annotated SQL from `sql/02_duality_views.sql`, a real
sample document from `results/`, and the reasoning behind each annotation
choice.

## Payments: writable in `order_dv`, immutable everywhere

`order_dv.payments` is annotated `WITH(INSERT, UPDATE)`, but a payment can
never actually change. The UPDATE annotation exists only so an order
document sent back as JSON text can carry its existing payments unchanged:
JSON text turns `paid_at` into a string, and without UPDATE MySQL rejects
that unchanged value as a modification (`docs/findings.md` E23).

What stops real changes is GUARD 5 (`trg_payments_guard_immutable` in
`sql/01_schema.sql`), a `BEFORE UPDATE` trigger on the `payments` table that
rejects any change to a column value. It is a table trigger, so it applies
to **every connection by design** -- the agent writing through `order_dv`,
and an administrator running a direct `UPDATE payments` alike (E25, E26). No
role or code path is exempt.

That is the intended rule, not a side effect: a payment is a financial
record, and it is corrected with a new `refund` payment, never edited. A
wrong 500.00 payment stays on the order; a refund of -500.00 (and, if
needed, a new correct payment) is inserted next to it, so the history of
what happened is kept. (The `payments` CHECK constraint requires refund
amounts to be negative. Inserting a refund through `payment_dv` is the
intended path but is not yet exercised by a test.)
