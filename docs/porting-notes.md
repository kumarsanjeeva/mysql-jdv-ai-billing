# Porting notes

Generic PostgreSQL -> MySQL porting decisions (type mapping, what didn't port
and why, tenant isolation without RLS).

## Primary keys: `BIGINT UNSIGNED AUTO_INCREMENT`, not UUIDs

Random `CHAR(36)` UUID keys were not used here; this repo uses
`BIGINT UNSIGNED AUTO_INCREMENT` keys. MySQL JSON
Duality Views have an all-or-nothing rule for `AUTO_INCREMENT` key columns (a nested
document either supplies every generated-key value itself, or lets the
database generate all of them — no mixing within one write). That rule is
exercised in this repo (E16–E18).

Decision: use `BIGINT UNSIGNED AUTO_INCREMENT` for every primary key,
and lean into the AUTO_INCREMENT rule as something to document empirically
(see `docs/findings.md` E16–E18) rather than design around. Two reasons:

1. **InnoDB clustered-index behavior (not verified here: no script in this repo measures page splits, cache locality or index size; this is general background, not a finding).** InnoDB physically orders a table's
   rows by its primary key (the primary key *is* the clustered index every
   secondary index points back into). A monotonically increasing key means
   new rows always append at the end of the index — sequential, cache-warm
   inserts, no page splits. A random key (a UUIDv4 CHAR(36)) scatters inserts
   across the whole B+tree, causing page splits and poor cache locality, and
   — because the primary key value is duplicated into every secondary index
   — a wide random key bloats every secondary index on the table too, not
   just the clustered one. That is a real cost for a MySQL/InnoDB-only
   demo, so this repo uses AUTO_INCREMENT integer keys instead of random
   ones.
2. **The all-or-nothing AUTO_INCREMENT rule is genuinely interesting JDV
   behavior**, and this repo uses integer AUTO_INCREMENT keys, so the rule
   applies here and is documented with real tests for the blog post.

Net effect: entity IDs in JSON documents are small integers, not UUID
strings — still perfectly readable by a human or an LLM.

## Idempotency key: `orders.request_id`

Server-generated primary keys give a retry no client-chosen id to rely on: with a
client-chosen UUID PK, retrying a failed "create order" call would be naturally safe (an upsert
on the same client-chosen id either inserts once or no-ops). With a
server-generated PK, a naive retry after a dropped response would create a
second order. `orders.request_id VARCHAR(64) NOT NULL UNIQUE` provides that
property explicitly: the agent generates one id per logical "create this
order" intent (not per HTTP/DB attempt) and sends it every time it retries.
A second insert attempt with the same `request_id` must fail on the unique
constraint, not silently produce a duplicate order — verified in `docs/findings.md` (E15).

## RLS: not ported

This repo uses no row-level security from MySQL itself (MySQL's own position on
row-level security was not tested here). `business_id` stays on every relevant table
(as in the existing application), and two boundaries replace RLS:
- `AGENT_DB_USER` has grants on the JSON Duality Views only, never on base
  tables (a privilege-level boundary — verified empirically, see E12/E13).
- Tenant/business scoping is enforced in `agent/tools.py` (a code-level
  boundary — no session-identity function was used here).

A real gap this leaves: foreign keys alone do not enforce that
`orders.customer_id`/`orders.outlet_id` belong to the same `business_id` as
the order. With no row-level security in this repo, that
gap is closed with a database guard instead: a trigger on `orders` (see the
GUARDS section of `sql/01_schema.sql`) that validates the referenced customer
and outlet both belong to the order's own `business_id`, rejecting the write
otherwise. This is the guard directly compensating for the lost RLS
protection, not a general-purpose integrity nicety.
