# When to use JSON Duality Views

_Written in Phase 5, from `docs/findings.md`._

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
