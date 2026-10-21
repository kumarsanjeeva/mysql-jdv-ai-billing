# Setup

_Planned._

Will contain full setup steps for Windows PowerShell and Linux/macOS: creating
the MySQL admin connection, filling `.env`, running `scripts/reset_db.py`, and
troubleshooting (MySQL version below 9.7, authentication plugin mismatches,
`mysql` client not on PATH).

## Database users

Two accounts are used. Replace every `<...>` value yourself; never commit real passwords.
Run this once as a MySQL account that may create users (for example `root`), before `sql/00_setup.sql`.

The admin account is the one `scripts/run_sql.py` connects as (`MYSQL_USER` in `.env`). No file in this
repo creates it; its grants below are those shown by `SHOW GRANTS` in `results/48_show_admin_grants.txt`.

```sql
CREATE USER IF NOT EXISTS 'jdv_admin'@'localhost' IDENTIFIED BY '<ADMIN_PASSWORD_PLACEHOLDER>';
GRANT CREATE USER ON *.* TO 'jdv_admin'@'localhost';
-- ALL on the demo database, with grant option: sql/02 uses it to grant on the views to the agent account.
GRANT ALL PRIVILEGES ON `jdv_ai_billing`.* TO 'jdv_admin'@'localhost' WITH GRANT OPTION;
-- Scratch database for the repro_* scripts.
GRANT ALL PRIVILEGES ON `jdv_repro_scratch`.* TO 'jdv_admin'@'localhost';
```

The agent account (`AGENT_DB_USER` in `.env`) is created by `sql/00_setup.sql`, so it is not created here:

```sql
CREATE USER '<AGENT_DB_USER>'@'%' IDENTIFIED BY '<AGENT_PASSWORD_PLACEHOLDER>';
```

`sql/02_duality_views.sql` then grants it access to the views only, with no grant on any base table:

```sql
GRANT SELECT, INSERT, UPDATE ON jdv_ai_billing.order_dv    TO '<AGENT_DB_USER>'@'%';
GRANT SELECT, INSERT         ON jdv_ai_billing.payment_dv  TO '<AGENT_DB_USER>'@'%';
GRANT SELECT                 ON jdv_ai_billing.catalog_dv  TO '<AGENT_DB_USER>'@'%';
GRANT SELECT                 ON jdv_ai_billing.customer_dv TO '<AGENT_DB_USER>'@'%';
```

No roles exist in `sql/`.

Note: if you re-apply the guard triggers without a full reset, run `sql/06_guards_6_7.sql` and then `sql/09_guard_8.sql`, together and in that order. Re-running 06 alone makes the GUARD 6 item trigger fire after GUARD 8 (`sql/14_trigger_order_evidence.sql`).
