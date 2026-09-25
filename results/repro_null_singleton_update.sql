-- repro_null_singleton_update.sql  (finding E20)
-- Minimal standalone repro: a nested array element whose nullable foreign
-- key is exposed as a nested READ-ONLY singleton object cannot be written
-- back once that foreign key is NULL.
--
-- Mirrors order_dv: order_items.product_variant_id (nullable FK) exposed as
-- 'product_variant': (SELECT JSON_DUALITY_OBJECT('id': id, ...) ...).
-- Here: child.ref_id (nullable FK to ref) exposed as 'ref': {...}.
--
-- A read of a child with ref_id = NULL returns "ref": null. The client then
-- UPDATEs the parent document (changing only a root scalar) and either:
--   NS1 -- sends the document back verbatim ("ref": null left in place), or
--   NS2 -- removes the "ref" key from that child before sending.
-- A document is only ever written the way it was read, so the expected
-- outcome of both is OK. Neither child's reference is being changed.
--
--   NS3 -- control: same UPDATE on a parent whose children ALL have a ref.
--   NS4 -- workaround: a second view over the SAME tables exposing the FK as
--          a flat scalar field 'ref_id' instead of the nested 'ref' object;
--          verbatim round trip of a document containing "ref_id": null.
--   NS5 -- consequence of the workaround: through the scalar view the FK is
--          an ordinary updatable column of the child (set NULL -> 1).
--
-- Runs in the throwaway jdv_repro_scratch database, never the demo database.
-- Each TEST block runs in its own session (scripts/run_sql.py test mode).

-- TEST: SETUP create tables and both views
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS ns_parent_dv, ns_parent_scalar_dv;
DROP TABLE IF EXISTS ns_child;
DROP TABLE IF EXISTS ns_parent;
DROP TABLE IF EXISTS ns_ref;
CREATE TABLE ns_ref (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE ns_parent (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE ns_child (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    ref_id BIGINT UNSIGNED NULL,
    label VARCHAR(50) NOT NULL,
    CONSTRAINT fk_ns_child_parent FOREIGN KEY (parent_id) REFERENCES ns_parent(id),
    CONSTRAINT fk_ns_child_ref FOREIGN KEY (ref_id) REFERENCES ns_ref(id)
) ENGINE=InnoDB;
INSERT INTO ns_ref (label) VALUES ('R1');

-- Nested read-only singleton (the order_dv.items[].product_variant shape).
CREATE JSON DUALITY VIEW ns_parent_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'name': name,
    'children': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'label': label,
                'ref': (
                    SELECT JSON_DUALITY_OBJECT('id': id, 'label': label)
                    FROM ns_ref WHERE ns_ref.id = ns_child.ref_id
                )
            )
        )
        FROM ns_child WHERE ns_child.parent_id = ns_parent.id
    )
)
FROM ns_parent;

-- Workaround shape: the FK as a flat scalar field on the child.
CREATE JSON DUALITY VIEW ns_parent_scalar_dv AS
SELECT JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
    '_id': id,
    'name': name,
    'children': (
        SELECT JSON_ARRAYAGG(
            JSON_DUALITY_OBJECT( WITH(INSERT, UPDATE)
                'id': id,
                'label': label,
                'ref_id': ref_id
            )
        )
        FROM ns_child WHERE ns_child.parent_id = ns_parent.id
    )
)
FROM ns_parent;

-- TEST: NS1 nested ref, one child ref NULL, verbatim round trip
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO ns_parent_dv VALUES('{"name":"NS1","children":[{"label":"A","ref":{"id":1}},{"label":"B"}]}');
SET @doc = (SELECT data FROM ns_parent_dv WHERE JSON_VALUE(data, '$.name') = 'NS1');
SELECT @doc AS read_back;
UPDATE ns_parent_dv SET data = JSON_SET(@doc, '$.name', 'NS1-renamed')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT data AS after_update FROM ns_parent_dv WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: NS2 nested ref, one child ref NULL, null key removed before write
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO ns_parent_dv VALUES('{"name":"NS2","children":[{"label":"A","ref":{"id":1}},{"label":"B"}]}');
SET @doc = (SELECT data FROM ns_parent_dv WHERE JSON_VALUE(data, '$.name') = 'NS2');
SELECT @doc AS read_back;
SET @sent = JSON_SET(JSON_REMOVE(@doc, '$.children[1].ref'), '$.name', 'NS2-renamed');
SELECT @sent AS sent_doc;
UPDATE ns_parent_dv SET data = @sent
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@sent, '$._id');
SELECT data AS after_update FROM ns_parent_dv WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: NS3 control, nested ref, every child has a ref, verbatim round trip
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO ns_parent_dv VALUES('{"name":"NS3","children":[{"label":"A","ref":{"id":1}},{"label":"B","ref":{"id":1}}]}');
SET @doc = (SELECT data FROM ns_parent_dv WHERE JSON_VALUE(data, '$.name') = 'NS3');
SELECT @doc AS read_back;
UPDATE ns_parent_dv SET data = JSON_SET(@doc, '$.name', 'NS3-renamed')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT data AS after_update FROM ns_parent_dv WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');

-- TEST: NS4 workaround, scalar ref_id, one child NULL, verbatim round trip
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO ns_parent_scalar_dv VALUES('{"name":"NS4","children":[{"label":"A","ref_id":1},{"label":"B"}]}');
SET @doc = (SELECT data FROM ns_parent_scalar_dv WHERE JSON_VALUE(data, '$.name') = 'NS4');
SELECT @doc AS read_back;
UPDATE ns_parent_scalar_dv SET data = JSON_SET(@doc, '$.name', 'NS4-renamed')
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT data AS after_update FROM ns_parent_scalar_dv WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT id, label, ref_id FROM ns_child WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;

-- TEST: NS5 workaround consequence, scalar ref_id is writable (NULL -> 1)
-- EXPECT: OK
USE jdv_repro_scratch;
INSERT INTO ns_parent_scalar_dv VALUES('{"name":"NS5","children":[{"label":"A","ref_id":1},{"label":"B"}]}');
SET @doc = (SELECT data FROM ns_parent_scalar_dv WHERE JSON_VALUE(data, '$.name') = 'NS5');
UPDATE ns_parent_scalar_dv SET data = JSON_SET(@doc, '$.children[1].ref_id', 1)
 WHERE JSON_VALUE(data, '$._id') = JSON_VALUE(@doc, '$._id');
SELECT id, label, ref_id FROM ns_child WHERE parent_id = JSON_VALUE(@doc, '$._id') ORDER BY id;
