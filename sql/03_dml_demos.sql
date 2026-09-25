-- ============================================================
-- 03_dml_demos.sql — happy paths, all through order_dv/customer_dv unless
-- noted. Runs as one mysql session so @doc (the last document read, etag
-- included) carries across statements — this is deliberate: it demonstrates
-- the real read-etag-then-write-etag pattern rather than a hardcoded etag
-- string, which would be exactly the kind of invented behavior rule 4 rules
-- out.
--
-- Reuses the seed data's Sunrise Bakers / MG Road / Priya Sharma / Black
-- Forest Cake / Chocolate Truffle Pastry — the same order agent/scenarios.py
-- narrates in Phase 4, so the SQL demo and the agent demo tell one story.
-- ============================================================

USE __MYSQL_DB__;

-- --- H01: insert a new order (2 items + 1 advance payment) as ONE document ---
INSERT INTO order_dv VALUES('{
  "business_id": 1,
  "request_id": "h01-demo-001",
  "order_status": "confirmed",
  "delivery_at": "2026-10-03 10:00:00.000000",
  "subtotal": 1440.00,
  "discount_type": "amount",
  "discount_value": 0.00,
  "gst_value": 72.00,
  "total": 1512.00,
  "outlet": {"id": 1},
  "customer": {"id": 1},
  "items": [
    {
      "name": "Black Forest Cake", "flavor": "Chocolate", "size": 1.00, "unit": "kg",
      "qty": 1, "price": 900.00, "gst_rate": 5.00, "is_gst_inclusive": 0,
      "gst_applicable": 1, "discount_exempt": 0, "gst_value": 45.00, "discount_value": 0.00,
      "product": {"id": 1}, "product_variant_id": 2
    },
    {
      "name": "Chocolate Truffle Pastry", "qty": 6, "price": 90.00, "gst_rate": 5.00,
      "is_gst_inclusive": 0, "gst_applicable": 1, "discount_exempt": 0,
      "gst_value": 27.00, "discount_value": 0.00,
      "product": {"id": 3}
    }
  ],
  "payments": [
    {"business_id": 1, "request_id": "h01-payment-advance", "payment_type": "advance", "method": "upi", "amount": 500.00}
  ]
}');

-- --- H02: read it back; show _metadata.etag ---
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT JSON_PRETTY(@doc) AS h02_document;
SELECT JSON_VALUE(@doc, '$._metadata.etag') AS h02_etag;

-- --- H03: the same data relationally (plain SELECT on the base tables) ---
SELECT o.id AS order_id, o.order_status, o.total, c.name AS customer, ot.name AS outlet
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN outlets ot ON ot.id = o.outlet_id
WHERE o.request_id = 'h01-demo-001';

SELECT id, name, qty, price, gst_value FROM order_items
WHERE order_id = (SELECT id FROM orders WHERE request_id = 'h01-demo-001');

SELECT id, payment_type, method, amount FROM payments
WHERE order_id = (SELECT id FROM orders WHERE request_id = 'h01-demo-001');

-- --- H04: add a second (final) payment ---
-- NOT a JSON_ARRAY_APPEND onto order_dv's payments array. That append
-- works only if the new payment carries an explicit id given as a value;
-- omitted, or computed by a subquery inside the UPDATE itself, MySQL 9.7.2
-- treats it as generated and rejects the generated/explicit mix with the
-- existing payment (ERROR 6560; docs/findings.md E24,
-- results/repro_append_bisect.sql). A client cannot know the next id in
-- advance, so payment_dv makes "add a payment to an existing order" a
-- single-object INSERT, not an array mutation.
SET @h01_order_id = (SELECT id FROM orders WHERE request_id = 'h01-demo-001');

INSERT INTO payment_dv VALUES(JSON_OBJECT(
    'business_id', 1,
    'request_id', 'h04-payment-final',
    'payment_type', 'final',
    'method', 'cash',
    'amount', 1012.00,
    'order', JSON_OBJECT('id', @h01_order_id)
));

SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT JSON_PRETTY(@doc) AS h04_document_after_second_payment;

-- --- H05: change order status via UPDATE, using the etag from H04's re-read ---
-- The document is sent back exactly as read, with only order_status
-- changed. Item 2 (the pastry) has no variant and reads back as
-- "product_variant_id": null -- that round-trips because order_dv exposes
-- the variant as a flat scalar. With a nested read-only product_variant
-- object it could not be written back at all, with or without the null key
-- (E20, results/repro_null_singleton_update.sql). @doc is text (a user
-- variable cannot hold the JSON type), exactly like a document an
-- application sends: paid_at comes back as a string, which order_dv accepts
-- only because its payments array allows UPDATE, with GUARD 5 rejecting
-- any real change (E23).
UPDATE order_dv
SET data = JSON_SET(@doc, '$.order_status', 'delivered')
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');

SELECT JSON_VALUE(data, '$.order_status') AS h05_order_status
FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001';

-- --- H06: customer_dv history reflects the new order ---
SELECT JSON_PRETTY(data) AS h06_priya_history FROM customer_dv WHERE JSON_VALUE(data, '$._id') = 1;

-- --- H07: reporting query on base tables (daily sales + GST) — proves plain SQL is untouched ---
SELECT
    DATE(o.created_at) AS sale_date,
    COUNT(DISTINCT o.id) AS orders_created,
    SUM(o.subtotal) AS subtotal_total,
    SUM(o.discount_value) AS discount_total,
    SUM(o.gst_value) AS gst_total,
    SUM(o.total) AS total_billed
FROM orders o
WHERE o.business_id = 1
GROUP BY DATE(o.created_at)
ORDER BY sale_date;
