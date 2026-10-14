-- 13_e33_order_id_guard.sql
-- Purpose: the E33 move AFTER order_id was added to the immutable columns of
--          trg_order_items_guard_upd (sql/06_guards_6_7.sql). Same statement
--          as the "before" probe, sql/12_e33_order_id_probe.sql
--          (results/12_e33_order_id_probe.txt, where it was accepted), so the
--          two outputs can be compared side by side. Same block format as
--          sql/04_edge_cases.sql.
--
-- Runs as the admin user (direct UPDATE on the base table: the agent has no
-- grant on order_items, E13), inside transactions that end with ROLLBACK.
-- The real error text is read from the results file. Run after the reset (or
-- after re-applying sql/06) and sql/03-05, 07, 08, 11.
--
-- Facts (seed data): seed-order-002 is business 1; seed-order-005 is
-- business 2. The item moved is the first item of seed-order-002.

-- TEST: E33b admin directly sets order_items.order_id of a business-1 item to the business-2 order seed-order-005
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
START TRANSACTION;
SET @from_order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
SET @to_order = (SELECT id FROM orders WHERE request_id = 'seed-order-005');
SET @item = (SELECT MIN(id) FROM order_items WHERE order_id = @from_order);
SELECT @item AS item_id, @from_order AS from_order, @to_order AS to_order;
UPDATE order_items SET order_id = @to_order WHERE id = @item;
SELECT ROW_COUNT() AS rows_changed;
ROLLBACK;

-- TEST: E33b_UNCHANGED the item is still in seed-order-002 and both orders still have their original two items (nothing was rolled back for it: the UPDATE never took effect)
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
          'PASS: item still in seed-order-002; both orders still have 2 items',
          (SELECT 1 UNION SELECT 2)) AS unchanged_check;

-- TEST: E33c an UPDATE that sets order_id to the value it already has (and changes the item's notes) still passes
-- EXPECT: OK
USE __MYSQL_DB__;
START TRANSACTION;
SET @from_order = (SELECT id FROM orders WHERE request_id = 'seed-order-002');
SET @item = (SELECT MIN(id) FROM order_items WHERE order_id = @from_order);
UPDATE order_items SET order_id = @from_order, notes = 'E33c same order_id' WHERE id = @item;
SELECT ROW_COUNT() AS rows_changed;
SELECT id AS item_id, order_id, notes FROM order_items WHERE id = @item;
ROLLBACK;
