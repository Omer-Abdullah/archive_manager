--------------------------------------------------------------------------------
-- 00_prereq_dba.sql                                archive_manager v1.0.0
-- Run ONCE as SYS or a DBA. Asks for the schema that will own the engine
-- (for the test kit: a scratch schema, e.g. ARCH_TEST) and its tablespaces.
--------------------------------------------------------------------------------
ACCEPT ENGINE_OWNER CHAR PROMPT 'Engine owner schema: '
ACCEPT DATA_TS  CHAR DEFAULT USERS PROMPT 'Data tablespace  [USERS]: '
ACCEPT INDEX_TS CHAR DEFAULT USERS PROMPT 'Index tablespace [USERS]: '

-- Cluster-wide user locks used by the engine (definer rights: direct grant).
GRANT EXECUTE ON SYS.DBMS_LOCK TO &&ENGINE_OWNER;

-- Normally already present for the schema owner; listed for completeness.
-- GRANT CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO &&ENGINE_OWNER;
-- ALTER USER &&ENGINE_OWNER QUOTA UNLIMITED ON &&DATA_TS;
-- ALTER USER &&ENGINE_OWNER QUOTA UNLIMITED ON &&INDEX_TS;

-- Optional, only for the GV$ queries in 07_dba_monitoring.sql if a non-DBA
-- account should run them:
-- GRANT SELECT_CATALOG_ROLE TO <monitoring_user>;

--------------------------------------------------------------------------------
-- Facts the DBA should confirm before the first run (read-only):
--------------------------------------------------------------------------------
-- Database version and COMPATIBLE (identifiers over 30 chars need >= 12.2)
SELECT name, value FROM v$parameter WHERE name IN ('compatible', 'parallel_max_servers', 'undo_retention');

-- Archive log mode, force logging, Data Guard role
SELECT name, log_mode, force_logging, database_role FROM v$database;

-- Free space in the tablespaces the engine and the archive tables use
SELECT tablespace_name, ROUND(SUM(bytes) / 1024 / 1024 / 1024, 1) AS free_gb
  FROM dba_free_space
 WHERE tablespace_name IN (UPPER('&&DATA_TS'), UPPER('&&INDEX_TS'))
 GROUP BY tablespace_name;

-- TEMP (staging sorts the ROWIDs of the biggest table) and UNDO size
SELECT tablespace_name, ROUND(SUM(bytes) / 1024 / 1024 / 1024, 1) AS size_gb
  FROM dba_temp_files GROUP BY tablespace_name;
SELECT tablespace_name, ROUND(SUM(bytes) / 1024 / 1024 / 1024, 1) AS size_gb
  FROM dba_data_files
 WHERE tablespace_name IN (SELECT tablespace_name FROM dba_tablespaces WHERE contents = 'UNDO')
 GROUP BY tablespace_name;

-- Fast recovery area (archived redo of the purge lands here)
SELECT name, ROUND(space_limit / 1024 / 1024 / 1024) AS limit_gb,
       ROUND(space_used / 1024 / 1024 / 1024) AS used_gb
  FROM v$recovery_file_dest;
