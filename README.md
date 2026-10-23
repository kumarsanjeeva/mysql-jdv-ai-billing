# mysql-jdv-ai-billing

An AI billing agent that writes to normalized MySQL tables through JSON
Duality Views (JDV), and never touches a table directly.

## Why this exists

AI agents are good at reasoning over documents and bad at reasoning over
foreign keys. Relational schemas are good at integrity and bad at handing an
LLM a single, coherent object to read or write. MySQL's JSON Duality Views
close that gap: the same data is simultaneously a normalized relational
schema and a set of JSON documents, backed by the same tables. Some rules
are enforced by database triggers; docs/findings.md lists what is tested and
what is not enforced. This repo builds a small, realistic bakery billing system
on that idea and puts an AI agent behind it — using JDV as the *only*
interface the agent is allowed to use, so the views double as the agent's
permission boundary as well as its data shape.

## Architecture at a glance

See [`docs/architecture.md`](docs/architecture.md) for the full set of
diagrams (component overview, write path, concurrency, trust boundaries, read
path). Summary: an LLM agent (the live runs captured in results/ used
Gemini models; no live Claude run is captured) calls a small set of Python
tools, which
talk to MySQL exclusively as a least-privilege user with grants on the
duality views only — never on the base tables. Counter staff / POS and
reporting queries continue to use the base tables directly, as before.

## What the demo proves

_(Planned: populated from real, captured test runs — see
[`docs/findings.md`](docs/findings.md) once written.)_

## Quick start

| Windows (PowerShell)                          | Linux / macOS                                 |
|------------------------------------------------|------------------------------------------------|
| `git clone <repo-url>`                          | `git clone <repo-url>`                          |
| `cd mysql-jdv-ai-billing`                       | `cd mysql-jdv-ai-billing`                       |
| `python -m venv .venv`                          | `python3 -m venv .venv`                         |
| `.venv\Scripts\Activate.ps1`                    | `source .venv/bin/activate`                     |
| `pip install -r requirements.txt`               | `pip install -r requirements.txt`               |
| `copy .env.example .env` (then fill it in)      | `cp .env.example .env` (then fill it in)        |
| `python scripts\reset_db.py`                    | `python scripts/reset_db.py`                    |
| `python -m agent.scenarios`                     | `python -m agent.scenarios`                     |
| `python -m agent.agent`                         | `python -m agent.agent`                         |

`agent.scenarios` runs a scripted demo without an Anthropic API key.
`agent.agent` is the interactive loop and requires `ANTHROPIC_API_KEY`.

## Repository layout

```
sql/            DDL, duality views, and DML demo/edge-case scripts (numbered, run in order)
scripts/        run_sql.py (execute a .sql file, capture output), reset_db.py
agent/          Python billing agent: db.py, tools.py, agent.py, scenarios.py
results/        captured real command output — the captured output that the claims in docs/ cite by file name
docs/           architecture, schema, duality-view reference, findings, guidance
```

## The duality views

Each view's `CREATE` statement, sample document, nested tables and tests are
in [`docs/duality-views.md`](docs/duality-views.md).

| View | Root | Nested | Annotations | Purpose |
|------|------|--------|-------------|---------|
| `order_dv` | `orders` | `order_items` (`items`), `payments`; singletons `products`, `customers`, `outlets` | `WITH(INSERT, UPDATE)` on the root and both arrays; no `DELETE` | read, create and update orders |
| `payment_dv` | `payments` | `orders` (singleton `order`) | `WITH(INSERT)` | add a payment to an existing order |
| `catalog_dv` | `products` | `product_variants` (`variants`) | none (read-only) | search the catalog |
| `customer_dv` | `customers` | `orders` (`orders`) | none (read-only) | look up a customer and order history |

## Sample: one order document

_(Planned: a real document from `results/`.)_

## When to use / not use JDV

Short version: JDV shines when an AI agent (or any client) needs a single,
consistent read/write document backed by normalized tables with database-side
guard triggers for some rules (docs/findings.md lists what is tested and what
is not enforced). It's a worse fit for bulk loads, set-based updates, and
ad hoc reporting, where plain SQL against the base tables remains the right
tool. See [`docs/when-to-use.md`](docs/when-to-use.md) for the full,
findings-based guidance.

## Requirements

- MySQL 9.7+ (JSON Duality Views support)
- Python 3.11+
- An LLM API key, only for `agent.agent` and the live runs (not for
  `agent.scenarios` or the SQL demos). Set `AGENT_PROVIDER`, `AGENT_MODEL`
  and `AGENT_PROMPT_VERSION`, and the provider's key in `.env`:
  `GEMINI_API_KEY` for `gemini` (the provider used in the captured live runs)

## Documentation index

- [`docs/architecture.md`](docs/architecture.md) — component, trust-boundary, schema, write/read, and concurrency diagrams
- [`docs/schema.md`](docs/schema.md) — table reference from `sql/01_schema.sql`: columns, keys, checks, triggers (the ER diagram is in `docs/architecture.md`)
- [`docs/duality-views.md`](docs/duality-views.md) — each view: `CREATE` statement, sample document, nested tables, tests; plus the payments rule
- [`docs/findings.md`](docs/findings.md) — every test, expected vs. actual
- [`docs/when-to-use.md`](docs/when-to-use.md) — JDV vs. alternatives
- [`docs/porting-notes.md`](docs/porting-notes.md) — PostgreSQL -> MySQL decisions
- [`docs/setup.md`](docs/setup.md) — full setup, Windows + Linux (planned; stub only)
- [`docs/blog-outline.md`](docs/blog-outline.md) — blog section plan (planned; stub only)

## References

- [Creating JSON Duality Views](https://dev.mysql.com/doc/refman/9.7/en/json-duality-views-syntax.html)
- [DML on JSON Duality Views](https://dev.mysql.com/doc/refman/9.7/en/json-duality-views-updatable.html)
- [Requirements and annotations](https://dev.mysql.com/doc/refman/9.7/en/jdv-requirements.html)
- [DML limitations](https://dev.mysql.com/doc/refman/9.7/en/jdv-limitations.html)
- [Concurrency](https://dev.mysql.com/doc/refman/9.7/en/jdv-concurrency.html)
- [Defining JSON Duality Views in MySQL](https://blogs.oracle.com/mysql/defining-json-duality-views-in-mysql)
- [Two Models, One World](https://blogs.oracle.com/mysql/two-models-one-world-introducing-json-relational-duality-views-in-mysql-heatwave)
- [No More JSON Plumbing](https://blogs.oracle.com/mysql/no-more-json-plumbing)

## License

MIT — see [`LICENSE`](LICENSE).

Author: Sanjeeva Kumar, Oracle ACE Associate, [dbadataverse.com](https://dbadataverse.com)
