# mysql-jdv-ai-billing

An AI billing agent that writes to normalized MySQL tables through JSON
Duality Views (JDV), and never touches a table directly.

## Why this exists

AI agents are good at reasoning over documents and bad at reasoning over
foreign keys. Relational schemas are good at integrity and bad at handing an
LLM a single, coherent object to read or write. MySQL's JSON Duality Views
close that gap: the same data is simultaneously a normalized relational
schema and a set of JSON documents, kept consistent by the database, not by
application code. This repo builds a small, realistic bakery billing system
on that idea and puts an AI agent behind it — using JDV as the *only*
interface the agent is allowed to use, so the views double as the agent's
permission boundary as well as its data shape.

## Architecture at a glance

See [`docs/architecture.md`](docs/architecture.md) for the full set of
diagrams (component overview, write path, concurrency, trust boundaries, read
path). Summary: a Claude-based agent calls a small set of Python tools, which
talk to MySQL exclusively as a least-privilege user with grants on the
duality views only — never on the base tables. Counter staff / POS and
reporting queries continue to use the base tables directly, as before.

## What the demo proves

_(Populated in Phase 3/5 from real, captured test runs — see
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
results/        captured real command output — the evidence behind every claim in docs/
docs/           architecture, schema, duality-view reference, findings, guidance
```

## The duality views

_(Table populated in Phase 5, from [`docs/duality-views.md`](docs/duality-views.md)
once the views are designed, approved, and built.)_

| View | Root | Nested | Annotations | Purpose |
|------|------|--------|-------------|---------|
| _TBD_ | | | | |

## Sample: one order document

_(A real document from `results/`, added after Phase 3.)_

## When to use / not use JDV

Short version: JDV shines when an AI agent (or any client) needs a single,
consistent read/write document backed by normalized tables with real
integrity guarantees. It's a worse fit for bulk loads, set-based updates, and
ad hoc reporting, where plain SQL against the base tables remains the right
tool. See [`docs/when-to-use.md`](docs/when-to-use.md) for the full,
findings-based guidance.

## Requirements

- MySQL 9.7+ (JSON Duality Views support)
- Python 3.11+
- An Anthropic API key — optional; only needed for `agent.agent`, not for
  `agent.scenarios` or the SQL demos

## Documentation index

- [`docs/architecture.md`](docs/architecture.md) — diagrams
- [`docs/schema.md`](docs/schema.md) — ER diagram + table reference
- [`docs/duality-views.md`](docs/duality-views.md) — each view, annotated
- [`docs/findings.md`](docs/findings.md) — every test, expected vs. actual
- [`docs/when-to-use.md`](docs/when-to-use.md) — JDV vs. alternatives
- [`docs/porting-notes.md`](docs/porting-notes.md) — PostgreSQL -> MySQL decisions
- [`docs/setup.md`](docs/setup.md) — full setup, Windows + Linux
- [`docs/blog-outline.md`](docs/blog-outline.md) — blog section plan

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
