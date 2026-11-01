--------------------------------------------------------------------------------
-- T02_test_config.sql                              archive_manager v1.0.0
-- Config rows for the synthetic tables (TABLE_ORDER 910-940, so they never
-- clash with your own configuration), then tag columns + index on their archives.
-- Small batch sizes on purpose: many batches exercise pause/stop/resume.
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DELETE FROM archive_table_config WHERE table_name LIKE 'TST\_%' ESCAPE '\';

INSERT INTO archive_table_config (table_order, table_name, table_owner, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree, enabled_flag, notes)
VALUES (910, 'TST_ORDER_ITEM', USER, 'TST_ORDER_ITEM_ARC', 'ITEMID', 'TOPORDERID',
        'TST_PURGE_ORDER_IDS', 'ORDER_ID', NULL, 5000, 2, 'Y', 'test kit');

INSERT INTO archive_table_config (table_order, table_name, table_owner, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree, enabled_flag, notes)
VALUES (920, 'TST_BASKET_ITEM', USER, 'TST_BASKET_ITEM_ARC', 'BASKETITEMID', 'BASKETID',
        'TST_PURGE_BASKETS', 'BASKETID', NULL, 5000, 2, 'Y', 'test kit');

INSERT INTO archive_table_config (table_order, table_name, table_owner, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree, enabled_flag, notes)
VALUES (930, 'TST_BASKET', USER, 'TST_BASKET_ARC', 'BASKETID', 'BASKETID',
        'TST_PURGE_BASKETS', 'BASKETID', NULL, 2000, 2, 'Y', 'test kit');

INSERT INTO archive_table_config (table_order, table_name, table_owner, arc_table_name, key_column, join_column,
                                  worklist_table, worklist_column, join_cast, batch_size, parallel_degree, enabled_flag, notes)
VALUES (940, 'TST_ORDER', USER, 'TST_ORDER_ARC', 'ORDERID', 'ORDERID',
        'TST_PURGE_ORDER_IDS', 'ORDER_ID', NULL, 2000, 2, 'Y', 'test kit');

COMMIT;

BEGIN
    FOR c IN (SELECT table_name FROM archive_table_config
               WHERE table_name LIKE 'TST\_%' ESCAPE '\' ORDER BY table_order) LOOP
        pkg_archive_manager.prepare_arc_table(p_table_name => c.table_name, p_parallel => 2);
    END LOOP;
END;
/

ALTER VIEW TST_ARC_SIGNATURES COMPILE;
