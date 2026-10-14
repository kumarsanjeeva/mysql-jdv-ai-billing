-- 11_e30_guard_8.sql
-- Purpose: edge cases E30/E31/E32 AFTER GUARD 8 and GUARD 8b exist
--          (sql/09_guard_8.sql). The same probes as the "before" script,
--          sql/10_e30_before_guard_8.sql (results/10_e30_before_guard_8.txt),
--          so the two outputs can be compared side by side. Same block format
--          as sql/04_edge_cases.sql.
--
-- Runs against the demo database after scripts/reset_db.py (which includes
-- sql/06 and sql/09), sql/03_dml_demos.sql and sql/04/05. Everything runs as
-- the agent user through order_dv, inside a transaction that ends with
-- ROLLBACK, except the two blocks marked admin.
--
-- Rejected blocks say `EXPECT: ERROR` and the real code and message are read
-- from the results file; the exact message decides WHICH guard stopped them.
--
-- Facts (seed data): business 1 = products 1-6, variants 1-7, outlets 1-2,
-- customers 1-3. Business 2 = products 7-10 (7 = Rainbow Cake, 1000.00),
-- variants 8-9 (both Rainbow Cake; 9 = 1 kg at 1000.00), outlet 3,
-- customers 4-5. seed-order-002 is business 1; seed-order-005 is business 2.

-- ------------------------------------------------------------
-- Same-tenant items still work
-- ------------------------------------------------------------

-- TEST: E30a business-1 order with business-1 product 1 and its variant 2 at 900.00
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30a-same-tenant","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","flavor":"Chocolate","size":1.00,"unit":"kg","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
SELECT JSON_VALUE(data, '$.business_id') AS order_business, JSON_VALUE(data, '$.items[0].product.id') AS item_product_id
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e30a-same-tenant';
ROLLBACK;

-- TEST: E30a2 business-2 order (outlet 3, customer 4) with business-2 product 7 and its variant 9 at 1000.00
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":2,"request_id":"e30a2-same-tenant-business-2","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":3},"customer":{"id":4},"items":[{"name":"Rainbow Cake","flavor":"Rainbow","size":1.00,"unit":"kg","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product":{"id":7},"product_variant_id":9}]}');
SELECT JSON_VALUE(data, '$.business_id') AS order_business, JSON_VALUE(data, '$.items[0].product.id') AS item_product_id
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e30a2-same-tenant-business-2';
ROLLBACK;

-- ------------------------------------------------------------
-- Cross-tenant items are rejected (the same probes as E30b-e before GUARD 8)
-- ------------------------------------------------------------

-- TEST: E30b business-1 order with business-2 product 7 (Rainbow Cake) at its own catalog price
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30b-cross-tenant-product","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product":{"id":7}}]}');
ROLLBACK;

-- TEST: E30c business-1 order with a business-2 variant only (variant 9, Rainbow 1 kg) at its own price
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30c-cross-tenant-variant","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","flavor":"Rainbow","size":1.00,"unit":"kg","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product_variant_id":9}]}');
ROLLBACK;

-- TEST: E30d business-1 order with business-2 product 7 AND its variant 9 (consistent with each other, wrong business)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30d-cross-tenant-both","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","flavor":"Rainbow","size":1.00,"unit":"kg","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product":{"id":7},"product_variant_id":9}]}');
ROLLBACK;

-- TEST: E30e business-2 order (outlet 3, customer 4) with business-1 product 1 (Black Forest Cake) at its own price
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":2,"request_id":"e30e-cross-tenant-reverse","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":3},"customer":{"id":4},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1}}]}');
ROLLBACK;

-- TEST: E30f wrong tenant AND wrong price (business-2 product 7 at 100.00 in a business-1 order): which guard reports?
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30f-wrong-tenant-and-price","order_status":"confirmed","subtotal":100.00,"discount_type":"amount","discount_value":0.00,"gst_value":5.00,"total":105.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","qty":1,"price":100.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":5.00,"discount_value":0.00,"product":{"id":7}}]}');
ROLLBACK;

-- ------------------------------------------------------------
-- An order's business cannot change (GUARD 8b)
-- Target: seed-order-002 (business 1, customer 2, outlet 1).
-- ------------------------------------------------------------

-- TEST: E31a change only business_id (1 -> 2); customer and outlet still belong to business 1
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
UPDATE order_dv SET data = JSON_SET(@doc, '$.business_id', 2)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E31b change business_id (1 -> 2) together with customer (-> 4) and outlet (-> 3), both business 2
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
UPDATE order_dv SET data = JSON_SET(@doc, '$.business_id', 2, '$.customer.id', 4, '$.outlet.id', 3)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E31c admin changes business_id, customer_id and outlet_id together with a direct UPDATE on orders
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
START TRANSACTION;
UPDATE orders SET business_id = 2, customer_id = 4, outlet_id = 3 WHERE request_id = 'seed-order-002';
ROLLBACK;

-- TEST: E31d an ordinary change to the same order (its status) is still allowed
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
UPDATE order_dv SET data = JSON_SET(@doc, '$.order_status', 'ready')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT JSON_VALUE(data, '$.order_status') AS status_after, JSON_VALUE(data, '$.business_id') AS business_after
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001';
ROLLBACK;

-- ------------------------------------------------------------
-- E32 again: appending another order's item (with its existing id) is still
-- rejected. This is a duplicate-id insert, not a move of the row.
-- ------------------------------------------------------------

-- TEST: E32 append an existing item of order seed-order-002 (business 1) to seed-order-005 (business 2), keeping its id (duplicate-id insert, not a move)
-- EXPECT: ERROR 1062
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @a = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SET @b = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-005');
SET @item = JSON_EXTRACT(@a, '$.items[1]');
UPDATE order_dv SET data = JSON_ARRAY_APPEND(@b, '$.items', CAST(@item AS JSON))
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@b, '$._id');
ROLLBACK;

-- ------------------------------------------------------------
-- Rollback proof (admin, base tables): nothing was left behind.
-- A failed assertion is an error, so the verdict shows SURPRISE.
-- ------------------------------------------------------------

-- TEST: E30_ROLLBACK_CHECK seed-order-001/002/005 unchanged and no e30 test orders left
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT id, request_id, business_id, customer_id, outlet_id, order_status
  FROM orders WHERE request_id IN ('seed-order-001', 'seed-order-002', 'seed-order-005') ORDER BY id;
SELECT IF((SELECT business_id FROM orders WHERE request_id = 'seed-order-002') = 1
          AND (SELECT customer_id FROM orders WHERE request_id = 'seed-order-002') = 2
          AND (SELECT outlet_id FROM orders WHERE request_id = 'seed-order-002') = 1
          AND (SELECT order_status FROM orders WHERE request_id = 'seed-order-001') = 'confirmed'
          AND (SELECT COUNT(*) FROM orders WHERE request_id LIKE 'e30%') = 0,
          'PASS: seed orders unchanged, no e30 test orders left', (SELECT 1 UNION SELECT 2)) AS rollback_check;
