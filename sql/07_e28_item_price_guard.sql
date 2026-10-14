-- 07_e28_item_price_guard.sql
-- Purpose: edge case E28 -- GUARD 6 (sql/06_guards_6_7.sql): an order item's
--          price must equal the current catalog price when it is inserted,
--          and price, product_id and product_variant_id can never change
--          afterwards. Same block format as sql/04_edge_cases.sql:
--            -- TEST: <id> <description>
--            -- EXPECT: OK | ERROR | ERROR <code>
--            -- AS: agent            (optional; default is the admin user)
--
-- Runs against the demo database after scripts/reset_db.py (which includes
-- sql/06_guards_6_7.sql) and sql/03_dml_demos.sql. Everything is written as
-- the agent user through order_dv, with two exceptions that cannot be done
-- through a view the agent can write to: E28d1/E28d3/E28d4 change, restore and
-- check a catalog price as admin (catalog_dv is read-only, E04).
--
-- Expected error codes are NOT guessed: blocks that should be rejected say
-- `EXPECT: ERROR` and the real code and message are read from the results
-- file and written up in docs/findings.md.
--
-- Every block except E28d1 and E28d3 runs inside a transaction and ends with
-- ROLLBACK (a failing statement ends the session, which also rolls back).
-- E28d1 COMMITS a real catalog price change, so it has safeguards: it first
-- proves the original price is the recorded value (900.00; the block stops
-- before changing anything if not), E28d3 puts it back, and E28d4 asserts it
-- is back (a failed assertion is an error, so the verdict shows SURPRISE).
--
-- Catalog facts used (seed data): product 1 Black Forest Cake 900.00 with
-- variants 1 (0.5 kg, 500.00), 2 (1 kg, 900.00), 3 (1.5 kg, 1300.00);
-- product 2 Vanilla Cake, variant 5 (1 kg, 750.00); product 3 Chocolate
-- Truffle Pastry 90.00, no variants. Business 1, outlet 1, customer 1.
-- seed-order-001's first item is Black Forest Cake (variant 2) at 900.00.

-- ------------------------------------------------------------
-- E28a: inserts at the right price
-- ------------------------------------------------------------

-- TEST: E28a item inserted at the catalog variant price (900.00)
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28a-correct-price","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
SELECT JSON_VALUE(data, '$.items[0].price') AS e28a_item_price FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e28a-correct-price';
ROLLBACK;

-- TEST: E28a2 same item with the price sent as the JSON integer 900 (no decimals)
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @base = '{"business_id":1,"request_id":"e28a2-integer-price","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}';
SELECT JSON_EXTRACT(JSON_SET(@base, '$.items[0].price', 900), '$.items[0].price') AS price_as_sent;
INSERT INTO order_dv VALUES(JSON_SET(@base, '$.items[0].price', 900));
SELECT JSON_VALUE(data, '$.items[0].price') AS e28a2_item_price FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e28a2-integer-price';
ROLLBACK;

-- TEST: E28a3 product-only item (no variant) inserted at the product price (90.00)
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28a3-product-only","order_status":"confirmed","subtotal":90.00,"discount_type":"amount","discount_value":0.00,"gst_value":4.50,"total":94.50,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Chocolate Truffle Pastry","qty":1,"price":90.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":4.50,"discount_value":0.00,"product":{"id":3}}]}');
SELECT JSON_VALUE(data, '$.items[0].price') AS e28a3_item_price FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e28a3-product-only';
ROLLBACK;

-- ------------------------------------------------------------
-- E28b: inserts the guard must reject
-- ------------------------------------------------------------

-- TEST: E28b item with a variant inserted at the wrong price (100.00 instead of 900.00)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @base = '{"business_id":1,"request_id":"e28b-wrong-price","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}';
INSERT INTO order_dv VALUES(JSON_SET(@base, '$.items[0].price', 100.00));
ROLLBACK;

-- TEST: E28b2 product-only item inserted at the wrong price (80.00 instead of 90.00)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28b2-wrong-product-price","order_status":"confirmed","subtotal":80.00,"discount_type":"amount","discount_value":0.00,"gst_value":4.00,"total":84.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Chocolate Truffle Pastry","qty":1,"price":80.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":4.00,"discount_value":0.00,"product":{"id":3}}]}');
ROLLBACK;

-- TEST: E28b3 item with neither a product nor a variant (nothing to check the price against)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28b3-no-catalog-link","order_status":"confirmed","subtotal":100.00,"discount_type":"amount","discount_value":0.00,"gst_value":5.00,"total":105.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Custom cake","qty":1,"price":100.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":5.00,"discount_value":0.00}]}');
ROLLBACK;

-- TEST: E28b4 variant of another product (Vanilla variant 5, 750.00) attached to Black Forest Cake (product 1)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @base = '{"business_id":1,"request_id":"e28b4-variant-of-other-product","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}';
INSERT INTO order_dv VALUES(JSON_SET(@base, '$.items[0].product_variant_id', 5, '$.items[0].price', 750.00));
ROLLBACK;

-- ------------------------------------------------------------
-- E28c: changes to an existing item
-- ------------------------------------------------------------

-- TEST: E28c existing item's price changed through order_dv (900.00 -> 1.00)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
SELECT JSON_VALUE(@doc, '$.items[0].name') AS item_name, JSON_VALUE(@doc, '$.items[0].price') AS price_before;
UPDATE order_dv SET data = JSON_SET(@doc, '$.items[0].price', 1.00)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E28c2 existing item's variant changed through order_dv (variant 2 -> variant 3)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
SELECT JSON_VALUE(@doc, '$.items[0].product_variant_id') AS variant_before;
UPDATE order_dv SET data = JSON_SET(@doc, '$.items[0].product_variant_id', 3)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E28c3 existing item's product changed through order_dv (product 1 -> product 2)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
SELECT JSON_VALUE(@doc, '$.items[0].product.id') AS product_before;
UPDATE order_dv SET data = JSON_SET(@doc, '$.items[0].product.id', 2)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
ROLLBACK;

-- TEST: E28c4 a harmless change to the same item (its notes) is still allowed
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
UPDATE order_dv SET data = JSON_SET(@doc, '$.items[0].notes', 'no candles')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT JSON_VALUE(data, '$.items[0].notes') AS notes_after, JSON_VALUE(data, '$.items[0].price') AS price_after
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001';
ROLLBACK;

-- ------------------------------------------------------------
-- E28d: a later catalog price change must not touch existing items.
-- Black Forest Cake 1 kg (variant 2): 900.00 -> 950.00, committed; then
-- restored. E28d1..E28d4 run in this order.
-- ------------------------------------------------------------

-- TEST: E28d1 admin raises the catalog price of variant 2 from 900.00 to 950.00 (committed)
-- EXPECT: OK
USE __MYSQL_DB__;
-- Safeguard: stop here (error, nothing changed) unless the original price is the recorded 900.00.
SELECT IF(price = 900.00, CONCAT('original price recorded: ', price), (SELECT 1 UNION SELECT 2)) AS original_price
  FROM product_variants WHERE id = 2;
UPDATE product_variants SET price = 950.00 WHERE id = 2 AND price = 900.00;
SELECT ROW_COUNT() AS rows_changed;
SELECT id, price AS catalog_price_now FROM product_variants WHERE id = 2;

-- TEST: E28d2 agent: the old item is unchanged and the order still reads and writes back through order_dv
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001');
SELECT JSON_VALUE(@doc, '$.items[0].price' RETURNING DECIMAL(10,2)) AS order_item_price,
       (SELECT v.price FROM catalog_dv c,
               JSON_TABLE(c.data, '$.variants[*]' COLUMNS (id BIGINT PATH '$.id', price DECIMAL(10,2) PATH '$.price')) v
         WHERE JSON_VALUE(c.data, '$._id') = 1 AND v.id = 2) AS catalog_price_now;
-- Assertion: the order item still says 900.00 (a mismatch is an error, so the verdict shows SURPRISE).
SELECT IF(JSON_VALUE(@doc, '$.items[0].price' RETURNING DECIMAL(10,2)) = 900.00,
          'old order item unchanged: 900.00', (SELECT 1 UNION SELECT 2)) AS old_item_check;
START TRANSACTION;
UPDATE order_dv SET data = JSON_SET(@doc, '$.delivery_address', 'e28d round trip')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT JSON_VALUE(data, '$.delivery_address') AS address_after, JSON_VALUE(data, '$.items[0].price') AS item_price_after
  FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-001';
ROLLBACK;

-- TEST: E28d2b agent: a NEW item at the old price 900.00 is now rejected (catalog says 950.00)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28d2b-old-price","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
ROLLBACK;

-- TEST: E28d2c agent: a NEW item at the new price 950.00 is accepted
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e28d2c-new-price","order_status":"confirmed","subtotal":950.00,"discount_type":"amount","discount_value":0.00,"gst_value":47.50,"total":997.50,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":950.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":47.50,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}]}');
SELECT JSON_VALUE(data, '$.items[0].price') AS e28d2c_item_price FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'e28d2c-new-price';
ROLLBACK;

-- TEST: E28d3 admin restores the catalog price of variant 2 to the recorded 900.00
-- EXPECT: OK
USE __MYSQL_DB__;
UPDATE product_variants SET price = 900.00 WHERE id = 2;
SELECT id, price AS catalog_price_after_restore FROM product_variants WHERE id = 2;

-- TEST: E28d4 assertion: the catalog price of variant 2 is back to the recorded 900.00
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT IF(price = 900.00, CONCAT('PASS: catalog price restored to ', price), (SELECT 1 UNION SELECT 2)) AS restore_check
  FROM product_variants WHERE id = 2;
SELECT COUNT(*) AS variants_not_matching_seed
  FROM product_variants WHERE (id = 1 AND price <> 500.00) OR (id = 2 AND price <> 900.00) OR (id = 3 AND price <> 1300.00);
