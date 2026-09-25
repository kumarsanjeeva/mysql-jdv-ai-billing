-- repro_e23_datetime_text_roundtrip.sql
-- MySQL 9.7.2, JSON Duality Views. Self-contained: creates its own database
-- objects; plain SQL, runs as-is in the mysql client.
--
-- Summary: a document read from a duality view cannot be written back as
-- JSON text when a nested array that is WITH(INSERT) only contains a
-- DATETIME column. The unchanged DATETIME comes back as a JSON string (JSON
-- text has no datetime type), MySQL treats it as a modification, and the
-- UPDATE fails with ERROR 6497 "Missing UPDATE tag". Every application
-- client sends documents as text, so it cannot update such a document.
--
-- Expected: step 3 succeeds -- the client changes only the root `status`
-- and sends every child field back exactly as it was read.
-- Actual:   ERROR 6497 (HY000): Missing UPDATE tag on
--           `jdv_repro_scratch`.`e23_payment`.paid_at, path '$.payments[0].paid_at'.
-- Control:  step 2, the same kind of text round trip on a parent with no
--           child rows, succeeds.

CREATE DATABASE IF NOT EXISTS jdv_repro_scratch;
USE jdv_repro_scratch;

DROP VIEW IF EXISTS e23_parent_dv;
DROP TABLE IF EXISTS e23_payment;
DROP TABLE IF EXISTS e23_parent;

CREATE TABLE e23_parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    status VARCHAR(20) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE e23_payment (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    paid_at DATETIME(6) NOT NULL,
    CONSTRAINT fk_e23_payment_parent FOREIGN KEY (parent_id) REFERENCES e23_parent(id)
) ENGINE=InnoDB;

CREATE JSON DUALITY VIEW e23_parent_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'status': status,
    'payments': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT)
                'id': id,
                'amount': amount,
                'paid_at': paid_at
            )
        )
        FROM e23_payment WHERE e23_payment.parent_id = e23_parent.id
    )
)
FROM e23_parent;

-- Step 1: parent 1 without payments; parent 2 with one payment.
INSERT INTO e23_parent_dv VALUES('{"status": "confirmed"}');
INSERT INTO e23_parent_dv VALUES('{"status": "confirmed", "payments": [{"amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}]}');

SELECT data AS read_back,
       JSON_TYPE(JSON_EXTRACT(data, '$.payments[0].paid_at')) AS paid_at_json_type
FROM e23_parent_dv ORDER BY JSON_VALUE(data, '$._id');

-- Step 2 (control): write parent 1 back as JSON text, status changed. Succeeds.
SET @etag1 = (SELECT JSON_VALUE(data, '$._metadata.etag') FROM e23_parent_dv WHERE JSON_VALUE(data, '$._id') = 1);
UPDATE e23_parent_dv
SET data = REPLACE('{"_id": 1, "status": "delivered", "_metadata": {"etag": "__ETAG__"}}', '__ETAG__', @etag1)
WHERE JSON_VALUE(data, '$._id') = 1;
SELECT data AS parent1_after_update FROM e23_parent_dv WHERE JSON_VALUE(data, '$._id') = 1;

-- Step 3: write parent 2 back as JSON text, status changed, payment exactly
-- as read. Fails with ERROR 6497.
SET @etag2 = (SELECT JSON_VALUE(data, '$._metadata.etag') FROM e23_parent_dv WHERE JSON_VALUE(data, '$._id') = 2);
UPDATE e23_parent_dv
SET data = REPLACE('{"_id": 2, "status": "delivered", "payments": [{"id": 1, "amount": 500.00, "paid_at": "2026-09-26 10:00:00.000000"}], "_metadata": {"etag": "__ETAG__"}}', '__ETAG__', @etag2)
WHERE JSON_VALUE(data, '$._id') = 2;

SELECT data AS parent2_after_update FROM e23_parent_dv WHERE JSON_VALUE(data, '$._id') = 2;
