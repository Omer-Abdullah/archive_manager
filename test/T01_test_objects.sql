--------------------------------------------------------------------------------
-- T01_test_objects.sql                             archive_manager v1.0.0
--
-- Synthetic order/basket tables for testing the engine in a NON-PRODUCTION
-- schema (e.g. ARCH_TEST) where the engine is installed too.
--   TST_ORDER        parent           (VARCHAR2 id, NCLOB column)
--   TST_ORDER_ITEM   child of order   (NCLOB column)
--   TST_BASKET       child of order   (hash partitioned)
--   TST_BASKET_ITEM  child of basket
-- Foreign keys are ENFORCED, so a wrong order fails loudly.
-- Worklists use NUMBER ids against VARCHAR2 columns (implicit conversion),
-- a common real-world mismatch the engine must handle.
-- Re-runnable: drops and recreates the TST_ objects.
--------------------------------------------------------------------------------
SET VERIFY OFF FEEDBACK ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE ORDERS                  = 50000
DEFINE ITEMS_PER_ORDER         = 10
DEFINE BASKET_ITEMS_PER_BASKET = 4

BEGIN
    FOR t IN (SELECT table_name FROM user_tables
               WHERE table_name IN ('TST_ORDER_ITEM', 'TST_BASKET_ITEM', 'TST_BASKET', 'TST_ORDER',
                                    'TST_ORDER_ITEM_ARC', 'TST_BASKET_ITEM_ARC', 'TST_BASKET_ARC', 'TST_ORDER_ARC',
                                    'TST_PURGE_ORDER_IDS', 'TST_PURGE_BASKETS', 'TST_BASELINE'))
    LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

CREATE TABLE TST_ORDER
(
    ORDERID          VARCHAR2(16)  NOT NULL,
    OSTATE           VARCHAR2(16)  NOT NULL,
    LASTUPDATEDDATE  DATE          NOT NULL,
    PRICE            NUMBER(14,4),
    NOTES            NCLOB,
    CONSTRAINT TST_ORDER_PK PRIMARY KEY (ORDERID)
);

CREATE TABLE TST_ORDER_ITEM
(
    TOPORDERID  VARCHAR2(16)  NOT NULL,
    ITEMID      VARCHAR2(16)  NOT NULL,
    POS         NUMBER(5)     NOT NULL,
    STATE       VARCHAR2(16),
    DATA        NCLOB,
    CONSTRAINT TST_ORDER_ITEM_PK PRIMARY KEY (ITEMID),
    CONSTRAINT TST_ORDER_ITEM_FK FOREIGN KEY (TOPORDERID) REFERENCES TST_ORDER (ORDERID)
);
CREATE INDEX TST_ORDER_ITEM_IX ON TST_ORDER_ITEM (TOPORDERID);

CREATE TABLE TST_BASKET
(
    BASKETID   VARCHAR2(16)  NOT NULL,
    ORDERID    VARCHAR2(16)  NOT NULL,
    STATE      VARCHAR2(16),
    CREATED  DATE,
    CONSTRAINT TST_BASKET_PK PRIMARY KEY (BASKETID),
    CONSTRAINT TST_BASKET_FK FOREIGN KEY (ORDERID) REFERENCES TST_ORDER (ORDERID)
)
PARTITION BY HASH (BASKETID) PARTITIONS 8;
CREATE INDEX TST_BASKET_IX ON TST_BASKET (ORDERID);

CREATE TABLE TST_BASKET_ITEM
(
    BASKETITEMID     VARCHAR2(16)  NOT NULL,
    BASKETID         VARCHAR2(16)  NOT NULL,
    AMOUNT           NUMBER(18,9),
    LASTUPDATEDDATE  TIMESTAMP(6),
    CONSTRAINT TST_BASKET_ITEM_PK PRIMARY KEY (BASKETITEMID),
    CONSTRAINT TST_BASKET_ITEM_FK FOREIGN KEY (BASKETID) REFERENCES TST_BASKET (BASKETID)
);
CREATE INDEX TST_BASKET_ITEM_IX ON TST_BASKET_ITEM (BASKETID);

-- Data: 30% of orders closed (CLOSED/CANCELLED/ABORTED); two thirds of those are old.
INSERT /*+ APPEND */ INTO TST_ORDER
SELECT TO_CHAR(LEVEL),
       CASE MOD(LEVEL, 10) WHEN 0 THEN 'CLOSED' WHEN 1 THEN 'CANCELLED' WHEN 2 THEN 'ABORTED' ELSE 'OPEN' END,
       CASE WHEN MOD(LEVEL, 3) = 0 THEN DATE '2025-06-01' ELSE DATE '2023-06-01' + MOD(LEVEL, 400) END,
       MOD(LEVEL * 7919, 100000) / 100,
       TO_NCLOB('Order ' || LEVEL || ' notes')
  FROM dual
CONNECT BY LEVEL <= &&ORDERS;
COMMIT;

INSERT /*+ APPEND */ INTO TST_ORDER_ITEM
SELECT o.orderid, o.orderid || '-' || g.n, g.n, 'DONE', TO_NCLOB('Item ' || g.n || ' of ' || o.orderid)
  FROM TST_ORDER o
 CROSS JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= &&ITEMS_PER_ORDER) g;
COMMIT;

INSERT /*+ APPEND */ INTO TST_BASKET
SELECT TO_CHAR(TO_NUMBER(orderid) + 5000000), orderid, 'CLOSED', lastupdateddate
  FROM TST_ORDER;
COMMIT;

INSERT /*+ APPEND */ INTO TST_BASKET_ITEM
SELECT b.basketid || '-' || g.n, b.basketid, g.n * 1.5, CAST(b.created AS TIMESTAMP(6))
  FROM TST_BASKET b
 CROSS JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= &&BASKET_ITEMS_PER_BASKET) g;
COMMIT;

-- Archive tables: same structure, no rows.
CREATE TABLE TST_ORDER_ARC       AS SELECT * FROM TST_ORDER       WHERE 1 = 0;
CREATE TABLE TST_ORDER_ITEM_ARC  AS SELECT * FROM TST_ORDER_ITEM  WHERE 1 = 0;
CREATE TABLE TST_BASKET_ARC      AS SELECT * FROM TST_BASKET      WHERE 1 = 0;
CREATE TABLE TST_BASKET_ITEM_ARC AS SELECT * FROM TST_BASKET_ITEM WHERE 1 = 0;

-- Worklists: NUMBER ids of the parents to archive.
CREATE TABLE TST_PURGE_ORDER_IDS (ORDER_ID NUMBER NOT NULL);
INSERT INTO TST_PURGE_ORDER_IDS
SELECT TO_NUMBER(orderid) FROM TST_ORDER
 WHERE ostate IN ('CLOSED', 'CANCELLED', 'ABORTED') AND lastupdateddate < DATE '2025-01-01';
CREATE INDEX TST_PURGE_ORDER_IDS_IX ON TST_PURGE_ORDER_IDS (ORDER_ID);

CREATE TABLE TST_PURGE_BASKETS (BASKETID NUMBER NOT NULL);
INSERT INTO TST_PURGE_BASKETS
SELECT TO_NUMBER(b.basketid) FROM TST_BASKET b JOIN TST_PURGE_ORDER_IDS p ON p.order_id = TO_NUMBER(b.orderid);
CREATE INDEX TST_PURGE_BASKETS_IX ON TST_PURGE_BASKETS (BASKETID);
COMMIT;

-- Signatures: row counts and content checksums, used by T03_assert.sql.
CREATE OR REPLACE VIEW TST_SIGNATURES AS
SELECT 'TST_ORDER' AS table_name, COUNT(*) AS total_rows, COUNT(p.order_id) AS matched_rows,
       SUM(sig) AS checksum, SUM(CASE WHEN p.order_id IS NOT NULL THEN sig END) AS matched_checksum
  FROM (SELECT o.orderid, ORA_HASH(o.orderid || '|' || o.ostate || '|' || TO_CHAR(o.lastupdateddate, 'YYYYMMDD')
                                   || '|' || TO_CHAR(o.price) || '|' || TO_CHAR(DBMS_LOB.SUBSTR(o.notes, 200, 1))) AS sig
          FROM TST_ORDER o) x
  LEFT JOIN TST_PURGE_ORDER_IDS p ON p.order_id = TO_NUMBER(x.orderid)
UNION ALL
SELECT 'TST_ORDER_ITEM', COUNT(*), COUNT(p.order_id), SUM(sig), SUM(CASE WHEN p.order_id IS NOT NULL THEN sig END)
  FROM (SELECT i.toporderid, ORA_HASH(i.toporderid || '|' || i.itemid || '|' || i.pos || '|' || i.state
                                     || '|' || TO_CHAR(DBMS_LOB.SUBSTR(i.data, 200, 1))) AS sig
          FROM TST_ORDER_ITEM i) x
  LEFT JOIN TST_PURGE_ORDER_IDS p ON p.order_id = TO_NUMBER(x.toporderid)
UNION ALL
SELECT 'TST_BASKET', COUNT(*), COUNT(p.basketid), SUM(sig), SUM(CASE WHEN p.basketid IS NOT NULL THEN sig END)
  FROM (SELECT b.basketid, ORA_HASH(b.basketid || '|' || b.orderid || '|' || b.state
                                    || '|' || TO_CHAR(b.created, 'YYYYMMDD')) AS sig
          FROM TST_BASKET b) x
  LEFT JOIN TST_PURGE_BASKETS p ON p.basketid = TO_NUMBER(x.basketid)
UNION ALL
SELECT 'TST_BASKET_ITEM', COUNT(*), COUNT(p.basketid), SUM(sig), SUM(CASE WHEN p.basketid IS NOT NULL THEN sig END)
  FROM (SELECT bi.basketid, ORA_HASH(bi.basketitemid || '|' || bi.basketid || '|' || TO_CHAR(bi.amount)
                                     || '|' || TO_CHAR(bi.lastupdateddate, 'YYYYMMDDHH24MISSFF6')) AS sig
          FROM TST_BASKET_ITEM bi) x
  LEFT JOIN TST_PURGE_BASKETS p ON p.basketid = TO_NUMBER(x.basketid);

-- Snapshot taken before any archiving.
CREATE TABLE TST_BASELINE AS SELECT * FROM TST_SIGNATURES;

BEGIN
    FOR t IN (SELECT table_name FROM user_tables WHERE table_name LIKE 'TST\_%' ESCAPE '\') LOOP
        DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => t.table_name);
    END LOOP;
END;
/

SELECT * FROM TST_BASELINE ORDER BY table_name;

-- Same checksums over the archive tables (only rows tagged with a run).
-- FORCE: ARC_RUN_ID only exists after PREPARE_ARC_TABLE (T02).
CREATE OR REPLACE FORCE VIEW TST_ARC_SIGNATURES AS
SELECT 'TST_ORDER' AS table_name, arc_run_id, COUNT(*) AS arc_rows,
       SUM(ORA_HASH(orderid || '|' || ostate || '|' || TO_CHAR(lastupdateddate, 'YYYYMMDD')
                    || '|' || TO_CHAR(price) || '|' || TO_CHAR(DBMS_LOB.SUBSTR(notes, 200, 1)))) AS checksum
  FROM TST_ORDER_ARC WHERE arc_run_id IS NOT NULL GROUP BY arc_run_id
UNION ALL
SELECT 'TST_ORDER_ITEM', arc_run_id, COUNT(*),
       SUM(ORA_HASH(toporderid || '|' || itemid || '|' || pos || '|' || state
                    || '|' || TO_CHAR(DBMS_LOB.SUBSTR(data, 200, 1))))
  FROM TST_ORDER_ITEM_ARC WHERE arc_run_id IS NOT NULL GROUP BY arc_run_id
UNION ALL
SELECT 'TST_BASKET', arc_run_id, COUNT(*),
       SUM(ORA_HASH(basketid || '|' || orderid || '|' || state || '|' || TO_CHAR(created, 'YYYYMMDD')))
  FROM TST_BASKET_ARC WHERE arc_run_id IS NOT NULL GROUP BY arc_run_id
UNION ALL
SELECT 'TST_BASKET_ITEM', arc_run_id, COUNT(*),
       SUM(ORA_HASH(basketitemid || '|' || basketid || '|' || TO_CHAR(amount)
                    || '|' || TO_CHAR(lastupdateddate, 'YYYYMMDDHH24MISSFF6')))
  FROM TST_BASKET_ITEM_ARC WHERE arc_run_id IS NOT NULL GROUP BY arc_run_id;
