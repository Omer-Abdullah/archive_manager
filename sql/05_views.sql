--------------------------------------------------------------------------------
-- 05_views.sql                                     archive_manager v1.0.0
-- Monitoring views over the engine's own tables (no special privileges).
--------------------------------------------------------------------------------

-- One row per run.
CREATE OR REPLACE VIEW V_ARCHIVE_RUN AS
SELECT r.run_id,
       r.status,
       r.created_at,
       r.created_by,
       r.closed_at,
       COUNT(s.table_name)                                         AS tables_in_run,
       SUM(CASE WHEN s.status = 'COMPLETED' THEN 1 ELSE 0 END)     AS tables_completed,
       SUM(CASE WHEN s.status = 'FAILED'    THEN 1 ELSE 0 END)     AS tables_failed,
       SUM(s.rows_staged)                                          AS rows_staged,
       SUM(s.rows_deleted)                                         AS rows_deleted,
       SUM(s.rows_restored)                                        AS rows_restored
  FROM archive_run r
  LEFT JOIN archive_run_state s ON s.run_id = r.run_id
 GROUP BY r.run_id, r.status, r.created_at, r.created_by, r.closed_at;

-- One row per table per run, with speed and time left.
CREATE OR REPLACE VIEW V_ARCHIVE_PROGRESS AS
SELECT s.run_id,
       c.table_order,
       s.table_name,
       s.status,
       s.last_action,
       s.rows_staged,
       s.batch_size,
       s.batches_total,
       s.batches_done,
       s.batches_restored,
       ROUND(100 * s.batches_done / NULLIF(s.batches_total, 0), 1)          AS pct_archived,
       s.rows_deleted,
       s.rows_restored,
       b.avg_batch_sec,
       b.rows_per_sec,
       CASE WHEN s.status IN ('STAGED', 'ARCHIVING') AND b.avg_batch_sec IS NOT NULL
            THEN ROUND((s.batches_total - s.batches_done) * b.avg_batch_sec / 60) END AS eta_minutes,
       s.staged_at,
       s.archive_started_at,
       s.completed_at,
       s.verify_result,
       s.verify_residual_rows,
       s.stats_gathered_at,
       s.last_exec_id,
       s.last_error
  FROM archive_run_state s
  JOIN archive_table_config c ON c.table_name = s.table_name
  LEFT JOIN (SELECT run_id,
                    table_name,
                    ROUND(AVG(archive_seconds), 1)                              AS avg_batch_sec,
                    ROUND(SUM(rows_deleted) / NULLIF(SUM(archive_seconds), 0))  AS rows_per_sec
               FROM archive_batch
              WHERE archive_seconds IS NOT NULL
              GROUP BY run_id, table_name) b
    ON b.run_id = s.run_id AND b.table_name = s.table_name;

-- One row per execution; NO_PROGRESS_15MIN flags a RUNNING execution that has
-- neither logged nor finished a batch for 15 minutes (stuck, blocked, or one
-- very long statement such as staging a big table).
CREATE OR REPLACE VIEW V_ARCHIVE_EXEC AS
SELECT e.exec_id,
       e.run_id,
       e.mode_name,
       e.status,
       e.table_filter,
       e.max_minutes,
       e.started_at,
       e.ended_at,
       e.deadline,
       e.stop_requested,
       e.inst_id,
       e.sid,
       e.client_host,
       e.os_user,
       GREATEST(NVL(l.last_log_time, e.started_at),
                NVL(b.last_batch_at, e.started_at))                        AS last_activity,
       CASE WHEN e.status = 'RUNNING'
             AND GREATEST(NVL(l.last_log_time, e.started_at), NVL(b.last_batch_at, e.started_at))
                 < SYSTIMESTAMP - INTERVAL '15' MINUTE
            THEN 'Y' ELSE 'N' END                                          AS no_progress_15min,
       e.message
  FROM archive_exec e
  LEFT JOIN (SELECT exec_id, MAX(log_time) AS last_log_time FROM archive_log GROUP BY exec_id) l
    ON l.exec_id = e.exec_id
  LEFT JOIN (SELECT exec_id, MAX(GREATEST(NVL(archived_at, restored_at), NVL(restored_at, archived_at))) AS last_batch_at
               FROM archive_batch GROUP BY exec_id) b
    ON b.exec_id = e.exec_id;
