-- ============================================================
-- 05_scenario.sql -- the billing story, end to end, in SQL.
--
-- Priya Sharma orders a 1 kg Black Forest Cake and 6 Chocolate Truffle
-- Pastries with a Rs 500 advance. Counter staff mark the order confirmed
-- while the agent is holding an older copy, so the agent's write fails on
-- a stale etag and is retried with a fresh read. The balance is paid
-- through payment_dv. Finally the order document is shown next to the
-- relational rows it is made of.
--
-- Every step except the last runs as the agent user, through the duality
-- views only. Prices, GST, totals and the balance are all computed here in
-- SQL from catalog_dv and order_dv -- nothing is typed in by hand. Request
-- ids are generated with UUID(), one per new order / payment.
--
-- Each TEST block runs in its own session (scripts/run_sql.py test mode),
-- so every step finds "Priya's latest order" through customer_dv.
-- Run after scripts/reset_db.py:  python scripts/run_sql.py sql/05_scenario.sql
-- ============================================================

-- TEST: S1 agent looks up the customer and the two products
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SELECT JSON_VALUE(data, '$._id') AS customer_id, JSON_VALUE(data, '$.name') AS name, JSON_VALUE(data, '$.phone') AS phone
  FROM customer_dv WHERE JSON_VALUE(data, '$.business_id') = 1 AND JSON_VALUE(data, '$.phone') = '9900000001';
SELECT JSON_VALUE(c.data, '$.name') AS product, v.variant_id, v.flavor, v.size, v.unit,
       COALESCE(v.price, JSON_VALUE(c.data, '$.price' RETURNING DECIMAL(10,2))) AS price,
       JSON_VALUE(c.data, '$.gst_rate') AS gst_rate, JSON_VALUE(c.data, '$.is_gst_inclusive') AS gst_inclusive
  FROM catalog_dv c
  LEFT JOIN JSON_TABLE(c.data, '$.variants[*]' COLUMNS (
        variant_id BIGINT PATH '$.id', flavor VARCHAR(50) PATH '$.flavor',
        size DECIMAL(6,2) PATH '$.size', unit VARCHAR(5) PATH '$.unit', price DECIMAL(10,2) PATH '$.price')) v
    ON v.size = 1.00
 WHERE JSON_VALUE(c.data, '$.business_id') = 1
   AND JSON_VALUE(c.data, '$.name') IN ('Black Forest Cake', 'Chocolate Truffle Pastry');

-- TEST: S2 agent creates the order (draft) with the Rs 500 advance, priced from the catalog
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SET @customer_id = (SELECT JSON_VALUE(data, '$._id') FROM customer_dv
                     WHERE JSON_VALUE(data, '$.business_id') = 1 AND JSON_VALUE(data, '$.phone') = '9900000001');
SET @cake = (SELECT data FROM catalog_dv WHERE JSON_VALUE(data, '$.business_id') = 1 AND JSON_VALUE(data, '$.name') = 'Black Forest Cake');
SET @pastry = (SELECT data FROM catalog_dv WHERE JSON_VALUE(data, '$.business_id') = 1 AND JSON_VALUE(data, '$.name') = 'Chocolate Truffle Pastry');
SELECT v.id, v.flavor, v.size, v.unit, v.price INTO @cake_variant_id, @cake_flavor, @cake_size, @cake_unit, @cake_price
  FROM JSON_TABLE(@cake, '$.variants[*]' COLUMNS (
        id BIGINT PATH '$.id', flavor VARCHAR(50) PATH '$.flavor', size DECIMAL(6,2) PATH '$.size',
        unit VARCHAR(5) PATH '$.unit', price DECIMAL(10,2) PATH '$.price')) v
 WHERE v.size = 1.00;
SET @cake_rate    = JSON_VALUE(@cake, '$.gst_rate' RETURNING DECIMAL(5,2));
SET @pastry_price = JSON_VALUE(@pastry, '$.price' RETURNING DECIMAL(10,2));
SET @pastry_rate  = JSON_VALUE(@pastry, '$.gst_rate' RETURNING DECIMAL(5,2));
SET @pastry_qty   = 6;
-- Both products are GST-exclusive (is_gst_inclusive = 0, shown in S1): GST is added on top.
SET @cake_gst   = ROUND(@cake_price * 1 * @cake_rate / 100, 2);
SET @pastry_gst = ROUND(@pastry_price * @pastry_qty * @pastry_rate / 100, 2);
SET @subtotal   = @cake_price * 1 + @pastry_price * @pastry_qty;
SET @gst_total  = @cake_gst + @pastry_gst;
SET @order_request_id = CONCAT('order-', UUID());
SET @advance_request_id = CONCAT('payment-', UUID());
SET @new_order = JSON_OBJECT(
    'business_id', 1,
    'request_id', @order_request_id,
    'order_status', 'draft',
    'delivery_at', '2026-10-03 10:00:00.000000',
    'subtotal', @subtotal, 'discount_type', 'amount', 'discount_value', 0.00,
    'gst_value', @gst_total, 'total', @subtotal + @gst_total,
    'outlet', JSON_OBJECT('id', 1),
    'customer', JSON_OBJECT('id', CAST(@customer_id AS UNSIGNED)),
    'items', JSON_ARRAY(
        JSON_OBJECT('name', JSON_VALUE(@cake, '$.name'), 'flavor', @cake_flavor, 'size', @cake_size, 'unit', @cake_unit,
                    'qty', 1, 'price', @cake_price, 'gst_rate', @cake_rate, 'is_gst_inclusive', 0,
                    'gst_applicable', 1, 'discount_exempt', 0, 'gst_value', @cake_gst, 'discount_value', 0.00,
                    'product', JSON_OBJECT('id', JSON_VALUE(@cake, '$._id' RETURNING UNSIGNED)),
                    'product_variant_id', @cake_variant_id),
        JSON_OBJECT('name', JSON_VALUE(@pastry, '$.name'),
                    'qty', @pastry_qty, 'price', @pastry_price, 'gst_rate', @pastry_rate, 'is_gst_inclusive', 0,
                    'gst_applicable', 1, 'discount_exempt', 0, 'gst_value', @pastry_gst, 'discount_value', 0.00,
                    'product', JSON_OBJECT('id', JSON_VALUE(@pastry, '$._id' RETURNING UNSIGNED)))),
    'payments', JSON_ARRAY(
        JSON_OBJECT('business_id', 1, 'request_id', @advance_request_id,
                    'payment_type', 'advance', 'method', 'upi', 'amount', 500.00)));
INSERT INTO order_dv VALUES (@new_order);
SELECT JSON_PRETTY(data) AS created_order FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = @order_request_id;

-- TEST: S3 counter staff confirm the order while the agent holds an older copy; the agent's write is stale
-- EXPECT: ERROR 6494
-- AS: agent
USE __MYSQL_DB__;
-- SELECT ... INTO, not SET @x = (SELECT ...): the SET form fails here (E27).
SELECT MAX(o.id) INTO @order_id FROM customer_dv c, JSON_TABLE(c.data, '$.orders[*]' COLUMNS (id BIGINT PATH '$.id')) o
 WHERE JSON_VALUE(c.data, '$.phone') = '9900000001';
-- The agent reads the order, intending to add the delivery address.
SET @agent_copy = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1);
SELECT JSON_VALUE(@agent_copy, '$.order_status') AS agent_sees_status, JSON_VALUE(@agent_copy, '$._metadata.etag') AS agent_etag;
-- Meanwhile counter staff read the same order and confirm it (a separate client; simulated in this session).
SET @staff_copy = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1);
UPDATE order_dv SET data = JSON_SET(@staff_copy, '$.order_status', 'confirmed')
 WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1;
SELECT JSON_VALUE(data, '$.order_status') AS status_after_staff, JSON_VALUE(data, '$._metadata.etag') AS etag_after_staff
  FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id;
-- The agent now writes its older copy. Its etag no longer matches: MySQL refuses.
UPDATE order_dv SET data = JSON_SET(@agent_copy, '$.delivery_address', '221 Brigade Road, Bengaluru')
 WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1;

-- TEST: S4 agent retries with a fresh read: its change is applied, the staff confirmation is kept
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
-- SELECT ... INTO, not SET @x = (SELECT ...): the SET form fails here (E27).
SELECT MAX(o.id) INTO @order_id FROM customer_dv c, JSON_TABLE(c.data, '$.orders[*]' COLUMNS (id BIGINT PATH '$.id')) o
 WHERE JSON_VALUE(c.data, '$.phone') = '9900000001';
SET @fresh = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1);
SELECT JSON_VALUE(@fresh, '$.order_status') AS fresh_status, JSON_VALUE(@fresh, '$._metadata.etag') AS fresh_etag;
UPDATE order_dv SET data = JSON_SET(@fresh, '$.delivery_address', '221 Brigade Road, Bengaluru')
 WHERE JSON_VALUE(data, '$._id') = @order_id AND JSON_VALUE(data, '$.business_id') = 1;
SELECT JSON_VALUE(data, '$.order_status') AS status, JSON_VALUE(data, '$.delivery_address') AS delivery_address
  FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id;

-- TEST: S5 agent pays the balance through payment_dv; the balance is computed in SQL
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
-- SELECT ... INTO, not SET @x = (SELECT ...): the SET form fails here (E27).
SELECT MAX(o.id) INTO @order_id FROM customer_dv c, JSON_TABLE(c.data, '$.orders[*]' COLUMNS (id BIGINT PATH '$.id')) o
 WHERE JSON_VALUE(c.data, '$.phone') = '9900000001';
SELECT JSON_VALUE(d.data, '$.total' RETURNING DECIMAL(10,2)) - COALESCE(SUM(p.amount), 0) INTO @balance
  FROM order_dv d
  LEFT JOIN JSON_TABLE(d.data, '$.payments[*]' COLUMNS (amount DECIMAL(10,2) PATH '$.amount')) p ON TRUE
 WHERE JSON_VALUE(d.data, '$._id') = @order_id AND JSON_VALUE(d.data, '$.business_id') = 1
 GROUP BY d.data;
SELECT @balance AS balance_due_before;
INSERT INTO payment_dv VALUES (JSON_OBJECT(
    'business_id', 1, 'request_id', CONCAT('payment-', UUID()),
    'payment_type', 'final', 'method', 'cash', 'amount', @balance,
    'order', JSON_OBJECT('id', @order_id)));
SELECT JSON_VALUE(d.data, '$.total' RETURNING DECIMAL(10,2)) - COALESCE(SUM(p.amount), 0) AS balance_due_after
  FROM order_dv d
  LEFT JOIN JSON_TABLE(d.data, '$.payments[*]' COLUMNS (amount DECIMAL(10,2) PATH '$.amount')) p ON TRUE
 WHERE JSON_VALUE(d.data, '$._id') = @order_id
 GROUP BY d.data;

-- TEST: S6 the final order document next to its relational rows (admin: the agent cannot read tables, E13)
-- EXPECT: OK
USE __MYSQL_DB__;
SET @order_id = (SELECT MAX(id) FROM orders WHERE customer_id = 1);
SELECT JSON_PRETTY(data) AS order_document FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id;
SELECT id, request_id, order_status, delivery_address, subtotal, gst_value, total FROM orders WHERE id = @order_id;
SELECT id, name, product_id, product_variant_id, qty, price, gst_rate, gst_value FROM order_items WHERE order_id = @order_id ORDER BY id;
SELECT id, request_id, payment_type, method, amount, paid_at FROM payments WHERE order_id = @order_id ORDER BY id;
