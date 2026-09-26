-- repro_e27_jsontable_set_subquery.sql  (finding E27)
-- MySQL 9.7.2. Self-contained: creates its own objects in jdv_repro_scratch.
--
-- JSON_TABLE over a duality view's `data` column fails with ERROR 1210
-- "Incorrect arguments to JSON_TABLE" when the query is a scalar subquery
-- inside SET @var = (...). The identical query succeeds when run on its
-- own, when written as SELECT ... INTO @var, and in the SET form when the
-- JSON does not come from a duality view.
--
-- Each TEST block runs in its own session (scripts/run_sql.py test mode).

-- TEST: SETUP one parent with two children, and a duality view over them
-- EXPECT: OK
USE jdv_repro_scratch;
DROP VIEW IF EXISTS e27_parent_dv;
DROP TABLE IF EXISTS e27_child;
DROP TABLE IF EXISTS e27_parent;
CREATE TABLE e27_parent (id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50) NOT NULL) ENGINE=InnoDB;
CREATE TABLE e27_child (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    CONSTRAINT fk_e27_child_parent FOREIGN KEY (parent_id) REFERENCES e27_parent(id)
) ENGINE=InnoDB;
CREATE JSON DUALITY VIEW e27_parent_dv AS
SELECT JSON_DUALITY_OBJECT(
    '_id': id,
    'name': name,
    'children': (SELECT JSON_ARRAYAGG(JSON_DUALITY_OBJECT('id': id)) FROM e27_child WHERE e27_child.parent_id = e27_parent.id)
)
FROM e27_parent;
INSERT INTO e27_parent (name) VALUES ('P1');
INSERT INTO e27_child (parent_id) VALUES (1), (1);

-- TEST: Q1 the query on its own
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT MAX(c.id) AS max_child_id
  FROM e27_parent_dv p, JSON_TABLE(p.data, '$.children[*]' COLUMNS (id BIGINT PATH '$.id')) c
 WHERE JSON_VALUE(p.data, '$.name') = 'P1';

-- TEST: Q2 the same query as SELECT ... INTO @var
-- EXPECT: OK
USE jdv_repro_scratch;
SELECT MAX(c.id) INTO @max_child_id
  FROM e27_parent_dv p, JSON_TABLE(p.data, '$.children[*]' COLUMNS (id BIGINT PATH '$.id')) c
 WHERE JSON_VALUE(p.data, '$.name') = 'P1';
SELECT @max_child_id AS max_child_id;

-- TEST: Q3 the same query as a scalar subquery in SET @var = (...)
-- EXPECT: OK
USE jdv_repro_scratch;
SET @max_child_id = (SELECT MAX(c.id)
  FROM e27_parent_dv p, JSON_TABLE(p.data, '$.children[*]' COLUMNS (id BIGINT PATH '$.id')) c
 WHERE JSON_VALUE(p.data, '$.name') = 'P1');
SELECT @max_child_id AS max_child_id;

-- TEST: Q4 control: SET @var = (...) with JSON_TABLE over JSON that is not from a duality view
-- EXPECT: OK
USE jdv_repro_scratch;
SET @max_child_id = (SELECT MAX(c.id)
  FROM (SELECT JSON_OBJECT('children', JSON_ARRAY(JSON_OBJECT('id', 1), JSON_OBJECT('id', 2))) AS data) p,
       JSON_TABLE(p.data, '$.children[*]' COLUMNS (id BIGINT PATH '$.id')) c);
SELECT @max_child_id AS max_child_id;
