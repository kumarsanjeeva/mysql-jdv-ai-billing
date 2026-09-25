-- 04_edge_cases.sql
-- Purpose: edge cases and limits of DML through duality views; the raw
--          material for docs/findings.md. Each test is a block:
--            -- TEST: <id> <description>
--            -- EXPECT: OK | ERROR | ERROR <code>
--            -- AS: agent            (optional; default is the admin user)
--          scripts/run_sql.py runs every block in its own session and
--          reports PASS/SURPRISE per test.
--
-- Runs against the demo database after scripts/reset_db.py and
-- sql/03_dml_demos.sql.

-- ------------------------------------------------------------
-- GUARD 5: payments are immutable once inserted (sql/01_schema.sql,
-- trg_payments_guard_immutable). Target: seed-payment-001, the 500.00 UPI
-- advance on seed-order-002.
-- ------------------------------------------------------------

-- TEST: E25 agent changes a payment amount through order_dv
-- EXPECT: ERROR 1644
-- AS: agent
USE __MYSQL_DB__;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
SET @amount_path = REPLACE(
    JSON_UNQUOTE(JSON_SEARCH(@doc, 'one', 'seed-payment-001', NULL, '$.payments[*].request_id')),
    '.request_id', '.amount');
SELECT @amount_path AS amount_path, JSON_EXTRACT(@doc, @amount_path) AS amount_before;
UPDATE order_dv SET data = JSON_SET(@doc, @amount_path, 1.00)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: E26 admin changes a payment amount with a direct UPDATE on payments
-- EXPECT: ERROR 1644
USE __MYSQL_DB__;
SELECT id, amount FROM payments WHERE request_id = 'seed-payment-001';
UPDATE payments SET amount = 1.00 WHERE request_id = 'seed-payment-001';

-- TEST: E25_E26_CHECK payment amount is still 500.00 after E25 and E26
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
SELECT JSON_EXTRACT(data, REPLACE(
           JSON_UNQUOTE(JSON_SEARCH(data, 'one', 'seed-payment-001', NULL, '$.payments[*].request_id')),
           '.request_id', '.amount')) AS amount_after
FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002';
