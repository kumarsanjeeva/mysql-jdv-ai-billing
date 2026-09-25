-- ============================================================
-- 01_schema.sql
-- Ported relational schema + realistic sample data.
--
-- Primary keys are BIGINT UNSIGNED AUTO_INCREMENT (not UUIDs) -- see
-- docs/porting-notes.md for why (InnoDB clustered-index behavior, and a
-- deliberate choice to exercise JSON Duality Views' AUTO_INCREMENT
-- all-or-nothing rule rather than design around it).
--
-- This file is organized in two parts:
--   1. PORT            -- tables, keys, indexes, ported from an existing application
--   2. GUARDS          -- a separate, clearly labeled section of DB-level
--                         checks/triggers added in this repo, enforced in the
--                         database rather than in application code (see docs/porting-notes.md
--                         and docs/findings.md for why, and whether they
--                         actually fire through the duality views).
-- Sample data (part 3) is plain INSERTs against these base tables -- the
-- duality views don't exist yet at this point in the run order (00 -> 02).
-- ============================================================

USE __MYSQL_DB__;

-- ============================================================
-- PART 1: PORT
-- ============================================================

-- ------------------------------------------------------------
-- BUSINESSES (tenant root)
-- ------------------------------------------------------------
CREATE TABLE businesses (
    id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(255) NOT NULL,
    gst_percent   DECIMAL(5,2) NOT NULL DEFAULT 0,   -- legacy/display field; order_items.gst_value is authoritative
    default_unit  ENUM('kg','lb') NOT NULL DEFAULT 'kg',
    is_active     TINYINT NOT NULL DEFAULT 1,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at    DATETIME(6) NULL
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- OUTLETS
-- ------------------------------------------------------------
CREATE TABLE outlets (
    id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id   BIGINT UNSIGNED NOT NULL,
    name          VARCHAR(255) NOT NULL,
    address       TEXT,
    is_active     TINYINT NOT NULL DEFAULT 1,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at    DATETIME(6) NULL,
    CONSTRAINT fk_outlets_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    INDEX idx_outlets_business (business_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- STAFF -- minimal staff table: no login linkage, no roles. It exists
-- only to give orders and payments a created_by reference and to drive
-- the counter-staff-vs-agent concurrency scenario in
-- agent/scenarios.py.
-- ------------------------------------------------------------
CREATE TABLE staff (
    id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id   BIGINT UNSIGNED NOT NULL,
    outlet_id     BIGINT UNSIGNED NULL,   -- NULL = business-wide staff
    name          VARCHAR(255) NOT NULL,
    is_active     TINYINT NOT NULL DEFAULT 1,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_staff_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    CONSTRAINT fk_staff_outlet FOREIGN KEY (outlet_id) REFERENCES outlets(id),
    INDEX idx_staff_business (business_id),
    INDEX idx_staff_outlet (outlet_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- CUSTOMERS (business-scoped, shared across outlets)
-- ------------------------------------------------------------
CREATE TABLE customers (
    id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id   BIGINT UNSIGNED NOT NULL,
    name          VARCHAR(255) NOT NULL,
    phone         VARCHAR(20) NOT NULL,
    address       TEXT,
    is_active     TINYINT NOT NULL DEFAULT 1,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at    DATETIME(6) NULL,
    CONSTRAINT fk_customers_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    CONSTRAINT uq_customers_business_phone UNIQUE (business_id, phone),
    INDEX idx_customers_business (business_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- PRODUCTS (catalog)
-- ------------------------------------------------------------
CREATE TABLE products (
    id                    BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id           BIGINT UNSIGNED NOT NULL,
    name                  VARCHAR(255) NOT NULL,
    price                 DECIMAL(10,2) NOT NULL DEFAULT 0,
    is_mrp                TINYINT NOT NULL DEFAULT 0,
    gst_applicable        TINYINT NOT NULL DEFAULT 1,
    gst_rate              DECIMAL(5,2) NOT NULL DEFAULT 0,
    is_gst_inclusive      TINYINT NOT NULL DEFAULT 0,
    discount_exempt       TINYINT NOT NULL DEFAULT 0,
    max_discount_amount   DECIMAL(10,2) NULL,
    is_active             TINYINT NOT NULL DEFAULT 1,
    created_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at            DATETIME(6) NULL,
    CONSTRAINT fk_products_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    INDEX idx_products_business (business_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- PRODUCT_VARIANTS -- optional flavor/size/price variants under a product.
-- size/unit normalized to DECIMAL+ENUM here (see docs/porting-notes.md --
-- both size columns are normalized here rather than guessing at
-- undocumented parsing).
-- ------------------------------------------------------------
CREATE TABLE product_variants (
    id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    product_id    BIGINT UNSIGNED NOT NULL,
    flavor        VARCHAR(255),
    size          DECIMAL(6,2),
    unit          ENUM('kg','lb'),
    price         DECIMAL(10,2) NOT NULL DEFAULT 0,
    is_active     TINYINT NOT NULL DEFAULT 1,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at    DATETIME(6) NULL,
    CONSTRAINT fk_variants_product FOREIGN KEY (product_id) REFERENCES products(id),
    INDEX idx_variants_product (product_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- GST_RATE_HISTORY -- audit trail of businesses.gst_percent changes.
-- Deliberately exposed through NO duality view (see sql/02_duality_views.sql)
-- -- plain SQL / reporting only. Demonstrates that not every table needs one.
-- ------------------------------------------------------------
CREATE TABLE gst_rate_history (
    id                   BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id          BIGINT UNSIGNED NOT NULL,
    gst_percent          DECIMAL(5,2) NOT NULL,
    effective_from       DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    changed_by_staff_id  BIGINT UNSIGNED NULL,
    created_at           DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_gst_history_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    CONSTRAINT fk_gst_history_staff FOREIGN KEY (changed_by_staff_id) REFERENCES staff(id),
    INDEX idx_gst_history_business (business_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- ORDERS (root of the billing document)
-- ------------------------------------------------------------
CREATE TABLE orders (
    id                   BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    business_id          BIGINT UNSIGNED NOT NULL,
    outlet_id            BIGINT UNSIGNED NOT NULL,
    customer_id          BIGINT UNSIGNED NOT NULL,
    created_by_staff_id  BIGINT UNSIGNED NULL,
    request_id           VARCHAR(64) NOT NULL,   -- agent-generated idempotency key, one per create-order intent
    order_status         ENUM('draft','confirmed','ready','delivered','cancelled') NOT NULL DEFAULT 'draft',
    delivery_address     TEXT,
    delivery_at          DATETIME(6) NULL,
    subtotal             DECIMAL(10,2) NOT NULL DEFAULT 0,
    discount_type        ENUM('amount','percent') NOT NULL DEFAULT 'amount',
    discount_value       DECIMAL(10,2) NOT NULL DEFAULT 0,
    gst_percent          DECIMAL(5,2) NOT NULL DEFAULT 0,   -- legacy/display; gst_value is authoritative
    gst_value             DECIMAL(10,2) NOT NULL DEFAULT 0,
    total                 DECIMAL(10,2) NOT NULL DEFAULT 0,
    cancellation_reason   TEXT,
    created_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at            DATETIME(6) NULL,
    CONSTRAINT uq_orders_request_id UNIQUE (request_id),
    CONSTRAINT fk_orders_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    CONSTRAINT fk_orders_outlet FOREIGN KEY (outlet_id) REFERENCES outlets(id),
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id),
    CONSTRAINT fk_orders_staff FOREIGN KEY (created_by_staff_id) REFERENCES staff(id),
    INDEX idx_orders_business (business_id),
    INDEX idx_orders_outlet (outlet_id),
    INDEX idx_orders_customer (customer_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- ORDER_ITEMS -- snapshot GST/discount rules from the product/variant at
-- the moment the item is added; a later product price/GST change must
-- never rewrite a historical order.
-- ------------------------------------------------------------
CREATE TABLE order_items (
    id                    BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    order_id              BIGINT UNSIGNED NOT NULL,
    product_id            BIGINT UNSIGNED NULL,
    product_variant_id    BIGINT UNSIGNED NULL,
    name                  VARCHAR(255) NOT NULL,
    flavor                VARCHAR(255),
    size                  DECIMAL(6,2),
    unit                  ENUM('kg','lb'),
    occasion              VARCHAR(255),
    dietary_flag          VARCHAR(255),
    qty                   DECIMAL(6,2) NOT NULL DEFAULT 1,
    price                 DECIMAL(10,2) NOT NULL DEFAULT 0,
    gst_rate              DECIMAL(5,2) NOT NULL DEFAULT 0,
    is_gst_inclusive      TINYINT NOT NULL DEFAULT 0,
    gst_applicable        TINYINT NOT NULL DEFAULT 1,
    discount_exempt       TINYINT NOT NULL DEFAULT 0,
    max_discount_amount   DECIMAL(10,2) NULL,
    gst_value             DECIMAL(10,2) NOT NULL DEFAULT 0,
    discount_value        DECIMAL(10,2) NOT NULL DEFAULT 0,
    notes                 TEXT,
    is_active             TINYINT NOT NULL DEFAULT 1,
    created_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at            DATETIME(6) NULL,
    CONSTRAINT chk_order_items_qty CHECK (qty > 0),   -- GUARD 1
    CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders(id),
    CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products(id),
    CONSTRAINT fk_items_variant FOREIGN KEY (product_variant_id) REFERENCES product_variants(id),
    INDEX idx_items_order (order_id),
    INDEX idx_items_product (product_id),
    INDEX idx_items_variant (product_variant_id)
) ENGINE=InnoDB;

-- ------------------------------------------------------------
-- PAYMENTS -- independent entity, many per order, never edited/deleted
-- after insert (in this repo: payment_dv has WITH(INSERT) only, see
-- sql/02_duality_views.sql, and GUARD 5 rejects any update).
-- ------------------------------------------------------------
CREATE TABLE payments (
    id                   BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    order_id             BIGINT UNSIGNED NOT NULL,
    business_id          BIGINT UNSIGNED NOT NULL,
    request_id           VARCHAR(64) NOT NULL,   -- agent-generated idempotency key, one per add-payment intent
    payment_type         ENUM('advance','installment','final','refund','udhaar_settlement') NOT NULL,
    method                ENUM('cash','upi','card','other') NOT NULL,
    amount                DECIMAL(10,2) NOT NULL,
    paid_at               DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    created_by_staff_id   BIGINT UNSIGNED NULL,
    created_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at             DATETIME(6) NULL,
    CONSTRAINT uq_payments_request_id UNIQUE (request_id),
    CONSTRAINT chk_payments_amount_sign CHECK (   -- GUARD 2
        (payment_type = 'refund' AND amount < 0)
        OR (payment_type <> 'refund' AND amount > 0)
    ),
    CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders(id),
    CONSTRAINT fk_payments_business FOREIGN KEY (business_id) REFERENCES businesses(id),
    CONSTRAINT fk_payments_staff FOREIGN KEY (created_by_staff_id) REFERENCES staff(id),
    INDEX idx_payments_order (order_id),
    INDEX idx_payments_business (business_id)
) ENGINE=InnoDB;

-- ============================================================
-- PART 2: GUARDS -- database-side checks on writes. An LLM agent writes
-- directly through the duality views and its output is not deterministic,
-- so rules that must hold for every writer live in these triggers.
-- Tenants here: writes are checked by the guard triggers; reads are
-- filtered by business_id in agent/tools.py; no row-level security is
-- used in this repo (MySQL's own position was not tested here). See
-- docs/when-to-use.md.
--
-- GUARD 3: orders.total must equal subtotal - discount_value + gst_value
--          (within a 1-paisa rounding tolerance). Fails loudly rather than
--          silently correcting -- an arithmetic mismatch from the agent is a
--          bug to surface, not paper over.
-- GUARD 4: orders.customer_id and orders.outlet_id must belong to the same
--          business_id as the order itself. This is the tenant check on
--          writes; it does not cover reads (see docs/when-to-use.md).
--          Write-side tenant checks are triggers only.
-- GUARD 5: payments are immutable once inserted. Any UPDATE that changes a
--          column value is rejected (updated_at excepted -- MySQL maintains
--          it). This is what lets order_dv expose payments WITH(INSERT,
--          UPDATE): an order document written back as JSON text carries
--          paid_at as a string, which an insert-only payments array rejects
--          as a "change" (E23); with UPDATE allowed, an unchanged payment
--          passes through and a real change is stopped here. Verified in
--          results/repro_payment_design_ab.sql (design B).
--
-- Whether these fire correctly when the write arrives through a JSON
-- Duality View (rather than a direct INSERT/UPDATE on orders) is verified,
-- not assumed -- see docs/findings.md, test E14.
-- ============================================================

DELIMITER $$

CREATE TRIGGER trg_orders_guards_ins BEFORE INSERT ON orders
FOR EACH ROW
BEGIN
    DECLARE v_customer_business BIGINT UNSIGNED;
    DECLARE v_outlet_business BIGINT UNSIGNED;

    IF ABS(NEW.total - (NEW.subtotal - NEW.discount_value + NEW.gst_value)) > 0.01 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 3: orders.total does not match subtotal - discount_value + gst_value';
    END IF;

    SELECT business_id INTO v_customer_business FROM customers WHERE id = NEW.customer_id;
    SELECT business_id INTO v_outlet_business FROM outlets WHERE id = NEW.outlet_id;

    IF v_customer_business IS NULL OR v_customer_business <> NEW.business_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 4: orders.customer_id does not belong to orders.business_id';
    END IF;
    IF v_outlet_business IS NULL OR v_outlet_business <> NEW.business_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 4: orders.outlet_id does not belong to orders.business_id';
    END IF;
END$$

CREATE TRIGGER trg_orders_guards_upd BEFORE UPDATE ON orders
FOR EACH ROW
BEGIN
    DECLARE v_customer_business BIGINT UNSIGNED;
    DECLARE v_outlet_business BIGINT UNSIGNED;

    IF ABS(NEW.total - (NEW.subtotal - NEW.discount_value + NEW.gst_value)) > 0.01 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 3: orders.total does not match subtotal - discount_value + gst_value';
    END IF;

    SELECT business_id INTO v_customer_business FROM customers WHERE id = NEW.customer_id;
    SELECT business_id INTO v_outlet_business FROM outlets WHERE id = NEW.outlet_id;

    IF v_customer_business IS NULL OR v_customer_business <> NEW.business_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 4: orders.customer_id does not belong to orders.business_id';
    END IF;
    IF v_outlet_business IS NULL OR v_outlet_business <> NEW.business_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 4: orders.outlet_id does not belong to orders.business_id';
    END IF;
END$$

CREATE TRIGGER trg_payments_guard_immutable BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    IF NOT (NEW.id <=> OLD.id)
       OR NOT (NEW.order_id <=> OLD.order_id)
       OR NOT (NEW.business_id <=> OLD.business_id)
       OR NOT (NEW.request_id <=> OLD.request_id)
       OR NOT (NEW.payment_type <=> OLD.payment_type)
       OR NOT (NEW.method <=> OLD.method)
       OR NOT (NEW.amount <=> OLD.amount)
       OR NOT (NEW.paid_at <=> OLD.paid_at)
       OR NOT (NEW.created_by_staff_id <=> OLD.created_by_staff_id)
       OR NOT (NEW.created_at <=> OLD.created_at)
       OR NOT (NEW.deleted_at <=> OLD.deleted_at) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARD 5: payments are immutable once inserted';
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- PART 3: SAMPLE DATA
-- Fictional Indian bakery context (INR, GST). Two businesses, three
-- outlets, ten products (four with variants), five customers, four staff,
-- five historical orders covering unpaid / partial (udhaar) / fully paid /
-- refunded / multi-installment payment states.
-- Plain INSERTs against base tables (duality views don't exist yet).
-- ============================================================

-- --- Businesses ---
INSERT INTO businesses (name, gst_percent, default_unit) VALUES ('Sunrise Bakers', 5.00, 'kg');
SET @biz_sunrise = LAST_INSERT_ID();

INSERT INTO businesses (name, gst_percent, default_unit) VALUES ('Melody Cakes', 5.00, 'kg');
SET @biz_melody = LAST_INSERT_ID();

-- --- Outlets ---
INSERT INTO outlets (business_id, name, address) VALUES (@biz_sunrise, 'Sunrise Bakers - MG Road', '12 MG Road, Bengaluru');
SET @outlet_sunrise_mg = LAST_INSERT_ID();

INSERT INTO outlets (business_id, name, address) VALUES (@biz_sunrise, 'Sunrise Bakers - Indiranagar', '45 100 Feet Road, Indiranagar, Bengaluru');
SET @outlet_sunrise_indiranagar = LAST_INSERT_ID();

INSERT INTO outlets (business_id, name, address) VALUES (@biz_melody, 'Melody Cakes - Koramangala', '7 80 Feet Road, Koramangala, Bengaluru');
SET @outlet_melody_koramangala = LAST_INSERT_ID();

-- --- Staff ---
INSERT INTO staff (business_id, outlet_id, name) VALUES (@biz_sunrise, @outlet_sunrise_mg, 'Asha');
SET @staff_asha = LAST_INSERT_ID();

INSERT INTO staff (business_id, outlet_id, name) VALUES (@biz_sunrise, @outlet_sunrise_indiranagar, 'Ravi');
SET @staff_ravi = LAST_INSERT_ID();

INSERT INTO staff (business_id, outlet_id, name) VALUES (@biz_sunrise, NULL, 'Meera');
SET @staff_meera = LAST_INSERT_ID();

INSERT INTO staff (business_id, outlet_id, name) VALUES (@biz_melody, @outlet_melody_koramangala, 'Farhan');
SET @staff_farhan = LAST_INSERT_ID();

-- --- Customers ---
INSERT INTO customers (business_id, name, phone, address) VALUES (@biz_sunrise, 'Priya Sharma', '9900000001', '221 Brigade Road, Bengaluru');
SET @cust_priya = LAST_INSERT_ID();

INSERT INTO customers (business_id, name, phone, address) VALUES (@biz_sunrise, 'Karthik Rao', '9900000002', '18 Residency Road, Bengaluru');
SET @cust_karthik = LAST_INSERT_ID();

INSERT INTO customers (business_id, name, phone, address) VALUES (@biz_sunrise, 'Divya Nair', '9900000003', '9 Indiranagar 12th Main, Bengaluru');
SET @cust_divya = LAST_INSERT_ID();

INSERT INTO customers (business_id, name, phone, address) VALUES (@biz_melody, 'Vikram Shah', '9900000004', '5 Koramangala 5th Block, Bengaluru');
SET @cust_vikram = LAST_INSERT_ID();

INSERT INTO customers (business_id, name, phone, address) VALUES (@biz_melody, 'Anjali Menon', '9900000005', '33 Sarjapur Road, Bengaluru');
SET @cust_anjali = LAST_INSERT_ID();

-- --- Products + variants: Sunrise Bakers ---
INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Black Forest Cake', 900.00, 1, 5.00, 0, 0, NULL);
SET @prod_blackforest = LAST_INSERT_ID();
INSERT INTO product_variants (product_id, flavor, size, unit, price) VALUES
    (@prod_blackforest, 'Chocolate', 0.5, 'kg', 500.00),
    (@prod_blackforest, 'Chocolate', 1.0, 'kg', 900.00),
    (@prod_blackforest, 'Chocolate', 1.5, 'kg', 1300.00);

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Vanilla Cake', 750.00, 1, 5.00, 0, 0, NULL);
SET @prod_vanilla = LAST_INSERT_ID();
INSERT INTO product_variants (product_id, flavor, size, unit, price) VALUES
    (@prod_vanilla, 'Vanilla', 0.5, 'kg', 400.00),
    (@prod_vanilla, 'Vanilla', 1.0, 'kg', 750.00);

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Chocolate Truffle Pastry', 90.00, 1, 5.00, 0, 0, NULL);
SET @prod_pastry = LAST_INSERT_ID();

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Red Velvet Cake', 950.00, 1, 5.00, 0, 0, NULL);
SET @prod_redvelvet = LAST_INSERT_ID();
INSERT INTO product_variants (product_id, flavor, size, unit, price) VALUES
    (@prod_redvelvet, 'Red Velvet', 0.5, 'kg', 550.00),
    (@prod_redvelvet, 'Red Velvet', 1.0, 'kg', 950.00);

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Butter Cookies (500g pack)', 250.00, 1, 5.00, 0, 0, NULL);
SET @prod_cookies = LAST_INSERT_ID();

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_sunrise, 'Dry Fruit Cake', 1100.00, 1, 5.00, 0, 0, NULL);
SET @prod_dryfruit = LAST_INSERT_ID();

-- --- Products + variants: Melody Cakes ---
INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_melody, 'Rainbow Cake', 1000.00, 1, 5.00, 0, 0, NULL);
SET @prod_rainbow = LAST_INSERT_ID();
INSERT INTO product_variants (product_id, flavor, size, unit, price) VALUES
    (@prod_rainbow, 'Rainbow', 0.5, 'kg', 550.00),
    (@prod_rainbow, 'Rainbow', 1.0, 'kg', 1000.00);

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_melody, 'Cupcake Box (6 pcs)', 350.00, 1, 5.00, 0, 0, NULL);
SET @prod_cupcake = LAST_INSERT_ID();

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_melody, 'Cheesecake', 1200.00, 1, 5.00, 0, 0, 100.00);
SET @prod_cheesecake = LAST_INSERT_ID();

INSERT INTO products (business_id, name, price, gst_applicable, gst_rate, is_gst_inclusive, discount_exempt, max_discount_amount)
VALUES (@biz_melody, 'Assorted Pastries (Box of 12)', 720.00, 1, 5.00, 0, 1, NULL);
SET @prod_assorted = LAST_INSERT_ID();

-- --- gst_rate_history (Sunrise had a rate change; Melody hasn't) ---
INSERT INTO gst_rate_history (business_id, gst_percent, effective_from, changed_by_staff_id) VALUES
    (@biz_sunrise, 12.00, '2023-01-01 00:00:00.000000', @staff_meera),
    (@biz_sunrise, 5.00,  '2024-04-01 00:00:00.000000', @staff_meera);
INSERT INTO gst_rate_history (business_id, gst_percent, effective_from, changed_by_staff_id) VALUES
    (@biz_melody, 5.00, '2023-06-01 00:00:00.000000', @staff_farhan);

-- --- Order O1: Priya @ Sunrise MG Road -- confirmed, unpaid ---
INSERT INTO orders (business_id, outlet_id, customer_id, created_by_staff_id, request_id, order_status,
                     delivery_at, subtotal, discount_type, discount_value, gst_value, total)
VALUES (@biz_sunrise, @outlet_sunrise_mg, @cust_priya, @staff_asha, 'seed-order-001', 'confirmed',
        '2026-09-20 10:00:00.000000', 1400.00, 'amount', 0.00, 70.00, 1470.00);
SET @order1 = LAST_INSERT_ID();

INSERT INTO order_items (order_id, product_id, product_variant_id, name, flavor, size, unit, qty, price,
                          gst_rate, is_gst_inclusive, gst_applicable, discount_exempt, gst_value, discount_value)
SELECT @order1, @prod_blackforest, pv.id, 'Black Forest Cake', pv.flavor, pv.size, pv.unit, 1, pv.price,
       5.00, 0, 1, 0, 45.00, 0.00
FROM product_variants pv WHERE pv.product_id = @prod_blackforest AND pv.size = 1.0;

INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                          discount_exempt, gst_value, discount_value)
VALUES (@order1, @prod_cookies, 'Butter Cookies (500g pack)', 2, 250.00, 5.00, 0, 1, 0, 25.00, 0.00);

-- --- Order O2: Karthik @ Sunrise MG Road -- delivered, partial/udhaar ---
INSERT INTO orders (business_id, outlet_id, customer_id, created_by_staff_id, request_id, order_status,
                     delivery_at, subtotal, discount_type, discount_value, gst_value, total)
VALUES (@biz_sunrise, @outlet_sunrise_mg, @cust_karthik, @staff_asha, 'seed-order-002', 'delivered',
        '2026-09-15 17:00:00.000000', 1290.00, 'amount', 40.00, 62.50, 1312.50);
SET @order2 = LAST_INSERT_ID();

INSERT INTO order_items (order_id, product_id, product_variant_id, name, flavor, size, unit, qty, price,
                          gst_rate, is_gst_inclusive, gst_applicable, discount_exempt, gst_value, discount_value)
SELECT @order2, @prod_vanilla, pv.id, 'Vanilla Cake', pv.flavor, pv.size, pv.unit, 1, pv.price,
       5.00, 0, 1, 0, 36.35, 23.00
FROM product_variants pv WHERE pv.product_id = @prod_vanilla AND pv.size = 1.0;

INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                          discount_exempt, gst_value, discount_value)
VALUES (@order2, @prod_pastry, 'Chocolate Truffle Pastry', 6, 90.00, 5.00, 0, 1, 0, 26.15, 17.00);

INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order2, @biz_sunrise, 'seed-payment-001', 'advance', 'upi', 500.00, '2026-09-14 12:00:00.000000', @staff_asha);

-- --- Order O3: Divya @ Sunrise Indiranagar -- delivered, fully paid ---
INSERT INTO orders (business_id, outlet_id, customer_id, created_by_staff_id, request_id, order_status,
                     delivery_at, subtotal, discount_type, discount_value, gst_value, total)
VALUES (@biz_sunrise, @outlet_sunrise_indiranagar, @cust_divya, @staff_ravi, 'seed-order-003', 'delivered',
        '2026-09-18 11:00:00.000000', 2050.00, 'amount', 0.00, 102.50, 2152.50);
SET @order3 = LAST_INSERT_ID();

INSERT INTO order_items (order_id, product_id, product_variant_id, name, flavor, size, unit, qty, price,
                          gst_rate, is_gst_inclusive, gst_applicable, discount_exempt, gst_value, discount_value)
SELECT @order3, @prod_redvelvet, pv.id, 'Red Velvet Cake', pv.flavor, pv.size, pv.unit, 1, pv.price,
       5.00, 0, 1, 0, 47.50, 0.00
FROM product_variants pv WHERE pv.product_id = @prod_redvelvet AND pv.size = 1.0;

INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                          discount_exempt, gst_value, discount_value)
VALUES (@order3, @prod_dryfruit, 'Dry Fruit Cake', 1, 1100.00, 5.00, 0, 1, 0, 55.00, 0.00);

INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order3, @biz_sunrise, 'seed-payment-002', 'final', 'card', 2152.50, '2026-09-18 11:05:00.000000', @staff_ravi);

-- --- Order O4: Priya @ Sunrise MG Road -- cancelled, advance refunded ---
INSERT INTO orders (business_id, outlet_id, customer_id, created_by_staff_id, request_id, order_status,
                     delivery_at, subtotal, discount_type, discount_value, gst_value, total, cancellation_reason)
VALUES (@biz_sunrise, @outlet_sunrise_mg, @cust_priya, @staff_asha, 'seed-order-004', 'cancelled',
        '2026-09-10 09:00:00.000000', 500.00, 'amount', 0.00, 25.00, 525.00,
        'Customer requested cancellation; advance refunded.');
SET @order4 = LAST_INSERT_ID();

INSERT INTO order_items (order_id, product_id, product_variant_id, name, flavor, size, unit, qty, price,
                          gst_rate, is_gst_inclusive, gst_applicable, discount_exempt, gst_value, discount_value)
SELECT @order4, @prod_blackforest, pv.id, 'Black Forest Cake', pv.flavor, pv.size, pv.unit, 1, pv.price,
       5.00, 0, 1, 0, 25.00, 0.00
FROM product_variants pv WHERE pv.product_id = @prod_blackforest AND pv.size = 0.5;

INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order4, @biz_sunrise, 'seed-payment-003', 'advance', 'cash', 500.00, '2026-09-08 10:00:00.000000', @staff_asha);
INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order4, @biz_sunrise, 'seed-payment-004', 'refund', 'cash', -500.00, '2026-09-10 09:10:00.000000', @staff_asha);

-- --- Order O5: Vikram @ Melody Koramangala -- ready, installments ---
INSERT INTO orders (business_id, outlet_id, customer_id, created_by_staff_id, request_id, order_status,
                     delivery_at, subtotal, discount_type, discount_value, gst_value, total)
VALUES (@biz_melody, @outlet_melody_koramangala, @cust_vikram, @staff_farhan, 'seed-order-005', 'ready',
        '2026-09-28 16:00:00.000000', 1700.00, 'amount', 0.00, 85.00, 1785.00);
SET @order5 = LAST_INSERT_ID();

INSERT INTO order_items (order_id, product_id, product_variant_id, name, flavor, size, unit, qty, price,
                          gst_rate, is_gst_inclusive, gst_applicable, discount_exempt, gst_value, discount_value)
SELECT @order5, @prod_rainbow, pv.id, 'Rainbow Cake', pv.flavor, pv.size, pv.unit, 1, pv.price,
       5.00, 0, 1, 0, 50.00, 0.00
FROM product_variants pv WHERE pv.product_id = @prod_rainbow AND pv.size = 1.0;

INSERT INTO order_items (order_id, product_id, name, qty, price, gst_rate, is_gst_inclusive, gst_applicable,
                          discount_exempt, gst_value, discount_value)
VALUES (@order5, @prod_cupcake, 'Cupcake Box (6 pcs)', 2, 350.00, 5.00, 0, 1, 0, 35.00, 0.00);

INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order5, @biz_melody, 'seed-payment-005', 'advance', 'upi', 600.00, '2026-09-25 14:00:00.000000', @staff_farhan);
INSERT INTO payments (order_id, business_id, request_id, payment_type, method, amount, paid_at, created_by_staff_id)
VALUES (@order5, @biz_melody, 'seed-payment-006', 'installment', 'cash', 500.00, '2026-09-27 09:00:00.000000', @staff_farhan);
