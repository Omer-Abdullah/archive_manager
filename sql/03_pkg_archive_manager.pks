--------------------------------------------------------------------------------
-- 03_pkg_archive_manager.pks                       archive_manager v1.0.0
-- Package specification. Install in the schema that owns the business tables.
-- Definer rights: needs a DIRECT grant on SYS.DBMS_LOCK.
--------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE PKG_ARCHIVE_MANAGER AUTHID DEFINER AS

    c_version CONSTANT VARCHAR2(10) := '1.0.0';

    FUNCTION version RETURN VARCHAR2;

    ----------------------------------------------------------------------------
    -- RUN_JOB: the single entry point used by archive_manager.sh.
    --
    -- p_mode         CHECK    validate config/structures, no changes
    --                STAGE    select rows for a run (read-only on source tables)
    --                ARCHIVE  copy + delete staged rows, batch by batch
    --                ROLLBACK move archived rows of a run back to the source
    --                VERIFY   count leftovers in source and rows in archive
    --                STATS    gather optimizer stats on completed tables
    --                CLOSE    close a run and drop its staging partition
    -- p_run_id       IN: run to work on (NULL with STAGE = create a new run)
    --                OUT: the run id used
    -- p_table_csv    optional comma list limiting this execution to some tables
    -- p_batch_size   STAGE only: overrides ARCHIVE_TABLE_CONFIG.BATCH_SIZE
    -- p_max_minutes  time limit: stops cleanly (status PAUSED) before it
    -- p_force        'Y' = CLOSE a run even with unfinished tables
    -- p_exec_id      OUT: id of this execution (ARCHIVE_EXEC)
    -- p_status       OUT: COMPLETED | PAUSED | STOPPED | FAILED
    -- p_message      OUT: error or summary text
    --
    -- Parameter errors raise ORA-20xxx before anything is recorded. Once the
    -- execution has started, errors are recorded and returned as FAILED.
    ----------------------------------------------------------------------------
    PROCEDURE RUN_JOB (
        p_mode         IN     VARCHAR2,
        p_run_id       IN OUT NUMBER,
        p_table_csv    IN     VARCHAR2 DEFAULT NULL,
        p_batch_size   IN     NUMBER   DEFAULT NULL,
        p_max_minutes  IN     NUMBER   DEFAULT NULL,
        p_force        IN     VARCHAR2 DEFAULT 'N',
        p_exec_id      OUT    NUMBER,
        p_status       OUT    VARCHAR2,
        p_message      OUT    VARCHAR2);

    -- Ask running executions to stop after their current batch.
    -- p_exec_id NULL = every running execution of p_run_id.
    PROCEDURE REQUEST_STOP (p_run_id IN NUMBER, p_exec_id IN NUMBER DEFAULT NULL);

    -- One-time preparation of an archive table: adds the INVISIBLE tag columns
    -- ARC_RUN_ID / ARC_BATCH_NO and an index on them. Invisible columns are
    -- skipped by SELECT * and by INSERT without a column list, so existing
    -- application code and scripts keep working unchanged.
    PROCEDURE PREPARE_ARC_TABLE (
        p_table_name  IN VARCHAR2,
        p_parallel    IN NUMBER   DEFAULT 8,
        p_index_ts    IN VARCHAR2 DEFAULT NULL);

END PKG_ARCHIVE_MANAGER;
/
