-- ============================================================
-- 06_guards_6_7.sql
-- GUARD 6 (order item price) and GUARD 7 (payment business) -- database
-- triggers added after the first five guards in sql/01_schema.sql. Kept in
-- their own file so they are visible as their own piece. scripts/reset_db.py
-- runs this after 00 -> 02, so a rebuild always ends up complete. Safe to
-- re-run: each trigger is dropped first.
--
-- GUARD 6 -- order_items (the agent only ever reaches this table through
--            order_dv; triggers fire for writes made through the view):
--   INSERT: the item must point at the catalog (a product, a variant, or
--           both), and its price must equal the current catalog price: the
--           variant's price if a variant is given, else the product's.
--   INSERT (added in this repo): if both product_id and
--           product_variant_id are given, the variant must belong to that
--           product. Otherwise a cheap variant of one product could be
--           attached to another.
--   UPDATE: price, product_id and product_variant_id can never change
--           (price immutability was in the spec; locking the two catalog
--           links is a deliberate addition, so the INSERT checks cannot be
--           bypassed by a later UPDATE). Nothing is re-checked against the
--           catalog on UPDATE, so a later catalog price change never
--           invalidates an existing item.
--   Prices are compared as DECIMAL with the NULL-safe <=>, so 450 and 450.00
--   arriving from a JSON round trip are equal (same family of problem as E23).
--
-- GUARD 7 -- payments:
--   INSERT: payments.business_id must equal the business_id of the order the
--           payment pays. UPDATEs are already stopped by GUARD 5
--           (trg_payments_guard_immutable, BEFORE UPDATE), so this trigger is
--           BEFORE INSERT only and does not interact with it or with the
--           payments WITH(INSERT, UPDATE) design (E23).
--           GUARD 4 does not cover this: it only checks an order's customer
--           and outlet.
--
-- Not covered here (known limitation, planned as GUARD 8): nothing checks
-- that an item's product or variant belongs to the same business as the
-- order. See docs/findings.md and docs/when-to-use.md.
--
-- The seed data in 01_schema.sql loads BEFORE these triggers exist, so the
-- last query in this file proves the seed items agree with the catalog.
-- ============================================================

USE __MYSQL_DB__;

DROP TRIGGER IF EXISTS trg_order_items_guard_ins;
DROP TRIGGER IF EXISTS trg_order_items_guard_upd;
DROP TRIGGER IF EXISTS trg_payments_guard_business_ins;

DELIMITER $$

CREATE TRIGGER trg_order_items_guard_ins BEFORE INSERT ON order_items
FOR EACH ROW
BEGIN
    DECLARE v_catalog_price DECIMAL(10,2);
    DECLARE v_variant_product BIGINT UNSIGNED;

    IF NEW.product_id IS NULL AND NEW.product_variant_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 6: order_items must reference a product or product variant, so the price can be checked against the catalog';
    END IF;

    IF NEW.product_variant_id IS NOT NULL THEN
        SELECT price, product_id INTO v_catalog_price, v_variant_product
          FROM product_variants WHERE id = NEW.product_variant_id;
        IF v_catalog_price IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARD 6: order_items.product_variant_id does not exist in the catalog';
        END IF;
        IF NEW.product_id IS NOT NULL AND NOT (NEW.product_id <=> v_variant_product) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARD 6: order_items.product_variant_id does not belong to order_items.product_id';
        END IF;
    ELSE
        SELECT price INTO v_catalog_price FROM products WHERE id = NEW.product_id;
        IF v_catalog_price IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARD 6: order_items.product_id does not exist in the catalog';
        END IF;
    END IF;

    IF NOT (NEW.price <=> v_catalog_price) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 6: order_items.price does not match the current catalog price';
    END IF;
END$$

CREATE TRIGGER trg_order_items_guard_upd BEFORE UPDATE ON order_items
FOR EACH ROW
BEGIN
    IF NOT (NEW.price <=> OLD.price)
       OR NOT (NEW.product_id <=> OLD.product_id)
       OR NOT (NEW.product_variant_id <=> OLD.product_variant_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 6: order_items.price, product_id and product_variant_id are immutable once inserted';
    END IF;
END$$

CREATE TRIGGER trg_payments_guard_business_ins BEFORE INSERT ON payments
FOR EACH ROW
BEGIN
    DECLARE v_order_business BIGINT UNSIGNED;

    SELECT business_id INTO v_order_business FROM orders WHERE id = NEW.order_id;

    IF v_order_business IS NULL OR v_order_business <> NEW.business_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 7: payments.business_id does not match the business_id of the order it pays';
    END IF;
END$$

DELIMITER ;

-- ------------------------------------------------------------
-- Evidence 1: the guard triggers now on the database.
-- ------------------------------------------------------------
SELECT TRIGGER_NAME, EVENT_MANIPULATION AS event, ACTION_TIMING AS timing, EVENT_OBJECT_TABLE AS on_table
  FROM INFORMATION_SCHEMA.TRIGGERS
 WHERE TRIGGER_SCHEMA = '__MYSQL_DB__'
 ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME;

-- ------------------------------------------------------------
-- Evidence 2: the seed items (loaded before these triggers existed) all
-- agree with the catalog. Every count except items_checked must be 0.
-- ------------------------------------------------------------
SELECT COUNT(*) AS items_checked,
       COALESCE(SUM(NOT (oi.price <=> COALESCE(pv.price, p.price))), 0) AS price_differs_from_catalog,
       COALESCE(SUM(oi.product_id IS NULL AND oi.product_variant_id IS NULL), 0) AS no_catalog_link,
       COALESCE(SUM(oi.product_variant_id IS NOT NULL AND oi.product_id IS NOT NULL
                    AND NOT (oi.product_id <=> pv.product_id)), 0) AS variant_not_of_product,
       IF(COALESCE(SUM(NOT (oi.price <=> COALESCE(pv.price, p.price))
                       OR (oi.product_id IS NULL AND oi.product_variant_id IS NULL)
                       OR (oi.product_variant_id IS NOT NULL AND oi.product_id IS NOT NULL
                           AND NOT (oi.product_id <=> pv.product_id))), 0) = 0,
          'PASS', 'FAIL') AS seed_vs_catalog
  FROM order_items oi
  LEFT JOIN product_variants pv ON pv.id = oi.product_variant_id
  LEFT JOIN products p ON p.id = oi.product_id;
