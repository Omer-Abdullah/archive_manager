--------------------------------------------------------------------------------
-- 04_pkg_archive_manager.pkb                       archive_manager v1.0.0
--
-- Design notes
--   * One run = one purge cycle (one worklist), worked on by many executions.
--   * STAGE stores ROWID + row key of every selected row with a batch number,
--     in one transaction together with the batch list and the table state.
--   * ARCHIVE processes one batch per transaction: copy rows to the archive
--     table (tagged ARC_RUN_ID/ARC_BATCH_NO), delete the same rows, check that
--     both counts are equal, commit. A deleted row is therefore always in the
--     archive. Both statements re-check the row key, so a reused ROWID can
--     never move or delete the wrong row.
--   * Every batch is checked against a stop flag and a time limit.
--   * Per-table DBMS_LOCK user locks (not released by COMMIT, released
--     automatically if the session dies) prevent two sessions working on the
--     same table anywhere in the RAC cluster. Different tables may run in
--     parallel sessions when DEPENDS_ON allows it.
--   * Identifiers from the config are validated with DBMS_ASSERT and quoted.
--------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY PKG_ARCHIVE_MANAGER AS

    TYPE t_names  IS TABLE OF VARCHAR2(128);
    TYPE t_rowids IS TABLE OF ROWID;
    TYPE t_keys   IS TABLE OF VARCHAR2(32767);

    SUBTYPE t_cfg   IS archive_table_config%ROWTYPE;
    SUBTYPE t_state IS archive_run_state%ROWTYPE;

    g_run_id      NUMBER;
    g_exec_id     NUMBER;
    g_mode        VARCHAR2(10);
    g_deadline    DATE;
    g_exec_lock   VARCHAR2(128);
    g_tab_lock    VARCHAR2(128);
    g_lo_rindex   BINARY_INTEGER;
    g_lo_slno     BINARY_INTEGER;

    ----------------------------------------------------------------------------
    -- Small helpers
    ----------------------------------------------------------------------------
    FUNCTION version RETURN VARCHAR2 IS
    BEGIN
        RETURN c_version;
    END version;

    FUNCTION error_text RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
    END error_text;

    -- Autonomous: the log line survives any ROLLBACK of the caller.
    PROCEDURE write_log (p_level   IN VARCHAR2,
                         p_message IN VARCHAR2,
                         p_table   IN VARCHAR2 DEFAULT NULL,
                         p_batch   IN NUMBER   DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO archive_log (log_id, run_id, exec_id, table_name, batch_no, log_level, message)
        VALUES (archive_log_seq.NEXTVAL, g_run_id, g_exec_id, p_table, p_batch, p_level,
                SUBSTR(p_message, 1, 4000));
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;   -- logging must never break the job itself
    END write_log;

    -- Validated, double-quoted identifier.
    FUNCTION qn (p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_ASSERT.ENQUOTE_NAME(DBMS_ASSERT.SIMPLE_SQL_NAME(p_name), FALSE);
    END qn;

    FUNCTION obj (p_owner IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN qn(p_owner) || '.' || qn(p_name);
    END obj;

    FUNCTION get_cfg (p_table IN VARCHAR2) RETURN t_cfg IS
        r t_cfg;
    BEGIN
        SELECT * INTO r FROM archive_table_config WHERE table_name = UPPER(p_table);
        RETURN r;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'No ARCHIVE_TABLE_CONFIG row for ' || p_table);
    END get_cfg;

    -- "W.<worklist col> = <alias>.<join col>", with the optional TO_CHAR cast.
    FUNCTION join_expr (r IN t_cfg, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
        v_w VARCHAR2(400) := 'W.' || qn(r.worklist_column);
    BEGIN
        IF r.join_cast = 'TO_CHAR' THEN
            v_w := 'TO_CHAR(' || v_w || ')';
        END IF;
        RETURN v_w || ' = ' || p_alias || '.' || qn(r.join_column);
    END join_expr;

    FUNCTION worklist_exists (r IN t_cfg, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'EXISTS (SELECT 1 FROM ' || obj(r.table_owner, r.worklist_table) || ' W WHERE '
               || join_expr(r, p_alias) || ')';
    END worklist_exists;

    -- Index on the archive table whose leading columns are ARC_RUN_ID, ARC_BATCH_NO.
    FUNCTION find_tag_index (r IN t_cfg) RETURN VARCHAR2 IS
        v_name VARCHAR2(128);
    BEGIN
        SELECT MIN(c1.index_name)
          INTO v_name
          FROM all_ind_columns c1
          JOIN all_ind_columns c2
            ON c2.index_owner     = c1.index_owner
           AND c2.index_name      = c1.index_name
           AND c2.column_position = 2
           AND c2.column_name     = 'ARC_BATCH_NO'
         WHERE c1.table_owner     = r.table_owner
           AND c1.table_name      = r.arc_table_name
           AND c1.column_position = 1
           AND c1.column_name     = 'ARC_RUN_ID';
        RETURN v_name;
    END find_tag_index;

    -- Column lists of the source table: plain, and prefixed with an alias.
    PROCEDURE column_lists (r        IN  t_cfg,
                            p_alias  IN  VARCHAR2,
                            p_plain  OUT VARCHAR2,
                            p_prefix OUT VARCHAR2) IS
    BEGIN
        p_plain  := NULL;
        p_prefix := NULL;
        FOR c IN (SELECT column_name
                    FROM all_tab_cols
                   WHERE owner          = r.table_owner
                     AND table_name     = r.table_name
                     AND hidden_column  = 'NO'
                     AND virtual_column = 'NO'
                   ORDER BY column_id)
        LOOP
            IF p_plain IS NOT NULL THEN
                p_plain  := p_plain  || ', ';
                p_prefix := p_prefix || ', ';
            END IF;
            p_plain  := p_plain  || qn(c.column_name);
            p_prefix := p_prefix || p_alias || '.' || qn(c.column_name);
        END LOOP;
        IF p_plain IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 'No columns found for ' || r.table_owner || '.' || r.table_name);
        END IF;
    END column_lists;

    ----------------------------------------------------------------------------
    -- Locks (DBMS_LOCK user locks: cluster-wide, survive COMMIT, freed when
    -- the session ends). ALLOCATE_UNIQUE_AUTONOMOUS does not commit.
    ----------------------------------------------------------------------------
    FUNCTION lock_name (p_kind IN VARCHAR2, p_key IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR('PKG_ARCHIVE_MANAGER.' || p_kind || '.' || p_key, 1, 128);
    END lock_name;

    FUNCTION acquire_lock (p_name IN VARCHAR2, p_handle OUT VARCHAR2) RETURN BOOLEAN IS
        v_rc PLS_INTEGER;
    BEGIN
        DBMS_LOCK.ALLOCATE_UNIQUE_AUTONOMOUS(lockname => p_name, lockhandle => p_handle);
        v_rc := DBMS_LOCK.REQUEST(lockhandle        => p_handle,
                                  lockmode          => DBMS_LOCK.X_MODE,
                                  timeout           => 0,
                                  release_on_commit => FALSE);
        RETURN v_rc IN (0, 4);   -- 0 = granted, 4 = this session already holds it
    END acquire_lock;

    PROCEDURE release_lock (p_handle IN OUT VARCHAR2) IS
        v_rc PLS_INTEGER;
    BEGIN
        IF p_handle IS NOT NULL THEN
            v_rc := DBMS_LOCK.RELEASE(lockhandle => p_handle);
            p_handle := NULL;
        END IF;
    END release_lock;

    -- An execution still marked RUNNING whose session lock is free has died
    -- (killed session, lost client, instance crash): mark it ABORTED.
    PROCEDURE cleanup_orphans IS
        v_handle VARCHAR2(128);
        v_rc     PLS_INTEGER;
    BEGIN
        FOR e IN (SELECT exec_id FROM archive_exec
                   WHERE status = 'RUNNING' AND exec_id <> g_exec_id)
        LOOP
            DBMS_LOCK.ALLOCATE_UNIQUE_AUTONOMOUS(lockname   => lock_name('EXEC', TO_CHAR(e.exec_id)),
                                                 lockhandle => v_handle);
            v_rc := DBMS_LOCK.REQUEST(lockhandle        => v_handle,
                                      lockmode          => DBMS_LOCK.X_MODE,
                                      timeout           => 0,
                                      release_on_commit => FALSE);
            IF v_rc = 0 THEN
                UPDATE archive_exec
                   SET status   = 'ABORTED',
                       ended_at = SYSTIMESTAMP,
                       message  = 'Session ended without finishing; detected by execution ' || g_exec_id
                 WHERE exec_id = e.exec_id
                   AND status  = 'RUNNING';
                COMMIT;
                v_rc := DBMS_LOCK.RELEASE(lockhandle => v_handle);
                write_log('WARN', 'Execution ' || e.exec_id || ' marked ABORTED: its session no longer exists');
            END IF;
        END LOOP;
    END cleanup_orphans;

    ----------------------------------------------------------------------------
    -- Stop flag and time limit. p_next_secs = expected length of the next unit
    -- of work; it is not started if it would end after the deadline.
    ----------------------------------------------------------------------------
    FUNCTION interruption (p_next_secs IN NUMBER) RETURN VARCHAR2 IS
        v_stop VARCHAR2(1);
    BEGIN
        SELECT stop_requested INTO v_stop FROM archive_exec WHERE exec_id = g_exec_id;
        IF v_stop = 'Y' THEN
            RETURN 'STOPPED';
        END IF;
        IF g_deadline IS NOT NULL
           AND SYSDATE + NVL(p_next_secs, 0) * 1.25 / 86400 > g_deadline THEN
            RETURN 'PAUSED';
        END IF;
        RETURN NULL;
    END interruption;

    -- V$SESSION.ACTION and V$SESSION_LONGOPS (with Oracle's own time estimate).
    PROCEDURE set_progress (p_op IN VARCHAR2, p_table IN VARCHAR2, p_done IN NUMBER, p_total IN NUMBER) IS
    BEGIN
        DBMS_APPLICATION_INFO.SET_ACTION(SUBSTR(p_op || ' ' || p_done || '/' || p_total, 1, 32));
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(SUBSTR('run ' || g_run_id || ' exec ' || g_exec_id
                                                     || ' ' || p_table, 1, 64));
        DBMS_APPLICATION_INFO.SET_SESSION_LONGOPS(
            rindex      => g_lo_rindex,
            slno        => g_lo_slno,
            op_name     => SUBSTR('PKG_ARCHIVE_MANAGER ' || p_op, 1, 64),
            context     => g_run_id,
            sofar       => p_done,
            totalwork   => p_total,
            target_desc => SUBSTR(p_table, 1, 32),
            units       => 'batches');
    END set_progress;

    ----------------------------------------------------------------------------
    -- Preflight checks for one table. Returns the number of errors; every
    -- finding is logged (and printed in CHECK mode).
    ----------------------------------------------------------------------------
    -- In CHECK mode every finding is printed as CHK|level|table|code|message and
    -- each table ends with CHKT|table|enabled|errors|warnings; archive_manager.sh
    -- turns these into the operator summary. code is '-' or a key for findings
    -- the utility groups (IMPLICIT = NUMBER/VARCHAR2 join by implicit conversion).
    FUNCTION check_table (r IN t_cfg) RETURN PLS_INTEGER IS
        v_errors PLS_INTEGER := 0;
        v_warns  PLS_INTEGER := 0;
        v_cnt    NUMBER;
        v_text   VARCHAR2(4000);
        v_type   VARCHAR2(128);
        v_wtype  VARCHAR2(128);

        PROCEDURE issue (p_level IN VARCHAR2, p_msg IN VARCHAR2, p_code IN VARCHAR2 DEFAULT '-') IS
        BEGIN
            IF p_level = 'ERROR' THEN
                v_errors := v_errors + 1;
            ELSIF p_level = 'WARN' THEN
                v_warns := v_warns + 1;
            END IF;
            write_log(p_level, 'Check: ' || p_msg, r.table_name);
            IF g_mode = 'CHECK' THEN
                DBMS_OUTPUT.PUT_LINE('CHK|' || p_level || '|' || r.table_name || '|' || p_code || '|'
                                     || REPLACE(p_msg, '|', '/'));
            END IF;
        END issue;

        FUNCTION check_result RETURN PLS_INTEGER IS
        BEGIN
            IF g_mode = 'CHECK' THEN
                DBMS_OUTPUT.PUT_LINE('CHKT|' || r.table_name || '|' || r.enabled_flag || '|' || v_errors || '|' || v_warns);
            END IF;
            RETURN v_errors;
        END check_result;

        FUNCTION table_exists (p_table IN VARCHAR2) RETURN BOOLEAN IS
            v_n NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_n FROM all_tables WHERE owner = r.table_owner AND table_name = p_table;
            RETURN v_n > 0;
        END table_exists;

        FUNCTION col_type (p_table IN VARCHAR2, p_col IN VARCHAR2) RETURN VARCHAR2 IS
            v_t VARCHAR2(128);
        BEGIN
            SELECT MIN(data_type) INTO v_t FROM all_tab_cols
             WHERE owner = r.table_owner AND table_name = p_table AND column_name = p_col;
            RETURN v_t;
        END col_type;
    BEGIN
        -- 1. identifiers
        BEGIN
            v_text := qn(r.table_owner) || qn(r.table_name) || qn(r.arc_table_name) || qn(r.key_column)
                   || qn(r.join_column) || qn(r.worklist_table) || qn(r.worklist_column);
        EXCEPTION
            WHEN OTHERS THEN
                issue('ERROR', 'bad name in ARCHIVE_TABLE_CONFIG: ' || SQLERRM);
                RETURN check_result;
        END;

        -- 2. objects
        IF NOT table_exists(r.table_name)     THEN issue('ERROR', 'source table not found');   END IF;
        IF NOT table_exists(r.arc_table_name) THEN issue('ERROR', 'archive table ' || r.arc_table_name || ' not found'); END IF;
        IF NOT table_exists(r.worklist_table) THEN issue('ERROR', 'worklist table ' || r.worklist_table || ' not found'); END IF;
        IF v_errors > 0 THEN
            RETURN check_result;
        END IF;

        -- 3. key, join and worklist columns
        v_type := col_type(r.table_name, r.key_column);
        IF v_type IS NULL THEN
            issue('ERROR', 'KEY_COLUMN ' || r.key_column || ' not found in source');
        ELSIF v_type NOT IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR', 'NUMBER') THEN
            issue('ERROR', 'KEY_COLUMN ' || r.key_column || ' is ' || v_type || ' (must be character or NUMBER)');
        END IF;
        v_type  := col_type(r.table_name, r.join_column);
        v_wtype := col_type(r.worklist_table, r.worklist_column);
        IF v_type IS NULL THEN
            issue('ERROR', 'JOIN_COLUMN ' || r.join_column || ' not found in source');
        END IF;
        IF v_wtype IS NULL THEN
            issue('ERROR', 'WORKLIST_COLUMN ' || r.worklist_column || ' not found in ' || r.worklist_table);
        END IF;
        IF v_type IS NOT NULL AND v_wtype IS NOT NULL AND r.join_cast IS NULL
           AND ((v_type = 'NUMBER' AND v_wtype <> 'NUMBER') OR (v_type <> 'NUMBER' AND v_wtype = 'NUMBER')) THEN
            issue('WARN', 'worklist ' || v_wtype || ' vs ' || r.join_column || ' ' || v_type
                  || ' (implicit conversion)', 'IMPLICIT');
        END IF;

        -- 4. source column types that cannot be copied
        SELECT COUNT(*) INTO v_cnt FROM all_tab_cols
         WHERE owner = r.table_owner AND table_name = r.table_name AND data_type IN ('LONG', 'LONG RAW');
        IF v_cnt > 0 THEN
            issue('ERROR', 'source has LONG/LONG RAW columns (cannot be copied)');
        END IF;
        SELECT COUNT(*) INTO v_cnt FROM all_tab_cols
         WHERE owner = r.table_owner AND table_name = r.table_name
           AND hidden_column = 'YES' AND user_generated = 'YES' AND virtual_column = 'NO';
        IF v_cnt > 0 THEN
            issue('ERROR', 'source has ' || v_cnt || ' invisible column(s) (would not be archived)');
        END IF;

        -- 5. every source column must exist in the archive table, same type, not smaller
        FOR c IN (SELECT s.column_name, s.data_type, s.data_length, s.char_length,
                         s.data_precision, s.data_scale,
                         a.column_name a_name, a.data_type a_type, a.data_length a_len,
                         a.char_length a_clen, a.data_precision a_prec, a.data_scale a_scale
                    FROM all_tab_cols s
                    LEFT JOIN all_tab_cols a
                      ON a.owner = s.owner
                     AND a.table_name = r.arc_table_name
                     AND a.column_name = s.column_name
                     AND a.hidden_column = 'NO'
                   WHERE s.owner = r.table_owner
                     AND s.table_name = r.table_name
                     AND s.hidden_column = 'NO'
                     AND s.virtual_column = 'NO'
                   ORDER BY s.column_id)
        LOOP
            IF c.a_name IS NULL THEN
                issue('ERROR', 'column ' || c.column_name || ' missing in archive');
            ELSIF c.a_type <> c.data_type THEN
                issue('ERROR', 'column ' || c.column_name || ': ' || c.data_type || ' in source, '
                      || c.a_type || ' in archive');
            ELSIF c.a_len < c.data_length OR NVL(c.a_clen, 0) < NVL(c.char_length, 0) THEN
                issue('ERROR', 'column ' || c.column_name || ' is shorter in archive');
            ELSIF c.data_type = 'NUMBER' AND c.a_prec IS NOT NULL
                  AND (c.data_precision IS NULL
                       OR c.a_prec - NVL(c.a_scale, 0) < c.data_precision - NVL(c.data_scale, 0)
                       OR NVL(c.a_scale, 0) < NVL(c.data_scale, 0)) THEN
                issue('ERROR', 'column ' || c.column_name || ': smaller NUMBER precision/scale in archive');
            END IF;
        END LOOP;

        -- 6. extra mandatory archive columns would make the insert fail
        FOR c IN (SELECT a.column_name
                    FROM all_tab_cols a
                   WHERE a.owner = r.table_owner
                     AND a.table_name = r.arc_table_name
                     AND a.nullable = 'N'
                     AND a.virtual_column = 'NO'
                     AND a.column_name NOT IN ('ARC_RUN_ID', 'ARC_BATCH_NO')
                     AND NOT EXISTS (SELECT 1 FROM all_tab_cols s
                                      WHERE s.owner = r.table_owner
                                        AND s.table_name = r.table_name
                                        AND s.column_name = a.column_name))
        LOOP
            issue('WARN', 'archive column ' || c.column_name || ' is NOT NULL and not in source'
                  || ' (insert fails without a default)');
        END LOOP;

        -- 7. tag columns and their index
        IF r.enabled_flag <> 'Y' AND (col_type(r.arc_table_name, 'ARC_RUN_ID') IS NULL OR find_tag_index(r) IS NULL) THEN
            issue('INFO', 'tag columns not added yet: after enabling, run 06_prepare_arc_tables.sql');
        ELSIF col_type(r.arc_table_name, 'ARC_RUN_ID') IS NULL OR col_type(r.arc_table_name, 'ARC_BATCH_NO') IS NULL THEN
            issue('ERROR', 'no tag columns in archive: run 06_prepare_arc_tables.sql');
        ELSIF find_tag_index(r) IS NULL THEN
            issue('ERROR', 'no tag index on archive: run 06_prepare_arc_tables.sql');
        END IF;

        -- 8. foreign keys that would change other tables silently
        SELECT LISTAGG(c.table_name || ' (ON DELETE ' || c.delete_rule || ')', ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY c.table_name)
          INTO v_text
          FROM all_constraints c
          JOIN all_constraints p
            ON p.owner = c.r_owner
           AND p.constraint_name = c.r_constraint_name
         WHERE p.owner = r.table_owner
           AND p.table_name = r.table_name
           AND c.constraint_type = 'R'
           AND c.status = 'ENABLED'
           AND c.delete_rule IN ('CASCADE', 'SET NULL');
        IF v_text IS NOT NULL THEN
            issue('ERROR', 'deletes would change child tables: ' || SUBSTR(v_text, 1, 3000));
        END IF;

        SELECT LISTAGG(c.table_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY c.table_name)
          INTO v_text
          FROM all_constraints c
          JOIN all_constraints p
            ON p.owner = c.r_owner
           AND p.constraint_name = c.r_constraint_name
         WHERE p.owner = r.table_owner
           AND p.table_name = r.table_name
           AND c.constraint_type = 'R'
           AND c.status = 'ENABLED'
           AND c.delete_rule = 'NO ACTION';
        IF v_text IS NOT NULL THEN
            issue('INFO', 'child tables: ' || SUBSTR(v_text, 1, 3000) || ' (archive them first)');
        END IF;

        -- 9. triggers that fire on our DML
        SELECT LISTAGG(trigger_name || ' (' || triggering_event || ')', '; ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY trigger_name)
          INTO v_text
          FROM all_triggers
         WHERE table_owner = r.table_owner
           AND table_name = r.table_name
           AND status = 'ENABLED'
           AND (triggering_event LIKE '%DELETE%' OR triggering_event LIKE '%INSERT%');
        IF v_text IS NOT NULL THEN
            issue('WARN', 'DML triggers fire on every archived row: ' || SUBSTR(v_text, 1, 3000));
        END IF;

        RETURN check_result;
    END check_table;

    ----------------------------------------------------------------------------
    -- Scope: enabled config tables, optionally limited by a comma list,
    -- ordered by TABLE_ORDER (descending for rollback).
    -- p_allow_disabled (CHECK only): tables named in the list may be disabled,
    -- so a table can be validated before it is enabled.
    ----------------------------------------------------------------------------
    FUNCTION resolve_scope (p_csv IN VARCHAR2, p_descending IN BOOLEAN,
                            p_allow_disabled IN BOOLEAN DEFAULT FALSE) RETURN t_names IS
        v_list  t_names := t_names();
        v_csv   VARCHAR2(4000) := UPPER(REPLACE(p_csv, ' '));
        v_name  VARCHAR2(128);
        v_flag  VARCHAR2(1);
        v_sign  NUMBER := CASE WHEN p_descending THEN -1 ELSE 1 END;
        v_allow VARCHAR2(1) := CASE WHEN p_allow_disabled AND p_csv IS NOT NULL THEN 'Y' ELSE 'N' END;
    BEGIN
        IF v_csv IS NOT NULL THEN
            FOR i IN 1 .. REGEXP_COUNT(v_csv, '[^,]+') LOOP
                v_name := REGEXP_SUBSTR(v_csv, '[^,]+', 1, i);
                BEGIN
                    SELECT enabled_flag INTO v_flag FROM archive_table_config WHERE table_name = v_name;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        RAISE_APPLICATION_ERROR(-20005, 'Table ' || v_name || ' is not in ARCHIVE_TABLE_CONFIG');
                END;
                IF v_flag <> 'Y' AND v_allow = 'N' THEN
                    RAISE_APPLICATION_ERROR(-20006, 'Table ' || v_name || ' is disabled (ENABLED_FLAG = N)');
                END IF;
            END LOOP;
        END IF;

        FOR c IN (SELECT table_name
                    FROM archive_table_config
                   WHERE (enabled_flag = 'Y' OR v_allow = 'Y')
                     AND (v_csv IS NULL OR INSTR(',' || v_csv || ',', ',' || table_name || ',') > 0)
                   ORDER BY table_order * v_sign)
        LOOP
            v_list.EXTEND;
            v_list(v_list.COUNT) := c.table_name;
        END LOOP;

        IF v_list.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20007, 'No enabled tables in scope (check ENABLED_FLAG in ARCHIVE_TABLE_CONFIG)');
        END IF;
        RETURN v_list;
    END resolve_scope;

    FUNCTION get_state (p_table IN VARCHAR2, p_state OUT t_state) RETURN BOOLEAN IS
    BEGIN
        SELECT * INTO p_state FROM archive_run_state WHERE run_id = g_run_id AND table_name = p_table;
        RETURN TRUE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN FALSE;
    END get_state;

    -- Tables that must be COMPLETED before r can be archived.
    FUNCTION archive_blockers (r IN t_cfg) RETURN VARCHAR2 IS
        v_text VARCHAR2(4000);
        v_deps VARCHAR2(4000) := UPPER(REPLACE(r.depends_on, ' '));
    BEGIN
        IF v_deps = 'NONE' THEN
            RETURN NULL;
        END IF;
        SELECT LISTAGG(c.table_name || ' (' || NVL(s.status, 'NOT STAGED') || ')', ', ')
                 WITHIN GROUP (ORDER BY c.table_order)
          INTO v_text
          FROM archive_table_config c
          LEFT JOIN archive_run_state s
            ON s.run_id = g_run_id
           AND s.table_name = c.table_name
         WHERE c.enabled_flag = 'Y'
           AND c.table_name <> r.table_name
           AND NVL(s.status, 'X') <> 'COMPLETED'
           AND ((v_deps IS NULL AND c.table_order < r.table_order)
                OR (v_deps IS NOT NULL AND INSTR(',' || v_deps || ',', ',' || c.table_name || ',') > 0));
        RETURN v_text;
    END archive_blockers;

    -- Tables later in the order that still hold archived rows of this run.
    FUNCTION rollback_blockers (r IN t_cfg) RETURN VARCHAR2 IS
        v_text VARCHAR2(4000);
    BEGIN
        SELECT LISTAGG(s.table_name, ', ') WITHIN GROUP (ORDER BY c.table_order DESC)
          INTO v_text
          FROM archive_run_state s
          JOIN archive_table_config c
            ON c.table_name = s.table_name
         WHERE s.run_id = g_run_id
           AND c.table_order > r.table_order
           AND s.batches_done > s.batches_restored;
        RETURN v_text;
    END rollback_blockers;

    ----------------------------------------------------------------------------
    -- STAGE one table: ROWIDs + keys + batch numbers, batch list and state,
    -- all in ONE transaction. Read-only on the source table.
    ----------------------------------------------------------------------------
    PROCEDURE stage_table (r IN t_cfg, p_batch_size IN NUMBER) IS
        v_st     t_state;
        v_bs     NUMBER := NVL(p_batch_size, r.batch_size);
        v_sql    VARCHAR2(32767);
        v_rows   NUMBER;
        v_found  NUMBER;
        v_t0     PLS_INTEGER := DBMS_UTILITY.GET_TIME;
        v_err    VARCHAR2(4000);
    BEGIN
        IF get_state(r.table_name, v_st) AND NOT (v_st.status = 'FAILED' AND v_st.last_action = 'STAGE') THEN
            write_log('INFO', 'Already staged in run ' || g_run_id || ' (' || v_st.status || '); skipped', r.table_name);
            RETURN;
        END IF;

        IF check_table(r) > 0 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Preflight checks failed for ' || r.table_name
                                    || '; see ARCHIVE_LOG or run mode CHECK');
        END IF;

        IF NOT acquire_lock(lock_name('TABLE', r.table_owner || '.' || r.table_name), g_tab_lock) THEN
            RAISE_APPLICATION_ERROR(-20024, r.table_name || ' is being processed by another session');
        END IF;

        BEGIN
            DBMS_APPLICATION_INFO.SET_ACTION(SUBSTR('STAGE ' || r.table_name, 1, 32));

            -- Refuse tables whose archive already holds rows of this worklist
            -- (for example archived by another process): no double archiving.
            v_sql := 'SELECT /*+ PARALLEL(' || r.parallel_degree || ') */ COUNT(*) FROM '
                  || obj(r.table_owner, r.arc_table_name) || ' A WHERE '
                  || worklist_exists(r, 'A') || ' AND ROWNUM = 1';
            EXECUTE IMMEDIATE v_sql INTO v_found;
            IF v_found > 0 THEN
                RAISE_APPLICATION_ERROR(-20011, r.arc_table_name || ' already contains rows for keys in '
                    || r.worklist_table || ' (archived outside this run, e.g. by another process).'
                    || ' Finish that table with the process that started it.');
            END IF;

            write_log('INFO', 'Staging started (batch size ' || v_bs || ', parallel ' || r.parallel_degree || ')',
                      r.table_name);

            EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';

            v_sql := 'INSERT /*+ APPEND PARALLEL(' || r.parallel_degree || ') */ INTO purge_rid_stage'
                  || ' (run_id, table_name, batch_no, row_id, key_val)'
                  || ' SELECT /*+ PARALLEL(' || r.parallel_degree || ') */ :1, :2,'
                  || ' CEIL(ROW_NUMBER() OVER (ORDER BY T.ROWID) / :3), T.ROWID, TO_CHAR(T.' || qn(r.key_column) || ')'
                  || ' FROM ' || obj(r.table_owner, r.table_name) || ' T'
                  || ' WHERE ' || worklist_exists(r, 'T');
            EXECUTE IMMEDIATE v_sql USING g_run_id, r.table_name, v_bs;
            v_rows := SQL%ROWCOUNT;

            IF v_rows > 0 THEN
                INSERT INTO archive_batch (run_id, table_name, batch_no, rows_staged, status)
                SELECT g_run_id, r.table_name, LEVEL,
                       LEAST(v_bs, v_rows - (LEVEL - 1) * v_bs), 'PENDING'
                  FROM dual
               CONNECT BY LEVEL <= CEIL(v_rows / v_bs);
            END IF;

            MERGE INTO archive_run_state s
            USING (SELECT g_run_id AS run_id, r.table_name AS table_name FROM dual) x
               ON (s.run_id = x.run_id AND s.table_name = x.table_name)
             WHEN MATCHED THEN UPDATE SET
                  s.status = 'STAGED', s.last_action = 'STAGE', s.batch_size = v_bs,
                  s.rows_staged = v_rows, s.batches_total = CEIL(v_rows / v_bs), s.batches_done = 0,
                  s.staged_at = SYSTIMESTAMP, s.last_exec_id = g_exec_id, s.last_error = NULL
             WHEN NOT MATCHED THEN INSERT
                  (run_id, table_name, status, last_action, batch_size, rows_staged, batches_total,
                   staged_at, last_exec_id)
                  VALUES (g_run_id, r.table_name, 'STAGED', 'STAGE', v_bs, v_rows, CEIL(v_rows / v_bs),
                          SYSTIMESTAMP, g_exec_id);

            COMMIT;
            EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

            write_log('INFO', 'Staged ' || v_rows || ' rows in ' || CEIL(v_rows / v_bs) || ' batches ('
                      || ROUND((DBMS_UTILITY.GET_TIME - v_t0) / 100) || ' s)', r.table_name);
            release_lock(g_tab_lock);
        EXCEPTION
            WHEN OTHERS THEN
                v_err := error_text;
                ROLLBACK;
                EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
                MERGE INTO archive_run_state s
                USING (SELECT g_run_id AS run_id, r.table_name AS table_name FROM dual) x
                   ON (s.run_id = x.run_id AND s.table_name = x.table_name)
                 WHEN MATCHED THEN UPDATE SET
                      s.status = 'FAILED', s.last_action = 'STAGE', s.last_exec_id = g_exec_id, s.last_error = v_err
                 WHEN NOT MATCHED THEN INSERT (run_id, table_name, status, last_action, last_exec_id, last_error)
                      VALUES (g_run_id, r.table_name, 'FAILED', 'STAGE', g_exec_id, v_err);
                COMMIT;
                write_log('ERROR', 'Staging failed: ' || v_err, r.table_name);
                release_lock(g_tab_lock);
                RAISE;
        END;
    END stage_table;

    ----------------------------------------------------------------------------
    -- ARCHIVE one table, batch by batch. Returns COMPLETED, PAUSED or STOPPED.
    ----------------------------------------------------------------------------
    FUNCTION archive_table (r IN t_cfg) RETURN VARCHAR2 IS
        v_st       t_state;
        v_text     VARCHAR2(4000);
        v_cols     VARCHAR2(32767);
        v_tcols    VARCHAR2(32767);
        v_ins_sql  VARCHAR2(32767);
        v_del_sql  VARCHAR2(32767);
        v_rids     t_rowids;
        v_keys     t_keys;
        v_b        NUMBER;
        v_staged   NUMBER;
        v_ins      NUMBER;
        v_del      NUMBER;
        v_t0       PLS_INTEGER;
        v_secs     NUMBER;
        v_est      NUMBER;
        v_done     NUMBER := 0;
        v_result   VARCHAR2(10);
        v_err      VARCHAR2(4000);
    BEGIN
        IF NOT get_state(r.table_name, v_st) THEN
            RAISE_APPLICATION_ERROR(-20020, r.table_name || ' is not staged in run ' || g_run_id);
        END IF;
        IF v_st.status = 'COMPLETED' THEN
            write_log('INFO', 'Already completed in run ' || g_run_id || '; skipped', r.table_name);
            RETURN 'COMPLETED';
        END IF;
        IF v_st.status IN ('RESTORING', 'RESTORED') OR v_st.last_action = 'ROLLBACK' THEN
            RAISE_APPLICATION_ERROR(-20021, r.table_name || ' was rolled back in run ' || g_run_id
                                    || '; stage a new run to archive it again');
        END IF;
        IF v_st.status = 'FAILED' AND v_st.last_action = 'STAGE' THEN
            RAISE_APPLICATION_ERROR(-20022, 'Staging of ' || r.table_name || ' failed; run STAGE again first');
        END IF;

        v_text := archive_blockers(r);
        IF v_text IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20023, r.table_name || ' cannot be archived before these tables are COMPLETED in run '
                                    || g_run_id || ': ' || v_text);
        END IF;

        IF check_table(r) > 0 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Preflight checks failed for ' || r.table_name
                                    || '; see ARCHIVE_LOG or run mode CHECK');
        END IF;

        IF NOT acquire_lock(lock_name('TABLE', r.table_owner || '.' || r.table_name), g_tab_lock) THEN
            RAISE_APPLICATION_ERROR(-20024, r.table_name || ' is being processed by another session');
        END IF;

        BEGIN
            column_lists(r, 'T', v_cols, v_tcols);

            -- Both statements re-check the row key: a ROWID that now points
            -- at another row (after a move/shrink) is neither copied nor deleted.
            v_ins_sql := 'INSERT INTO ' || obj(r.table_owner, r.arc_table_name)
                      || ' (' || v_cols || ', "ARC_RUN_ID", "ARC_BATCH_NO")'
                      || ' SELECT ' || v_tcols || ', :1, :2'
                      || ' FROM ' || obj(r.table_owner, r.table_name) || ' T'
                      || ' WHERE T.ROWID = :3 AND TO_CHAR(T.' || qn(r.key_column) || ') = :4';
            v_del_sql := 'DELETE FROM ' || obj(r.table_owner, r.table_name) || ' T'
                      || ' WHERE T.ROWID = :1 AND TO_CHAR(T.' || qn(r.key_column) || ') = :2';

            UPDATE archive_run_state
               SET status = 'ARCHIVING', last_action = 'ARCHIVE', last_exec_id = g_exec_id,
                   archive_started_at = NVL(archive_started_at, SYSTIMESTAMP), last_error = NULL
             WHERE run_id = g_run_id AND table_name = r.table_name;
            COMMIT;

            SELECT AVG(archive_seconds) INTO v_est
              FROM (SELECT archive_seconds FROM archive_batch
                     WHERE run_id = g_run_id AND table_name = r.table_name
                       AND status <> 'PENDING' AND archive_seconds IS NOT NULL
                     ORDER BY archived_at DESC FETCH FIRST 5 ROWS ONLY);

            g_lo_rindex := DBMS_APPLICATION_INFO.SET_SESSION_LONGOPS_NOHINT;
            write_log('INFO', 'Archiving: ' || (v_st.batches_total - v_st.batches_done) || ' of '
                      || v_st.batches_total || ' batches left', r.table_name);

            LOOP
                v_result := interruption(v_est);
                EXIT WHEN v_result IS NOT NULL;

                SELECT MIN(batch_no) INTO v_b
                  FROM archive_batch
                 WHERE run_id = g_run_id AND table_name = r.table_name AND status = 'PENDING';
                IF v_b IS NULL THEN
                    v_result := 'COMPLETED';
                    EXIT;
                END IF;

                v_t0 := DBMS_UTILITY.GET_TIME;

                SELECT rows_staged INTO v_staged
                  FROM archive_batch
                 WHERE run_id = g_run_id AND table_name = r.table_name AND batch_no = v_b;

                SELECT /*+ INDEX(s purge_rid_stage_ix) */ row_id, key_val
                  BULK COLLECT INTO v_rids, v_keys
                  FROM purge_rid_stage s
                 WHERE run_id = g_run_id AND table_name = r.table_name AND batch_no = v_b;

                IF v_rids.COUNT <> v_staged THEN
                    RAISE_APPLICATION_ERROR(-20101, 'Staging data for batch ' || v_b || ' has ' || v_rids.COUNT
                                            || ' rows, expected ' || v_staged || ' (staging partition changed?)');
                END IF;

                FORALL i IN 1 .. v_rids.COUNT
                    EXECUTE IMMEDIATE v_ins_sql USING g_run_id, v_b, v_rids(i), v_keys(i);
                v_ins := SQL%ROWCOUNT;

                FORALL i IN 1 .. v_rids.COUNT
                    EXECUTE IMMEDIATE v_del_sql USING v_rids(i), v_keys(i);
                v_del := SQL%ROWCOUNT;

                IF v_ins <> v_del THEN
                    ROLLBACK;
                    RAISE_APPLICATION_ERROR(-20100, 'Batch ' || v_b || ' copied ' || v_ins || ' rows but deleted '
                                            || v_del || '; batch rolled back, nothing changed');
                END IF;

                v_secs := (DBMS_UTILITY.GET_TIME - v_t0) / 100;

                UPDATE archive_batch
                   SET status = 'DONE', rows_archived = v_ins, rows_deleted = v_del,
                       archived_at = SYSTIMESTAMP, archive_seconds = v_secs, exec_id = g_exec_id
                 WHERE run_id = g_run_id AND table_name = r.table_name AND batch_no = v_b AND status = 'PENDING';
                IF SQL%ROWCOUNT <> 1 THEN
                    ROLLBACK;
                    RAISE_APPLICATION_ERROR(-20102, 'Batch ' || v_b || ' was changed by another session; rolled back');
                END IF;

                UPDATE archive_run_state
                   SET batches_done  = batches_done + 1,
                       rows_archived = rows_archived + v_ins,
                       rows_deleted  = rows_deleted + v_del
                 WHERE run_id = g_run_id AND table_name = r.table_name;

                COMMIT;   -- the batch is archived and deleted, or neither

                IF v_del < v_staged THEN
                    write_log('WARN', (v_staged - v_del) || ' staged rows were gone or had a different key; skipped',
                              r.table_name, v_b);
                END IF;

                v_est  := CASE WHEN v_est IS NULL THEN v_secs ELSE 0.7 * v_est + 0.3 * v_secs END;
                v_done := v_done + 1;
                set_progress('ARCHIVE', r.table_name, v_st.batches_done + v_done, v_st.batches_total);
                IF MOD(v_done, 50) = 0 THEN
                    write_log('INFO', 'Progress: ' || (v_st.batches_done + v_done) || ' of ' || v_st.batches_total
                              || ' batches, about ' || ROUND(v_est, 1) || ' s per batch', r.table_name, v_b);
                END IF;
            END LOOP;

            IF v_result = 'COMPLETED' THEN
                UPDATE archive_run_state
                   SET status = 'COMPLETED', completed_at = SYSTIMESTAMP
                 WHERE run_id = g_run_id AND table_name = r.table_name;
                COMMIT;
                write_log('INFO', 'Archive completed (' || v_done || ' batches in this execution)', r.table_name);
            ELSE
                write_log('INFO', 'Archive ' || v_result || ' after ' || v_done || ' batches in this execution',
                          r.table_name);
            END IF;

            release_lock(g_tab_lock);
            RETURN v_result;
        EXCEPTION
            WHEN OTHERS THEN
                v_err := error_text;
                ROLLBACK;
                UPDATE archive_run_state
                   SET status = 'FAILED', last_error = v_err, last_exec_id = g_exec_id
                 WHERE run_id = g_run_id AND table_name = r.table_name;
                COMMIT;
                write_log('ERROR', 'Archive failed at batch ' || v_b || ': ' || v_err, r.table_name, v_b);
                release_lock(g_tab_lock);
                RAISE;
        END;
    END archive_table;

    ----------------------------------------------------------------------------
    -- ROLLBACK one table: move this run's rows back from the archive table,
    -- last batch first, one batch per transaction.
    ----------------------------------------------------------------------------
    FUNCTION rollback_table (r IN t_cfg) RETURN VARCHAR2 IS
        v_st       t_state;
        v_text     VARCHAR2(4000);
        v_ix       VARCHAR2(128);
        v_cols     VARCHAR2(32767);
        v_acols    VARCHAR2(32767);
        v_ins_sql  VARCHAR2(32767);
        v_del_sql  VARCHAR2(32767);
        v_b        NUMBER;
        v_expect   NUMBER;
        v_ins      NUMBER;
        v_del      NUMBER;
        v_t0       PLS_INTEGER;
        v_secs     NUMBER;
        v_est      NUMBER;
        v_done     NUMBER := 0;
        v_result   VARCHAR2(10);
        v_err      VARCHAR2(4000);
    BEGIN
        IF NOT get_state(r.table_name, v_st) OR v_st.batches_done = v_st.batches_restored THEN
            write_log('INFO', 'Nothing archived in run ' || g_run_id || '; skipped', r.table_name);
            RETURN 'COMPLETED';
        END IF;

        v_text := rollback_blockers(r);
        IF v_text IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20031, r.table_name || ' cannot be restored before these tables: ' || v_text);
        END IF;

        v_ix := find_tag_index(r);
        IF v_ix IS NULL THEN
            RAISE_APPLICATION_ERROR(-20032, 'No index on ' || r.arc_table_name
                                    || '(ARC_RUN_ID, ARC_BATCH_NO); run PKG_ARCHIVE_MANAGER.PREPARE_ARC_TABLE');
        END IF;

        IF NOT acquire_lock(lock_name('TABLE', r.table_owner || '.' || r.table_name), g_tab_lock) THEN
            RAISE_APPLICATION_ERROR(-20024, r.table_name || ' is being processed by another session');
        END IF;

        BEGIN
            column_lists(r, 'A', v_cols, v_acols);
            v_ins_sql := 'INSERT INTO ' || obj(r.table_owner, r.table_name) || ' (' || v_cols || ')'
                      || ' SELECT /*+ INDEX(A ' || qn(v_ix) || ') */ ' || v_acols
                      || ' FROM ' || obj(r.table_owner, r.arc_table_name) || ' A'
                      || ' WHERE A."ARC_RUN_ID" = :1 AND A."ARC_BATCH_NO" = :2';
            v_del_sql := 'DELETE /*+ INDEX(A ' || qn(v_ix) || ') */ FROM ' || obj(r.table_owner, r.arc_table_name) || ' A'
                      || ' WHERE A."ARC_RUN_ID" = :1 AND A."ARC_BATCH_NO" = :2';

            UPDATE archive_run_state
               SET status = 'RESTORING', last_action = 'ROLLBACK', last_exec_id = g_exec_id, last_error = NULL
             WHERE run_id = g_run_id AND table_name = r.table_name;
            COMMIT;

            g_lo_rindex := DBMS_APPLICATION_INFO.SET_SESSION_LONGOPS_NOHINT;
            write_log('INFO', 'Rollback: ' || (v_st.batches_done - v_st.batches_restored) || ' batches to restore',
                      r.table_name);

            LOOP
                v_result := interruption(v_est);
                EXIT WHEN v_result IS NOT NULL;

                SELECT MAX(batch_no) INTO v_b
                  FROM archive_batch
                 WHERE run_id = g_run_id AND table_name = r.table_name AND status = 'DONE';
                IF v_b IS NULL THEN
                    v_result := 'COMPLETED';
                    EXIT;
                END IF;

                v_t0 := DBMS_UTILITY.GET_TIME;
                SELECT rows_archived INTO v_expect
                  FROM archive_batch
                 WHERE run_id = g_run_id AND table_name = r.table_name AND batch_no = v_b;

                EXECUTE IMMEDIATE v_ins_sql USING g_run_id, v_b;
                v_ins := SQL%ROWCOUNT;
                EXECUTE IMMEDIATE v_del_sql USING g_run_id, v_b;
                v_del := SQL%ROWCOUNT;

                IF v_ins <> v_del OR v_ins <> v_expect THEN
                    ROLLBACK;
                    RAISE_APPLICATION_ERROR(-20103, 'Restore of batch ' || v_b || ': expected ' || v_expect
                                            || ', restored ' || v_ins || ', removed from archive ' || v_del
                                            || '; batch rolled back');
                END IF;

                v_secs := (DBMS_UTILITY.GET_TIME - v_t0) / 100;
                UPDATE archive_batch
                   SET status = 'RESTORED', rows_restored = v_ins, restored_at = SYSTIMESTAMP,
                       restore_seconds = v_secs, exec_id = g_exec_id
                 WHERE run_id = g_run_id AND table_name = r.table_name AND batch_no = v_b AND status = 'DONE';
                UPDATE archive_run_state
                   SET batches_restored = batches_restored + 1, rows_restored = rows_restored + v_ins
                 WHERE run_id = g_run_id AND table_name = r.table_name;
                COMMIT;

                v_est  := CASE WHEN v_est IS NULL THEN v_secs ELSE 0.7 * v_est + 0.3 * v_secs END;
                v_done := v_done + 1;
                set_progress('ROLLBACK', r.table_name, v_st.batches_restored + v_done, v_st.batches_done);
            END LOOP;

            IF v_result = 'COMPLETED' THEN
                UPDATE archive_run_state
                   SET status = 'RESTORED', restored_at = SYSTIMESTAMP
                 WHERE run_id = g_run_id AND table_name = r.table_name;
                COMMIT;
                write_log('INFO', 'Rollback completed (' || v_done || ' batches in this execution)', r.table_name);
            ELSE
                write_log('INFO', 'Rollback ' || v_result || ' after ' || v_done || ' batches', r.table_name);
            END IF;

            release_lock(g_tab_lock);
            RETURN v_result;
        EXCEPTION
            WHEN OTHERS THEN
                v_err := error_text;
                ROLLBACK;
                UPDATE archive_run_state
                   SET status = 'FAILED', last_error = v_err, last_exec_id = g_exec_id
                 WHERE run_id = g_run_id AND table_name = r.table_name;
                COMMIT;
                write_log('ERROR', 'Rollback failed at batch ' || v_b || ': ' || v_err, r.table_name, v_b);
                release_lock(g_tab_lock);
                RAISE;
        END;
    END rollback_table;

    ----------------------------------------------------------------------------
    -- VERIFY one table (read-only).
    ----------------------------------------------------------------------------
    PROCEDURE verify_table (r IN t_cfg) IS
        v_st      t_state;
        v_ix      VARCHAR2(128);
        v_sql     VARCHAR2(32767);
        v_resid   NUMBER;
        v_arc     NUMBER;
        v_expect  NUMBER;
        v_result  VARCHAR2(10) := 'OK';
        v_note    VARCHAR2(4000);
    BEGIN
        IF NOT get_state(r.table_name, v_st) THEN
            write_log('INFO', 'Not part of run ' || g_run_id || '; skipped', r.table_name);
            RETURN;
        END IF;
        DBMS_APPLICATION_INFO.SET_ACTION(SUBSTR('VERIFY ' || r.table_name, 1, 32));

        v_sql := 'SELECT /*+ PARALLEL(' || r.parallel_degree || ') */ COUNT(*) FROM '
              || obj(r.table_owner, r.table_name) || ' T WHERE ' || worklist_exists(r, 'T');
        EXECUTE IMMEDIATE v_sql INTO v_resid;

        v_ix  := find_tag_index(r);
        v_sql := 'SELECT ' || CASE WHEN v_ix IS NOT NULL THEN '/*+ INDEX(A ' || qn(v_ix) || ') */ ' END
              || 'COUNT(*) FROM ' || obj(r.table_owner, r.arc_table_name) || ' A WHERE A."ARC_RUN_ID" = :1';
        EXECUTE IMMEDIATE v_sql INTO v_arc USING g_run_id;

        v_expect := v_st.rows_archived - v_st.rows_restored;
        IF v_arc <> v_expect THEN
            v_result := 'ATTENTION';
            v_note   := 'archive holds ' || v_arc || ' rows of this run, state says ' || v_expect || '. ';
        END IF;
        IF v_st.status = 'COMPLETED' AND v_resid > 0 THEN
            v_result := 'ATTENTION';
            v_note   := v_note || v_resid || ' rows still match the worklist in the source'
                     || ' (created or changed after staging, or not staged). ';
        END IF;

        UPDATE archive_run_state
           SET verified_at = SYSTIMESTAMP, verify_residual_rows = v_resid,
               verify_arc_rows = v_arc, verify_result = v_result
         WHERE run_id = g_run_id AND table_name = r.table_name;
        COMMIT;

        write_log(CASE WHEN v_result = 'OK' THEN 'INFO' ELSE 'WARN' END,
                  'Verify ' || v_result || ': ' || v_resid || ' rows left in source matching the worklist, '
                  || v_arc || ' rows in archive for this run. ' || v_note, r.table_name);
        DBMS_OUTPUT.PUT_LINE(RPAD(r.table_name, 32) || RPAD(v_result, 11) || 'left in source: ' || v_resid
                             || ', in archive: ' || v_arc || ', expected in archive: ' || v_expect);
    END verify_table;

    ----------------------------------------------------------------------------
    -- STATS for one completed table.
    ----------------------------------------------------------------------------
    PROCEDURE stats_table (r IN t_cfg) IS
        v_st t_state;
        v_t0 PLS_INTEGER := DBMS_UTILITY.GET_TIME;
    BEGIN
        IF NOT get_state(r.table_name, v_st) OR v_st.status NOT IN ('COMPLETED', 'RESTORED') THEN
            write_log('INFO', 'Not completed in run ' || g_run_id || '; stats skipped', r.table_name);
            RETURN;
        END IF;
        IF v_st.stats_gathered_at >= NVL(v_st.restored_at, v_st.completed_at) THEN
            write_log('INFO', 'Stats already gathered after completion; skipped', r.table_name);
            RETURN;
        END IF;
        DBMS_APPLICATION_INFO.SET_ACTION(SUBSTR('STATS ' || r.table_name, 1, 32));
        DBMS_STATS.GATHER_TABLE_STATS(ownname          => r.table_owner,
                                      tabname          => r.table_name,
                                      estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                      degree           => r.parallel_degree,
                                      cascade          => DBMS_STATS.AUTO_CASCADE,
                                      no_invalidate    => DBMS_STATS.AUTO_INVALIDATE);
        UPDATE archive_run_state SET stats_gathered_at = SYSTIMESTAMP
         WHERE run_id = g_run_id AND table_name = r.table_name;
        COMMIT;
        write_log('INFO', 'Stats gathered (' || ROUND((DBMS_UTILITY.GET_TIME - v_t0) / 100) || ' s)', r.table_name);
    END stats_table;

    ----------------------------------------------------------------------------
    -- CLOSE a run: no further archiving; staging partition dropped.
    -- Rollback stays possible (it uses the archive tags, not the staging data).
    ----------------------------------------------------------------------------
    PROCEDURE close_run (p_force IN VARCHAR2) IS
        v_text VARCHAR2(4000);
        v_cnt  NUMBER;
    BEGIN
        SELECT LISTAGG(table_name || ' (' || status || ')', ', ') WITHIN GROUP (ORDER BY table_name)
          INTO v_text
          FROM archive_run_state
         WHERE run_id = g_run_id
           AND status NOT IN ('COMPLETED', 'RESTORED');
        IF v_text IS NOT NULL AND NVL(p_force, 'N') <> 'Y' THEN
            RAISE_APPLICATION_ERROR(-20040, 'Run ' || g_run_id || ' has unfinished tables: ' || v_text
                                    || '. Use force to close anyway (their pending batches are abandoned).');
        END IF;

        SELECT COUNT(*) INTO v_cnt FROM archive_exec
         WHERE run_id = g_run_id AND status = 'RUNNING' AND exec_id <> g_exec_id;
        IF v_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20041, 'Run ' || g_run_id || ' still has ' || v_cnt || ' running execution(s)');
        END IF;

        UPDATE archive_run SET status = 'CLOSED', closed_at = SYSTIMESTAMP WHERE run_id = g_run_id;
        COMMIT;
        write_log('INFO', 'Run closed' || CASE WHEN v_text IS NOT NULL THEN ' (forced; unfinished: ' || v_text || ')' END);

        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE purge_rid_stage DROP PARTITION FOR (' || TO_CHAR(g_run_id) || ')';
            write_log('INFO', 'Staging partition dropped');
        EXCEPTION
            WHEN OTHERS THEN
                write_log('WARN', 'Staging partition not dropped (none staged?): ' || SQLERRM);
        END;
    END close_run;

    ----------------------------------------------------------------------------
    -- Public procedures
    ----------------------------------------------------------------------------
    PROCEDURE REQUEST_STOP (p_run_id IN NUMBER, p_exec_id IN NUMBER DEFAULT NULL) IS
        v_n NUMBER;
    BEGIN
        UPDATE archive_exec
           SET stop_requested = 'Y'
         WHERE status = 'RUNNING'
           AND ((p_exec_id IS NOT NULL AND exec_id = p_exec_id)
                OR (p_exec_id IS NULL AND run_id = p_run_id));
        v_n := SQL%ROWCOUNT;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE(v_n || ' running execution(s) will stop after their current batch.');
    END REQUEST_STOP;

    PROCEDURE PREPARE_ARC_TABLE (p_table_name IN VARCHAR2,
                                 p_parallel   IN NUMBER   DEFAULT 8,
                                 p_index_ts   IN VARCHAR2 DEFAULT NULL) IS
        r      t_cfg := get_cfg(p_table_name);
        v_arc  VARCHAR2(400);
        v_ix   VARCHAR2(128);
        v_cnt  NUMBER;
        v_dop  NUMBER := GREATEST(1, LEAST(NVL(p_parallel, 8), 64));
    BEGIN
        v_arc := obj(r.table_owner, r.arc_table_name);

        SELECT COUNT(*) INTO v_cnt FROM all_tab_cols
         WHERE owner = r.table_owner AND table_name = r.arc_table_name AND column_name = 'ARC_RUN_ID';
        IF v_cnt = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE ' || v_arc || ' ADD ("ARC_RUN_ID" NUMBER INVISIBLE)';
            DBMS_OUTPUT.PUT_LINE(r.arc_table_name || ': added invisible column ARC_RUN_ID');
        END IF;

        SELECT COUNT(*) INTO v_cnt FROM all_tab_cols
         WHERE owner = r.table_owner AND table_name = r.arc_table_name AND column_name = 'ARC_BATCH_NO';
        IF v_cnt = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE ' || v_arc || ' ADD ("ARC_BATCH_NO" NUMBER INVISIBLE)';
            DBMS_OUTPUT.PUT_LINE(r.arc_table_name || ': added invisible column ARC_BATCH_NO');
        END IF;

        v_ix := find_tag_index(r);
        IF v_ix IS NULL THEN
            v_ix := 'ARC_TAG_IX_' || r.table_order;
            EXECUTE IMMEDIATE 'CREATE INDEX ' || obj(r.table_owner, v_ix) || ' ON ' || v_arc
                           || ' ("ARC_RUN_ID", "ARC_BATCH_NO")'
                           || CASE WHEN p_index_ts IS NOT NULL THEN ' TABLESPACE ' || qn(p_index_ts) END
                           || ' PARALLEL ' || v_dop;
            EXECUTE IMMEDIATE 'ALTER INDEX ' || obj(r.table_owner, v_ix) || ' NOPARALLEL';
            DBMS_OUTPUT.PUT_LINE(r.arc_table_name || ': created index ' || v_ix);
        ELSE
            DBMS_OUTPUT.PUT_LINE(r.arc_table_name || ': tag index ' || v_ix || ' already present');
        END IF;
    END PREPARE_ARC_TABLE;

    PROCEDURE RUN_JOB (
        p_mode         IN     VARCHAR2,
        p_run_id       IN OUT NUMBER,
        p_table_csv    IN     VARCHAR2 DEFAULT NULL,
        p_batch_size   IN     NUMBER   DEFAULT NULL,
        p_max_minutes  IN     NUMBER   DEFAULT NULL,
        p_force        IN     VARCHAR2 DEFAULT 'N',
        p_exec_id      OUT    NUMBER,
        p_status       OUT    VARCHAR2,
        p_message      OUT    VARCHAR2) IS

        v_mode     VARCHAR2(10) := UPPER(TRIM(p_mode));
        v_tables   t_names;
        v_result   VARCHAR2(10);
        v_run_st   VARCHAR2(10);
        v_errors   PLS_INTEGER := 0;
        v_err      VARCHAR2(4000);
    BEGIN
        p_exec_id := NULL;
        p_status  := NULL;
        p_message := NULL;
        g_mode    := v_mode;
        g_run_id  := NULL;
        g_exec_id := NULL;

        ------------------------------------------------------------------------
        -- Parameter validation (raises; nothing recorded yet)
        ------------------------------------------------------------------------
        IF v_mode IS NULL OR v_mode NOT IN ('CHECK', 'STAGE', 'ARCHIVE', 'ROLLBACK', 'VERIFY', 'STATS', 'CLOSE') THEN
            RAISE_APPLICATION_ERROR(-20050, 'Unknown mode ' || p_mode);
        END IF;
        IF p_batch_size IS NOT NULL AND v_mode <> 'STAGE' THEN
            RAISE_APPLICATION_ERROR(-20051, 'Batch size applies to STAGE only (batches are fixed at staging)');
        END IF;
        IF p_batch_size IS NOT NULL AND (p_batch_size < 1000 OR p_batch_size > 2000000) THEN
            RAISE_APPLICATION_ERROR(-20052, 'Batch size must be between 1,000 and 2,000,000');
        END IF;
        IF p_max_minutes IS NOT NULL AND (p_max_minutes < 1 OR p_max_minutes > 1440) THEN
            RAISE_APPLICATION_ERROR(-20053, 'Max minutes must be between 1 and 1440');
        END IF;

        IF p_run_id IS NULL THEN
            IF v_mode NOT IN ('STAGE', 'CHECK') THEN
                RAISE_APPLICATION_ERROR(-20054, 'A run id is required for mode ' || v_mode);
            END IF;
        ELSE
            BEGIN
                SELECT status INTO v_run_st FROM archive_run WHERE run_id = p_run_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20055, 'Run ' || p_run_id || ' does not exist');
            END;
            IF v_run_st = 'CLOSED' AND v_mode IN ('STAGE', 'ARCHIVE', 'CLOSE') THEN
                RAISE_APPLICATION_ERROR(-20056, 'Run ' || p_run_id || ' is closed');
            END IF;
        END IF;

        ------------------------------------------------------------------------
        -- Start the execution
        ------------------------------------------------------------------------
        IF p_run_id IS NULL AND v_mode = 'STAGE' THEN
            p_run_id := archive_run_seq.NEXTVAL;
            INSERT INTO archive_run (run_id, status, created_by)
            VALUES (p_run_id, 'OPEN', NVL(SYS_CONTEXT('USERENV', 'OS_USER'), USER));
        END IF;
        g_run_id  := p_run_id;
        g_exec_id := archive_exec_seq.NEXTVAL;
        p_exec_id := g_exec_id;

        IF NOT acquire_lock(lock_name('EXEC', TO_CHAR(g_exec_id)), g_exec_lock) THEN
            RAISE_APPLICATION_ERROR(-20057, 'Could not take the execution lock');
        END IF;

        g_deadline := CASE WHEN p_max_minutes IS NOT NULL THEN SYSDATE + p_max_minutes / 1440 END;

        INSERT INTO archive_exec (exec_id, run_id, mode_name, table_filter, batch_size, max_minutes, deadline,
                                  status, inst_id, sid, client_host, os_user)
        VALUES (g_exec_id, g_run_id, v_mode, UPPER(p_table_csv), p_batch_size, p_max_minutes, g_deadline,
                'RUNNING', TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE')), TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')),
                SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'OS_USER'));
        COMMIT;

        DBMS_APPLICATION_INFO.SET_MODULE(module_name => 'PKG_ARCHIVE_MANAGER', action_name => v_mode);

        ------------------------------------------------------------------------
        -- Work. From here on, errors are recorded and returned as FAILED.
        ------------------------------------------------------------------------
        BEGIN
            cleanup_orphans;
            write_log('INFO', 'Execution started: mode ' || v_mode || ', tables ' || NVL(UPPER(p_table_csv), 'ALL ENABLED')
                      || CASE WHEN p_batch_size IS NOT NULL THEN ', batch size ' || p_batch_size END
                      || CASE WHEN p_max_minutes IS NOT NULL THEN ', max ' || p_max_minutes || ' min' END
                      || ', engine ' || c_version);

            BEGIN
                EXECUTE IMMEDIATE 'ALTER SESSION SET parallel_force_local = TRUE';
            EXCEPTION
                WHEN OTHERS THEN
                    write_log('WARN', 'Could not set parallel_force_local (PX may span RAC instances): ' || SQLERRM);
            END;

            v_tables := resolve_scope(p_table_csv, v_mode = 'ROLLBACK', v_mode = 'CHECK');

            IF v_mode = 'CHECK' THEN
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_errors := v_errors + check_table(get_cfg(v_tables(i)));
                END LOOP;
                v_result := CASE WHEN v_errors = 0 THEN 'COMPLETED' ELSE 'FAILED' END;
                p_message := v_errors || ' error(s) in ' || v_tables.COUNT || ' table(s)';

            ELSIF v_mode = 'STAGE' THEN
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_result := interruption(0);
                    EXIT WHEN v_result IS NOT NULL;
                    stage_table(get_cfg(v_tables(i)), p_batch_size);
                END LOOP;

            ELSIF v_mode = 'ARCHIVE' THEN
                -- fail fast if anything in scope is not staged
                FOR i IN 1 .. v_tables.COUNT LOOP
                    SELECT COUNT(*) INTO v_errors FROM archive_run_state
                     WHERE run_id = g_run_id AND table_name = v_tables(i) AND status <> 'FAILED';
                    IF v_errors = 0 THEN
                        SELECT COUNT(*) INTO v_errors FROM archive_run_state
                         WHERE run_id = g_run_id AND table_name = v_tables(i) AND last_action = 'ARCHIVE';
                    END IF;
                    IF v_errors = 0 THEN
                        RAISE_APPLICATION_ERROR(-20020, v_tables(i) || ' is not staged in run ' || g_run_id);
                    END IF;
                END LOOP;
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_result := archive_table(get_cfg(v_tables(i)));
                    EXIT WHEN v_result <> 'COMPLETED';
                END LOOP;

            ELSIF v_mode = 'ROLLBACK' THEN
                IF v_run_st = 'CLOSED' THEN
                    write_log('WARN', 'Rolling back tables of a closed run');
                END IF;
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_result := rollback_table(get_cfg(v_tables(i)));
                    EXIT WHEN v_result <> 'COMPLETED';
                END LOOP;

            ELSIF v_mode = 'VERIFY' THEN
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_result := interruption(0);
                    EXIT WHEN v_result IS NOT NULL;
                    verify_table(get_cfg(v_tables(i)));
                END LOOP;

            ELSIF v_mode = 'STATS' THEN
                FOR i IN 1 .. v_tables.COUNT LOOP
                    v_result := interruption(0);
                    EXIT WHEN v_result IS NOT NULL;
                    stats_table(get_cfg(v_tables(i)));
                END LOOP;

            ELSIF v_mode = 'CLOSE' THEN
                close_run(p_force);
            END IF;

            p_status := NVL(v_result, 'COMPLETED');
        EXCEPTION
            WHEN OTHERS THEN
                v_err := error_text;
                ROLLBACK;
                p_status  := 'FAILED';
                p_message := SUBSTR(SQLERRM, 1, 4000);
                write_log('ERROR', 'Execution failed: ' || v_err);
                release_lock(g_tab_lock);
        END;

        ------------------------------------------------------------------------
        -- Finish the execution
        ------------------------------------------------------------------------
        UPDATE archive_exec
           SET status = p_status, ended_at = SYSTIMESTAMP, message = p_message
         WHERE exec_id = g_exec_id;
        COMMIT;
        write_log('INFO', 'Execution finished: ' || p_status || CASE WHEN p_message IS NOT NULL THEN ' - ' || p_message END);
        release_lock(g_exec_lock);
        DBMS_APPLICATION_INFO.SET_MODULE(module_name => NULL, action_name => NULL);
        p_run_id := g_run_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Parameter errors and failures of the bookkeeping itself.
            ROLLBACK;
            release_lock(g_tab_lock);
            release_lock(g_exec_lock);
            RAISE;
    END RUN_JOB;

END PKG_ARCHIVE_MANAGER;
/
