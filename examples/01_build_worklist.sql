--------------------------------------------------------------------------------
-- examples/01_build_worklist.sql                   archive_manager v1.0.0
--
-- EXAMPLE ONLY - adapt the table names and the business rule to your schema.
--
-- A worklist is a plain table holding the parent keys to archive in one
-- purge cycle (one run). The engine never decides WHAT to archive: you do,
-- here. Every configured table joins its JOIN_COLUMN to the worklist.
--
-- Example schema (yours will differ):
--   ORDERS          parent      key ORDER_ID      (status, last_updated)
--   ORDER_ITEMS     child       key ITEM_ID       -> ORDERS.ORDER_ID
--   ORDER_PAYMENTS  child       key PAYMENT_ID    -> ORDERS.ORDER_ID
--   ORDER_EVENTS    independent key EVENT_ID      (ORDER_ID, no FK)
--
-- Rule in this example: orders closed or cancelled more than 18 months ago.
-- Run as the schema that owns the business tables and the engine.
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE KEEP_MONTHS = 18

-- Re-runnable: drop the previous cycle's worklist. Close the previous run
-- first (archive_manager.sh -m close -r <id>): staging of a new run refuses
-- tables whose archive already holds rows of the worklist.
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE ARC_WORKLIST_ORDERS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE <> -942 THEN RAISE; END IF;
END;
/

CREATE TABLE ARC_WORKLIST_ORDERS
(
    ORDER_ID  NUMBER  NOT NULL
);

INSERT /*+ APPEND */ INTO ARC_WORKLIST_ORDERS (ORDER_ID)
SELECT o.order_id
  FROM orders o
 WHERE o.status IN ('CLOSED', 'CANCELLED')
   AND o.last_updated < ADD_MONTHS(TRUNC(SYSDATE), -&&KEEP_MONTHS);
COMMIT;

-- An index (or primary key) on the worklist column keeps the semi-joins cheap.
ALTER TABLE ARC_WORKLIST_ORDERS ADD CONSTRAINT ARC_WORKLIST_ORDERS_PK PRIMARY KEY (ORDER_ID);

EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => 'ARC_WORKLIST_ORDERS');

SELECT COUNT(*) AS orders_to_archive FROM ARC_WORKLIST_ORDERS;
