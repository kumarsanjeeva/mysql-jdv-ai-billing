-- repro_datetime_roundtrip.sql
-- Question (from H05): a document is read from a duality view and written
-- back with only a root scalar changed. The nested child array is
-- WITH(INSERT) only (like order_dv.payments) and has a DATETIME(6) column
-- (like payments.paid_at). Does the write succeed, and does the answer
-- depend on HOW the client holds/sends the document?
--
--   A  -- document held in a user variable (@doc), as sql/03_dml_demos.sql does
--   B  -- document held in a temporary table with a JSON column (so it
--         stays JSON; the id is fetched first because a temporary table
--         can be referenced only once per statement)
--   C  -- user variable wrapped in CAST(@doc AS JSON)
--   D1 -- literal JSON text, the way an application sends it, datetime in
--         MySQL format ("2026-09-26 10:00:00.000000")
--   D2 -- same literal, datetime in ISO format ("2026-09-26T10:00:00.000000")
--
-- In D1/D2 the document is a string literal written in this file; only the
-- generated ids and the etag are filled in with REPLACE, exactly as an
-- application fills them in from its previous read.
--
-- Every test expects OK: nothing in the child array is being changed.
-- Runs in the throwaway jdv_repro_scratch database. Each TEST block runs in
-- its own session and creates its own parent, so blocks are independent.

-- TEST: SETUP create tables and view
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS dt_parent_dv;
DROP TABLE IF EXISTS dt_payment;
DROP TABLE IF EXISTS dt_parent;
CREATE TABLE dt_parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE dt_payment (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    paid_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_dt_payment_parent FOREIGN KEY (parent_id) REFERENCES dt_parent(id)
) ENGINE=InnoDB;
CREATE JSON DUALITY VIEW dt_parent_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'name': name,
    'status': status,
    'payments': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT)
                'id': id,
                'amount': amount,
                'paid_at': paid_at
            )
        )
        FROM dt_payment WHERE dt_payment.parent_id = dt_parent.id
    )
)
FROM dt_parent;

-- TEST: A document in a user variable
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO dt_parent_dv VALUES('{"name":"A","status":"confirmed","payments":[{"amount":500.00,"paid_at":"2026-09-26 10:00:00.000000"}]}');
SET @doc = (SELECT data FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'A');
SELECT (SELECT JSON_TYPE(JSON_EXTRACT(data, '$.payments[0].paid_at')) FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'A') AS type_in_view,
       JSON_TYPE(JSON_EXTRACT(@doc, '$.payments[0].paid_at')) AS type_in_user_var;
UPDATE dt_parent_dv SET data = JSON_SET(@doc, '$.status', 'delivered')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT data AS after_update FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'A';

-- TEST: B document in a temporary table with a JSON column
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO dt_parent_dv VALUES('{"name":"B","status":"confirmed","payments":[{"amount":500.00,"paid_at":"2026-09-26 10:00:00.000000"}]}');
CREATE TEMPORARY TABLE held_doc (doc JSON NOT NULL);
INSERT INTO held_doc SELECT data FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'B';
SELECT JSON_TYPE(JSON_EXTRACT(doc, '$.payments[0].paid_at')) AS type_in_temp_table FROM held_doc;
-- A TEMPORARY table may appear only once per statement (ERROR 1137
-- otherwise), so the id is fetched first; the document itself never leaves
-- the JSON column.
SET @pid = (SELECT JSON_VALUE(doc, '$._id') FROM held_doc);
UPDATE dt_parent_dv SET data = (SELECT JSON_SET(doc, '$.status', 'delivered') FROM held_doc)
 WHERE JSON_VALUE(data, '$._id') = @pid;
SELECT data AS after_update FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'B';

-- TEST: C user variable wrapped in CAST(@doc AS JSON)
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO dt_parent_dv VALUES('{"name":"C","status":"confirmed","payments":[{"amount":500.00,"paid_at":"2026-09-26 10:00:00.000000"}]}');
SET @doc = (SELECT data FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'C');
SELECT JSON_TYPE(JSON_EXTRACT(CAST(@doc AS JSON), '$.payments[0].paid_at')) AS type_after_cast;
UPDATE dt_parent_dv SET data = JSON_SET(CAST(@doc AS JSON), '$.status', 'delivered')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT data AS after_update FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'C';

-- TEST: D1 literal JSON text, MySQL datetime format
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO dt_parent_dv VALUES('{"name":"D1","status":"confirmed","payments":[{"amount":500.00,"paid_at":"2026-09-26 10:00:00.000000"}]}');
SELECT data AS read_back FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D1';
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @pid, @payid, @etag
  FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D1';
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __PID__, "name": "D1", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__PID__', @pid), '__PAYID__', @payid), '__ETAG__', @etag);
SELECT @sent AS sent_text;
UPDATE dt_parent_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @pid;
SELECT data AS after_update FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D1';

-- TEST: D2 literal JSON text, ISO datetime format (with T)
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO dt_parent_dv VALUES('{"name":"D2","status":"confirmed","payments":[{"amount":500.00,"paid_at":"2026-09-26 10:00:00.000000"}]}');
SELECT data AS read_back FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D2';
SELECT JSON_VALUE(data, '$._id'), JSON_VALUE(data, '$.payments[0].id'), JSON_VALUE(data, '$._metadata.etag')
  INTO @pid, @payid, @etag
  FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D2';
SET @sent = REPLACE(REPLACE(REPLACE(
  '{"_id": __PID__, "name": "D2", "status": "delivered", "payments": [{"id": __PAYID__, "amount": 500.00, "paid_at": "2026-09-26T10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}',
  '__PID__', @pid), '__PAYID__', @payid), '__ETAG__', @etag);
SELECT @sent AS sent_text;
UPDATE dt_parent_dv SET data = @sent WHERE JSON_VALUE(data, '$._id') = @pid;
SELECT data AS after_update FROM dt_parent_dv WHERE JSON_VALUE(data, '$.name') = 'D2';
