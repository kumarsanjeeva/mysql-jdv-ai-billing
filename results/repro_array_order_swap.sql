-- repro_array_order_swap.sql
-- Question: when a client writes back a document whose nested array has the
-- SAME existing elements in a DIFFERENT order, does MySQL match elements to
-- rows by primary key (order irrelevant), or by position?
--
-- Shape mirrors order_dv.items: AUTO_INCREMENT-keyed children with
-- WITH(INSERT, UPDATE), no DELETE. Each TEST block runs in its own session
-- (scripts/run_sql.py test mode) and starts from a fresh parent, so one
-- failure never hides the next.
--
--   SWAP1 -- swap the two children, change nothing else. Expect success with
--            no child row modified (updated_at unchanged).
--   SWAP2 -- swap the two children AND change the label of the element now
--            at index 0 (which is child C2). Expect C2's row to change and
--            C1's row to stay untouched -- i.e. matching is by id.
--
-- Runs in the throwaway jdv_repro_scratch database, never the demo database.

-- TEST: SETUP create swap tables and view
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS swap_parent_dv;
DROP TABLE IF EXISTS swap_child;
DROP TABLE IF EXISTS swap_parent;
CREATE TABLE swap_parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE swap_child (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    label VARCHAR(50) NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_swap_child_parent FOREIGN KEY (parent_id) REFERENCES swap_parent(id)
) ENGINE=InnoDB;
CREATE JSON DUALITY VIEW swap_parent_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'name': name,
    'children': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'label': label
            )
        )
        FROM swap_child WHERE swap_child.parent_id = swap_parent.id
    )
)
FROM swap_parent;

-- TEST: SWAP1 reversed array, no content change
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO swap_parent_dv VALUES('{"name":"S1","children":[{"label":"C1"},{"label":"C2"}]}');
SET @doc = (SELECT data FROM swap_parent_dv WHERE JSON_VALUE(data, '$.name') = 'S1');
SELECT @doc AS before_doc;
SELECT id, label, updated_at FROM swap_child
 WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;
DO SLEEP(0.01);
SET @swapped = JSON_SET(@doc,
    '$.children[0]', JSON_EXTRACT(@doc, '$.children[1]'),
    '$.children[1]', JSON_EXTRACT(@doc, '$.children[0]'));
SELECT @swapped AS sent_doc;
UPDATE swap_parent_dv SET data = @swapped
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@swapped, '$._id');
SELECT ROW_COUNT() AS rows_affected;
SELECT data AS after_doc FROM swap_parent_dv WHERE JSON_VALUE(data, '$.name') = 'S1';
SELECT id, label, updated_at FROM swap_child
 WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;

-- TEST: SWAP2 reversed array, edit label of new index 0 (C2)
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO swap_parent_dv VALUES('{"name":"S2","children":[{"label":"C1"},{"label":"C2"}]}');
SET @doc = (SELECT data FROM swap_parent_dv WHERE JSON_VALUE(data, '$.name') = 'S2');
SELECT @doc AS before_doc;
SELECT id, label, updated_at FROM swap_child
 WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;
DO SLEEP(0.01);
SET @swapped = JSON_SET(@doc,
    '$.children[0]', JSON_SET(JSON_EXTRACT(@doc, '$.children[1]'), '$.label', 'C2-edited'),
    '$.children[1]', JSON_EXTRACT(@doc, '$.children[0]'));
SELECT @swapped AS sent_doc;
UPDATE swap_parent_dv SET data = @swapped
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@swapped, '$._id');
SELECT ROW_COUNT() AS rows_affected;
SELECT data AS after_doc FROM swap_parent_dv WHERE JSON_VALUE(data, '$.name') = 'S2';
SELECT id, label, updated_at FROM swap_child
 WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;
