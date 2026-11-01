# Examples

These scripts show how to put your own tables under archive_manager. They use
a sample schema: `ORDERS`, its children `ORDER_ITEMS` and `ORDER_PAYMENTS`,
and an independent `ORDER_EVENTS` table. Replace the names, keys and business
rule with yours.

| Step | File                       | What it does                                                    |
|------|----------------------------|-----------------------------------------------------------------|
| 1    | `01_build_worklist.sql`    | builds the worklist: the parent keys to archive in this cycle   |
| 2    | `02_create_arc_tables.sql` | creates the archive tables (empty copies)                       |
| 3    | `03_register_tables.sql`   | one `ARCHIVE_TABLE_CONFIG` row per table, all disabled          |

Then, for each table:

```
bin/archive_manager.sh -m check -t ORDER_ITEMS        # fix anything reported
UPDATE archive_table_config SET enabled_flag = 'Y' WHERE table_name = 'ORDER_ITEMS';
COMMIT;
@sql/06_prepare_arc_tables.sql                         # tag columns + index on the archive
```

## Rules of thumb

- **Order.** Give children a lower `TABLE_ORDER` than their parents. A table
  with an `ON DELETE CASCADE` child is refused by `check`. Archive that child
  first.
- **Several worklists.** Each table can use its own worklist, for example
  `ARC_WORKLIST_BASKETS` derived from the order worklist. Build the derived
  worklists in step 1 too.
- **Indexes.** The source `JOIN_COLUMN` should be indexed, and so should the
  worklist column.
- **Type mismatch.** If a NUMBER worklist meets a VARCHAR2 column, `check`
  warns about implicit conversion. Set `JOIN_CAST = 'TO_CHAR'` to keep the
  column's index usable.
- **Batch size.** Aim for 2-5 minutes per batch. After the first window, read
  `AVG_BATCH_SEC` in `V_ARCHIVE_PROGRESS` and re-stage with `-b` if needed.
- **New cycle.** Close the previous run before building a new worklist.
