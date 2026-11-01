--------------------------------------------------------------------------------
-- 01_control_objects.sql                           archive_manager v1.0.0
--
-- Creates the engine's own tables and sequences. Run as the schema that will
-- own PKG_ARCHIVE_MANAGER, through install.sql, which DEFINEs:
--   DATA_TS  - tablespace for control tables        (e.g. USERS)
--   INDEX_TS - tablespace for control indexes       (e.g. USERS)
--
-- Nothing here touches the business tables.
--------------------------------------------------------------------------------

CREATE SEQUENCE ARCHIVE_RUN_SEQ  START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE ARCHIVE_EXEC_SEQ START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE ARCHIVE_LOG_SEQ  START WITH 1 INCREMENT BY 1 CACHE 1000;

--------------------------------------------------------------------------------
-- ARCHIVE_TABLE_CONFIG: one row per table the engine may archive.
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_TABLE_CONFIG
(
    TABLE_NAME       VARCHAR2(128)  NOT NULL,   -- source table
    TABLE_OWNER      VARCHAR2(128)  DEFAULT USER NOT NULL,
    TABLE_ORDER      NUMBER(5)      NOT NULL,   -- archive order (children low, parent high)
    ARC_TABLE_NAME   VARCHAR2(128)  NOT NULL,   -- archive table, same owner
    KEY_COLUMN       VARCHAR2(128)  NOT NULL,   -- row identity check (VARCHAR2/CHAR/NUMBER)
    JOIN_COLUMN      VARCHAR2(128)  NOT NULL,   -- source column matched to the worklist
    WORKLIST_TABLE   VARCHAR2(128)  NOT NULL,   -- table listing the parent keys to archive, same owner
    WORKLIST_COLUMN  VARCHAR2(128)  NOT NULL,   -- key column of the worklist
    JOIN_CAST        VARCHAR2(10),              -- NULL = compare as-is, 'TO_CHAR' = TO_CHAR(worklist col)
    BATCH_SIZE       NUMBER(10)     DEFAULT 100000 NOT NULL,
    PARALLEL_DEGREE  NUMBER(3)      DEFAULT 4 NOT NULL,   -- staging, verify, stats
    DEPENDS_ON       VARCHAR2(4000),            -- NULL = every enabled table with a lower TABLE_ORDER,
                                                -- 'NONE' = no dependency; else comma list of table names
    ENABLED_FLAG     VARCHAR2(1)    DEFAULT 'N' NOT NULL,
    NOTES            VARCHAR2(4000),
    CONSTRAINT ARC_CFG_PK         PRIMARY KEY (TABLE_NAME) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_CFG_ORDER_UK   UNIQUE (TABLE_ORDER)     USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_CFG_ENABLED_CK CHECK (ENABLED_FLAG IN ('Y','N')),
    CONSTRAINT ARC_CFG_CAST_CK    CHECK (JOIN_CAST IS NULL OR JOIN_CAST = 'TO_CHAR'),
    CONSTRAINT ARC_CFG_BATCH_CK   CHECK (BATCH_SIZE BETWEEN 1000 AND 2000000),
    CONSTRAINT ARC_CFG_DOP_CK     CHECK (PARALLEL_DEGREE BETWEEN 1 AND 64),
    CONSTRAINT ARC_CFG_UPPER_CK   CHECK (TABLE_NAME = UPPER(TABLE_NAME) AND TABLE_OWNER = UPPER(TABLE_OWNER)
                                         AND ARC_TABLE_NAME = UPPER(ARC_TABLE_NAME) AND KEY_COLUMN = UPPER(KEY_COLUMN)
                                         AND JOIN_COLUMN = UPPER(JOIN_COLUMN) AND WORKLIST_TABLE = UPPER(WORKLIST_TABLE)
                                         AND WORKLIST_COLUMN = UPPER(WORKLIST_COLUMN))
)
TABLESPACE &&DATA_TS;

--------------------------------------------------------------------------------
-- ARCHIVE_RUN: one purge cycle (one worklist). Spans many executions/windows.
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_RUN
(
    RUN_ID      NUMBER         NOT NULL,
    STATUS      VARCHAR2(10)   DEFAULT 'OPEN' NOT NULL,     -- OPEN, CLOSED
    CREATED_AT  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CREATED_BY  VARCHAR2(128),
    CLOSED_AT   TIMESTAMP,
    NOTES       VARCHAR2(4000),
    CONSTRAINT ARC_RUN_PK        PRIMARY KEY (RUN_ID) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_RUN_STATUS_CK CHECK (STATUS IN ('OPEN','CLOSED'))
)
TABLESPACE &&DATA_TS;

--------------------------------------------------------------------------------
-- ARCHIVE_EXEC: one row per invocation of the engine (one bash call).
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_EXEC
(
    EXEC_ID         NUMBER          NOT NULL,
    RUN_ID          NUMBER,                       -- NULL only for CHECK without a run
    MODE_NAME       VARCHAR2(10)    NOT NULL,     -- CHECK STAGE ARCHIVE ROLLBACK VERIFY STATS CLOSE
    TABLE_FILTER    VARCHAR2(4000),
    BATCH_SIZE      NUMBER,
    MAX_MINUTES     NUMBER,
    DEADLINE        DATE,
    STATUS          VARCHAR2(10)    NOT NULL,     -- RUNNING COMPLETED PAUSED STOPPED FAILED ABORTED
    STOP_REQUESTED  VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    STARTED_AT      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    ENDED_AT        TIMESTAMP,
    INST_ID         NUMBER,
    SID             NUMBER,
    CLIENT_HOST     VARCHAR2(128),
    OS_USER         VARCHAR2(128),
    MESSAGE         VARCHAR2(4000),
    CONSTRAINT ARC_EXEC_PK        PRIMARY KEY (EXEC_ID) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_EXEC_RUN_FK    FOREIGN KEY (RUN_ID) REFERENCES ARCHIVE_RUN (RUN_ID),
    CONSTRAINT ARC_EXEC_STATUS_CK CHECK (STATUS IN ('RUNNING','COMPLETED','PAUSED','STOPPED','FAILED','ABORTED')),
    CONSTRAINT ARC_EXEC_STOP_CK   CHECK (STOP_REQUESTED IN ('Y','N'))
)
TABLESPACE &&DATA_TS;

CREATE INDEX ARC_EXEC_RUN_IX ON ARCHIVE_EXEC (RUN_ID, STATUS) TABLESPACE &&INDEX_TS;

--------------------------------------------------------------------------------
-- ARCHIVE_RUN_STATE: progress of each table inside a run (the resumable state).
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_RUN_STATE
(
    RUN_ID                NUMBER          NOT NULL,
    TABLE_NAME            VARCHAR2(128)   NOT NULL,
    STATUS                VARCHAR2(12)    NOT NULL,  -- STAGED ARCHIVING COMPLETED RESTORING RESTORED FAILED
    LAST_ACTION           VARCHAR2(10),              -- STAGE ARCHIVE ROLLBACK
    BATCH_SIZE            NUMBER,
    ROWS_STAGED           NUMBER          DEFAULT 0 NOT NULL,
    BATCHES_TOTAL         NUMBER          DEFAULT 0 NOT NULL,
    BATCHES_DONE          NUMBER          DEFAULT 0 NOT NULL,   -- archived (ever)
    BATCHES_RESTORED      NUMBER          DEFAULT 0 NOT NULL,
    ROWS_ARCHIVED         NUMBER          DEFAULT 0 NOT NULL,
    ROWS_DELETED          NUMBER          DEFAULT 0 NOT NULL,
    ROWS_RESTORED         NUMBER          DEFAULT 0 NOT NULL,
    STAGED_AT             TIMESTAMP,
    ARCHIVE_STARTED_AT    TIMESTAMP,
    COMPLETED_AT          TIMESTAMP,
    RESTORED_AT           TIMESTAMP,
    VERIFIED_AT           TIMESTAMP,
    VERIFY_RESIDUAL_ROWS  NUMBER,
    VERIFY_ARC_ROWS       NUMBER,
    VERIFY_RESULT         VARCHAR2(10),               -- OK, ATTENTION
    STATS_GATHERED_AT     TIMESTAMP,
    LAST_EXEC_ID          NUMBER,
    LAST_ERROR            VARCHAR2(4000),
    CONSTRAINT ARC_STATE_PK        PRIMARY KEY (RUN_ID, TABLE_NAME) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_STATE_RUN_FK    FOREIGN KEY (RUN_ID) REFERENCES ARCHIVE_RUN (RUN_ID),
    CONSTRAINT ARC_STATE_STATUS_CK CHECK (STATUS IN ('STAGED','ARCHIVING','COMPLETED','RESTORING','RESTORED','FAILED'))
)
TABLESPACE &&DATA_TS;

--------------------------------------------------------------------------------
-- ARCHIVE_BATCH: one row per batch. A batch is archived AND deleted in one
-- transaction, so its status is always either fully PENDING or fully DONE.
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_BATCH
(
    RUN_ID           NUMBER          NOT NULL,
    TABLE_NAME       VARCHAR2(128)   NOT NULL,
    BATCH_NO         NUMBER          NOT NULL,
    ROWS_STAGED      NUMBER          NOT NULL,
    STATUS           VARCHAR2(10)    DEFAULT 'PENDING' NOT NULL,  -- PENDING DONE RESTORED
    ROWS_ARCHIVED    NUMBER,
    ROWS_DELETED     NUMBER,
    ROWS_RESTORED    NUMBER,
    ARCHIVED_AT      TIMESTAMP,
    ARCHIVE_SECONDS  NUMBER,
    RESTORED_AT      TIMESTAMP,
    RESTORE_SECONDS  NUMBER,
    EXEC_ID          NUMBER,
    CONSTRAINT ARC_BATCH_PK        PRIMARY KEY (RUN_ID, TABLE_NAME, BATCH_NO) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_BATCH_STATUS_CK CHECK (STATUS IN ('PENDING','DONE','RESTORED'))
)
TABLESPACE &&DATA_TS;

CREATE INDEX ARC_BATCH_EXEC_IX ON ARCHIVE_BATCH (EXEC_ID) TABLESPACE &&INDEX_TS;

--------------------------------------------------------------------------------
-- PURGE_RID_STAGE: ROWID + row key of every row selected for a run, with its
-- batch number. One interval partition per run, dropped when the run is closed.
-- Written once by direct-path insert (hence COMPRESS BASIC), then only read.
--------------------------------------------------------------------------------
CREATE TABLE PURGE_RID_STAGE
(
    RUN_ID      NUMBER          NOT NULL,
    TABLE_NAME  VARCHAR2(128)   NOT NULL,
    BATCH_NO    NUMBER          NOT NULL,
    ROW_ID      ROWID           NOT NULL,
    KEY_VAL     VARCHAR2(4000)  NOT NULL
)
TABLESPACE &&DATA_TS
COMPRESS BASIC
PARTITION BY RANGE (RUN_ID) INTERVAL (1)
(
    PARTITION P_START VALUES LESS THAN (1)
);

CREATE INDEX PURGE_RID_STAGE_IX ON PURGE_RID_STAGE (TABLE_NAME, BATCH_NO)
    LOCAL COMPRESS 1 TABLESPACE &&INDEX_TS;

--------------------------------------------------------------------------------
-- ARCHIVE_LOG: append-only log, written by an autonomous transaction.
--------------------------------------------------------------------------------
CREATE TABLE ARCHIVE_LOG
(
    LOG_ID      NUMBER          NOT NULL,
    LOG_TIME    TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    RUN_ID      NUMBER,
    EXEC_ID     NUMBER,
    TABLE_NAME  VARCHAR2(128),
    BATCH_NO    NUMBER,
    LOG_LEVEL   VARCHAR2(5)     NOT NULL,     -- INFO WARN ERROR
    MESSAGE     VARCHAR2(4000),
    CONSTRAINT ARC_LOG_PK       PRIMARY KEY (LOG_ID) USING INDEX TABLESPACE &&INDEX_TS,
    CONSTRAINT ARC_LOG_LEVEL_CK CHECK (LOG_LEVEL IN ('INFO','WARN','ERROR'))
)
TABLESPACE &&DATA_TS;

CREATE INDEX ARC_LOG_RUN_IX  ON ARCHIVE_LOG (RUN_ID, LOG_TIME) TABLESPACE &&INDEX_TS;
CREATE INDEX ARC_LOG_EXEC_IX ON ARCHIVE_LOG (EXEC_ID)         TABLESPACE &&INDEX_TS;
