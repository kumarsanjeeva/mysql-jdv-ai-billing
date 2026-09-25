# Findings

_The full table is written in Phase 5, from the edge-case runs in
`sql/04_edge_cases.sql` and `results/`._

Will list one row per test ID (E01-E14, plus H01-H07) with: expected result,
actual result (quoted error code/message where relevant), verdict, and what it
means for developers building on JSON Duality Views. Surprises -- anything that
didn't match the documented behavior -- will be called out explicitly.

## Recorded so far (MySQL 9.7.2)

### E20 -- a nested read-only reference that reads back as `null` cannot be written back

Evidence: `results/repro_null_singleton_update.sql` / `.txt` (standalone, in
the `jdv_repro_scratch` database).

Setup: a child row's nullable foreign key exposed as a nested read-only
singleton object (the original `order_dv.items[].product_variant` shape).
A child with the foreign key NULL reads back as `"ref": null`. The UPDATE
changes only a root scalar; no reference is being changed.

| Test | What the client sends back | Result |
|---|---|---|
| NS1 | the document verbatim (`"ref": null`) | `ERROR 6495 (HY000): Value was not provided for path '$.children[1]' and could not be inferred for column ... ns_child.ref_id.` |
| NS2 | the document with the null `ref` key removed | same `ERROR 6495` |
| NS3 | control: every child has a ref, verbatim | OK |
| NS4 | workaround: FK exposed as flat scalar `ref_id`, verbatim with `"ref_id": null` | OK, `ref_id` stays NULL |
| NS5 | through the scalar view, set `ref_id` NULL -> 1 | OK, the column is an ordinary updatable field |

Meaning: once any array element has a NULL reference, the whole parent
document cannot be updated through that view, whether the null is sent or
omitted. The same error hit `order_dv` at H05 (item 2 has no variant).

Resolution: `order_dv` now exposes `'product_variant_id': product_variant_id`
as a flat scalar instead of the nested `product_variant` object. The item
keeps its own `flavor`/`size`/`unit` snapshot, so no information is lost from
the document. Re-run of H01-H05: E20 no longer occurs (H05 now fails later, on
a different, still-open error -- see below).

### E21 -- UUID-keyed child: appending a new child with an explicit key works

Evidence: `results/repro_uuid_child_append.sql` / `.txt`, run in a scratch database (this repo's tables use `BIGINT UNSIGNED AUTO_INCREMENT` keys). Child primary key
`CHAR(36)`, client-supplied UUIDs, no AUTO_INCREMENT. UPDATE keeps the
existing child by its UUID and appends a second child with a new UUID:
succeeds, `ROW_COUNT() = 1`, both rows present.

### E22 -- nested array order is irrelevant; elements are matched by key

Evidence: `results/repro_array_order_swap.sql` / `.txt`. AUTO_INCREMENT
children, `WITH(INSERT, UPDATE)`.
- SWAP1 (reverse the two children, no other change): OK, `ROW_COUNT() = 0`,
  neither row's `updated_at` changed, etag unchanged, read-back in id order.
- SWAP2 (reverse, and edit the element now at index 0, i.e. C2): OK,
  `ROW_COUNT() = 1`; only C2's row changed; C1's `updated_at` untouched.

### E23 -- a DATETIME in an insert-only nested array cannot survive a JSON-text round trip

Evidence: `results/repro_datetime_roundtrip.sql` / `.txt` (five ways), and
`results/repro_e23_datetime_text_roundtrip.sql` / `.txt` (standalone,
bug-report style).

Setup: root `WITH(INSERT, UPDATE)`; nested child array `WITH(INSERT)` only
(the `order_dv.payments` shape) with a `DATETIME(6)` column. The client
reads the document and writes it back with only a root scalar changed.

| How the client holds/sends the document | `paid_at` JSON type | Result |
|---|---|---|
| A: user variable `@doc` | STRING | `ERROR 6497 (HY000): Missing UPDATE tag on ... dt_payment.paid_at, path '$.payments[0].paid_at'.` |
| B: temporary table, JSON column | DATETIME | OK |
| C: `CAST(@doc AS JSON)` | STRING | same `ERROR 6497` |
| D1: literal JSON text, `"2026-09-26 10:00:00.000000"` | STRING | same `ERROR 6497` |
| D2: literal JSON text, `"2026-09-26T10:00:00.000000"` | STRING | same `ERROR 6497` |

Meaning: a duality view reads a DATETIME as the JSON DATETIME type, but
JSON text has no datetime type, so any document that passes through text
carries it back as a JSON string. MySQL then treats the unchanged value as
an update, and an insert-only array rejects it. User variables cannot hold
the JSON type, so `@doc` is text too. Every application client sends text
(D1/D2), so for them the document cannot be written back at all once it
has a payment. Only a document that never leaves SQL's JSON type works (B).
This is what blocked H05 once E20 was fixed.

Two designs tested against case D1 (`results/repro_payment_design_ab.sql` / `.txt`):

- **Design A -- payments read-only inside the order view** (no annotations;
  payments written only through their own view). The transaction part
  works: order-view INSERT + payment-view INSERT commits together (A1), rolls
  back together (A2), and a failing payment insert leaves no order behind
  (A3). But the D1 round trip still fails (A4): `ERROR 6497 (HY000): Missing
  UPDATE tag on ... da_payment.paid_at`. A read-only array rejects the
  string datetime exactly like an insert-only one. So the problem is the
  value comparison (the string `paid_at` does not compare equal to the
  stored DATETIME, so it counts as a change), not the annotation: removing
  write permission does not make the unchanged value acceptable.
- **Design B -- payments `WITH(INSERT, UPDATE)` plus a BEFORE UPDATE trigger
  that rejects any column change.** The D1 round trip succeeds and the
  payment row is not modified (`updated_at` unchanged) (B1). Changing an
  amount in the text is rejected by the trigger: `ERROR 1644 (45000):
  payments are immutable: a column value changed` (B2).

Resolution: design B adopted -- `order_dv.payments` is `WITH(INSERT,
UPDATE)` and GUARD 5 (`trg_payments_guard_immutable` in `sql/01_schema.sql`)
rejects any change to a payment. In the demo database, H05 then succeeded:
the order became `delivered` and neither payment row was modified.

### E25 / E26 -- GUARD 5 holds in the demo database, for every connection

Evidence: `sql/04_edge_cases.sql`, `results/04_edge_cases.txt`. Target:
`seed-payment-001` (500.00).

| Test | Who / how | Result |
|---|---|---|
| E25 | agent user, through `order_dv`, sets the payment's `amount` to 1.00 | `ERROR 1644 (45000): GUARD 5: payments are immutable once inserted` |
| E26 | admin user, direct `UPDATE payments SET amount = 1.00` | same `ERROR 1644` |
| check | agent reads the payment back | `amount` still 500.00 |

### E24 -- an explicit child id works; an id from an inline subquery is treated as generated

Evidence: `results/repro_append_explicit_ids.sql`,
`results/repro_append_rerun_h04b.sql`, `results/repro_append_bisect.sql`
(each with its `.txt`).

Appending a new child with an explicit AUTO_INCREMENT id next to an
existing child, via `JSON_ARRAY_APPEND` in an UPDATE:

| Variant | Result |
|---|---|
| id from `@next_id`, set earlier (minimal scratch view) | OK |
| B0: real `order_dv`, id as `(SELECT AUTO_INCREMENT FROM information_schema.tables ...)` inline in the UPDATE (the original attempt) | `ERROR 6560 (HY000): Paths $.payments[2] and $.payments[0] use generated and explicit values for the same primary key, which is not allowed.` |
| B2: as B0, plus the payment's `request_id` | same `ERROR 6560` |
| B1: real `order_dv`, id from `@next_id` set earlier | passes the id check (then stops on E23's `ERROR 6497`) |
| B3: real `order_dv`, id as the literal `9` | passes the id check (then stops on E23's `ERROR 6497`) |
| B4: minimal scratch view, id as the inline subquery | `ERROR 6560` |

The same subquery evaluated on its own returns `{"id": 9}`. Meaning: an
explicit id works; an id produced by a subquery inside the UPDATE itself is
treated as generated, so it counts as a generated/explicit mix. Neither
the annotations nor the nesting made a difference.

This corrects the earlier claim (in the `sql/02_duality_views.sql` and
`sql/03_dml_demos.sql` comments) that an explicit-id append is always
rejected; those comments now state it precisely.

