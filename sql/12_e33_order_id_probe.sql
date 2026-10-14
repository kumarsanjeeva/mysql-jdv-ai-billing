-- 12_e33_order_id_probe.sql
-- Purpose: PROBE ONLY -- can order_items.order_id be changed after insert?
--          E32 only tested a duplicate-id insert through order_dv, not a
--          change of the item's order, so whether to lock order_id is still
--          undecided. This probe finds out; nothing is added based on it
--          until the result has been reviewed.
--          Same block format as sql/04_edge_cases.sql.
--
-- Runs as the admin user (direct UPDATE on the base table: the agent has no
-- grant on order_items, E13), inside a transaction that ends with ROLLBACK.
-- A second block asserts the row is back. The EXPECT line is a hypothesis
-- ("the change is accepted, i.e. the gap exists"); the real output is the
-- finding. Run after the reset and sql/03-05, 07, 08, 11.
--
-- Facts (seed data): seed-order-002 is business 1 (customer 2, outlet 1);
-- seed-order-005 is business 2. The item moved is the first item of
-- seed-order-002 (a business-1 product).

-- TEST: E33 admin directly sets order_items.order_id of a business-1 item to the business-2 order seed-order-005
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
SET @from_order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
SET @to_order = (SELECT id FROM orders WHERE request_id = 'seed-order-005');
SET @item = (SELECT MIN(id) FROM order_items WHERE order_id = @from_order);
SELECT @item AS item_id, @from_order AS from_order, @to_order AS to_order,
       (SELECT business_id FROM orders WHERE id = @from_order) AS from_order_business,
       (SELECT business_id FROM orders WHERE id = @to_order) AS to_order_business,
       (SELECT p.business_id FROM order_items oi JOIN products p ON p.id = oi.product_id WHERE oi.id = @item) AS item_product_business;
UPDATE order_items SET order_id = @to_order WHERE id = @item;
SELECT ROW_COUNT() AS rows_changed;
-- If accepted: the item now sits in another business's order.
SELECT oi.id AS item_id, oi.order_id AS order_id_now, o.request_id AS order_request_id, o.business_id AS order_business,
       p.business_id AS item_product_business
  FROM order_items oi JOIN orders o ON o.id = oi.order_id JOIN products p ON p.id = oi.product_id
 WHERE oi.id = @item;
ROLLBACK;

-- TEST: E33_ROLLBACK_CHECK the item is back in seed-order-002 and both orders have their original two items
-- EXPECT: OK
USE __MYSQL_DB__;
SELECT oi.id AS item_id, oi.order_id, o.request_id FROM order_items oi JOIN orders o ON o.id = oi.order_id
 WHERE o.request_id IN ('seed-order-002', 'seed-order-005') ORDER BY o.request_id, oi.id;
-- A failed assertion is an error, so the verdict would show SURPRISE.
SELECT IF((SELECT COUNT(*) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')) = 2
          AND (SELECT COUNT(*) FROM order_items WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-005')) = 2
          AND (SELECT order_id FROM order_items WHERE id = (SELECT MIN(id) FROM order_items
                 WHERE order_id = (SELECT id FROM orders WHERE request_id = 'seed-order-002')))
              = (SELECT id FROM orders WHERE request_id = 'seed-order-002'),
          'PASS: item back in seed-order-002; both orders still have 2 items',
          (SELECT 1 UNION SELECT 2)) AS rollback_check;
