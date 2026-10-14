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

### E27 -- JSON_TABLE over a duality view fails inside `SET @var = (SELECT ...)`

Evidence: `results/repro_e27_jsontable_set_subquery.sql` / `.txt`
(standalone, in `jdv_repro_scratch`). Found while writing
`sql/05_scenario.sql`.

| Test | Form | Result |
|---|---|---|
| Q1 | `SELECT MAX(c.id) FROM parent_dv p, JSON_TABLE(p.data, '$.children[*]' ...) c` on its own | OK |
| Q2 | the same query as `SELECT ... INTO @var` | OK |
| Q3 | the same query as `SET @var = (SELECT ...)` | `ERROR 1210 (HY000): Incorrect arguments to JSON_TABLE` |
| Q4 | control: `SET @var = (SELECT ...)` with `JSON_TABLE` over JSON not from a duality view | OK |

Meaning: only the combination of a duality view's `data` column, `JSON_TABLE`
and a scalar subquery in `SET` fails. Use `SELECT ... INTO @var` instead;
`sql/05_scenario.sql` does.

## GUARD 6 and GUARD 7 -- `sql/06_guards_6_7.sql`

Two more database-level guards, in their own file. `scripts/reset_db.py` runs
it after `00` -> `02`, so a rebuild always ends complete. Evidence:
`results/06_guards_6_7.txt` (the six guard triggers now on the database, and
the seed check below), `results/07_e28_item_price_guard.txt` (E28),
`results/08_e29_payment_business_guard.txt` (E29). All three are real runs
against MySQL 9.7.2 on local `localhost:3306`. Every error below was produced
through `order_dv` / `payment_dv` as the agent user, except where marked admin.

**GUARD 6 -- order item price** (`trg_order_items_guard_ins`,
`trg_order_items_guard_upd` on `order_items`):

- **INSERT:** an item must point at the catalog, and its `price` must equal the
  current catalog price -- the variant's price if `product_variant_id` is set,
  else the product's. Compared as DECIMAL with `<=>`.
- **UPDATE:** `price`, `product_id` and `product_variant_id` cannot change.
  Nothing is re-checked against the catalog on UPDATE, so a later catalog price
  change never touches an existing item.

**GUARD 7 -- payment business** (`trg_payments_guard_business_ins` on
`payments`): on INSERT, `payments.business_id` must equal the `business_id` of
the order the payment pays (a missing order also fails). It is BEFORE INSERT
only; updates were already stopped by GUARD 5, so the two triggers do not
interact and the `order_dv.payments` `WITH(INSERT, UPDATE)` design (E23) is
unchanged. GUARD 4 did not cover this: it only checks an order's customer and
outlet.

**Additions in this repo** (deliberate, each added after a design
review):

1. **Variant must belong to the product.** If an item carries both
   `product_id` and `product_variant_id`, the variant's product must be that
   product. Without it, a cheap variant of one product could be attached to
   another and still pass the price check (E28b4).
2. **An item with neither a product nor a variant is rejected.** It has nothing
   to be price-checked against, so allowing it would leave a hole (E28b3).
3. **`product_id` and `product_variant_id` are immutable on UPDATE**, not only
   `price` (E28c2, E28c3). Otherwise the checks in item 1 could be bypassed by
   a later UPDATE that swaps the catalog link without touching the price.

**Seed data.** The seed rows load before the triggers exist, so the end of
`sql/06_guards_6_7.sql` checks them: 9 items checked; 0 differ from their
catalog price, 0 have no catalog link, 0 have a variant of another product;
`seed_vs_catalog = PASS` (`results/06_guards_6_7.txt`).

### E28 -- GUARD 6 through `order_dv`

Evidence: `sql/07_e28_item_price_guard.sql`, `results/07_e28_item_price_guard.txt`.
All 17 blocks matched their expectation. Rejected blocks were written as
"expect any error" and the real code and message are recorded here.

| ID | Test | Result |
|---|---|---|
| E28a | Black Forest Cake 1 kg (variant 2) inserted at 900.00 | OK |
| E28a2 | same, price sent as the JSON integer `900` | OK -- no false rejection from 900 vs 900.00 |
| E28a3 | product-only item (pastry, no variant) at 90.00 | OK |
| E28b | variant item at 100.00 | `ERROR 1644`: GUARD 6: order_items.price does not match the current catalog price |
| E28b2 | product-only item at 80.00 | `ERROR 1644`: same message |
| E28b3 | item with neither product nor variant | `ERROR 1644`: GUARD 6: order_items must reference a product or product variant, so the price can be checked against the catalog |
| E28b4 | Vanilla variant 5 attached to Black Forest Cake (product 1), at 750.00 | `ERROR 1644`: GUARD 6: order_items.product_variant_id does not belong to order_items.product_id |
| E28c | existing item's price 900.00 -> 1.00 | `ERROR 1644`: GUARD 6: order_items.price, product_id and product_variant_id are immutable once inserted |
| E28c2 | existing item's variant 2 -> 3 | `ERROR 1644`: same message |
| E28c3 | existing item's product 1 -> 2 (`$.items[0].product.id`) | `ERROR 1644`: same message -- the change reached `order_items.product_id` through the view and GUARD 6 stopped it |
| E28c4 | existing item's `notes` changed | OK -- the guard does not block other edits |

**E28d -- a later catalog price change leaves existing items alone.** This is
the one block that commits a real change (admin, because `catalog_dv` is
read-only, E04). Safeguards: E28d1 first asserts the original price is the
recorded 900.00 (it stops before changing anything otherwise); E28d3 restores
it; E28d4 asserts it is back. Order of events:

| ID | Step | Result |
|---|---|---|
| E28d1 | admin: variant 2 price 900.00 -> 950.00, committed | `original price recorded: 900.00`; 1 row changed; catalog now 950.00 |
| E28d2 | agent: read `seed-order-001`, write it back through `order_dv` (rolled back) | the old item still reads 900.00 while `catalog_dv` says 950.00; the write-back succeeds with the item still at 900.00 |
| E28d2b | agent: NEW item at the old price 900.00 | `ERROR 1644`: price does not match the current catalog price |
| E28d2c | agent: NEW item at 950.00 | OK |
| E28d3 | admin: variant 2 restored to 900.00 | 900.00 |
| E28d4 | assertion: price is back to the recorded value | `PASS: catalog price restored to 900.00`; 0 of the three Black Forest variants differ from their seed prices |

Consequences worth stating: if the catalog changes between the agent reading a
price and inserting the item, the insert is rejected (E28d2b shows the effect);
and since `order_dv` has no DELETE and the price is immutable, a wrongly priced
item that did get in cannot be corrected through the view -- only an admin can.

### E29 -- GUARD 7 through `payment_dv` and `order_dv`

Evidence: `sql/08_e29_payment_business_guard.sql`,
`results/08_e29_payment_business_guard.txt`. All 3 blocks matched.

| ID | Test | Result |
|---|---|---|
| E29a | payment for `seed-order-002` (business 1) with `business_id` 1, via `payment_dv` | OK -- payment and order both show business 1 (rolled back) |
| E29b | same payment with `business_id` 2 | `ERROR 1644`: GUARD 7: payments.business_id does not match the business_id of the order it pays |
| E29c | new order (business 1) created through `order_dv` with a nested payment of `business_id` 2 | `ERROR 1644`: same message |

### Regression after adding GUARD 6 and 7

After `scripts/reset_db.py` (which now includes `06`), `sql/03_dml_demos.sql`
(H01-H07) ran with exit code 0; `sql/04_edge_cases.sql` -- all 25 blocks
(E01-E18, REFUND1/2, E25, E26, check) PASS; `sql/05_scenario.sql` -- all 6
blocks PASS. Evidence: the regenerated `results/03_dml_demos.txt`,
`results/04_edge_cases.txt`, `results/05_scenario.txt`. E10 (order with product
id 999999, expected `ERROR 6491`) still returns `ERROR 6491` with the view's
own message ("Read-only subobject ... maps to row where `products`.id =
(999999), which does not exist"), so GUARD 6 did not change that outcome.

### Tenant gap on items -- proven, then closed by GUARD 8 (next section)

This section originally recorded the gap as a known limitation. It was stated
before it was tested; it was then tested (`results/10_e30_before_guard_8.txt`)
and closed by GUARD 8 / 8b below.

## GUARD 8 and GUARD 8b -- `sql/09_guard_8.sql`

`scripts/reset_db.py` runs it after `06`. Evidence: `results/10_e30_before_guard_8.txt`
(probes run BEFORE the guard existed -- never regenerated by a reset),
`results/09_guard_8.txt` (the triggers and the seed check),
`results/11_e30_guard_8.txt` (the same probes AFTER). Real runs on MySQL 9.7.2,
`localhost:3306`, as the agent user through `order_dv` unless marked admin.

**GUARD 8** (`trg_order_items_guard_tenant_ins`, BEFORE INSERT on `order_items`):
the item's product, and the product of the item's variant, must belong to the
same business as the order. A missing order, product or variant also fails
(NULL is tested explicitly, because a comparison with NULL is never true).
Created `FOLLOWS trg_order_items_guard_ins`, so **GUARD 6 reports first**: an
item that is both wrong-tenant and wrong-price is reported as GUARD 6 (E30f).
Inserts are enough: GUARD 6 already stops `product_id` and `product_variant_id`
from changing afterwards.

**GUARD 8b** (`trg_orders_guard_business_immutable`, BEFORE UPDATE on `orders`):
`orders.business_id` cannot change, NULL-safe (`NOT (OLD.business_id <=> NEW.business_id)`).
Created `FOLLOWS trg_orders_guards_upd`, so GUARD 3/4 report first. This is why
it was added (deliberate addition, approved after the probes): see E31b below.

**Before GUARD 8** (`results/10_e30_before_guard_8.txt`; every block rolled back,
and a final admin block proves the rollback: `seed-order-002` is business 1,
customer 2, outlet 1 again, items and payment untouched):

| ID | Probe | Result |
|---|---|---|
| E30b | business-1 order, business-2 product 7 at its own price | **accepted** (order business 1, product's business 2) |
| E30c | business-1 order, business-2 variant 9 only | **accepted** |
| E30d | business-1 order, product 7 and variant 9 | **accepted** |
| E30e | business-2 order, business-1 product 1 | **accepted** (the gap runs both ways) |
| E31a | change only `business_id` 1 -> 2 | `ERROR 1644`: GUARD 4: orders.customer_id does not belong to orders.business_id |
| E31b | change `business_id`, customer and outlet together (2, 4, 3) | **accepted**: the order became business 2 while its payment was still business 1 (`[1]`) and its items still business-1 products (`[2, 3]`) |
| E32 | append another order's item (same id) to a business-2 order | `ERROR 1062`: Duplicate entry '4' for key 'order_items.PRIMARY'. **This tested a duplicate-id insert, not a move.** It shows the document route does not re-parent a row; it says nothing about a direct change of `order_items.order_id`. Whether to lock `order_id` is **undecided, not ruled out** (probe E33). |

(Verdict SURPRISE on E32 in the file means only that its expectation line,
written as "OK", did not hold: the append was rejected. The line is left as
written. The probe was designed as an attempt to move an item, but what it
actually exercises is inserting a row whose primary key already exists.)

**After GUARD 8** (`results/11_e30_guard_8.txt`, same probes):

| ID | Test | Result |
|---|---|---|
| E30a | business-1 order, business-1 product 1 + variant 2 | OK |
| E30a2 | business-2 order, business-2 product 7 + variant 9 | OK |
| E30b | cross-tenant product | `ERROR 1644`: GUARD 8: order_items.product_id does not belong to the business of the order |
| E30c | cross-tenant variant only | `ERROR 1644`: GUARD 8: order_items.product_variant_id does not belong to the business of the order |
| E30d | cross-tenant product and variant | `ERROR 1644`: GUARD 8 (product_id) |
| E30e | business-2 order, business-1 product | `ERROR 1644`: GUARD 8 (product_id) |
| E30f | wrong tenant and wrong price (product 7 at 100.00) | `ERROR 1644`: **GUARD 6**: order_items.price does not match the current catalog price (GUARD 6 fires first) |
| E31a | change only `business_id` | `ERROR 1644`: GUARD 4 (fires before 8b) |
| E31b | `business_id` + customer + outlet together | `ERROR 1644`: GUARD 8: orders.business_id is immutable once inserted |
| E31c | same, admin, direct `UPDATE orders` | `ERROR 1644`: same GUARD 8 message |
| E31d | ordinary change (status) to a seed order | OK -- 8b does not block normal updates |
| E32 | append another order's item to a business-2 order | `ERROR 1644`: GUARD 8: order_items.product_id does not belong to the business of the order -- **SURPRISE vs the 1062 I expected**: the item is a business-1 product in a business-2 order, so GUARD 8's insert trigger now fires before the primary-key collision. Still a duplicate-id insert being rejected; a move was never tested here. |

Seed check (end of `sql/09_guard_8.sql`): 9 items checked, 0 with a product or
variant from another business, `PASS`. Final agent run
(`results/agent_scenarios.txt`) step G7: the other business's product at its
own correct price -> `ERROR 1644`: GUARD 8.

**Probe bug, for the record.** The first version of E32 failed with
`ERROR 6485: Path '$.items[2]' is not of type 'Json_object'` because a user
variable holds text, not JSON, so it must be cast (`CAST(@item AS JSON)`)
before JSON functions use it. Same family as E23, but caused by the probe, not
by MySQL.

**Regression after GUARD 8** (one reset, then in order): `03` (H01-H07) exit 0;
`04` all 25 PASS (E10 still `ERROR 6491` with the view's own message);
`05` all 6 PASS; `07` (E28) all 17 PASS; `08` (E29) all 3 PASS; `11` 12 of 13
PASS (the one SURPRISE is E32 above); the scripted agent scenarios, S1-S10 and
G1-G7, behave as expected. Results: `results/03_dml_demos.txt`,
`results/04_edge_cases.txt`, `results/05_scenario.txt`,
`results/07_e28_item_price_guard.txt`, `results/08_e29_payment_business_guard.txt`,
`results/11_e30_guard_8.txt`, `results/agent_scenarios.txt`.