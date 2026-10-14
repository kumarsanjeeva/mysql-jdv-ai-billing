# agent/db.py -- the billing agent's one database connection.
#
# It connects only as AGENT_DB_USER, the least-privilege account that has
# grants on the duality views and none on the base tables. There is no admin
# fallback: if the agent is refused something, widening its grants is not the
# fix (that would defeat the point of the demo). Connection details come from
# .env; the password is read from there and never printed or logged.

import os

import mysql.connector
from dotenv import load_dotenv

load_dotenv()

_conn = None


def connection():
    """Open (once) and return the agent user's database connection."""
    global _conn
    if _conn is None or not _conn.is_connected():
        _conn = mysql.connector.connect(
            host=os.environ["MYSQL_HOST"], port=int(os.environ["MYSQL_PORT"]),
            user=os.environ["AGENT_DB_USER"], password=os.environ["AGENT_DB_PASSWORD"],
            database=os.environ["MYSQL_DB"], autocommit=True)
    return _conn


def run(sql, params, fetch=True):
    """Run one statement; return the first column of the first row, or the rows affected."""
    cur = connection().cursor()
    try:
        cur.execute(sql, params)
        if fetch:
            row = cur.fetchone()
            return row[0] if row else None
        return cur.rowcount
    finally:
        cur.close()
