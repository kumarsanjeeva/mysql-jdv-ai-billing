-- ============================================================
-- 00_setup.sql
-- Purpose: create the database and the least-privilege AGENT_DB_USER.
--
-- Grants on the duality views (and only the duality views — never a base
-- table) are added at the end of sql/02_duality_views.sql, once those views
-- exist. This file only creates the account.
--
-- Placeholders (__NAME__) are substituted by scripts/run_sql.py from .env
-- before this file is sent to the mysql client — nothing here is a real
-- credential, and this file is committed as-is.
-- ============================================================

CREATE DATABASE IF NOT EXISTS __MYSQL_DB__
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_unicode_ci;

DROP USER IF EXISTS '__AGENT_DB_USER__'@'%';
CREATE USER '__AGENT_DB_USER__'@'%' IDENTIFIED BY '__AGENT_DB_PASSWORD__';
