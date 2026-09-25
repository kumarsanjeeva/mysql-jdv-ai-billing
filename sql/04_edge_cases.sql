-- 04_edge_cases.sql
-- Purpose: edge cases and limits of DML through duality views; the raw
--          material for docs/findings.md. Each test is a block:
--            -- TEST: <id> <description>
--            -- EXPECT: OK | ERROR | ERROR <code>
--            -- AS: agent            (optional; default is the admin user)
--          scripts/run_sql.py runs every block in its own session and
--          reports PASS/SURPRISE per test.
--
-- Runs against the demo database after scripts/reset_db.py and
-- sql/03_dml_demos.sql.
--
-- Expected error codes come from the server's own error catalog (perror).
-- Where the catalog has more than one plausible code (multi-document
-- UPDATE, INSERT ... SELECT, ON DUPLICATE KEY UPDATE, EXPLAIN UPDATE), the
-- test says `EXPECT: ERROR` and the actual code is read from the output.
--
-- Every block that writes runs inside a transaction and ends with ROLLBACK
-- (a failing statement ends the session, which also rolls back), so tests
-- never depend on each other's side effects.
--
-- Shared test order (valid for GUARD 3 and GUARD 4): business 1 (Sunrise
-- Bakers), outlet 1, customer 1 (Priya Sharma), one Black Forest Cake item.
-- Each block that needs it builds it from this literal:
--   {"business_id":1,"request_id":"<id>","order_status":"confirmed",
--    "subtotal":900.00,"discount_type":"amount","discount_value":0.00,
--    "gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},
--    "items":[{"name":"Black Forest Cake","qty":1,"price":900.00,...,
--              "product":{"id":1},"product_variant_id":2}]}

-- ------------------------------------------------------------
-- Document writes through order_dv (agent user)
-- ------------------------------------------------------------

-- TEST: E01 stale etag: second UPDATE reuses the etag the first one replaced
-- EXPECT: ERROR 6494
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
SELECT JSON_VALUE(@doc, '$._metadata.etag') AS etag_read;
UPDATE order_dv SET data = JSON_SET(@doc, '$.order_status', 'ready')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT JSON_VALUE(data, '$._metadata.etag') AS etag_after_first_update
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001';
UPDATE order_dv SET data = JSON_SET(@doc, '$.order_status', 'delivered')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E02 omitted item: write the order back without one of its two items
-- EXPECT: ERROR 6498
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT JSON_LENGTH(@doc, '$.items') AS items_before;
UPDATE order_dv SET data = JSON_REMOVE(@doc, '$.items[1]')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E03 omitted payment: write the order back without one of its payments
-- EXPECT: ERROR 6498
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT JSON_LENGTH(@doc, '$.payments') AS payments_before;
UPDATE order_dv SET data = JSON_REMOVE(@doc, '$.payments[0]')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E04 agent changes a product price through catalog_dv (SELECT-only grant)
-- EXPECT: ERROR 1142
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM catalog_dv WHERE JSON_VALUE(data, '$.name') = 'Black Forest Cake');
UPDATE catalog_dv SET data = JSON_SET(@doc, '$.price', 1.00)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E04b admin changes a product price through catalog_dv (view has no UPDATE annotation)
-- EXPECT: ERROR 6497
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM catalog_dv WHERE JSON_VALUE(data, '$.name') = 'Black Forest Cake');
UPDATE catalog_dv SET data = JSON_SET(@doc, '$.price', 1.00)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E05 primary key change: document written back with a different _id
-- EXPECT: ERROR 6496
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
UPDATE order_dv SET data = JSON_SET(@doc, '$._id', 999999)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E06 multi-document UPDATE: one statement sets the status of every business-1 order
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SELECT COUNT(*) AS business1_orders FROM order_dv WHERE JSON_VALUE(data, '$.business_id') = 1;
UPDATE order_dv SET data = JSON_SET(data, '$.order_status', 'ready')
 WHERE JSON_VALUE(data, '$.business_id') = 1;
SELECT ROW_COUNT() AS rows_affected;
ROLLBACK;

-- TEST: E07 INSERT ... SELECT into order_dv (a valid new document, supplied by a SELECT)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv
SELECT CAST('{"business_id":1,"request_id":"e07-insert-select","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}' AS JSON);
SELECT COUNT(*) AS e07_orders FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e07-insert-select';
ROLLBACK;

-- TEST: E08 INSERT ... ON DUPLICATE KEY UPDATE on order_dv (existing document as an upsert)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
INSERT INTO order_dv VALUES (JSON_SET(@doc, '$.order_status', 'ready'))
ON DUPLICATE KEY UPDATE data = VALUES(data);
ROLLBACK;

-- TEST: E09 EXPLAIN SELECT on order_dv as admin
-- EXPECT: OK
USE __MYSQL_DB__;
EXPLAIN SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001';

-- TEST: E09b EXPLAIN SELECT on order_dv as the agent (no grants on the underlying tables)
-- EXPECT: ERROR 1345
-- AS: agent
USE __MYSQL_DB__;
EXPLAIN SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001';

-- TEST: E09c EXPLAIN UPDATE on order_dv as admin
-- EXPECT: ERROR
USE __MYSQL_DB__;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
EXPLAIN UPDATE order_dv SET data = JSON_SET(@doc, '$.order_status', 'ready')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: E10 new order referencing a product id that does not exist
-- EXPECT: ERROR 6491
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e10-no-product","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Phantom Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":999999}}]}');
ROLLBACK;

-- TEST: E11 cross-tenant reference: business-1 order for a business-2 customer (GUARD 4)
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @other_customer = (SELECT JSON_VALUE(data, '$._id') FROM customer_dv WHERE JSON_VALUE(data, '$.phone') = '9900000004');
SELECT @other_customer AS vikram_customer_id,
       (SELECT JSON_VALUE(data, '$.business_id') FROM customer_dv WHERE JSON_VALUE(data, '$.phone') = '9900000004') AS vikram_business_id;
INSERT INTO order_dv VALUES(JSON_SET('{"business_id":1,"request_id":"e11-cross-tenant","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}',
    '$.customer.id', CAST(@other_customer AS UNSIGNED)));
ROLLBACK;

-- ------------------------------------------------------------
-- The agent's privilege boundary
-- ------------------------------------------------------------

-- TEST: E12 agent (grants on views only) inserts and updates an order through order_dv
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SHOW GRANTS;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e12-agent-dml","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e12-agent-dml');
UPDATE order_dv SET data = JSON_SET(@doc, '$.order_status', 'ready')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT JSON_VALUE(data, '$.order_status') AS e12_status FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e12-agent-dml';
ROLLBACK;

-- TEST: E13 agent SELECTs a base table directly
-- EXPECT: ERROR 1142
-- AS: agent
USE __MYSQL_DB__;
SELECT id, total FROM orders LIMIT 1;

-- ------------------------------------------------------------
-- Idempotency
-- ------------------------------------------------------------

-- TEST: E15 second order with an already-used request_id
-- EXPECT: ERROR 1062
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"h01-demo-001","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
ROLLBACK;

-- ------------------------------------------------------------
-- AUTO_INCREMENT rules: appending a payment to order_dv.payments
-- (order h01-demo-001 already has two payments)
-- ------------------------------------------------------------

-- TEST: E16 new payment without an id next to existing payments (generated/explicit mix)
-- EXPECT: ERROR 6560
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
UPDATE order_dv SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'business_id', 1, 'request_id', 'e16-payment', 'payment_type', 'installment', 'method', 'cash', 'amount', 10.00))
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E17 new payment with an explicit id given as a value (@next_id)
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SET @next_id = (SELECT MAX(id) + 1 FROM payments);
SELECT @next_id AS explicit_new_payment_id;
UPDATE order_dv SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', @next_id, 'business_id', 1, 'request_id', 'e17-payment', 'payment_type', 'installment', 'method', 'cash', 'amount', 10.00))
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT id, request_id, amount FROM payments WHERE order_id = JSON_VALUE(@doc, '$._id') ORDER BY id;
ROLLBACK;

-- TEST: E18 new payment with an explicit id from a subquery inside the UPDATE (E24)
-- EXPECT: ERROR 6560
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
UPDATE order_dv SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments'),
    'business_id', 1, 'request_id', 'e18-payment', 'payment_type', 'installment', 'method', 'cash', 'amount', 10.00))
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- ------------------------------------------------------------
-- Refunds: a payment is corrected with a new refund payment, never edited
-- ------------------------------------------------------------

-- TEST: REFUND1 agent inserts a -500.00 refund for seed-order-002 through payment_dv
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @order_id = (SELECT JSON_VALUE(data, '$._id') FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
INSERT INTO payment_dv VALUES(JSON_OBJECT(
    'business_id', 1, 'request_id', 'refund1-seed-order-002', 'payment_type', 'refund',
    'method', 'upi', 'amount', -500.00, 'order', JSON_OBJECT('id', CAST(@order_id AS UNSIGNED))));
SELECT JSON_PRETTY(data) AS refund_payment FROM payment_dv WHERE JSON_VALUE(data, '$.request_id') = 'refund1-seed-order-002';
SELECT JSON_EXTRACT(data, '$.payments') AS order_payments FROM order_dv WHERE JSON_VALUE(data, '$._id') = @order_id;
ROLLBACK;

-- TEST: REFUND2 refund with a positive amount (CHECK chk_payments_amount_sign)
-- EXPECT: ERROR 3819
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @order_id = (SELECT JSON_VALUE(data, '$._id') FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
INSERT INTO payment_dv VALUES(JSON_OBJECT(
    'business_id', 1, 'request_id', 'refund2-seed-order-002', 'payment_type', 'refund',
    'method', 'upi', 'amount', 500.00, 'order', JSON_OBJECT('id', CAST(@order_id AS UNSIGNED))));
ROLLBACK;

-- ------------------------------------------------------------
-- GUARD 5: payments are immutable once inserted (sql/01_schema.sql,
-- trg_payments_guard_immutable). Target: seed-payment-001, the 500.00 UPI
-- advance on seed-order-002.
-- ------------------------------------------------------------

-- TEST: E25 agent changes a payment amount through order_dv
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SET @amount_path = REPLACE(
    JSON_UNQUOTE(JSON_SEARCH(@doc, 'one', 'seed-payment-001', NULL, '$.payments[*].request_id')),
    '.request_id', '.amount');
SELECT @amount_path AS amount_path, JSON_EXTRACT(@doc, @amount_path) AS amount_before;
UPDATE order_dv SET data = JSON_SET(@doc, @amount_path, 1.00)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: E26 admin changes a payment amount with a direct UPDATE on payments
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
SELECT id, amount FROM payments WHERE request_id = 'seed-payment-001';
UPDATE payments SET amount = 1.00 WHERE request_id = 'seed-payment-001';

-- TEST: E25_E26_CHECK payment amount is still 500.00 after E25 and E26
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SELECT JSON_EXTRACT(data, REPLACE(
           JSON_UNQUOTE(JSON_SEARCH(data, 'one', 'seed-payment-001', NULL, '$.payments[*].request_id')),
           '.request_id', '.amount')) AS amount_after
FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002';
