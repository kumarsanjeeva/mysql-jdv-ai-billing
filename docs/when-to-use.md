# When to use JSON Duality Views

_Planned, from `docs/findings.md`._

Will cover: JDV vs. JSON columns vs. hand-built `JSON_OBJECT`/`JSON_ARRAYAGG`
vs. an ORM (comparison table across integrity, write path, concurrency,
flexibility, portability); use-when / avoid-when guidance (bulk loads,
reporting, set-based updates, EXPLAIN needs); operational notes for DBAs; and
a short, generic PostgreSQL-comparison note (no native JDV equivalent — the
pattern can be emulated with a jsonb view + write function + version column,
at higher code cost).

## Known limitation: no row-level security on reads

JSON Duality Views have no row-level security, and neither does MySQL. A
grant on a duality view is all-or-nothing: an account that can `SELECT` from
`order_dv` can read every business's orders. In this demo:

- **Writes** are tenant-consistent in SQL: guard #4 in `sql/01_schema.sql`
  rejects an order whose customer or outlet belongs to a different business.
- **Reads** are filtered by `business_id` in the agent's own query
  (`agent/tools.py`, a `WHERE` clause). This is application code, not a
  database guarantee. A bug there, or another client using the same
  account, can read across businesses.

## Write-side tenant checks, and what they needed

Because there is no row-level security, every place a row can name another
business has to be closed by a trigger. In this demo that took four pieces,
each found by testing rather than assumed:

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

Still open: an administrator can change `products.business_id` directly (no
view allows it), which would leave existing items pointing at another business.
Reads are covered by the section above.
