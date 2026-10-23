# When to use JSON Duality Views

What was tested here, and what is reasoning only. Sections marked "tested"
cite a file in `results/`; sections marked "reasoning, not tested here" do not.
Comparison with a hand-built `JSON_OBJECT`/`JSON_ARRAYAGG` query is tested; JSON
columns and ORMs are not. Operational notes for DBAs are not covered.

## Known limitation: no row-level security on reads

This repo found no row-level security on duality views (not verified against
the manual) and uses none from MySQL itself (MySQL's own position on
row-level security was not tested here). A grant on a duality view is
all-or-nothing: an account that can `SELECT` from `order_dv` can read every
business's orders (`agent/scenarios.py` part 2). In this demo:

- **Writes** are tenant-consistent in SQL: guard #4 in `sql/01_schema.sql`
  rejects an order whose customer or outlet belongs to a different business.
- **Reads** are filtered by `business_id` in the agent's own query
  (`agent/tools.py`, a `WHERE` clause). This is application code, not a
  database guarantee. A bug there, or another client using the same
  account, can read across businesses.

## Write-side tenant checks, and what they needed

Because this repo uses no row-level security, every place a row can name
another business has to be closed by a trigger. In this demo that took five
pieces, each found by testing rather than assumed:

- **guard #4:** an order's customer and outlet belong to the order's business.
- **guard #7:** a payment's `business_id` matches its order's.
- **guard #8:** an item's product and variant belong to the order's business.
  Before it existed, a business-1 order could carry a business-2 product at
  that product's own correct price, and the reverse
  (`results/10_e30_before_guard_8.txt`, E30b-e).
- **guard #8b:** `orders.business_id` cannot change. Without it, changing the
  business together with the customer and outlet slipped past guard #4 and
  left the order's items and payments in the old business (E31b in the same
  file), because #7 and #8 only check inserts.
- **order_id lock (guard #6):** an item's `order_id` cannot change. An admin could
  move a business-1 item into a business-2 order (E33, `results/12_*.txt`);
  now rejected for a direct `UPDATE` on the base table (`results/13_*.txt`).
  A move through `order_dv` was not probed (Known limits 6).

## Known limits

Six things this database does not enforce, or that were not tested: a payment
can push the total paid above the order total; item `gst_value` need not sum
to the order's `gst_value`; `udhaar_settlement` payments may not map to one
order's total; cancelled orders and lowering `orders.total` below the amount
paid are not covered; an administrator can change `products.business_id`
directly on the base table (no script has run that update); and changing an
item's `order_id` through `order_dv` is untested. Each has its evidence, what
a fix would need and why none was built in
[`findings.md`](findings.md#known-limits). Reads are covered by the section
above.

## Duality view vs hand-built JSON in SQL (tested)

Tested on order 77 (`results/47_manual_vs_dv.txt`). One query on the base
tables with `JSON_OBJECT` and `JSON_ARRAYAGG` builds the same document as
`order_dv`.

- Content: identical as JSON once `_metadata` is removed and both sides are
  cast to JSON (step 5 of the file).
- Text: not identical. The hand-built text has `1.00` where the view has
  `1.0`. Compare as JSON, never as text.
- Length: the hand-built query is 37 lines; the view definition is 82 (75
  without blanks and comments). Counted, not timed. No performance claim.
- Only the view returns `_metadata.etag`.
- The hand-built query is read-only. The view also takes `INSERT` and
  `UPDATE` of the document.

The view costs more to write once. It buys the write path, the etag, and a
grant on views instead of tables: the agent has grants on the four views and
none on base tables (`results/04_edge_cases.txt`, grant listing and E13).

Not tested here: a plain SQL view over the hand-built query could carry the
same read grant. It was not tried whether it could take a document back on
`INSERT` or `UPDATE`; it would not return an etag.

## Duality view vs a JSON column (reasoning, not tested here)

Use a JSON column when the document is the record: nothing else reads its
parts, and no rule links it to another row.

Use the view when tables must stay the system of record: other consumers
(POS, reporting) read the rows, and rules such as catalog price (GUARD 6) or
tenant (GUARDs 4, 7, 8) check one row against another. Those guards are table
triggers, so they need tables. Whether the same rules can be written against a
JSON column was not tried.

Cost of the view: tables are designed first, and every document shape is a
view definition you maintain.

## Duality view vs an ORM (reasoning, not tested here)

No ORM was used in this repo. Nothing here compares or measures one.

- Where the work sits: an ORM maps rows to objects in application code, per
  language. With a duality view the mapping and the write rules sit in the
  database; this repo's Python sends plain SQL through `agent/tools.py` with no
  mapping layer.
- Permission: the agent holds grants on four views and none on tables (E13). A
  layer that issues statements against base tables needs grants on those
  tables by construction.
- What the view does not give: migrations, query composition in the
  application language, and portability. The view definitions here are written
  for MySQL 9.7.2 and were not tried on any other database.

## Where the views were the wrong tool

- One document per statement. A multi-row `UPDATE` (E06),
  `INSERT ... SELECT` (E07) and an upsert (E08) were refused with `ERROR 6482`
  as `jdv_agent`, and `EXPLAIN SELECT` as the agent failed with `ERROR 1345`
  (E09b). `EXPLAIN UPDATE` failed with `ERROR 6482` as `jdv_admin` (E09c). The
  manual also lists `LOAD DATA`; it was not tested. See
  [Official limitations](findings.md#official-limitations-not-tested-here).
- Leaving an array element out means delete; `order_dv` refuses it (`ERROR
  6498`, E02/E03).
- Mixing generated and explicit ids in one nested array is `ERROR 6560`
  (E16 and E18 in `results/04_edge_cases.txt`; E24 in `findings.md`).
- A nested read-only singleton that reads back as null cannot be written back
  (E20).
- A JSON-text round trip of `paid_at` forced `UPDATE` on the payments array
  (E23).
- Six rules are not enforced by the database: see Known limits.

E-numbers are in [`findings.md`](findings.md) and `results/04_edge_cases.txt`.