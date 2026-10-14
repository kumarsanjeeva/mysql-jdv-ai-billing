# agent/scenarios.py -- the billing story played through the agent's own tools,
# with no Anthropic API key. A script stands in for the model: it makes the
# same tool calls Claude would (agent/tools.py, i.e. the duality views only)
# and prints every call and MySQL's answer unchanged. Everything is saved to
# results/agent_scenarios.txt as evidence for the docs.
#
# Part 1 -- Priya Sharma orders a cake and pastries with a Rs 500 advance;
#           counter staff confirm the order while the agent holds an older
#           copy (stale etag, retried); the balance is paid.
# Part 2 -- guardrails: things the database refuses (a positive refund, a
#           repeated request_id, a direct read of a base table, an item at a
#           wrong price -- GUARD 6, a payment for another business's order --
#           GUARD 7, an item from another business's product -- GUARD 8).
#
# Each step says what MySQL should answer ("OK" or an error number). If the
# real answer differs, the run stops and says so -- a surprise is a finding
# to record in docs/findings.md, not something to patch over here.
# The only arithmetic here is the order's price/GST sums, which the model
# would do itself; MySQL rejects a total that does not add up.
#
# Usage (after python scripts/reset_db.py):  python -m agent.scenarios

import json
import sys
import uuid
from decimal import Decimal
from pathlib import Path

import mysql.connector

from agent import tools
from agent.db import run

OUT = Path(__file__).resolve().parent.parent / "results" / "agent_scenarios.txt"
PHONE = "9900000001"  # Priya Sharma


def log(text=""):
    """Print a line and append it to the results file."""
    print(text)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(text + "\n")


def check(label, text, is_error, expect, must_contain=None):
    """Show a step's outcome and stop the run if it is not the expected one (None = success)."""
    log(f"  -> {'ERROR' if is_error else 'OK'}: {text}")
    errno = int(text.split()[2].rstrip(":")) if is_error else None
    if errno != expect:
        log(f"\nSTOP: {label} expected {'OK' if expect is None else f'MySQL error {expect}'}"
            f" but got {'OK' if errno is None else f'MySQL error {errno}'}.")
        sys.exit(1)
    if must_contain and must_contain not in text:
        log(f"\nSTOP: {label} got the expected error number but the message does not mention {must_contain!r}.")
        sys.exit(1)


def step(label, name, expect=None, must_contain=None, **args):
    """Call one agent tool, print the call and the result, check the outcome, return the result text."""
    log(f"\n{label}\n  TOOL CALL {name}: {json.dumps(args, ensure_ascii=False)}")
    text, is_error = tools.call(name, args)
    check(label, text, is_error, expect, must_contain)
    return text


def doc(text):
    """Parse a JSON document returned by a tool, keeping money as exact decimals."""
    return json.loads(text, parse_float=Decimal)


def part1():
    """Priya's order: create with advance, stale-etag status change, pay the balance."""
    log("=== Part 1: Priya Sharma's order ===")
    customer = doc(step("S1 find the customer", "get_customer", phone=PHONE))
    cake = doc(step("S2 search the catalog (cake)", "search_catalog", query="Black Forest"))[0]
    pastry = doc(step("S3 search the catalog (pastry)", "search_catalog", query="Chocolate Truffle"))[0]

    # Stand-in for the model's arithmetic: prices and rates come from the catalog results above.
    variant = next(v for v in cake["variants"] if v["size"] == 1)
    qty = 6
    cake_gst = (variant["price"] * cake["gst_rate"] / 100).quantize(Decimal("0.01"))
    pastry_gst = (pastry["price"] * qty * pastry["gst_rate"] / 100).quantize(Decimal("0.01"))
    subtotal = variant["price"] + pastry["price"] * qty
    gst = cake_gst + pastry_gst
    item = dict(qty=1, gst_applicable=1, discount_exempt=0, is_gst_inclusive=0, discount_value=0.0)
    order = {
        "request_id": f"order-{uuid.uuid4()}", "order_status": "draft", "delivery_at": "2026-10-03 10:00:00",
        "subtotal": float(subtotal), "discount_type": "amount", "discount_value": 0.0,
        "gst_value": float(gst), "total": float(subtotal + gst),
        "outlet": {"id": 1}, "customer": {"id": customer["_id"]},
        "items": [
            {**item, "name": cake["name"], "flavor": variant["flavor"], "size": float(variant["size"]),
             "unit": variant["unit"], "price": float(variant["price"]), "gst_rate": float(cake["gst_rate"]),
             "gst_value": float(cake_gst), "product": {"id": cake["_id"]}, "product_variant_id": variant["id"]},
            {**item, "name": pastry["name"], "qty": qty, "price": float(pastry["price"]),
             "gst_rate": float(pastry["gst_rate"]), "gst_value": float(pastry_gst), "product": {"id": pastry["_id"]}}],
        "payments": [{"business_id": tools.BUSINESS_ID, "request_id": f"payment-{uuid.uuid4()}",
                      "payment_type": "advance", "method": "upi", "amount": 500.0}]}

    step("S4 create the order (draft) with the Rs 500 advance", "create_order", order=order)
    created = doc(step("S5 read it back", "get_order", request_id=order["request_id"]))
    order_id, old_etag = created["_id"], created["_metadata"]["etag"]

    log("\nS6 counter staff confirm the order while the agent still holds the old etag "
        "(simulated on the same agent account)")
    run("UPDATE order_dv SET data = JSON_SET(data, '$.order_status', 'confirmed')"
        " WHERE JSON_VALUE(data, '$._id') = %s AND JSON_VALUE(data, '$.business_id') = %s",
        (order_id, tools.BUSINESS_ID), fetch=False)
    step("S7 agent sets status 'ready' with its stale etag (the tool re-reads and retries once)",
         "update_order_status", order_id=order_id, status="ready", etag=old_etag)

    balance = doc(step("S8 read the order: balance due", "get_order", order_id=order_id))["balance_due"]
    step("S9 pay the balance", "add_payment", order_id=order_id,
         payment={"request_id": f"payment-{uuid.uuid4()}", "payment_type": "final", "method": "cash",
                  "amount": float(balance)})
    after = doc(step("S10 read the order again", "get_order", order_id=order_id))
    if after["balance_due"] != 0:
        log(f"\nSTOP: expected balance_due 0 after paying {balance}, got {after['balance_due']}.")
        sys.exit(1)
    return order, order_id


def part2(order, order_id):
    """Guardrails: the database refuses these; the agent code checks none of them."""
    log("\n=== Part 2: what the database refuses ===")
    step("G1 refund recorded with a positive amount", "add_payment", expect=3819, order_id=order_id,
         payment={"request_id": f"payment-{uuid.uuid4()}", "payment_type": "refund", "method": "cash", "amount": 100.0})
    step("G2 the same refund with a negative amount", "add_payment", order_id=order_id,
         payment={"request_id": f"payment-{uuid.uuid4()}", "payment_type": "refund", "method": "cash", "amount": -100.0})
    step("G3 retry create_order with the already-used request_id", "create_order", expect=1062, order=order)

    log("\nG4 direct read of the orders table by the agent user")
    try:
        text, is_error = str(run("SELECT COUNT(*) FROM orders", ())), False
    except mysql.connector.Error as e:
        text, is_error = f"MySQL error {e.errno}: {e.msg}", True
    check("G4", text, is_error, 1142)

    wrong_price = json.loads(json.dumps(order))
    wrong_price["request_id"] = f"order-{uuid.uuid4()}"
    wrong_price["payments"][0]["request_id"] = f"payment-{uuid.uuid4()}"  # fresh, so only the price can be at fault
    wrong_price["items"][0]["price"] = 100.0
    step("G5 create_order with the cake at 100.00 instead of its catalog price (GUARD 6)", "create_order",
         expect=1644, must_contain="GUARD 6", order=wrong_price)

    # A rogue or buggy client looking up another business's order: the view has no row-level
    # security (docs/when-to-use.md), so this read works; the write below is what the database stops.
    other = run("SELECT JSON_VALUE(data, '$._id') FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = %s",
                ("seed-order-005",))
    log(f"\n(order {other} belongs to the other business; it was found by reading order_dv without the business filter)")
    step("G6 add_payment (business 1) to the other business's order (GUARD 7)", "add_payment",
         expect=1644, must_contain="GUARD 7", order_id=int(other),
         payment={"request_id": f"payment-{uuid.uuid4()}", "payment_type": "advance", "method": "cash", "amount": 100.0})

    # Same kind of rogue lookup: another business's product, read from catalog_dv without the business filter.
    rainbow = doc(run("SELECT data FROM catalog_dv WHERE JSON_VALUE(data, '$.name') = %s", ("Rainbow Cake",)))
    gst = (rainbow["price"] * rainbow["gst_rate"] / 100).quantize(Decimal("0.01"))
    cross_tenant = {
        "request_id": f"order-{uuid.uuid4()}", "order_status": "draft", "delivery_at": "2026-10-03 10:00:00",
        "subtotal": float(rainbow["price"]), "discount_type": "amount", "discount_value": 0.0,
        "gst_value": float(gst), "total": float(rainbow["price"] + gst),
        "outlet": {"id": 1}, "customer": order["customer"],
        "items": [{"qty": 1, "gst_applicable": 1, "discount_exempt": 0, "is_gst_inclusive": 0, "discount_value": 0.0,
                   "name": rainbow["name"], "price": float(rainbow["price"]), "gst_rate": float(rainbow["gst_rate"]),
                   "gst_value": float(gst), "product": {"id": rainbow["_id"]}}]}
    log(f"\n(product {rainbow['_id']}, {rainbow['name']}, belongs to the other business; priced correctly at its own "
        f"catalog price {rainbow['price']}, so only the tenant check can stop it)")
    step("G7 create_order for business 1 with the other business's product at its correct price (GUARD 8)",
         "create_order", expect=1644, must_contain="GUARD 8", order=cross_tenant)


def main():
    """Run both parts and save the output."""
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("# Scripted agent scenarios (no API key) -- every call goes through agent/tools.py\n",
                   encoding="utf-8")
    order, order_id = part1()
    part2(order, order_id)
    log("\nAll scenario steps behaved as expected.")


if __name__ == "__main__":
    main()
