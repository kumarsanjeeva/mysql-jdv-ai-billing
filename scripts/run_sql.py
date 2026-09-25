# run_sql.py -- runs one .sql file through the mysql command-line client and
# saves exactly what MySQL printed to results/<file name>.txt, so every claim
# in docs/ can point at real output. It is a thin launcher: all data logic
# lives in the .sql files themselves; this script only fills in names from
# .env, hands the text to mysql, and records the result.
#
# Why it exists: the password must never appear on a command line, so it
# writes a temporary mysql option file, uses it, and always deletes it.
#
# Usage:
#     python scripts/run_sql.py sql/02_duality_views.sql
#     python scripts/run_sql.py sql/04_edge_cases.sql --as agent
#
# Two modes:
#   - Normal file: sent as one mysql session; stops at the first SQL error.
#   - Test file (contains `-- TEST: <id> <description>` lines): each test
#     block runs in its own mysql session so one failure never hides the
#     rest. A block may say `-- EXPECT: OK`, `-- EXPECT: ERROR` (any error)
#     or `-- EXPECT: ERROR 1644` (that exact code); default is OK. It may say
#     `-- AS: agent` (run as the least-privilege agent user). Each block is
#     marked PASS if the outcome matched EXPECT, SURPRISE if not -- a
#     SURPRISE is a finding to write up in docs/findings.md, never something
#     to hide by editing EXPECT.
#
# Placeholders __MYSQL_DB__, __AGENT_DB_USER__, __AGENT_DB_PASSWORD__ in the
# SQL are replaced from .env, so no real credential is ever committed.

import argparse
import datetime
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = ROOT / "results"

REQUIRED_KEYS = [
    "MYSQL_HOST", "MYSQL_PORT", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DB",
    "AGENT_DB_USER", "AGENT_DB_PASSWORD",
]

PLACEHOLDERS = {
    "__MYSQL_DB__": "MYSQL_DB",
    "__AGENT_DB_USER__": "AGENT_DB_USER",
    "__AGENT_DB_PASSWORD__": "AGENT_DB_PASSWORD",
}

TEST_RE = re.compile(r"^--\s*TEST:\s*(\S+)\s*(.*)$")
EXPECT_RE = re.compile(r"^--\s*EXPECT:\s*(ERROR|OK)(?:\s+(\d+))?\s*$", re.IGNORECASE)
ERROR_CODE_RE = re.compile(r"^ERROR (\d+)", re.MULTILINE)
AS_RE = re.compile(r"^--\s*AS:\s*(admin|agent)\s*$", re.IGNORECASE)


def load_env() -> dict:
    """Read connection settings from .env and exit if a required one is missing."""
    load_dotenv(ROOT / ".env")
    env = {k: os.environ.get(k, "") for k in REQUIRED_KEYS}
    # MYSQL_PASSWORD may legitimately be empty for local dev accounts.
    missing = [k for k in REQUIRED_KEYS if k != "MYSQL_PASSWORD" and not env[k]]
    if missing:
        print(f"Missing required .env keys: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    return env


def substitute(sql_text: str, env: dict) -> str:
    """Replace the __NAME__ placeholders in the SQL text with values from .env."""
    for placeholder, key in PLACEHOLDERS.items():
        sql_text = sql_text.replace(placeholder, env[key])
    return sql_text


def write_defaults_file(env: dict, user: str, password: str) -> str:
    """Write a temporary mysql option file holding the login, and return its path."""
    fd, path = tempfile.mkstemp(prefix="mysql_defaults_", suffix=".cnf")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("[client]\n")
        f.write(f"host={env['MYSQL_HOST']}\n")
        f.write(f"port={env['MYSQL_PORT']}\n")
        f.write(f"user={user}\n")
        f.write(f"password={password}\n")
    return path


def mysql_invoke(env: dict, sql_text: str, as_agent: bool) -> tuple[int, str, str, str]:
    """Send SQL text to the mysql client as admin or agent; return (exit code, stdout, stderr, user)."""
    user = env["AGENT_DB_USER"] if as_agent else env["MYSQL_USER"]
    password = env["AGENT_DB_PASSWORD"] if as_agent else env["MYSQL_PASSWORD"]
    defaults_path = write_defaults_file(env, user, password)
    try:
        cmd = ["mysql", f"--defaults-extra-file={defaults_path}", "--table", "--show-warnings",
               "--default-character-set=utf8mb4"]
        proc = subprocess.run(cmd, input=sql_text, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
        return proc.returncode, proc.stdout, proc.stderr, user
    finally:
        try:
            os.remove(defaults_path)
        except OSError:
            pass


def header(env: dict, sql_path: Path, user: str) -> str:
    """Build the first lines of a results file: script, time, user, and host."""
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    return (
        f"-- run_sql.py -- {ts}\n"
        f"-- file: {sql_path.relative_to(ROOT) if sql_path.is_relative_to(ROOT) else sql_path.name}\n"
        f"-- connecting user: {user}\n"
        f"-- host: {env['MYSQL_HOST']}:{env['MYSQL_PORT']}  (database chosen by the file's own USE)\n"
        f"{'=' * 70}\n"
    )


def parse_blocks(sql_text: str) -> list[dict]:
    """Split a test file into its `-- TEST:` blocks, reading each block's EXPECT and AS markers."""
    blocks = []
    current = None
    for line in sql_text.splitlines():
        m = TEST_RE.match(line.strip())
        if m:
            if current is not None:
                blocks.append(current)
            current = {"id": m.group(1), "desc": m.group(2).strip(), "expect": None, "as": "admin", "sql": []}
            continue
        if current is None:
            continue
        m = EXPECT_RE.match(line.strip())
        if m:
            current["expect"] = m.group(1).upper() + (f" {m.group(2)}" if m.group(2) else "")
            continue
        m = AS_RE.match(line.strip())
        if m:
            current["as"] = m.group(1).lower()
            continue
        current["sql"].append(line)
    if current is not None:
        blocks.append(current)
    return blocks


def run_edge_case_file(sql_path: Path, env: dict, default_as_agent: bool) -> int:
    """Run each test block separately, print a PASS/SURPRISE table, and save the full transcript."""
    raw = substitute(sql_path.read_text(encoding="utf-8-sig"), env)
    results = []
    transcript = []
    for b in parse_blocks(raw):
        block_sql = "\n".join(b["sql"]).strip()
        as_agent = default_as_agent or (b["as"] == "agent")
        rc, out, err, user = mysql_invoke(env, block_sql, as_agent)
        code = ERROR_CODE_RE.search(err)
        actual = "OK" if rc == 0 else ("ERROR " + code.group(1) if code else "ERROR")
        expect = b["expect"] or "OK"
        # "EXPECT: ERROR" accepts any error; "EXPECT: ERROR 1644" needs that exact code.
        verdict = "PASS" if actual == expect or (expect == "ERROR" and actual.startswith("ERROR")) else "SURPRISE"
        results.append((b["id"], b["desc"], expect, actual, verdict))
        transcript.append(
            f"\n--- {b['id']}: {b['desc']} (as {user}) ---\n"
            f"EXPECT: {expect}  ACTUAL: {actual}  VERDICT: {verdict}\n"
            f"SQL:\n{block_sql}\n"
            f"STDOUT:\n{out}"
            f"STDERR:\n{err}"
        )

    col_id = max(4, max((len(r[0]) for r in results), default=4))
    col_desc = max(11, max((len(r[1]) for r in results), default=11))
    table_lines = [f"{'ID':<{col_id}}  {'DESCRIPTION':<{col_desc}}  {'EXPECT':<10}  {'ACTUAL':<10}  VERDICT"]
    for r in results:
        table_lines.append(f"{r[0]:<{col_id}}  {r[1]:<{col_desc}}  {r[2]:<10}  {r[3]:<10}  {r[4]}")
    table = "\n".join(table_lines)

    print(table)
    surprises = [r for r in results if r[4] == "SURPRISE"]
    if surprises:
        print(f"\n{len(surprises)} SURPRISE(S) -- see results/{sql_path.stem}.txt, review before writing docs/findings.md")

    out_path = RESULTS_DIR / f"{sql_path.stem}.txt"
    RESULTS_DIR.mkdir(exist_ok=True)
    out_path.write_text(header(env, sql_path, "per test, see below") + table + "\n\n" + "\n".join(transcript),
                        encoding="utf-8")
    # Exit 0 means the harness itself ran cleanly; individual SURPRISEs are findings, not harness failures.
    return 0


def run_single_file(sql_path: Path, env: dict, as_agent: bool) -> int:
    """Run a whole file as one mysql session, save its output, and return mysql's exit code."""
    raw = substitute(sql_path.read_text(encoding="utf-8-sig"), env)
    rc, out, err, user = mysql_invoke(env, raw, as_agent)

    out_path = RESULTS_DIR / f"{sql_path.stem}.txt"
    RESULTS_DIR.mkdir(exist_ok=True)
    out_path.write_text(header(env, sql_path, user) + out + err, encoding="utf-8")

    print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)

    if rc != 0:
        print(f"\nSQL error running {sql_path} as {user} (exit {rc}). See {out_path}", file=sys.stderr)
    return rc


def main() -> int:
    """Parse the command line and run the file in normal or test-block mode."""
    parser = argparse.ArgumentParser(description="Run a .sql file and capture its output under results/.")
    parser.add_argument("sql_file", type=Path)
    parser.add_argument("--as", dest="as_user", choices=["admin", "agent"], default="admin")
    args = parser.parse_args()

    sql_path = (args.sql_file if args.sql_file.is_absolute() else ROOT / args.sql_file).resolve()
    if not sql_path.exists():
        print(f"No such file: {sql_path}", file=sys.stderr)
        return 1

    env = load_env()
    as_agent = args.as_user == "agent"

    raw_text = sql_path.read_text(encoding="utf-8-sig")
    if any(TEST_RE.match(line.strip()) for line in raw_text.splitlines()):
        return run_edge_case_file(sql_path, env, as_agent)
    return run_single_file(sql_path, env, as_agent)


if __name__ == "__main__":
    sys.exit(main())
