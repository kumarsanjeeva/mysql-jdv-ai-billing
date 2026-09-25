-- ============================================================
-- 02_duality_views.sql
-- The JSON Duality Views that make up the AI agent's entire contract with
-- the database. Four views:
--
--   order_dv     — root: orders. WITH(INSERT, UPDATE), no DELETE (cancel is
--                  an order_status UPDATE). Nested items: WITH(INSERT,
--                  UPDATE), no DELETE (removal is a DB-level impossibility
--                  through this view). Nested payments: WITH(INSERT, UPDATE),
--                  no DELETE. INSERT is used for payments bundled into order
--                  CREATION (H01 in sql/03_dml_demos.sql). UPDATE is there
--                  only so an order document written back as JSON text can
--                  carry its existing payments unchanged: with INSERT alone,
--                  the text round trip turns paid_at into a string that
--                  MySQL rejects as a change (docs/findings.md E23). Payments
--                  still cannot actually change -- GUARD 5 in
--                  sql/01_schema.sql rejects any column change on payments.
--   payment_dv   — root: payments, WITH(INSERT) only. The way to add a
--                  payment to an ALREADY-EXISTING order. Appending to
--                  order_dv's payments array instead works only if the new
--                  payment carries an explicit id: omit it and the array
--                  mixes generated and explicit ids (ERROR 6560); supply it
--                  from a subquery inside the UPDATE itself and MySQL treats
--                  it as generated too (ERROR 6560); supply it as a value
--                  (literal or variable) and it is accepted
--                  (docs/findings.md E24). A client cannot know the next id
--                  in advance, so a single-object INSERT into this view is
--                  the practical path. Nested `order`: read-only reference.
--   catalog_dv   — root: products, fully read-only, with nested read-only
--                  variants[].
--   customer_dv  — root: customers, fully read-only, with a nested
--                  read-only order-history summary (not full items/payments
--                  — those live in order_dv/payment_dv).
--
-- gst_rate_history is deliberately exposed through NO duality view — plain
-- SQL / reporting only. Not every table needs one.
--
-- Grants for AGENT_DB_USER are at the end of this file (views must exist
-- before they can be granted on) — SELECT/INSERT/UPDATE on order_dv,
-- SELECT/INSERT on payment_dv, SELECT only on catalog_dv/customer_dv (both
-- fully read-only), and nothing at all on any base table.
-- ============================================================

USE __MYSQL_DB__;

DROP VIEW IF EXISTS order_dv, payment_dv, catalog_dv, customer_dv;

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

-- ============================================================
-- One sample document per view, for a human/blog reader.
-- ============================================================
SELECT JSON_PRETTY(data) FROM order_dv WHERE JSON_VALUE(data, '$._id') = (
    SELECT id FROM orders WHERE request_id = 'seed-order-002'
);
SELECT JSON_PRETTY(data) FROM payment_dv WHERE JSON_VALUE(data, '$._id') = (
    SELECT id FROM payments WHERE request_id = 'seed-payment-001'
);
SELECT JSON_PRETTY(data) FROM catalog_dv WHERE JSON_VALUE(data, '$._id') = (
    SELECT id FROM products WHERE name = 'Black Forest Cake'
);
SELECT JSON_PRETTY(data) FROM customer_dv WHERE JSON_VALUE(data, '$._id') = (
    SELECT id FROM customers WHERE name = 'Priya Sharma'
);

-- ============================================================
-- Catalog metadata: confirm MySQL registered these as duality views.
-- ============================================================
SELECT * FROM INFORMATION_SCHEMA.JSON_DUALITY_VIEWS WHERE TABLE_SCHEMA = '__MYSQL_DB__';
SELECT * FROM INFORMATION_SCHEMA.JSON_DUALITY_VIEW_TABLES WHERE TABLE_SCHEMA = '__MYSQL_DB__';

-- ============================================================
-- AGENT_DB_USER grants — the duality views only, never a base table.
-- order_dv is writable (agent bills orders); catalog_dv/customer_dv are
-- SELECT-only (they carry no WITH() annotations at all, so INSERT/UPDATE
-- privilege on them would do nothing useful anyway).
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON __MYSQL_DB__.order_dv TO '__AGENT_DB_USER__'@'%';
GRANT SELECT, INSERT ON __MYSQL_DB__.payment_dv TO '__AGENT_DB_USER__'@'%';
GRANT SELECT ON __MYSQL_DB__.catalog_dv TO '__AGENT_DB_USER__'@'%';
GRANT SELECT ON __MYSQL_DB__.customer_dv TO '__AGENT_DB_USER__'@'%';
