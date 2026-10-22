# JSON Duality Views reference

The four duality views that make up the agent's contract with the database,
as defined in [`sql/02_duality_views.sql`](../sql/02_duality_views.sql). For
each view: the `CREATE` statement copied from that file, one sample document
from a committed results file, the nested tables with their updatable or
read-only status, and the tests that exercise the view. Anything with no
results file is marked "not tested here". Test IDs (E01, REFUND1, ...) are
explained in [`findings.md`](findings.md); the table reference is
[`schema.md`](schema.md).

`gst_rate_history` has no duality view. The agent's grants are on the four
views only (`SHOW GRANTS` output in `results/04_edge_cases.txt`, test E12):

```
GRANT SELECT ON `jdv_ai_billing`.`catalog_dv` TO `jdv_agent`@`%`
GRANT SELECT ON `jdv_ai_billing`.`customer_dv` TO `jdv_agent`@`%`
GRANT SELECT, INSERT, UPDATE ON `jdv_ai_billing`.`order_dv` TO `jdv_agent`@`%`
GRANT SELECT, INSERT ON `jdv_ai_billing`.`payment_dv` TO `jdv_agent`@`%`
```

The nested-table status below is the server's own metadata, captured in
`results/02_duality_views.txt` (queries on
`INFORMATION_SCHEMA.JSON_DUALITY_VIEWS` and `JSON_DUALITY_VIEW_TABLES`).

## order_dv

Used by the tools `get_order`, `create_order` and `update_order_status`.

```sql
CREATE JSON DUALITY VIEW order_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'business_id': business_id,
    'request_id': request_id,
    'order_status': order_status,
    'delivery_address': delivery_address,
    'delivery_at': delivery_at,
    'subtotal': subtotal,
    'discount_type': discount_type,
    'discount_value': discount_value,
    'gst_value': gst_value,
    'total': total,
    'cancellation_reason': cancellation_reason,
    'created_at': created_at,
    'outlet': (
        SELECT JSON_DUALITY_OBJECT(
            'id': id,
            'name': name
        )
        FROM outlets WHERE outlets.id = orders.outlet_id
    ),
    'customer': (
        SELECT JSON_DUALITY_OBJECT(
            'id': id,
            'name': name,
            'phone': phone
        )
        FROM customers WHERE customers.id = orders.customer_id
    ),
    'items': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'name': name,
                'flavor': flavor,
                'size': size,
                'unit': unit,
                'qty': qty,
                'price': price,
                'gst_rate': gst_rate,
                'is_gst_inclusive': is_gst_inclusive,
                'gst_applicable': gst_applicable,
                'discount_exempt': discount_exempt,
                'gst_value': gst_value,
                'discount_value': discount_value,
                'notes': notes,
                'product': (
                    SELECT JSON_DUALITY_OBJECT(
                        'id': id,
                        'name': name
                    )
                    FROM products WHERE products.id = order_items.product_id
                ),
                -- A flat scalar, NOT a nested read-only product_variant
                -- object: most items have no variant, and a nested object
                -- that reads back as null cannot be written back (E20,
                -- results/repro_null_singleton_update.sql). The item's own
                -- flavor/size/unit columns already snapshot the variant.
                'product_variant_id': product_variant_id
            )
        )
        FROM order_items WHERE order_items.order_id = orders.id
    ),
    'payments': (
        SELECT JSON_ARRAYAGG(
            -- UPDATE here only lets unchanged payments round-trip as JSON
            -- text (E23); GUARD 5 rejects any real change.
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'business_id': business_id,
                'request_id': request_id,
                'payment_type': payment_type,
                'method': method,
                'amount': amount,
                'paid_at': paid_at
            )
        )
        FROM payments WHERE payments.order_id = orders.id
    )
)
FROM orders;
```

**Sample document** (order `seed-order-002`; `results/02_duality_views.txt`,
first `JSON_PRETTY` output):

```json
{
  "_id": 2,
  "items": [
    {
      "id": 3,
      "qty": 1.00,
      "name": "Vanilla Cake",
      "size": 1.00,
      "unit": "kg",
      "notes": null,
      "price": 750.00,
      "flavor": "Vanilla",
      "product": {
        "id": 2,
        "name": "Vanilla Cake"
      },
      "gst_rate": 5.00,
      "gst_value": 36.35,
      "discount_value": 23.00,
      "gst_applicable": 1,
      "discount_exempt": 0,
      "is_gst_inclusive": 0,
      "product_variant_id": 5
    },
    {
      "id": 4,
      "qty": 6.00,
      "name": "Chocolate Truffle Pastry",
      "size": null,
      "unit": null,
      "notes": null,
      "price": 90.00,
      "flavor": null,
      "product": {
        "id": 3,
        "name": "Chocolate Truffle Pastry"
      },
      "gst_rate": 5.00,
      "gst_value": 26.15,
      "discount_value": 17.00,
      "gst_applicable": 1,
      "discount_exempt": 0,
      "is_gst_inclusive": 0,
      "product_variant_id": null
    }
  ],
  "total": 1312.50,
  "outlet": {
    "id": 1,
    "name": "Sunrise Bakers - MG Road"
  },
  "customer": {
    "id": 2,
    "name": "Karthik Rao",
    "phone": "9900000002"
  },
  "payments": [
    {
      "id": 1,
      "amount": 500.00,
      "method": "upi",
      "paid_at": "2026-09-14 12:00:00.000000",
      "request_id": "seed-payment-001",
      "business_id": 1,
      "payment_type": "advance"
    }
  ],
  "subtotal": 1290.00,
  "_metadata": {
    "etag": "2647eb0b6823a00a33d3ec298b4a18a5"
  },
  "gst_value": 62.50,
  "created_at": "2026-10-15 02:18:07.004020",
  "request_id": "seed-order-002",
  "business_id": 1,
  "delivery_at": "2026-09-15 17:00:00.000000",
  "order_status": "delivered",
  "discount_type": "amount",
  "discount_value": 40.00,
  "delivery_address": null,
  "cancellation_reason": null
}
```

**Nested tables and status** (`results/02_duality_views.txt`):

| Table | Nesting | Insert | Update | Delete | Read-only |
|---|---|---|---|---|---|
| `orders` | root | yes | yes | no | no |
| `order_items` | nested array | yes | yes | no | no |
| `payments` | nested array | yes | yes | no | no |
| `products` | singleton (`items[].product`) | no | no | no | yes |
| `customers` | singleton | no | no | no | yes |
| `outlets` | singleton | no | no | no | yes |

**Tests:**

| What | Test | Result | Results file |
|---|---|---|---|
| Insert and update as the agent | E12 | OK: the order is created, then reads back with the new status | `results/04_edge_cases.txt` |
| Etag must match | E01 | `ERROR 6494` on the second update with a stale etag | `results/04_edge_cases.txt` |
| No DELETE on items | E02 | `ERROR 6498`: Missing DELETE tag on `order_items` | `results/04_edge_cases.txt` |
| No DELETE on payments | E03 | `ERROR 6498`: Missing DELETE tag on `payments` | `results/04_edge_cases.txt` |
| `_id` cannot change | E05 | `ERROR 6496` | `results/04_edge_cases.txt` |
| Read-only nested product | E10 | `ERROR 6491` for an item whose product does not exist | `results/04_edge_cases.txt` |
| One document per statement | E06, E07, E08 | `ERROR 6482` for multi-document UPDATE, `INSERT ... SELECT`, upsert | `results/04_edge_cases.txt` |
| `EXPLAIN` | E09, E09b, E09c | OK for admin `EXPLAIN SELECT`; `ERROR 1345` for the agent; `ERROR 6482` for `EXPLAIN UPDATE` | `results/04_edge_cases.txt` |
| `product_variant_id` as a flat scalar, not a nested object | E20 | a nested object that reads back as `null` cannot be written back (`ERROR 6495`); the scalar form can | `results/repro_null_singleton_update.txt` |
| Appending a payment inside `order_dv` | E16, E17, E18, E24 | `ERROR 6560` without an id or with an id from an inline subquery; OK with an explicit id given as a value | `results/04_edge_cases.txt`, `results/repro_append_explicit_ids.txt` |
| Payments `WITH(INSERT, UPDATE)` | E23 | a `DATETIME` cannot survive a JSON-text round trip in an insert-only array; design B (UPDATE plus GUARD 5) works | `results/repro_datetime_roundtrip.txt`, `results/repro_payment_design_ab.txt` |
| A payment cannot change | E25 | `ERROR 1644` GUARD 5 | `results/04_edge_cases.txt` |
| Item prices through `order_dv` | E28 | GUARD 6, 17 of 17 | `results/07_e28_item_price_guard.txt` |
| Payment business through `order_dv` | E29c | `ERROR 1644` (GUARD 7) | `results/08_e29_payment_business_guard.txt` |
| Payments bundled into order creation | H01 | order created with a payment | `results/03_dml_demos.txt` |
| Writing to the nested `outlet` or `customer` objects | not tested here | | |
| A `DELETE` statement on `order_dv` | not tested here (the metadata shows `ALLOW_DELETE` 0) | | |

## payment_dv

Used by the tool `add_payment`, the way to add a payment to an order that
already exists.

```sql
CREATE JSON DUALITY VIEW payment_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT)
    '_id': id,
    'business_id': business_id,
    'request_id': request_id,
    'payment_type': payment_type,
    'method': method,
    'amount': amount,
    'paid_at': paid_at,
    'order': (
        SELECT JSON_DUALITY_OBJECT(
            'id': id,
            'request_id': request_id,
            'order_status': order_status,
            'total': total
        )
        FROM orders WHERE orders.id = payments.order_id
    )
)
FROM payments;
```

**Sample document** (payment `seed-payment-001`; `results/02_duality_views.txt`,
second `JSON_PRETTY` output):

```json
{
  "_id": 1,
  "order": {
    "id": 2,
    "total": 1312.50,
    "request_id": "seed-order-002",
    "order_status": "delivered"
  },
  "amount": 500.00,
  "method": "upi",
  "paid_at": "2026-09-14 12:00:00.000000",
  "_metadata": {
    "etag": "50e96691075ce23bf6e39ca71be9b428"
  },
  "request_id": "seed-payment-001",
  "business_id": 1,
  "payment_type": "advance"
}
```

**Nested tables and status** (`results/02_duality_views.txt`):

| Table | Nesting | Insert | Update | Delete | Read-only |
|---|---|---|---|---|---|
| `payments` | root | yes | no | no | no |
| `orders` | singleton (`order`) | no | no | no | yes |

**Tests:**

| What | Test | Result | Results file |
|---|---|---|---|
| A refund is inserted through the view | REFUND1 | OK: the -500.00 refund appears in `payment_dv` and in the order's `payments` | `results/04_edge_cases.txt` |
| A refund with a positive amount | REFUND2 | `ERROR 3819` (`chk_payments_amount_sign`) | `results/04_edge_cases.txt` |
| Payment business must match its order | E29a, E29b | OK with the order's own business; `ERROR 1644` (GUARD 7) with a different one | `results/08_e29_payment_business_guard.txt` |
| An `UPDATE` or `DELETE` on `payment_dv` | not tested here (the metadata shows `ALLOW_UPDATE` 0 and `ALLOW_DELETE` 0) | | |
| Writing to the nested `order` object | not tested here | | |

## catalog_dv

Used by the tool `search_catalog`. Fully read-only.

```sql
CREATE JSON DUALITY VIEW catalog_dv AS
SELECT JSON_DUALITY_OBJECT(
    '_id': id,
    'business_id': business_id,
    'name': name,
    'price': price,
    'is_mrp': is_mrp,
    'gst_applicable': gst_applicable,
    'gst_rate': gst_rate,
    'is_gst_inclusive': is_gst_inclusive,
    'discount_exempt': discount_exempt,
    'max_discount_amount': max_discount_amount,
    'variants': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT(
                'id': id,
                'flavor': flavor,
                'size': size,
                'unit': unit,
                'price': price
            )
        )
        FROM product_variants WHERE product_variants.product_id = products.id
    )
)
FROM products;
```

**Sample document** (product "Black Forest Cake"; `results/02_duality_views.txt`,
third `JSON_PRETTY` output):

```json
{
  "_id": 1,
  "name": "Black Forest Cake",
  "price": 900.00,
  "is_mrp": 0,
  "gst_rate": 5.00,
  "variants": [
    {
      "id": 1,
      "size": 0.50,
      "unit": "kg",
      "price": 500.00,
      "flavor": "Chocolate"
    },
    {
      "id": 2,
      "size": 1.00,
      "unit": "kg",
      "price": 900.00,
      "flavor": "Chocolate"
    },
    {
      "id": 3,
      "size": 1.50,
      "unit": "kg",
      "price": 1300.00,
      "flavor": "Chocolate"
    }
  ],
  "_metadata": {
    "etag": "a6bbb19172fb4a6cc48293cb2c529fad"
  },
  "business_id": 1,
  "gst_applicable": 1,
  "discount_exempt": 0,
  "is_gst_inclusive": 0,
  "max_discount_amount": null
}
```

**Nested tables and status** (`results/02_duality_views.txt`):

| Table | Nesting | Insert | Update | Delete | Read-only |
|---|---|---|---|---|---|
| `products` | root | no | no | no | yes |
| `product_variants` | nested array (`variants`) | no | no | no | yes |

**Tests:**

| What | Test | Result | Results file |
|---|---|---|---|
| The agent cannot change a price | E04 | `ERROR 1142`: UPDATE command denied (SELECT-only grant) | `results/04_edge_cases.txt` |
| Not even an administrator can | E04b | `ERROR 6497`: Missing UPDATE tag on `products`.price (the view has no UPDATE annotation) | `results/04_edge_cases.txt` |
| Writes to `variants` | not tested here | | |

## customer_dv

Used by the tool `get_customer`. Fully read-only, with an order-history
summary (not the items or payments, which are in `order_dv` and `payment_dv`).

```sql
CREATE JSON DUALITY VIEW customer_dv AS
SELECT JSON_DUALITY_OBJECT(
    '_id': id,
    'business_id': business_id,
    'name': name,
    'phone': phone,
    'address': address,
    'orders': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT(
                'id': id,
                'order_status': order_status,
                'total': total,
                'created_at': created_at,
                'delivery_at': delivery_at
            )
        )
        FROM orders WHERE orders.customer_id = customers.id
    )
)
FROM customers;
```

**Sample document** (customer "Priya Sharma"; `results/02_duality_views.txt`,
fourth `JSON_PRETTY` output):

```json
{
  "_id": 1,
  "name": "Priya Sharma",
  "phone": "9900000001",
  "orders": [
    {
      "id": 1,
      "total": 1470.00,
      "created_at": "2026-10-15 02:18:06.994689",
      "delivery_at": "2026-09-20 10:00:00.000000",
      "order_status": "confirmed"
    },
    {
      "id": 4,
      "total": 525.00,
      "created_at": "2026-10-15 02:18:07.022203",
      "delivery_at": "2026-09-10 09:00:00.000000",
      "order_status": "cancelled"
    }
  ],
  "address": "221 Brigade Road, Bengaluru",
  "_metadata": {
    "etag": "2387f1848a3a70d85cc596b15df8c31f"
  },
  "business_id": 1
}
```

**Nested tables and status** (`results/02_duality_views.txt`):

| Table | Nesting | Insert | Update | Delete | Read-only |
|---|---|---|---|---|---|
| `customers` | root | no | no | no | yes |
| `orders` | nested array (`orders`) | no | no | no | yes |

**Tests:**

| What | Test | Result | Results file |
|---|---|---|---|
| The agent's grant is SELECT only | E12 (`SHOW GRANTS`) | `GRANT SELECT ON ... customer_dv` | `results/04_edge_cases.txt` |
| Reads by phone and business | scripted scenario | `customer_dv` is read in the SQL scenario | `results/05_scenario.txt` |
| A write attempt on `customer_dv`, by the agent or an administrator | not tested here | | |

## Payments: writable in `order_dv`, immutable everywhere

`order_dv.payments` is annotated `WITH(INSERT, UPDATE)`, but a payment can
never actually change. The UPDATE annotation exists only so an order
document sent back as JSON text can carry its existing payments unchanged:
JSON text turns `paid_at` into a string, and without UPDATE MySQL rejects
that unchanged value as a modification (`docs/findings.md` E23).

What stops real changes is GUARD 5 (`trg_payments_guard_immutable` in
`sql/01_schema.sql`), a `BEFORE UPDATE` trigger on the `payments` table that
rejects any change to a column value. It is a table trigger, so it fires for
any connection that writes the table. It was tested for two accounts only:
the agent user through `order_dv` (E25) and `jdv_admin` with a direct
`UPDATE payments` (E26); no other account or code path was tested.

That is the intended rule, not a side effect: a payment is a financial
record, and it is corrected with a new `refund` payment, never edited. A
wrong 500.00 payment stays on the order; a refund of -500.00 (and, if
needed, a new correct payment) is inserted next to it, so the history of
what happened is kept. Refunds go in through `payment_dv` like any other
payment; the agent inserting a -500.00 refund works (REFUND1), and the
`payments` CHECK constraint rejects a refund with a positive amount
(REFUND2, `ERROR 3819`).
