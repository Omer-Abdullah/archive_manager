--------------------------------------------------------------------------------
-- 07_dba_monitoring.sql                            archive_manager v1.0.0
-- Queries for the DBA during a window. The first block needs only the engine
-- owner; the GV$/V$ blocks need SELECT_CATALOG_ROLE or a DBA account.
-- The engine tables are read in the current schema: connect as the engine
-- owner, or as a DBA after:  ALTER SESSION SET CURRENT_SCHEMA = <engine owner>;
--------------------------------------------------------------------------------
SET LINESIZE 250 PAGESIZE 100 VERIFY OFF
COLUMN table_name FORMAT A28
COLUMN status     FORMAT A10
COLUMN message    FORMAT A80 WORD_WRAPPED

PROMPT === Engine: progress of the open runs
SELECT run_id, table_order, table_name, status, batches_done || '/' || batches_total AS batches,
       pct_archived, rows_deleted, avg_batch_sec, rows_per_sec, eta_minutes, verify_result
  FROM v_archive_progress
 WHERE run_id IN (SELECT run_id FROM archive_run WHERE status = 'OPEN')
 ORDER BY run_id, table_order;

PROMPT === Engine: running executions (NO_PROGRESS_15MIN = Y deserves a look)
SELECT exec_id, run_id, mode_name, status, inst_id, sid, started_at, deadline, last_activity,
       no_progress_15min, stop_requested
  FROM v_archive_exec
 WHERE status = 'RUNNING';

PROMPT === Engine: errors and warnings of the last 24 hours
SELECT log_time, exec_id, table_name, batch_no, log_level, message
  FROM archive_log
 WHERE log_level IN ('ERROR', 'WARN')
   AND log_time > SYSTIMESTAMP - INTERVAL '1' DAY
 ORDER BY log_time DESC
 FETCH FIRST 30 ROWS ONLY;

PROMPT === Session: what the engine session is doing now
SELECT inst_id, sid, serial#, module, action, client_info, status, event, seconds_in_wait,
       sql_id, blocking_instance, blocking_session
  FROM gv$session
 WHERE module = 'PKG_ARCHIVE_MANAGER';

PROMPT === Session: Oracle's own progress and time-remaining estimate
SELECT inst_id, sid, opname, target_desc, sofar, totalwork, units,
       ROUND(100 * sofar / NULLIF(totalwork, 0), 1) AS pct, elapsed_seconds, time_remaining
  FROM gv$session_longops
 WHERE opname LIKE 'PKG_ARCHIVE_MANAGER%'
   AND sofar < totalwork;

PROMPT === Session: size of the open transaction (one batch)
SELECT s.inst_id, s.sid, t.used_ublk AS undo_blocks, t.used_urec AS undo_records, t.start_time
  FROM gv$transaction t
  JOIN gv$session s ON s.taddr = t.addr AND s.inst_id = t.inst_id
 WHERE s.module = 'PKG_ARCHIVE_MANAGER';

PROMPT === Blocking anywhere in the cluster
SELECT inst_id, sid, module, event, seconds_in_wait, blocking_instance, blocking_session
  FROM gv$session
 WHERE blocking_session IS NOT NULL;

PROMPT === Redo generated per hour, last 24 hours (archive destination 1)
SELECT TRUNC(first_time, 'HH24') AS hour,
       ROUND(SUM(blocks * block_size) / 1024 / 1024 / 1024, 1) AS redo_gb
  FROM v$archived_log
 WHERE first_time > SYSDATE - 1
   AND dest_id = 1
 GROUP BY TRUNC(first_time, 'HH24')
 ORDER BY 1;

PROMPT === Fast recovery area
SELECT name, ROUND(space_limit / 1024 / 1024 / 1024) AS limit_gb,
       ROUND(space_used / 1024 / 1024 / 1024) AS used_gb,
       ROUND(space_reclaimable / 1024 / 1024 / 1024) AS reclaimable_gb,
       ROUND(100 * (space_used - space_reclaimable) / NULLIF(space_limit, 0), 1) AS pct_really_used
  FROM v$recovery_file_dest;

PROMPT === Undo in use
SELECT tablespace_name, status, ROUND(SUM(bytes) / 1024 / 1024 / 1024, 1) AS gb
  FROM dba_undo_extents
 GROUP BY tablespace_name, status
 ORDER BY 1, 2;

PROMPT === TEMP in use by the engine (staging sorts)
SELECT s.inst_id, s.sid, u.tablespace, ROUND(SUM(u.blocks) * 8 / 1024 / 1024, 1) AS gb_if_8k_blocks
  FROM gv$tempseg_usage u
  JOIN gv$session s ON s.saddr = u.session_addr AND s.inst_id = u.inst_id
 WHERE s.module = 'PKG_ARCHIVE_MANAGER'
 GROUP BY s.inst_id, s.sid, u.tablespace;

PROMPT === Standby destinations (run on the primary)
SELECT dest_id, dest_name, status, gap_status, error
  FROM v$archive_dest_status
 WHERE status <> 'INACTIVE'
   AND type <> 'LOCAL';
