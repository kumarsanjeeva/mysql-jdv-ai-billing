-- repro_payment_design_ab.sql
-- Two candidate designs for payments inside an order document, tested
-- against E23 (results/repro_e23_datetime_text_roundtrip.sql). The
-- round-trip test in both is E23's case D1: the document written back as
-- literal JSON text, datetime in MySQL format, only the root status changed.
--
-- Design A: payments fully READ-ONLY inside the order view (no
--   annotations). Payments are only ever written through their own view
--   (WITH(INSERT)), and "order + advance payment" is an order-view INSERT
--   plus a payment-view INSERT inside one explicit transaction.
--   A1 commit, A2 rollback, A3 failure mid-transaction (each checked from a
--   fresh session), A4 the D1 round trip, A5/A6 what happens if the text
--   tries to change or add a payment.
--
-- Design B: payments WITH(INSERT, UPDATE) inside the order view, plus a
--   BEFORE UPDATE trigger on the payment table that raises an error if any
--   column value actually changes.
--   B1 the D1 round trip, B2 the text tries to change a payment amount.
--
-- Runs in the throwaway jdv_repro_scratch database. Each TEST block runs in
-- its own session.

-- TEST: SETUP_A tables and views for design A
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS da_order_dv, da_payment_dv;
DROP TABLE IF EXISTS da_payment;
DROP TABLE IF EXISTS da_order;
CREATE TABLE da_order (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    request_id VARCHAR(64) NOT NULL UNIQUE,
    status VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE da_payment (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    order_id BIGINT UNSIGNED NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    paid_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    CONSTRAINT chk_da_payment_amount CHECK (amount > 0),
    CONSTRAINT fk_da_payment_order FOREIGN KEY (order_id) REFERENCES da_order(id)
) ENGINE=InnoDB;
CREATE JSON DUALITY VIEW da_order_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'request_id': request_id,
    'status': status,
    'payments': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT(
                'id': id,
                'amount': amount,
                'paid_at': paid_at
            )
        )
        FROM da_payment WHERE da_payment.order_id = da_order.id
    )
)
FROM da_order;
CREATE JSON DUALITY VIEW da_payment_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT)
    '_id': id,
    'amount': amount,
    'paid_at': paid_at,
    'order': (
        SELECT JSON_DUALITY_OBJECT('id': id, 'status': status)
        FROM da_order WHERE da_order.id = da_payment.order_id
    )
)
FROM da_payment;

-- TEST: A1 transaction commit: order insert + payment insert, then COMMIT
-- EXPECT: OK
USE jdv_repro_scratch;
START TRANSACTION;
INSERT INTO da_order_dv VALUES('{"request_id": "a1", "status": "confirmed"}');
SET @oid = (SELECT JSON_VALUE(data, '$._id') FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1');
INSERT INTO da_payment_dv VALUES(JSON_OBJECT('amount', 500.00, 'paid_at', '2026-09-26 10:00:00.000000', 'order', JSON_OBJECT('id', @oid)));
COMMIT;

-- TEST: A1_CHECK fresh session sees the committed order with its payment
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT data AS a1_document FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1';

-- TEST: A2 transaction rollback: order insert + payment insert, then ROLLBACK
-- EXPECT: OK
USE jdv_repro_scratch;
START TRANSACTION;
INSERT INTO da_order_dv VALUES('{"request_id": "a2", "status": "confirmed"}');
SET @oid = (SELECT JSON_VALUE(data, '$._id') FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a2');
INSERT INTO da_payment_dv VALUES(JSON_OBJECT('amount', 500.00, 'paid_at', '2026-09-26 10:00:00.000000', 'order', JSON_OBJECT('id', @oid)));
SELECT COUNT(*) AS a2_payments_inside_txn FROM da_payment WHERE order_id = @oid;
ROLLBACK;

-- TEST: A2_CHECK fresh session: neither the order nor the payment exists
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT (SELECT COUNT(*) FROM da_order WHERE request_id = 'a2') AS a2_orders,
       (SELECT COUNT(*) FROM da_payment p LEFT JOIN da_order o ON o.id = p.order_id WHERE o.id IS NULL) AS orphan_payments;

-- TEST: A3 payment insert fails (CHECK amount > 0) mid-transaction; session ends
-- EXPECT: ERROR
USE jdv_repro_scratch;
START TRANSACTION;
INSERT INTO da_order_dv VALUES('{"request_id": "a3", "status": "confirmed"}');
SET @oid = (SELECT JSON_VALUE(data, '$._id') FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a3');
INSERT INTO da_payment_dv VALUES(JSON_OBJECT('amount', -5.00, 'paid_at', '2026-09-26 10:00:00.000000', 'order', JSON_OBJECT('id', @oid)));
COMMIT;

-- TEST: A3_CHECK fresh session: the order from the failed transaction does not exist
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT COUNT(*) AS a3_orders FROM da_order WHERE request_id = 'a3';

-- TEST: A4 D1 round trip: order a1 sent back as JSON text, status changed
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT data AS read_back FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1';
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @oid, @payid, @etag FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1';
SELECT updated_at INTO @pay_updated_before FROM da_payment WHERE id = @payid;
DO SLEEP(0.01);
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __OID__, "request_id": "a1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__OID__', @oid), '__PAYID__', @payid), '__ETAG__', @etag);
SELECT @sent AS sent_text;
UPDATE da_order_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT data AS after_update FROM da_order_dv WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT id, amount, paid_at, updated_at = @pay_updated_before AS payment_row_untouched FROM da_payment WHERE id = @payid;

-- TEST: A5 JSON text changes the payment amount (read-only array)
-- EXPECT: ERROR
USE jdv_repro_scratch;
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @oid, @payid, @etag FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1';
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __OID__, "request_id": "a1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 1.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__OID__', @oid), '__PAYID__', @payid), '__ETAG__', @etag);
UPDATE da_order_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT id, amount FROM da_payment WHERE id = @payid;

-- TEST: A6 JSON text adds a second payment (read-only array)
-- EXPECT: ERROR
USE jdv_repro_scratch;
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @oid, @payid, @etag FROM da_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'a1';
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __OID__, "request_id": "a1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}, {"amount": 250.00, "paid_at": "2026-09-27 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__OID__', @oid), '__PAYID__', @payid), '__ETAG__', @etag);
UPDATE da_order_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT id, amount FROM da_payment WHERE order_id = @oid ORDER BY id;

-- TEST: SETUP_B tables, view and no-change trigger for design B
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS db_order_dv;
DROP TABLE IF EXISTS db_payment;
DROP TABLE IF EXISTS db_order;
CREATE TABLE db_order (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    request_id VARCHAR(64) NOT NULL UNIQUE,
    status VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE db_payment (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    order_id BIGINT UNSIGNED NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    paid_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_db_payment_order FOREIGN KEY (order_id) REFERENCES db_order(id)
) ENGINE=InnoDB;
DELIMITER $$
CREATE TRIGGER trg_db_payment_no_change BEFORE UPDATE ON db_payment
FOR EACH ROW
BEGIN
    IF NOT (NEW.order_id <=> OLD.order_id) OR NOT (NEW.amount <=> OLD.amount) OR NOT (NEW.paid_at <=> OLD.paid_at) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'payments are immutable: a column value changed';
    END IF;
END$$
DELIMITER ;
CREATE JSON DUALITY VIEW db_order_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'request_id': request_id,
    'status': status,
    'payments': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'amount': amount,
                'paid_at': paid_at
            )
        )
        FROM db_payment WHERE db_payment.order_id = db_order.id
    )
)
FROM db_order;

-- TEST: B1 D1 round trip: order sent back as JSON text, status changed
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO db_order_dv VALUES('{"request_id": "b1", "status": "confirmed", "payments": [{"amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}]}');
SELECT data AS read_back FROM db_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'b1';
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @oid, @payid, @etag FROM db_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'b1';
SELECT updated_at INTO @pay_updated_before FROM db_payment WHERE id = @payid;
DO SLEEP(0.01);
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __OID__, "request_id": "b1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__OID__', @oid), '__PAYID__', @payid), '__ETAG__', @etag);
UPDATE db_order_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT data AS after_update FROM db_order_dv WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT id, amount, paid_at, updated_at = @pay_updated_before AS payment_row_untouched FROM db_payment WHERE id = @payid;

-- TEST: B2 JSON text changes the payment amount; trigger must reject
-- EXPECT: ERROR
USE jdv_repro_scratch;
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @oid, @payid, @etag FROM db_order_dv WHERE JSON_VALUE(data, '$.request_id') = 'b1';
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __OID__, "request_id": "b1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 1.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__OID__', @oid), '__PAYID__', @payid), '__ETAG__', @etag);
UPDATE db_order_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @oid;
SELECT id, amount FROM db_payment WHERE id = @payid;
