--------------------------------------------------------------------------------
-- 06_prepare_arc_tables.sql                        archive_manager v1.0.0
--
-- Adds the INVISIBLE tag columns ARC_RUN_ID / ARC_BATCH_NO and their index to
-- the archive table of every ENABLED config row. Safe to re-run.
--   * Adding a nullable column without default is a dictionary-only change.
--   * The index build reads the whole archive table once (parallel 8); rows
--     archived earlier by other processes have NULL tags and are not
--     stored in the index.
--   * Invisible columns are skipped by SELECT * and by INSERT without a column
--     list: existing scripts and application code keep working unchanged.
-- Run as the engine owner. Change INDEX_TS if needed.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
DEFINE INDEX_TS = USERS

BEGIN
    FOR c IN (SELECT table_name FROM archive_table_config WHERE enabled_flag = 'Y' ORDER BY table_order) LOOP
        pkg_archive_manager.prepare_arc_table(p_table_name => c.table_name, p_parallel => 8, p_index_ts => '&&INDEX_TS');
    END LOOP;
END;
/
