# Changelog

## 1.0.0 - 2026-11-01

First public release (`archive_manager.sh` 1.0.0, `PKG_ARCHIVE_MANAGER` 1.0.0).

- Modes `check`, `stage`, `archive`, `rollback`, `verify`, `stats`, `close`,
  plus `status` and `stop` in the utility.
- Batch-atomic archive (insert = delete or the batch is rolled back), tag
  columns `ARC_RUN_ID` / `ARC_BATCH_NO`, rollback by tag.
- Time limit (`-T`), stop flag, `DBMS_LOCK` per table and per execution,
  monitoring views and `ARCHIVE_LOG`.
- `DEPENDS_ON` per table: `NULL` (all lower-order tables), `NONE`, or a list.
- `check` accepts disabled tables, gives a short summary per table, and shows
  every finding with `-v`.
- Dry run (`-n`) validates the run id and warns about disabled or unknown
  tables.
- User/password login (prompt, env file or `ARCH_DB_PASSWORD`) or Oracle
  wallet. The password is never logged.
- `upgrade_pkg.sql` replaces the package only.
- Synthetic end-to-end test kit (`test/`).
- Examples for registering your own tables (`examples/`).
