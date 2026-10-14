-- ============================================================
-- 09_guard_8.sql
-- GUARD 8 -- tenant consistency of order items, plus GUARD 8b -- an order's
-- business can never change. Runs after sql/06_guards_6_7.sql;
-- scripts/reset_db.py runs it right after 06. Safe to re-run: each trigger
-- is dropped first.
--
-- Why: GUARD 4 checks an order's customer and outlet, GUARD 7 a payment's
-- business -- nothing checked the items. Before this file a business-1 order
-- could carry a business-2 product or variant, in both directions, and an
-- order's business_id could be changed together with its customer and outlet,
-- leaving its items and payments behind in the old business (proof, run
-- before this file existed: results/10_e30_before_guard_8.txt, E30b-e, E31b).
--
-- GUARD 8 -- order_items, BEFORE INSERT:
--   The item's product, and the product of the item's variant, must belong to
--   the same business as the order the item is added to. A missing order,
--   product or variant also fails (the NULL case: a comparison with NULL is
--   never true, so it is tested explicitly). The trigger is created
--   FOLLOWS trg_order_items_guard_ins, so GUARD 6 (price, catalog link,
--   variant of its product) always reports first: an item that is both
--   wrong-tenant and wrong-price is reported as GUARD 6.
--   Only inserts need checking: GUARD 6 already stops product_id and
--   product_variant_id from changing afterwards.
--
-- GUARD 8b -- orders, BEFORE UPDATE:
--   orders.business_id cannot change. Without it the insert-only checks of
--   GUARDS 7 and 8 could be sidestepped by changing the order's business_id
--   (with its customer and outlet, to get past GUARD 4) after its items and
--   payments exist (results/10_e30_before_guard_8.txt, E31b). NULL-safe.
--   Created FOLLOWS trg_orders_guards_upd, so GUARD 3/4 report first.
--
-- Not added (undecided, not ruled out): a lock on order_items.order_id. E32
-- only showed that appending another order's item with its existing id is
-- rejected (a duplicate-id insert, not a move); a direct change of order_id
-- is probed separately in sql/12_e33_order_id_probe.sql.
-- ============================================================

USE __MYSQL_DB__;

DROP TRIGGER IF EXISTS trg_order_items_guard_tenant_ins;
DROP TRIGGER IF EXISTS trg_orders_guard_business_immutable;

DELIMITER $$

CREATE TRIGGER trg_order_items_guard_tenant_ins BEFORE INSERT ON order_items
FOR EACH ROW FOLLOWS trg_order_items_guard_ins
BEGIN
    DECLARE v_order_business BIGINT UNSIGNED;
    DECLARE v_product_business BIGINT UNSIGNED;
    DECLARE v_variant_business BIGINT UNSIGNED;

    SELECT business_id INTO v_order_business FROM orders WHERE id = NEW.order_id;
    IF v_order_business IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 8: order_items.order_id does not refer to an existing order';
    END IF;

    IF NEW.product_id IS NOT NULL THEN
        SELECT business_id INTO v_product_business FROM products WHERE id = NEW.product_id;
        IF v_product_business IS NULL OR v_product_business <> v_order_business THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARD 8: order_items.product_id does not belong to the business of the order';
        END IF;
    END IF;

    IF NEW.product_variant_id IS NOT NULL THEN
        SELECT p.business_id INTO v_variant_business
          FROM product_variants pv JOIN products p ON p.id = pv.product_id
         WHERE pv.id = NEW.product_variant_id;
        IF v_variant_business IS NULL OR v_variant_business <> v_order_business THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARD 8: order_items.product_variant_id does not belong to the business of the order';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_orders_guard_business_immutable BEFORE UPDATE ON orders
FOR EACH ROW FOLLOWS trg_orders_guards_upd
BEGIN
    IF NOT (OLD.business_id <=> NEW.business_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 8: orders.business_id is immutable once inserted';
    END IF;
END$$

DELIMITER ;

-- ------------------------------------------------------------
-- Evidence 1: the triggers on order_items and orders, in firing order.
-- ------------------------------------------------------------
SELECT EVENT_OBJECT_TABLE AS on_table, EVENT_MANIPULATION AS event, ACTION_TIMING AS timing,
       ACTION_ORDER AS fires_in_position, TRIGGER_NAME
  FROM INFORMATION_SCHEMA.TRIGGERS
 WHERE TRIGGER_SCHEMA = '__MYSQL_DB__' AND EVENT_OBJECT_TABLE IN ('order_items', 'orders')
 ORDER BY on_table, event, ACTION_ORDER;

-- ------------------------------------------------------------
-- Evidence 2: rows loaded before these triggers existed are tenant-consistent.
-- Every count except items_checked must be 0.
-- ------------------------------------------------------------
SELECT COUNT(*) AS items_checked,
       COALESCE(SUM(p.business_id <> o.business_id), 0) AS product_in_other_business,
       COALESCE(SUM(vp.business_id <> o.business_id), 0) AS variant_in_other_business,
       IF(COALESCE(SUM(p.business_id <> o.business_id OR vp.business_id <> o.business_id), 0) = 0,
          'PASS', 'FAIL') AS items_vs_orders
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  LEFT JOIN products p ON p.id = oi.product_id
  LEFT JOIN product_variants pv ON pv.id = oi.product_variant_id
  LEFT JOIN products vp ON vp.id = pv.product_id;
