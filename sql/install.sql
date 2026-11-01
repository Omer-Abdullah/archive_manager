--------------------------------------------------------------------------------
-- install.sql                                      archive_manager v1.0.0
--
-- Run in SQL*Plus as the engine owner from this directory:
--   cd sql
--   sqlplus /nolog
--   SQL> CONNECT <engine owner>@<service>
--   SQL> @install.sql
--
-- Afterwards register your tables (see examples/01_register_tables.sql, or
-- the test kit config) and run 06_prepare_arc_tables.sql.
--------------------------------------------------------------------------------
SET ECHO OFF VERIFY OFF FEEDBACK ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

-- Tablespaces for the engine's own objects; change if needed.
DEFINE DATA_TS  = USERS
DEFINE INDEX_TS = USERS

SPOOL install_archive_manager.log

PROMPT === Control objects
@@01_control_objects.sql

PROMPT === Package specification
@@03_pkg_archive_manager.pks
SHOW ERRORS PACKAGE PKG_ARCHIVE_MANAGER

PROMPT === Package body
@@04_pkg_archive_manager.pkb
SHOW ERRORS PACKAGE BODY PKG_ARCHIVE_MANAGER

PROMPT === Views
@@05_views.sql

DECLARE
    v_errors NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_errors FROM user_errors WHERE name = 'PKG_ARCHIVE_MANAGER';
    IF v_errors > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'PKG_ARCHIVE_MANAGER has ' || v_errors || ' compilation error(s); see above');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PKG_ARCHIVE_MANAGER ' || pkg_archive_manager.version || ' installed without errors');
END;
/

SPOOL OFF
