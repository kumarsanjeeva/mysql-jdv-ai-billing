-- 49_guard_1_3_negative.sql
-- Purpose: negative tests for GUARD 1 (CHECK order_items.qty > 0) and GUARD 3
--          (orders.total = subtotal - discount_value + gst_value, 0.01
--          tolerance). Until now only the trigger source was captured for
--          these two (results/40_gst_guard_readonly_check.txt); no run showed
--          them rejecting a bad row. Same block format as
--          sql/04_edge_cases.sql, sql/10 and sql/13.
--
-- Runs as the admin user (default; direct statements on the base tables, the
-- agent has no grant on them, E13). Every statement that changes data sits in
-- a transaction that ends with ROLLBACK. A block that fails stops at the
-- failing statement and the connection closes, which rolls the transaction
-- back; the *_UNCHANGED blocks then check, on a new connection, that nothing
-- was left behind. The real error text is read from the results file.
-- Run after the reset and sql/03-05, 07, 08, 11 (same as sql/13).
--
-- Facts (seed data, sql/01_schema.sql): seed-order-002 is business 1, customer
-- 2, outlet 1, subtotal 1290.00, discount_value 40.00, gst_value 62.50,
-- total 1312.50, two items (Vanilla Cake qty 1, Chocolate Truffle Pastry
-- qty 6). Product 3 is Chocolate Truffle Pastry, business 1, catalog price
-- 90.00, so GUARD 6 and GUARD 8 should accept the new item and the CHECK
-- should be the only thing rejecting it. That is an expectation, not a
-- finding: if a trigger rejects the row first, the error code shows it.
--
-- Expected results (hypotheses; the run is the finding):
--   E49_PRE  OK, read-only: prints seed-order-002's amounts and items and
--            fails if they differ from the Facts above (then nothing else
--            should be run)
--   E34a, E34b  ERROR 3819 (chk_order_items_qty)
--   E34c  OK, qty 1 at the catalog price is accepted (control), rolled back
--   E34_UNCHANGED  OK, seed-order-002 still has its 2 items, no E34 row exists
--   E35a  ERROR 1644 (GUARD 3, UPDATE trigger), total 1.00 off
--   E35b  ERROR 1644 (GUARD 3, INSERT trigger)
--   E35c  OK, 1 row changed (a balanced change passes), then rolled back
--   E35d  OK, total off by exactly 0.01 (the tolerance is "> 0.01"), rolled back
--   E35e  ERROR 1644 (GUARD 3), total off by 0.02
--   E35_UNCHANGED  OK, seed-order-002 still 1290.00 / 40.00 / 62.50 / 1312.50,
--                  no order e35b-wrong-total exists

-- ------------------------------------------------------------
-- Pre-check (read-only): the data the tests below assume
-- ------------------------------------------------------------

-- TEST: E49_PRE seed-order-002 has the amounts and items stated in the header (read-only)
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT id, business_id, customer_id, outlet_id, subtotal, discount_value, gst_value, total
  FROM orders WHERE request_id = 'seed-order-002';
SELECT oi.id AS item_id, oi.product_id, oi.name, oi.qty, oi.price
  FROM order_items oi JOIN orders o ON o.id = oi.order_id
 WHERE o.request_id = 'seed-order-002' ORDER BY oi.id;
-- A failed assertion is an error, so the verdict would show SURPRISE.
SELECT IF((SELECT COUNT(*) FROM orders WHERE request_id = 'seed-order-002' AND business_id = 1
             AND subtotal = 1290.00 AND discount_value = 40.00 AND gst_value = 62.50 AND total = 1312.50) = 1
          AND (SELECT COUNT(*) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')) = 2
          AND (SELECT SUM(qty) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')) = 7
          AND (SELECT price FROM products WHERE id = 3 AND business_id = 1) = 90.00,
          'PASS: seed-order-002 matches the header values; product 3 is business 1 at 90.00',
          (SELECT 1 UNION SELECT 2)) AS precheck;

-- ------------------------------------------------------------
-- GUARD 1: qty must be greater than 0
-- ------------------------------------------------------------

-- TEST: E34a admin inserts an order_items row with qty = 0 into seed-order-002 (valid product 3 at its catalog price)
-- EXPECT: ERROR 3819
USE __MYSQL_DB__;
START TRANSACTION;
SET @order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                         discount_exempt, gst_value, discount_value)
VALUES (@order, 3, 'E34a qty zero', 0, 90.00, 5.00, 0, 1, 0, 0.00, 0.00);
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E34b admin inserts an order_items row with qty = -1 into seed-order-002 (valid product 3 at its catalog price)
-- EXPECT: ERROR 3819
USE __MYSQL_DB__;
START TRANSACTION;
SET @order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                         discount_exempt, gst_value, discount_value)
VALUES (@order, 3, 'E34b qty minus one', -1, 90.00, 5.00, 0, 1, 0, 0.00, 0.00);
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E34c control: admin inserts an order_items row with qty = 1 into seed-order-002 (valid product 3 at its catalog price), then rolls back
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
SET @order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                         discount_exempt, gst_value, discount_value)
VALUES (@order, 3, 'E34c qty one', 1, 90.00, 5.00, 0, 1, 0, 0.00, 0.00);
SELECT ROW_COUNT() AS rows_changed;
SELECT COUNT(*) AS items_in_order_inside_transaction FROM order_items WHERE order_id = @order;
ROLLBACK;

-- TEST: E34_UNCHANGED seed-order-002 still has its original 2 items (qty 1 and 6) and no E34 row exists
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT oi.id AS item_id, oi.name, oi.qty FROM order_items oi JOIN orders o ON o.id = oi.order_id
 WHERE o.request_id = 'seed-order-002' ORDER BY oi.id;
-- A failed assertion is an error, so the verdict would show SURPRISE.
SELECT IF((SELECT COUNT(*) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')) = 2
          AND (SELECT SUM(qty) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')) = 7
          AND (SELECT COUNT(*) FROM order_items WHERE name LIKE 'E34%') = 0,
          'PASS: seed-order-002 has 2 items (qty total 7); no E34 row exists',
          (SELECT 1 UNION SELECT 2)) AS unchanged_check;

-- ------------------------------------------------------------
-- GUARD 3: total must equal subtotal - discount_value + gst_value
-- ------------------------------------------------------------

-- TEST: E35a admin sets seed-order-002 total to 1313.50 (1.00 above subtotal - discount_value + gst_value = 1312.50)
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
START TRANSACTION;
SELECT id, subtotal, discount_value, gst_value, total FROM orders WHERE request_id = 'seed-order-002';
UPDATE orders SET total = 1313.50 WHERE request_id = 'seed-order-002';
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E35b admin inserts an order (business 1, customer 1, outlet 1) with subtotal 900.00, gst_value 45.00 and total 1000.00 (should be 945.00)
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO orders (business_id, outlet_id, customer_id, request_id, order_status,
                    subtotal, discount_type, discount_value, gst_value, total)
VALUES (1, 1, 1, 'e35b-wrong-total', 'confirmed', 900.00, 'amount', 0.00, 45.00, 1000.00);
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E35c admin makes a balanced change to seed-order-002 (discount_value 40.00 -> 50.00 and total 1312.50 -> 1302.50) and it is accepted, then rolled back
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
UPDATE orders SET discount_value = 50.00, total = 1302.50 WHERE request_id = 'seed-order-002';
SELECT ROW_COUNT() AS rows_changed;
SELECT id, subtotal, discount_value, gst_value, total FROM orders WHERE request_id = 'seed-order-002';
ROLLBACK;

-- TEST: E35d tolerance: admin sets seed-order-002 total to 1312.51 (off by exactly 0.01; the trigger rejects only a difference greater than 0.01), then rolls back
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
UPDATE orders SET total = 1312.51 WHERE request_id = 'seed-order-002';
SELECT ROW_COUNT() AS rows_changed;
SELECT id, subtotal, discount_value, gst_value, total FROM orders WHERE request_id = 'seed-order-002';
ROLLBACK;

-- TEST: E35e tolerance: admin sets seed-order-002 total to 1312.52 (off by 0.02)
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
START TRANSACTION;
UPDATE orders SET total = 1312.52 WHERE request_id = 'seed-order-002';
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E35_UNCHANGED seed-order-002 still has subtotal 1290.00, discount_value 40.00, gst_value 62.50, total 1312.50 and no order e35b-wrong-total exists
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT id, request_id, subtotal, discount_value, gst_value, total FROM orders
 WHERE request_id IN ('seed-order-002', 'e35b-wrong-total');
-- A failed assertion is an error, so the verdict would show SURPRISE.
SELECT IF((SELECT COUNT(*) FROM orders WHERE request_id = 'seed-order-002' AND subtotal = 1290.00
             AND discount_value = 40.00 AND gst_value = 62.50 AND total = 1312.50) = 1
          AND (SELECT COUNT(*) FROM orders WHERE request_id = 'e35b-wrong-total') = 0,
          'PASS: seed-order-002 has its original amounts; no e35b-wrong-total order exists',
          (SELECT 1 UNION SELECT 2)) AS unchanged_check;
