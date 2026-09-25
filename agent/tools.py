# agent/tools.py -- the small set of tools the billing agent (Claude) may
# call, each a thin wrapper that runs one parameterized SQL statement against
# a JSON Duality View and returns MySQL's answer (document or error) as-is.
#
# Why it is thin: every data rule lives in the database -- the duality
# views decide what may be read or written, and constraints, foreign keys
# and triggers in sql/01_schema.sql decide what is valid. Python does not
# validate, compute totals, or reshape documents; if MySQL rejects a write,
# the tool returns MySQL's error text to the model so it can correct itself.
#
# Planned tools (Phase 4): search_catalog, get_customer, get_order,
# create_order, add_payment, update_order_status.
#
# Conventions for every tool:
# - Reads filter by business_id with a WHERE clause -- the one rule kept
#   here, because duality views have no row-level security (see
#   docs/when-to-use.md). Write-side tenant checks are guard #4 in SQL.
# - SQL only against order_dv / payment_dv / catalog_dv / customer_dv, never
#   a base table (the agent user has no base-table grants anyway).
# - The model's JSON is passed as a bound parameter, never spliced into SQL.
# - Updates send back the etag from the latest read; on a stale-etag error,
#   re-read once and retry once, then return the fresh document.
# - Each create-order / add-payment intent carries one request_id, reused on
#   retries, so the UNIQUE constraint in the database blocks duplicates.

raise NotImplementedError("agent/tools.py is implemented in Phase 4")
