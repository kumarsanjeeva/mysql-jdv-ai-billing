-- repro_append_bisect.sql
-- Bisect the contradiction between results/repro_append_rerun_h04b.sql
-- (real order_dv: explicit-id append FAILS with ERROR 6560) and
-- results/repro_append_explicit_ids.sql (minimal scratch view: explicit-id
-- append SUCCEEDS). Each block changes ONE thing relative to B0 (verbatim).
--
-- Reading the outcome: ERROR 6560 = the new element was treated as
-- "generated". Any other outcome (OK, or a different error such as 6497 on
-- the existing payment's paid_at -- see repro_datetime_roundtrip.sql) means
-- the id check passed.
--
-- Every block runs in a transaction on the real order_dv and is rolled back
-- (on error the session ends and the open transaction rolls back).

-- TEST: B0 verbatim original (inline information_schema subquery for id)
-- EXPECT: ERROR
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT JSON_OBJECT('id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments')) AS new_element_as_built;
UPDATE order_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments'),
    'business_id', 1, 'payment_type', 'final', 'method', 'cash', 'amount', 1012.00
))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');
ROLLBACK;

-- TEST: B1 peeked id read into @next_id first (as the scratch repro does)
-- EXPECT: ERROR
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SET @next_id = (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments');
SELECT @next_id AS next_id;
UPDATE order_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', @next_id,
    'business_id', 1, 'payment_type', 'final', 'method', 'cash', 'amount', 1012.00
))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');
ROLLBACK;

-- TEST: B2 inline subquery kept, new payment given its required request_id
-- EXPECT: ERROR
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
UPDATE order_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments'),
    'business_id', 1, 'request_id', 'bisect-b2', 'payment_type', 'final', 'method', 'cash', 'amount', 1012.00
))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');
ROLLBACK;

-- TEST: B3 id as a hardcoded literal (value taken from the B1 output)
-- EXPECT: ERROR
USE __MYSQL_DB__;
START TRANSACTION;
SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');
SELECT AUTO_INCREMENT AS next_id FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments';
UPDATE order_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', 9,
    'business_id', 1, 'payment_type', 'final', 'method', 'cash', 'amount', 1012.00
))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');
ROLLBACK;

-- TEST: B4 minimal scratch view (repro_append_explicit_ids.sql) with the id as an inline subquery
-- EXPECT: OK
USE jdv_repro_scratch;
START TRANSACTION;
INSERT INTO parent_dv VALUES('{"name":"P-B4","children":[{"label":"C1"}]}');
SET @doc = (SELECT data FROM parent_dv WHERE JSON_VALUE(data, '$.name') = 'P-B4');
UPDATE parent_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.children', JSON_OBJECT(
    'id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = 'jdv_repro_scratch' AND table_name = 'child'),
    'label', 'C2'))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');
SELECT data AS after_update FROM parent_dv WHERE JSON_VALUE(data, '$.name') = 'P-B4';
ROLLBACK;
