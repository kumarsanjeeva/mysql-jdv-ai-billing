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

## Known limitation: order items are not checked for tenant

Write-side tenant checks cover an order's customer and outlet (guard #4) and a
payment's `business_id` (guard #7), but not the order's items: nothing
verifies that an item's product or variant belongs to the same business as the
order. Guard #6 checks the item's price against the catalog and that a variant
belongs to its product, which does not close this. A business-1 order can
carry a business-2 product whose price matches its own catalog entry. A
guard #8 using the same pattern as guard #4 would close it; it is not in this
round. See the last section of `docs/findings.md`.
