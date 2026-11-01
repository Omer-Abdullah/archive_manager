--------------------------------------------------------------------------------
-- examples/02_create_arc_tables.sql                archive_manager v1.0.0
--
-- EXAMPLE ONLY. Every source table needs an archive table in the same schema
-- with at least the same columns (same types, same or larger sizes). The
-- simplest way is an empty copy; add partitioning, compression or a different
-- tablespace to suit your storage. Archive tables need no PK or FK.
--
-- "archive_manager.sh -m check -t <table>" compares source and archive
-- column by column and reports anything that would not fit.
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

CREATE TABLE ORDER_ITEMS_ARC    AS SELECT * FROM ORDER_ITEMS    WHERE 1 = 0;
CREATE TABLE ORDER_PAYMENTS_ARC AS SELECT * FROM ORDER_PAYMENTS WHERE 1 = 0;
CREATE TABLE ORDER_EVENTS_ARC   AS SELECT * FROM ORDER_EVENTS   WHERE 1 = 0;
CREATE TABLE ORDERS_ARC         AS SELECT * FROM ORDERS         WHERE 1 = 0;

-- Example with compression and monthly interval partitions (Oracle 12.2+):
-- CREATE TABLE ORDER_EVENTS_ARC
--     COMPRESS BASIC
--     PARTITION BY RANGE (EVENT_TIME) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
--     (PARTITION P0 VALUES LESS THAN (DATE '2020-01-01'))
--     AS SELECT * FROM ORDER_EVENTS WHERE 1 = 0;
