# reset_db.py -- rebuilds the demo database from nothing by running, in
# order: sql/reset_drop_database.sql, sql/00_setup.sql, sql/01_schema.sql,
# sql/02_duality_views.sql, sql/06_guards_6_7.sql. Stops at the first file
# that fails.
#
# Why it exists: every demo and edge-case run should start from the same
# known state. All the actual work (dropping, creating, seeding, granting)
# is in those .sql files; this script only runs them in sequence through
# run_sql.py.
#
# Usage:
#     python scripts/reset_db.py

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_sql import ROOT, load_env, run_single_file  # noqa: E402

REBUILD_FILES = [
    ROOT / "sql" / "reset_drop_database.sql",
    ROOT / "sql" / "00_setup.sql",
    ROOT / "sql" / "01_schema.sql",
    ROOT / "sql" / "02_duality_views.sql",
    ROOT / "sql" / "06_guards_6_7.sql",
]


def main() -> int:
    """Run the rebuild files in order, stopping at the first one that errors."""
    env = load_env()
    for sql_path in REBUILD_FILES:
        print(f"\nRunning {sql_path.relative_to(ROOT)} ...")
        rc = run_single_file(sql_path, env, as_agent=False)
        if rc != 0:
            print(f"\nStopped: {sql_path} failed. Fix the error above and re-run.", file=sys.stderr)
            return rc
    print("\nDatabase rebuilt (drop -> 00_setup -> 01_schema -> 02_duality_views -> 06_guards_6_7).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
