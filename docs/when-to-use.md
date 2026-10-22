# When to use JSON Duality Views

Will cover: JDV vs. JSON columns vs. hand-built `JSON_OBJECT`/`JSON_ARRAYAGG`
vs. an ORM (comparison table across integrity, write path, concurrency,
flexibility, portability); use-when / avoid-when guidance (bulk loads,
reporting, set-based updates, EXPLAIN needs); and operational notes for DBAs.

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
