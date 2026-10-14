-- 08_e29_payment_business_guard.sql
-- Purpose: edge case E29 -- GUARD 7 (sql/06_guards_6_7.sql): a payment's
--          business_id must equal the business_id of the order it pays.
--          Same block format as sql/04_edge_cases.sql:
--            -- TEST: <id> <description>
--            -- EXPECT: OK | ERROR | ERROR <code>
--            -- AS: agent
--
-- Runs against the demo database after scripts/reset_db.py (which includes
-- sql/06_guards_6_7.sql) and sql/03_dml_demos.sql. Everything is written as
-- the agent user through the views. Every block ends with ROLLBACK (a failing
-- statement ends the session, which also rolls back), so nothing is left behind.
--
-- Expected error codes are NOT guessed: rejected blocks say `EXPECT: ERROR`
-- and the real code and message are read from the results file.
--
-- Facts used (seed data): seed-order-002 belongs to business 1 (Sunrise
-- Bakers); business 2 is Melody Cakes.

-- TEST: E29a payment through payment_dv with the order's own business_id (1)
-- EXPECT: OK
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @order_id = (SELECT JSON_VALUE(data, '$._id') FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
INSERT INTO payment_dv VALUES(JSON_OBJECT(
    'business_id', 1, 'request_id', 'e29a-matching-business', 'payment_type', 'installment',
    'method', 'cash', 'amount', 100.00, 'order', JSON_OBJECT('id', CAST(@order_id AS UNSIGNED))));
SELECT JSON_VALUE(data, '$.business_id') AS payment_business_id,
       (SELECT JSON_VALUE(o.data, '$.business_id') FROM order_dv o WHERE JSON_VALUE(o.data, '$._id') = @order_id) AS order_business_id
  FROM payment_dv WHERE JSON_VALUE(data, '$.request_id') = 'e29a-matching-business';
ROLLBACK;

-- TEST: E29b payment through payment_dv with a different business_id (2) than its order (1)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
SET @order_id = (SELECT JSON_VALUE(data, '$._id') FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'seed-order-002');
INSERT INTO payment_dv VALUES(JSON_OBJECT(
    'business_id', 2, 'request_id', 'e29b-other-business', 'payment_type', 'installment',
    'method', 'cash', 'amount', 100.00, 'order', JSON_OBJECT('id', CAST(@order_id AS UNSIGNED))));
ROLLBACK;

-- TEST: E29c new order created through order_dv with a nested payment whose business_id (2) differs from the order's (1)
-- EXPECT: ERROR
-- AS: agent
USE __MYSQL_DB__;
START TRANSACTION;
INSERT INTO order_dv VALUES('{"business_id":1,"request_id":"e29c-nested-other-business","order_status":"confirmed","subtotal":900.00,"discount_type":"amount","discount_value":0.00,"gst_value":45.00,"total":945.00,"outlet":{"id":1},"customer":{"id":1},"items":[{"name":"Black Forest Cake","qty":1,"price":900.00,"gst_rate":5.00,"is_gst_inclusive":0,"gst_applicable":1,"discount_exempt":0,"gst_value":45.00,"discount_value":0.00,"product":{"id":1},"product_variant_id":2}],"payments":[{"business_id":2,"request_id":"e29c-nested-payment","payment_type":"advance","method":"upi","amount":500.00}]}');
ROLLBACK;
