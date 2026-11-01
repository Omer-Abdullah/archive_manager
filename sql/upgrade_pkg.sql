--------------------------------------------------------------------------------
-- upgrade_pkg.sql                                  archive_manager v1.0.0
--
-- Replaces PKG_ARCHIVE_MANAGER (spec + body) on an engine that is already
-- installed. Tables, configuration, runs and logs are kept unchanged.
-- Run as the engine owner from this directory, when no execution is RUNNING:
--   cd sql
--   sqlplus /nolog
--   SQL> CONNECT <engine owner>@<service>
--   SQL> @upgrade_pkg.sql
--------------------------------------------------------------------------------
SET ECHO OFF VERIFY OFF FEEDBACK ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

SPOOL upgrade_pkg.log

PROMPT === Version before
SELECT pkg_archive_manager.version AS old_version FROM dual;

PROMPT === Package specification
@@03_pkg_archive_manager.pks
SHOW ERRORS PACKAGE PKG_ARCHIVE_MANAGER

PROMPT === Package body
@@04_pkg_archive_manager.pkb
SHOW ERRORS PACKAGE BODY PKG_ARCHIVE_MANAGER

DECLARE
    v_errors NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_errors FROM user_errors WHERE name = 'PKG_ARCHIVE_MANAGER';
    IF v_errors > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'PKG_ARCHIVE_MANAGER has ' || v_errors || ' compilation error(s); see above');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PKG_ARCHIVE_MANAGER ' || pkg_archive_manager.version || ' upgraded without errors');
END;
/

SPOOL OFF
