-- repro_append_explicit_ids.sql
-- Minimal repro for MySQL 9.7.2 JSON Duality View behavior that appears to
-- contradict the documented AUTO_INCREMENT rule: "A field of a JSON document
-- that maps to a primary key column that has the AUTO_INCREMENT attribute
-- cannot have a mix of both explicit and generated values. The JSON document
-- must either provide all automatically generated values, or none of them."
-- (https://dev.mysql.com/doc/refman/9.7/en/jdv-requirements.html)
--
-- Here every child element in the array supplies an EXPLICIT primary key
-- value -- none is omitted, none relies on generation -- and MySQL still
-- rejects the write with the "generated and explicit values" error.
--
-- Two tables, one parent row, one pre-existing child. The UPDATE adds a
-- second child with an explicit (real, correctly peeked, not-yet-used) id,
-- alongside the pre-existing child referenced by its own real id.

CREATE DATABASE IF NOT EXISTS jdv_repro_scratch;
USE jdv_repro_scratch;

DROP VIEW IF EXISTS parent_dv;
DROP TABLE IF EXISTS child;
DROP TABLE IF EXISTS parent;

CREATE TABLE parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE child (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    label VARCHAR(50) NOT NULL,
    CONSTRAINT fk_child_parent FOREIGN KEY (parent_id) REFERENCES parent(id)
) ENGINE=InnoDB;

CREATE JSON DUALITY VIEW parent_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'name': name,
    'children': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT)
                'id': id,
                'label': label
            )
        )
        FROM child WHERE child.parent_id = parent.id
    )
)
FROM parent;

-- Step 1: create a parent with one child (both auto-generated).
INSERT INTO parent_dv VALUES('{"name":"P1","children":[{"label":"C1"}]}');
SELECT data AS after_insert FROM parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1';

-- Step 2: peek the real, next AUTO_INCREMENT value for `child` -- not a
-- guess, the actual value MySQL would assign next.
SELECT AUTO_INCREMENT AS next_child_id FROM information_schema.tables
WHERE table_schema = 'jdv_repro_scratch' AND table_name = 'child';

-- Step 3: UPDATE the parent document. Existing child kept by its real id.
-- New child added with an EXPLICIT id equal to the peeked value. Every id
-- in this array is explicit; none is omitted; none asks MySQL to generate.
SET @doc = (SELECT data FROM parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1');
SET @next_id = (SELECT AUTO_INCREMENT FROM information_schema.tables
                 WHERE table_schema = 'jdv_repro_scratch' AND table_name = 'child');

UPDATE parent_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.children', JSON_OBJECT('id', @next_id, 'label', 'C2'))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');

-- EXPECTED per the documented rule: succeeds (every id is explicit).
-- ACTUAL: see repro_append_explicit_ids.txt for what MySQL 9.7.2 actually did.
SELECT data AS after_update FROM parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1';
