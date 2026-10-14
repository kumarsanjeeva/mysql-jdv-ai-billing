-- 14_trigger_order_evidence.sql
-- Purpose: evidence of the firing order of the order_items INSERT triggers.
--          GUARD 6 (trg_order_items_guard_ins) must fire first, GUARD 8
--          (trg_order_items_guard_tenant_ins) second, so a row that breaks
--          both reports GUARD 6 (E30f). Re-applying sql/06 alone recreates
--          guard_ins and puts it after the GUARD 8 trigger; always re-apply
--          06 and 09 together, in that order.
USE __MYSQL_DB__;
SELECT EVENT_OBJECT_TABLE AS on_table, EVENT_MANIPULATION AS event, ACTION_TIMING AS timing,
       ACTION_ORDER, TRIGGER_NAME
  FROM INFORMATION_SCHEMA.TRIGGERS
 WHERE EVENT_OBJECT_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = 'order_items'
   AND EVENT_MANIPULATION = 'INSERT' AND ACTION_TIMING = 'BEFORE'
 ORDER BY ACTION_ORDER;
SELECT IF((SELECT ACTION_ORDER FROM INFORMATION_SCHEMA.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = DATABASE()
            AND TRIGGER_NAME = 'trg_order_items_guard_ins') = 1
      AND (SELECT ACTION_ORDER FROM INFORMATION_SCHEMA.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = DATABASE()
            AND TRIGGER_NAME = 'trg_order_items_guard_tenant_ins') = 2,
      'PASS: guard_ins = 1, guard_tenant_ins = 2', (SELECT 1 UNION SELECT 2)) AS order_check;
