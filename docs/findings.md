# Findings

Every entry below comes from a script that was run against MySQL 9.7.2, with
its output captured in `results/`.

## Edge cases -- `sql/04_edge_cases.sql`

Evidence: `results/04_edge_cases.txt`. Run after `scripts/reset_db.py` and
`sql/03_dml_demos.sql`. Each block that writes runs in a transaction and is
rolled back. Expected codes were taken from the server's error catalog
(`perror`) before the run; where the catalog offered more than one plausible
code, the test expected "any error" and the actual code is recorded here.
All 25 tests matched their expectation.

| ID | Test | Who | Result |
|---|---|---|---|
| E01 | Second UPDATE sends the etag the first UPDATE replaced | agent | `ERROR 6494`: The ETAG of the document in the database did not match the ETAG ... passed in. (The first UPDATE succeeded; the etag changed.) |
| E02 | Order written back without one of its two items | agent | `ERROR 6498`: Missing DELETE tag on table `order_items`, path '$.items[1]'. |
| E03 | Order written back without one of its payments | agent | `ERROR 6498`: Missing DELETE tag on table `payments`, path '$.payments[0]'. |
| E04 | Product price changed through `catalog_dv` | agent | `ERROR 1142`: UPDATE command denied ... for table 'catalog_dv' (SELECT-only grant). |
| E04b | Same change | admin | `ERROR 6497`: Missing UPDATE tag on `products`.price, path '$.price' (the view has no UPDATE annotation). |
| E05 | Document written back with a different `_id` | agent | `ERROR 6496`: Cannot update primary key column `orders`.id from path '$._id'. |
| E06 | One UPDATE changing every business-1 order | agent | `ERROR 6482`: Multiple object update is not supported for JSON Duality Views. |
| E07 | `INSERT ... SELECT` of a valid new document | agent | `ERROR 6482`: INSERT... SELECT is not supported for JSON Duality Views. |
| E08 | `INSERT ... ON DUPLICATE KEY UPDATE` as an upsert | agent | `ERROR 6482`: INSERT... ON DUPLICATE KEY UPDATE is not supported for JSON Duality Views. |
| E09 | `EXPLAIN SELECT` on `order_dv` | admin | OK -- a plan is returned. |
| E09b | `EXPLAIN SELECT` on `order_dv` | agent | `ERROR 1345`: EXPLAIN/SHOW can not be issued; lacking privileges for underlying table. |
| E09c | `EXPLAIN UPDATE` on `order_dv` | admin | `ERROR 6482`: EXPLAIN for INSERT/UPDATE/DELETE is not supported for JSON Duality Views. |
| E10 | New order whose item references product id 999999 | agent | `ERROR 6491`: Read-only subobject with path '$.items[0].product', maps to row where `products`.id = (999999), which does not exist. |
| E11 | Business-1 order for a business-2 customer | agent | `ERROR 1644`: GUARD 4: orders.customer_id does not belong to orders.business_id. |
| E12 | Agent (grants on the four views only, none on tables) inserts an order, then updates it | agent | OK -- the order reads back with the new status. |
| E13 | Direct `SELECT` on the `orders` table | agent | `ERROR 1142`: SELECT command denied ... for table 'orders'. |
| E15 | Second order with an already-used `request_id` | agent | `ERROR 1062`: Duplicate entry 'h01-demo-001' for key 'orders.uq_orders_request_id'. |
| E16 | Payment appended to `order_dv.payments` without an id | agent | `ERROR 6560`: Paths $.payments[0] and $.payments[2] use generated and explicit values for the same primary key. |
| E17 | Payment appended with an explicit id given as a value (`@next_id`) | admin | OK -- the payment row is created next to the two existing ones. |
| E18 | Payment appended with its id from a subquery inside the UPDATE | admin | `ERROR 6560` (as E24). |
| REFUND1 | -500.00 `refund` inserted through `payment_dv` | agent | OK -- the refund appears in `payment_dv` and in the order's `payments`. |
| REFUND2 | `refund` with a positive amount | agent | `ERROR 3819`: Check constraint 'chk_payments_amount_sign' is violated. |
| E25 | Payment amount changed through `order_dv` | agent | `ERROR 1644`: GUARD 5: payments are immutable once inserted. |
| E26 | Payment amount changed with a direct `UPDATE payments` | admin | `ERROR 1644`: GUARD 5 (same message). |
| check | Payment re-read after E25/E26 | agent | amount still 500.00. |

What this means:

- **E01-E03, E05:** the document is the unit of change. An etag must match;
  leaving something out of an array means "delete it", which the view refuses
  unless it allows DELETE; primary keys cannot be changed.
- **E04/E04b, E12/E13:** two independent layers stop writes. Grants decide
  what the agent may touch at all (views yes, tables no); annotations decide
  what a view allows even for an admin.
- **E06-E08:** one document per statement. Bulk updates, `INSERT ... SELECT`
  and upserts are not available through a duality view; use SQL on the base
  tables for those (as an admin, not the agent).
- **E09 / E09b / E09c:** `EXPLAIN SELECT` works on a duality view for an
  account with rights on the underlying tables; `EXPLAIN UPDATE` fails with
  6482 for everyone; and the agent cannot EXPLAIN at all, because it has no
  rights on the underlying tables. Plan analysis therefore needs a separate
  DBA account -- it cannot be done with the agent's credentials.
- **E10, E11, E15, REFUND2:** the database rejects bad references, cross-
  tenant orders (GUARD 4), duplicate requests and wrong-signed refunds before
  anything is stored -- the agent's code does not have to check any of these.
- **E16-E18:** appending to an AUTO_INCREMENT-keyed array needs an explicit
  id given as a value (see E24). E17 works only since GUARD 5/design B (E23),
  which stopped existing payments' `paid_at` from blocking the write.
  `payment_dv` remains the practical path, since a client cannot know the
  next id in advance.
- **REFUND1, E25/E26:** payments are corrected by a new refund row, never by
  editing one.

## Other findings

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

