-- ============================================================
-- reset_drop_database.sql
-- Purpose: drop the demo database so scripts/reset_db.py can rebuild it
-- from scratch (00_setup -> 01_schema -> 02_duality_views).
--
-- Deliberately NOT numbered: running the numbered files in order must never
-- wipe the database by accident. Only reset_db.py runs this.
-- ============================================================

DROP DATABASE IF EXISTS __MYSQL_DB__;
