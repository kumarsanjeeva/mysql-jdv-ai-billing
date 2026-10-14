# agent/tools.py -- the six tools the billing assistant (Claude) can call.
#
# Each tool runs ONE parameterized SQL statement against a JSON Duality View
# and hands MySQL's answer back unchanged -- the document it read, or the
# exact MySQL error. Python does not check, compute or reshape anything:
# the views, constraints and triggers in sql/ are the rules.
#
# Every statement is limited to one business: reads filter on business_id
# in their WHERE clause, and writes set business_id in SQL. Duality views
# have no row-level security, so this WHERE clause is the read-side tenant
# boundary (docs/when-to-use.md); writes are also checked by GUARD 4.
#
# The connection uses only the least-privilege agent account, which can
# reach the four views and no table.

import json
import os

import mysql.connector
from dotenv import load_dotenv

from agent.db import run

load_dotenv()
BUSINESS_ID = int(os.environ.get("AGENT_BUSINESS_ID", "1"))
ETAG_MISMATCH = 6494  # ER_JDV_ETAG_MISMATCH


def rows_written(n):
    """Say how many rows a write touched: '1 row written' or '4 rows written'."""
    return f"{n} row written" if n == 1 else f"{n} rows written"


def search_catalog(query):
    """Find products (with variants and prices) whose name contains the query text."""
    return run("SELECT JSON_ARRAYAGG(data) FROM catalog_dv"
               " WHERE JSON_VALUE(data, '$.business_id') = %s AND LOCATE(LOWER(%s), LOWER(JSON_VALUE(data, '$.name'))) > 0",
               (BUSINESS_ID, query)) or "[]"


def get_customer(phone):
    """Find a customer (with their order history) by phone number."""
    return run("SELECT data FROM customer_dv"
               " WHERE JSON_VALUE(data, '$.business_id') = %s AND JSON_VALUE(data, '$.phone') = %s",
               (BUSINESS_ID, phone)) or "No customer with that phone number."


def get_order(order_id=None, request_id=None):
    """Read one order document by id or request_id, with balance_due computed in SQL."""
    return run("SELECT JSON_SET(d.data, '$.balance_due',"
               "       JSON_VALUE(d.data, '$.total' RETURNING DECIMAL(10,2)) - COALESCE(SUM(p.amount), 0))"
               "  FROM order_dv d"
               "  LEFT JOIN JSON_TABLE(d.data, '$.payments[*]' COLUMNS (amount DECIMAL(10,2) PATH '$.amount')) p ON TRUE"
               " WHERE JSON_VALUE(d.data, '$.business_id') = %s"
               "   AND (JSON_VALUE(d.data, '$._id') = %s OR JSON_VALUE(d.data, '$.request_id') = %s)"
               " GROUP BY d.data",
               (BUSINESS_ID, order_id, request_id)) or "No such order."


def create_order(order):
    """Insert a new order document (items, optional advance payment) through order_dv."""
    rows = run("INSERT INTO order_dv VALUES (JSON_SET(%s, '$.business_id', %s))",
               (json.dumps(order), BUSINESS_ID), fetch=False)
    return f"Created: {rows_written(rows)}. Read it back with get_order(request_id={order.get('request_id')!r})."


def add_payment(order_id, payment):
    """Insert one payment for an existing order through payment_dv."""
    rows = run("INSERT INTO payment_dv VALUES (JSON_SET(%s, '$.business_id', %s, '$.order', JSON_OBJECT('id', %s)))",
               (json.dumps(payment), BUSINESS_ID, order_id), fetch=False)
    return f"Payment recorded: {rows_written(rows)}."


def update_order_status(order_id, status, etag):
    """Set an order's status, sending the etag last read; on a stale etag re-read it and retry once."""
    sql = ("UPDATE order_dv SET data = JSON_SET(data, '$.order_status', %s, '$._metadata.etag', %s)"
           " WHERE JSON_VALUE(data, '$._id') = %s AND JSON_VALUE(data, '$.business_id') = %s")
    try:
        rows = run(sql, (status, etag, order_id, BUSINESS_ID), fetch=False)
        return f"Status set to {status} ({rows_written(rows)})."
    except mysql.connector.Error as e:
        if e.errno != ETAG_MISMATCH:
            raise
        fresh = run("SELECT JSON_VALUE(data, '$._metadata.etag') FROM order_dv"
                    " WHERE JSON_VALUE(data, '$._id') = %s AND JSON_VALUE(data, '$.business_id') = %s",
                    (order_id, BUSINESS_ID))
        rows = run(sql, (status, fresh, order_id, BUSINESS_ID), fetch=False)
        return (f"The order had changed since you read it (MySQL error {e.errno}: {e.msg}). "
                f"Re-read it and retried once: status set to {status} ({rows_written(rows)}).")


def call(name, args):
    """Run the named tool; return (text, is_error), with any MySQL error passed back unchanged."""
    try:
        return str(TOOLS[name](**args)), False
    except mysql.connector.Error as e:
        return f"MySQL error {e.errno}: {e.msg}", True


TOOLS = {f.__name__: f for f in
         (search_catalog, get_customer, get_order, create_order, add_payment, update_order_status)}

ORDER_SCHEMA_NOTE = (
    "Order document fields: request_id (new unique id you generate), order_status ('draft'|'confirmed'), "
    "delivery_at ('YYYY-MM-DD HH:MM:SS'), subtotal, discount_type ('amount'), discount_value, gst_value, total, "
    "outlet {id}, customer {id}, items [{name, flavor, size, unit, qty, price, gst_rate, is_gst_inclusive, "
    "gst_applicable, discount_exempt, gst_value, discount_value, product {id}, product_variant_id (omit if none)}], "
    "optional payments [{business_id, request_id, payment_type ('advance'), method ('cash'|'upi'|'card'|'other'), amount}]. "
    "Prices and gst_rate come from search_catalog. total must equal subtotal - discount_value + gst_value.")

SCHEMAS = [
    {"name": "search_catalog", "description": "Search the bakery catalog by product name. Returns products with price, gst_rate and variants.",
     "input_schema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}},
    {"name": "get_customer", "description": "Look up a customer by phone number. Returns their id and order history.",
     "input_schema": {"type": "object", "properties": {"phone": {"type": "string"}}, "required": ["phone"]}},
    {"name": "get_order", "description": "Read one order by order_id or request_id. Includes items, payments, _metadata.etag and balance_due.",
     "input_schema": {"type": "object", "properties": {"order_id": {"type": "integer"}, "request_id": {"type": "string"}}}},
    {"name": "create_order", "description": "Create a new order. " + ORDER_SCHEMA_NOTE,
     "input_schema": {"type": "object", "properties": {"order": {"type": "object"}}, "required": ["order"]}},
    {"name": "add_payment", "description": "Record a payment on an existing order. payment: {request_id (new unique id you generate), "
                                           "payment_type ('advance'|'installment'|'final'|'refund'), method ('cash'|'upi'|'card'|'other'), amount}.",
     "input_schema": {"type": "object", "properties": {"order_id": {"type": "integer"}, "payment": {"type": "object"}},
                      "required": ["order_id", "payment"]}},
    {"name": "update_order_status", "description": "Change an order's status ('draft'|'confirmed'|'ready'|'delivered'|'cancelled'). "
                                                   "Pass the etag from your latest get_order.",
     "input_schema": {"type": "object", "properties": {"order_id": {"type": "integer"}, "status": {"type": "string"},
                                                       "etag": {"type": "string"}}, "required": ["order_id", "status", "etag"]}},
]
