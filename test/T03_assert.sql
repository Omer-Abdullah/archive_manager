--------------------------------------------------------------------------------
-- T03_assert.sql                                   archive_manager v1.0.0
-- Usage:  @T03_assert.sql <AFTER_ARCHIVE|AFTER_ROLLBACK> <run_id>
-- Compares row counts AND content checksums with TST_BASELINE.
-- Exits with an error (non-zero SQL*Plus code) on the first failed check.
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK OFF SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_phase  VARCHAR2(20) := UPPER('&1');
    v_run    NUMBER       := TO_NUMBER('&2');
    v_fail   PLS_INTEGER  := 0;
    v_arc_rows NUMBER;
    v_arc_sum  NUMBER;

    PROCEDURE check_eq (p_what IN VARCHAR2, p_got IN NUMBER, p_want IN NUMBER) IS
    BEGIN
        IF NVL(p_got, 0) = NVL(p_want, 0) THEN
            DBMS_OUTPUT.PUT_LINE('PASS  ' || p_what || ' = ' || NVL(p_got, 0));
        ELSE
            DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_what || ': got ' || NVL(p_got, 0) || ', expected ' || NVL(p_want, 0));
            v_fail := v_fail + 1;
        END IF;
    END check_eq;
BEGIN
    IF v_phase NOT IN ('AFTER_ARCHIVE', 'AFTER_ROLLBACK') THEN
        RAISE_APPLICATION_ERROR(-20900, 'Phase must be AFTER_ARCHIVE or AFTER_ROLLBACK');
    END IF;

    FOR b IN (SELECT bl.table_name, bl.total_rows, bl.matched_rows, bl.checksum, bl.matched_checksum,
                     cur.total_rows AS cur_total, cur.matched_rows AS cur_matched, cur.checksum AS cur_checksum
                FROM tst_baseline bl
                JOIN tst_signatures cur ON cur.table_name = bl.table_name
               ORDER BY bl.table_name)
    LOOP
        SELECT NVL(SUM(arc_rows), 0), NVL(SUM(checksum), 0) INTO v_arc_rows, v_arc_sum
          FROM tst_arc_signatures WHERE table_name = b.table_name AND arc_run_id = v_run;

        IF v_phase = 'AFTER_ARCHIVE' THEN
            check_eq(b.table_name || ' rows left in source',             b.cur_total,    b.total_rows - b.matched_rows);
            check_eq(b.table_name || ' worklist rows left in source',    b.cur_matched,  0);
            check_eq(b.table_name || ' source checksum',                 b.cur_checksum, b.checksum - b.matched_checksum);
            check_eq(b.table_name || ' rows in archive for run',         v_arc_rows,     b.matched_rows);
            check_eq(b.table_name || ' archive checksum',                v_arc_sum,      b.matched_checksum);
        ELSE
            check_eq(b.table_name || ' rows in source',                  b.cur_total,    b.total_rows);
            check_eq(b.table_name || ' source checksum',                 b.cur_checksum, b.checksum);
            check_eq(b.table_name || ' rows in archive for run',         v_arc_rows,     0);
        END IF;
    END LOOP;

    -- Engine bookkeeping agrees with reality
    FOR s IN (SELECT st.table_name, st.status, st.rows_deleted, st.rows_restored, bl.matched_rows
                FROM archive_run_state st
                JOIN tst_baseline bl ON bl.table_name = st.table_name
               WHERE st.run_id = v_run
               ORDER BY st.table_name)
    LOOP
        IF v_phase = 'AFTER_ARCHIVE' THEN
            check_eq(s.table_name || ' ARCHIVE_RUN_STATE.rows_deleted', s.rows_deleted, s.matched_rows);
            IF s.status <> 'COMPLETED' THEN
                DBMS_OUTPUT.PUT_LINE('FAIL  ' || s.table_name || ' status ' || s.status || ', expected COMPLETED');
                v_fail := v_fail + 1;
            END IF;
        ELSE
            check_eq(s.table_name || ' ARCHIVE_RUN_STATE.rows_restored', s.rows_restored, s.matched_rows);
            IF s.status <> 'RESTORED' THEN
                DBMS_OUTPUT.PUT_LINE('FAIL  ' || s.table_name || ' status ' || s.status || ', expected RESTORED');
                v_fail := v_fail + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20901, v_phase || ': ' || v_fail || ' check(s) failed');
    END IF;
    DBMS_OUTPUT.PUT_LINE(v_phase || ': all checks passed');
END;
/
