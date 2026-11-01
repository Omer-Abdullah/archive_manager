--------------------------------------------------------------------------------
-- examples/03_register_tables.sql                  archive_manager v1.0.0
--
-- EXAMPLE ONLY. Registers the tables of examples/01 and 02 in
-- ARCHIVE_TABLE_CONFIG. Run as the engine owner after install.sql.
--
-- Columns
--   TABLE_ORDER      archive order: children low, parents high (unique).
--                    Rollback runs in the reverse order.
--   TABLE_NAME       source table            TABLE_OWNER  defaults to USER
--   ARC_TABLE_NAME   archive table, same owner
--   KEY_COLUMN       unique row key (character or NUMBER), re-checked on
--                    every copy and delete
--   JOIN_COLUMN      source column matched to the worklist
--   WORKLIST_TABLE / WORKLIST_COLUMN   the worklist of examples/01
--   JOIN_CAST        NULL = compare as is; 'TO_CHAR' = TO_CHAR(worklist col),
--                    for a NUMBER worklist against a VARCHAR2 column when you
--                    want an index on that column to be usable
--   BATCH_SIZE       rows per batch (1,000 - 2,000,000); aim for 2-5 minutes
--                    per batch, tune from V_ARCHIVE_PROGRESS.AVG_BATCH_SEC
--   PARALLEL_DEGREE  for staging, verify and stats (1 - 64)
--   DEPENDS_ON       NULL   = wait for every ENABLED table with a lower order
--                    'NONE' = independent, archive in any order / window
--                    'A,B'  = wait only for tables A and B (COMPLETED)
--   ENABLED_FLAG     'N' until "-m check -t <table>" is clean
--
-- Rows start DISABLED. For each table:
--   archive_manager.sh -m check -t ORDER_ITEMS      (works while disabled)
--   UPDATE archive_table_config SET enabled_flag = 'Y' WHERE table_name = ...;
--   then run sql/06_prepare_arc_tables.sql (adds the tag columns + index).
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

INSERT INTO archive_table_config (table_order, table_name, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree,
                                  depends_on, enabled_flag, notes)
VALUES (10, 'ORDER_ITEMS', 'ORDER_ITEMS_ARC', 'ITEM_ID', 'ORDER_ID',
        'ARC_WORKLIST_ORDERS', 'ORDER_ID', NULL, 500000, 8,
        'NONE', 'N', 'Child of ORDERS');

INSERT INTO archive_table_config (table_order, table_name, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree,
                                  depends_on, enabled_flag, notes)
VALUES (20, 'ORDER_PAYMENTS', 'ORDER_PAYMENTS_ARC', 'PAYMENT_ID', 'ORDER_ID',
        'ARC_WORKLIST_ORDERS', 'ORDER_ID', NULL, 500000, 8,
        'NONE', 'N', 'Child of ORDERS');

-- Independent table whose ORDER_ID is a VARCHAR2: TO_CHAR keeps its index usable.
INSERT INTO archive_table_config (table_order, table_name, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree,
                                  depends_on, enabled_flag, notes)
VALUES (30, 'ORDER_EVENTS', 'ORDER_EVENTS_ARC', 'EVENT_ID', 'ORDER_ID',
        'ARC_WORKLIST_ORDERS', 'ORDER_ID', 'TO_CHAR', 500000, 8,
        'NONE', 'N', 'No FK; any order');

-- Parent: DEPENDS_ON NULL = waits for every enabled table with a lower order.
INSERT INTO archive_table_config (table_order, table_name, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree,
                                  depends_on, enabled_flag, notes)
VALUES (100, 'ORDERS', 'ORDERS_ARC', 'ORDER_ID', 'ORDER_ID',
        'ARC_WORKLIST_ORDERS', 'ORDER_ID', NULL, 100000, 4,
        NULL, 'N', 'Parent table: always last');

COMMIT;

COLUMN table_name FORMAT A24
COLUMN depends_on FORMAT A40
SELECT table_order, table_name, enabled_flag, batch_size,
       NVL(depends_on, '(all lower-order enabled tables)') AS depends_on
  FROM archive_table_config
 ORDER BY table_order;
