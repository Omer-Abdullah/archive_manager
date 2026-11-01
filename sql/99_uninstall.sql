--------------------------------------------------------------------------------
-- 99_uninstall.sql                                 archive_manager v1.0.0
-- Removes the engine objects. Does NOT touch business tables or archive tables:
-- the invisible ARC_RUN_ID / ARC_BATCH_NO columns and ARC_TAG_IX_* indexes stay
-- (drop them by hand only if no rollback will ever be needed).
-- Run as the engine owner. Everything recorded in the run/log tables is lost.
--------------------------------------------------------------------------------
SET VERIFY OFF
WHENEVER SQLERROR CONTINUE

DROP VIEW v_archive_exec;
DROP VIEW v_archive_progress;
DROP VIEW v_archive_run;
DROP PACKAGE pkg_archive_manager;
DROP TABLE archive_log         PURGE;
DROP TABLE purge_rid_stage     PURGE;
DROP TABLE archive_batch       PURGE;
DROP TABLE archive_run_state   PURGE;
DROP TABLE archive_exec        PURGE;
DROP TABLE archive_run         PURGE;
DROP TABLE archive_table_config PURGE;
DROP SEQUENCE archive_log_seq;
DROP SEQUENCE archive_exec_seq;
DROP SEQUENCE archive_run_seq;
