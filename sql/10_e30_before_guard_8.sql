-- 10_e30_before_guard_8.sql
-- Purpose: probes run BEFORE GUARD 8 exists, to show with real output that the
--          tenant gaps described in docs/findings.md are real. After GUARD 6/7
--          and before GUARD 8 (sql/09_guard_8.sql). Output is kept as
--          results/10_e30_before_guard_8.txt and must not be overwritten.
--          Same block format as sql/04_edge_cases.sql.
--
-- Everything runs as the agent user through order_dv, inside a transaction that
-- ends with ROLLBACK, so nothing is left behind.
--
-- EXPECT lines are hypotheses to be confirmed or refuted by the run: for the
-- gap probes "OK" means "the gap exists" and the verdict SURPRISE means it
-- does not. Either way the real output is the finding.
--
-- Facts (seed data): business 1 = products 1-6, variants 1-7, outlets 1-2,
-- customers 1-3. Business 2 = products 7-10 (7 = Rainbow Cake, 1000.00),
-- variants 8-9 (both Rainbow Cake; 9 = 1 kg at 1000.00), outlet 3,
-- customers 4-5. seed-order-002 is business 1 (customer 2, outlet 1, one
-- payment); seed-order-005 is business 2.

-- ------------------------------------------------------------
-- E30: can an order carry an item from another business's catalog?
-- ------------------------------------------------------------

-- TEST: E30b business-1 order with business-2 product 7 (Rainbow Cake) at its own catalog price
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30b-cross-tenant-product","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product":{"id":7}}]}');
SELECT JSON_VALUE(o.data, '$.business_id') AS order_business,
       JSON_VALUE(o.data, '$.items[0].product.id') AS item_product_id,
       (SELECT JSON_VALUE(c.data, '$.business_id') FROM catalog_dv c WHERE JSON_VALUE(c.data, '$._id') = 7) AS product_business
  FROM order_dv o WHERE JSON_VALUE(o.data, '$.request_id') = 'e30b-cross-tenant-product';
ROLLBACK;

-- TEST: E30c business-1 order with a business-2 variant only (variant 9, Rainbow 1 kg) at its own price
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30c-cross-tenant-variant","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","flavor":"Rainbow","size":1.00,"unit":"kg","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product_variant_id":9}]}');
SELECT JSON_VALUE(o.data, '$.business_id') AS order_business,
       JSON_VALUE(o.data, '$.items[0].product_variant_id') AS item_variant_id,
       (SELECT JSON_VALUE(c.data, '$.business_id') FROM catalog_dv c WHERE JSON_VALUE(c.data, '$._id') = 7) AS variant_product_business
  FROM order_dv o WHERE JSON_VALUE(o.data, '$.request_id') = 'e30c-cross-tenant-variant';
ROLLBACK;

-- TEST: E30d business-1 order with business-2 product 7 AND its variant 9 (consistent with each other, wrong business)
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e30d-cross-tenant-both","order_status":"confirmed","subtotal":1000.00,"discount_type":"amount","discount_value":0.00,"gst_value":50.00,"total":1050.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Rainbow Cake","flavor":"Rainbow","size":1.00,"unit":"kg","qty":1,"price":1000.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":50.00,"discount_value":0.00,"product":{"id":7},"product_variant_id":9}]}');
SELECT JSON_VALUE(o.data, '$.business_id') AS order_business,
       JSON_VALUE(o.data, '$.items[0].product.id') AS item_product_id,
       JSON_VALUE(o.data, '$.items[0].product_variant_id') AS item_variant_id
  FROM order_dv o WHERE JSON_VALUE(o.data, '$.request_id') = 'e30d-cross-tenant-both';
ROLLBACK;

-- TEST: E30e business-2 order (outlet 3, customer 4) with business-1 product 1 (Black Forest Cake) at its own price
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":2,"request_id":"e30e-cross-tenant-reverse","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":3},"customer":{"id":4},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1}}]}');
SELECT JSON_VALUE(o.data, '$.business_id') AS order_business,
       JSON_VALUE(o.data, '$.items[0].product.id') AS item_product_id,
       (SELECT JSON_VALUE(c.data, '$.business_id') FROM catalog_dv c WHERE JSON_VALUE(c.data, '$._id') = 1) AS product_business
  FROM order_dv o WHERE JSON_VALUE(o.data, '$.request_id') = 'e30e-cross-tenant-reverse';
ROLLBACK;

-- ------------------------------------------------------------
-- E31: can an existing order's business_id be changed through order_dv?
-- Target: seed-order-002 (business 1, customer 2, outlet 1, one payment of
-- business 1, items of business-1 products).
-- ------------------------------------------------------------

-- TEST: E31a change only business_id (1 -> 2); customer and outlet still belong to business 1
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SELECT JSON_VALUE(@doc, '$.business_id') AS business_before;
UPDATE order_dv SET data = JSON_SET(@doc, '$.business_id', 2)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E31b change business_id (1 -> 2) together with customer (-> 4) and outlet (-> 3), both business 2
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SELECT JSON_VALUE(@doc, '$.business_id') AS business_before,
       JSON_VALUE(@doc, '$.customer.id') AS customer_before, JSON_VALUE(@doc, '$.outlet.id') AS outlet_before;
UPDATE order_dv SET data = JSON_SET(@doc, '$.business_id', 2, '$.customer.id', 4, '$.outlet.id', 3)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
-- If the update was accepted: the order is now business 2, while its payment and items are still business 1's.
SELECT JSON_VALUE(data, '$.business_id') AS order_business_after,
       JSON_VALUE(data, '$.customer.id') AS customer_after, JSON_VALUE(data, '$.outlet.id') AS outlet_after,
       JSON_EXTRACT(data, '$.payments[*].business_id') AS payment_businesses,
       JSON_EXTRACT(data, '$.items[*].product.id') AS item_product_ids
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002';
ROLLBACK;

-- ------------------------------------------------------------
-- E32: can an item be moved to another order (another business) through order_dv?
-- The item cannot be moved by editing a column (order_id is not in the
-- document), so the probe appends seed-order-002's pastry item, with its own
-- id, to the items of seed-order-005 (business 2) and writes that order back.
-- ------------------------------------------------------------

-- TEST: E32 append an existing item of order seed-order-002 (business 1) to seed-order-005 (business 2), keeping its id
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @a = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SET @b = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-005');
SET @item = JSON_EXTRACT(@a, '$.items[1]');
SELECT JSON_VALUE(@item, '$.id') AS moved_item_id, JSON_VALUE(@item, '$.name') AS moved_item_name,
       JSON_LENGTH(@a, '$.items') AS a_items_before, JSON_LENGTH(@b, '$.items') AS b_items_before;
-- @item is a user variable, so it holds text, not JSON: without the CAST the
-- append adds a JSON string and fails with ERROR 6485 (the first version of
-- this probe did exactly that; see docs/findings.md).
UPDATE order_dv SET data = JSON_ARRAY_APPEND(@b, '$.items', CAST(@item AS JSON))
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@b, '$._id');
-- If accepted: which order holds the item now?
SELECT JSON_VALUE(data, '$.request_id') AS order_request_id, JSON_VALUE(data, '$.business_id') AS order_business,
       JSON_LENGTH(data, '$.items') AS items_after, JSON_EXTRACT(data, '$.items[*].id') AS item_ids_after
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') IN ('seed-order-002', 'seed-order-005')
 ORDER BY order_request_id;
ROLLBACK;

-- ------------------------------------------------------------
-- Rollback proof. E31b and E32 may have changed seed-order-002 / seed-order-005
-- inside their transactions; every probe rolls back. This block (admin, reads
-- the base tables) asserts the "before" state is intact, so the evidence above
-- can be trusted. A failed assertion is an error, so the verdict shows SURPRISE.
-- ------------------------------------------------------------

-- TEST: E30_ROLLBACK_CHECK seed-order-002 is back on business 1 with customer 2 and outlet 1; items and payment untouched
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT id, request_id, business_id, customer_id, outlet_id FROM orders WHERE request_id IN ('seed-order-002', 'seed-order-005') ORDER BY id;
SELECT IF(o.business_id = 1 AND o.customer_id = 2 AND o.outlet_id = 1,
          'PASS: seed-order-002 is business 1, customer 2, outlet 1', (SELECT 1 UNION SELECT 2)) AS order_restored
  FROM orders o WHERE o.request_id = 'seed-order-002';
SELECT IF((SELECT COUNT(*) FROM order_items WHERE order_id = o2.id) = 2
          AND (SELECT COUNT(*) FROM order_items WHERE order_id = o5.id) = 2
          AND (SELECT COUNT(*) FROM payments WHERE order_id = o2.id AND business_id = 1) = 1
          AND (SELECT COUNT(*) FROM orders WHERE request_id LIKE 'e30%') = 0,
          'PASS: items per order unchanged (2 and 2), payment still business 1, no e30 test orders left',
          (SELECT 1 UNION SELECT 2)) AS contents_restored
  FROM orders o2, orders o5 WHERE o2.request_id = 'seed-order-002' AND o5.request_id = 'seed-order-005';
