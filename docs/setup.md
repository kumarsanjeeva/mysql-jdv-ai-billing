# Setup

_Planned._

Will contain full setup steps for Windows PowerShell and Linux/macOS: creating
the MySQL admin connection, filling `.env`, running `scripts/reset_db.py`, and
troubleshooting (MySQL version below 9.7, authentication plugin mismatches,
`mysql` client not on PATH).

Note: if you re-apply the guard triggers without a full reset, run `sql/06_guards_6_7.sql` and then `sql/09_guard_8.sql`, together and in that order. Re-running 06 alone makes the GUARD 6 item trigger fire after GUARD 8 (`sql/14_trigger_order_evidence.sql`).
