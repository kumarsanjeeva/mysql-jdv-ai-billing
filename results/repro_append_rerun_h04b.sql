-- repro_append_rerun_h04b.sql
-- The original failing "append with explicit peeked id" attempt against the
-- real order_dv, re-run VERBATIM (same SQL as first attempted). At the time
-- it failed with ERROR 6560 ("... use generated and explicit values for the
-- same primary key"). Since then the schema gained payments.request_id
-- (NOT NULL) and order_dv.payments gained paid_at; the SQL is unchanged.
--
-- Wrapped in a transaction and rolled back so the demo data is unchanged
-- (if the UPDATE errors, the client exits and the open transaction is
-- rolled back when the session ends).

USE __MYSQL_DB__;
START TRANSACTION;

SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments';

SET @doc = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001');

UPDATE order_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.payments', JSON_OBJECT(
    'id', (SELECT AUTO_INCREMENT FROM information_schema.tables WHERE table_schema = '__MYSQL_DB__' AND table_name = 'payments'),
    'business_id', 1, 'payment_type', 'final', 'method', 'cash', 'amount', 1012.00
))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');

SELECT JSON_LENGTH(data, '$.payments') AS payments_after FROM order_dv WHERE JSON_VALUE(data, '$.request_id') = 'h01-demo-001';

ROLLBACK;
