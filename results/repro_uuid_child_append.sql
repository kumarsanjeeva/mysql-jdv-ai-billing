-- repro_uuid_child_append.sql
-- Companion to repro_append_explicit_ids.sql. Same shape (one parent, one
-- pre-existing child, UPDATE that appends a second child with an explicit
-- key), with ONE difference: the child's primary key is a client-supplied
-- CHAR(36) UUID -- no AUTO_INCREMENT anywhere on the child table.
--
-- Question: is the "generated and explicit values for the same primary key"
-- rejection specific to AUTO_INCREMENT keys, or does appending a new child
-- to an existing nested array fail regardless of key type?
--
-- Runs in the throwaway jdv_repro_scratch database, never the demo database.

USE jdv_repro_scratch;

DROP VIEW IF EXISTS uuid_parent_dv;
DROP TABLE IF EXISTS uuid_child;
DROP TABLE IF EXISTS uuid_parent;

CREATE TABLE uuid_parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE uuid_child (
    id CHAR(36) NOT NULL PRIMARY KEY,          -- client-supplied UUID, no default
    parent_id BIGINT UNSIGNED NOT NULL,
    label VARCHAR(50) NOT NULL,
    CONSTRAINT fk_uuid_child_parent FOREIGN KEY (parent_id) REFERENCES uuid_parent(id)
) ENGINE=InnoDB;

CREATE JSON DUALITY VIEW uuid_parent_dv AS
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
        FROM uuid_child WHERE uuid_child.parent_id = uuid_parent.id
    )
)
FROM uuid_parent;

-- Step 1: create a parent with one child; the child's UUID is supplied.
INSERT INTO uuid_parent_dv VALUES(JSON_OBJECT(
    'name', 'P1',
    'children', JSON_ARRAY(JSON_OBJECT('id', UUID(), 'label', 'C1'))
));
SELECT data AS after_insert FROM uuid_parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1';

-- Step 2: UPDATE the parent document: keep C1 by its real UUID, append C2
-- with a new explicit UUID. Every key in the array is explicit.
SET @doc = (SELECT data FROM uuid_parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1');

UPDATE uuid_parent_dv
SET data = JSON_ARRAY_APPEND(@doc, '$.children', JSON_OBJECT('id', UUID(), 'label', 'C2'))
WHERE JSON_VALUE(@doc, '$._id') = JSON_VALUE(data, '$._id');

SELECT ROW_COUNT() AS rows_affected;
SELECT data AS after_update FROM uuid_parent_dv WHERE JSON_VALUE(data, '$.name') = 'P1';
SELECT id, parent_id, label FROM uuid_child ORDER BY label;
