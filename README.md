# archive_manager

Batch archive-and-purge for Oracle tables. You give it a list of parent keys
(a *worklist*). It moves every matching row from your source tables into
archive tables, one batch per transaction. Each run can be resumed, stopped,
time-boxed and rolled back.

All logic, state and logging live in one PL/SQL package (`PKG_ARCHIVE_MANAGER`)
and a few control tables. A small bash utility (`bin/archive_manager.sh`) wraps
it for operators and schedulers.

## Features

- **Batch-atomic moves.** Each batch copies the rows to the archive, deletes
  the same rows and checks that both counts match before it commits. A deleted
  row is always in the archive. Both statements re-check the row key, so a
  reused ROWID never moves the wrong row.
- **Resumable runs.** One run is one purge cycle. Rows are staged once, then
  archived across as many maintenance windows as needed.
- **Time limit and stop.** `-T <minutes>` ends cleanly before the window
  closes (status PAUSED). `-m stop` stops after the current batch.
- **Rollback.** Archived rows carry invisible tag columns (`ARC_RUN_ID`,
  `ARC_BATCH_NO`), so any run can be moved back last batch first, even weeks
  later.
- **Dependency order.** Children are archived before parents and parents are
  restored before children. With `DEPENDS_ON`, independent tables can be
  archived in any window.
- **Preflight check.** `-m check` compares source and archive columns and
  looks for LONG columns, ON DELETE CASCADE children, triggers, missing
  indexes and type mismatches, without changing anything.
- **Concurrency-safe.** `DBMS_LOCK` user locks per table work across RAC. Two
  sessions never work on the same table.
- **Observable.** Monitoring views, `V$SESSION_LONGOPS` progress, an
  autonomous `ARCHIVE_LOG`, per-execution log files and an optional alert
  hook.
- **Safe identifiers.** Every name in the config goes through `DBMS_ASSERT`
  and is quoted.

## Requirements

- Oracle Database 12.2 or later (tested on 19c), Enterprise Edition with the
  Partitioning option (the staging table is interval-partitioned per run).
- A direct `EXECUTE` grant on `SYS.DBMS_LOCK` for the engine owner.
- The engine is installed in the schema that owns the tables to archive.
- For the utility: bash 4.2+ and SQL*Plus (Instant Client is fine) on Linux.

## Layout

```
bin/archive_manager.sh                command-line utility
conf/archive_manager.env.example      settings -> copy to conf/archive_manager.env, chmod 600
sql/00_prereq_dba.sql                 run once as a DBA: DBMS_LOCK grant + sizing checks
sql/install.sql                       run as the engine owner: installs 01, 03, 04, 05
sql/01_control_objects.sql            control tables and sequences
sql/03_pkg_archive_manager.pks/.pkb   the package
sql/05_views.sql                      V_ARCHIVE_RUN, V_ARCHIVE_PROGRESS, V_ARCHIVE_EXEC
sql/06_prepare_arc_tables.sql         tag columns + index on the archive tables of enabled rows
sql/07_dba_monitoring.sql             queries for the DBA during a window
sql/upgrade_pkg.sql                   replace the package only (keeps all data)
sql/99_uninstall.sql                  remove the engine (never business or archive data)
examples/                             worklist, archive tables and config for a sample schema
test/                                 synthetic end-to-end test kit (non-production only)
```

## Quick start

1. **Prerequisites (DBA, once).** Run this as a DBA. It asks for the engine
   owner and tablespaces.
   ```
   cd sql && sqlplus / as sysdba @00_prereq_dba.sql
   ```
2. **Install (engine owner).** Edit `DATA_TS`/`INDEX_TS` at the top of
   `install.sql` if `USERS` is not right for you.
   ```
   cd sql && sqlplus <owner>@<service> @install.sql
   ```
3. **Configure the utility.**
   ```
   cp conf/archive_manager.env.example conf/archive_manager.env
   chmod 600 conf/archive_manager.env      # then set DB_USER / DB_TNS (or DB_CONNECT)
   chmod +x bin/archive_manager.sh
   ```
4. **Describe your tables.** Follow `examples/` (see
   [examples/README.md](examples/README.md)):
   - build the worklist,
   - create the archive tables,
   - insert one `ARCHIVE_TABLE_CONFIG` row per table.
5. **Check, enable, prepare.**
   ```
   bin/archive_manager.sh -m check -t ORDER_ITEMS     # repeat per table until clean
   -- SQL: UPDATE archive_table_config SET enabled_flag = 'Y' WHERE ...; COMMIT;
   sqlplus <owner>@<service> @sql/06_prepare_arc_tables.sql
   ```
6. **Run a cycle.**
   ```
   bin/archive_manager.sh -m stage                    # creates run N, read-only on source tables
   bin/archive_manager.sh -m archive -r N -T 200 -y   # one window; repeat until COMPLETED
   bin/archive_manager.sh -m verify -r N
   bin/archive_manager.sh -m stats  -r N
   bin/archive_manager.sh -m close  -r N
   ```

Try it on a scratch schema first with the test kit (`test/run_test.sh`, see below).

## Modes

| Mode       | What it does                                                             | Needs `-r` |
|------------|--------------------------------------------------------------------------|------------|
| `check`    | validate configuration and table structures; no changes                  | no         |
| `stage`    | select the rows of a run into the staging table; read-only on sources    | no (new run) |
| `archive`  | copy + delete staged rows batch by batch                                 | yes        |
| `rollback` | move a run's archived rows back, last batch first                        | yes        |
| `verify`   | count leftovers in the source and rows in the archive                    | yes        |
| `stats`    | gather optimizer statistics on completed tables                          | yes        |
| `status`   | list runs, or one run's progress, executions and warnings                | optional   |
| `stop`     | ask running executions of a run to stop after the current batch          | yes        |
| `close`    | close a run and drop its staging partition (`-f` for unfinished tables)  | yes        |

Options: `-t` table list, `-b` batch size (stage only), `-T` time limit in
minutes, `-n` dry run (stage/archive/rollback), `-y` no confirmation prompt,
`-v` verbose check, `-V` versions, `-u`/`-d`/`-c` connection overrides. Run
`bin/archive_manager.sh -h` for the full help.

## Exit codes

| Code | Meaning                                  |
|------|------------------------------------------|
| 0    | completed                                |
| 1    | failed (see the log and `ARCHIVE_LOG`)   |
| 2    | usage error / not confirmed              |
| 3    | paused by the time limit (resume later)  |
| 4    | stopped on request                       |
| 5    | SQL*Plus, connection or engine refusal   |

## Connection

In priority order:

1. `-c STRING`, used as is.
2. `DB_USER` / `-u`, plus `DB_TNS` / `-d`. The password comes from
   `DB_PASSWORD`, then `ARCH_DB_PASSWORD`, then a silent prompt.
3. `DB_CONNECT="/@alias"` for an Oracle wallet.

The password is never logged (`user/***@tns`). It is sent to SQL*Plus on
stdin, so it never appears in `ps`.

## Monitoring

```sql
SELECT * FROM v_archive_progress WHERE run_id = :run ORDER BY table_order;
SELECT * FROM v_archive_exec     WHERE status = 'RUNNING';
SELECT * FROM archive_log        WHERE run_id = :run AND log_level <> 'INFO' ORDER BY log_id DESC;
```

`sql/07_dba_monitoring.sql` adds session, undo, redo, TEMP, FRA and standby
queries for the DBA. `ALERT_CMD` in the env file runs your script when an
execution ends FAILED or STOPPED.

## Test kit

Run it on a **non-production** schema only.

1. Install the engine there.
2. Point `conf/archive_manager.env` at that schema.
3. Run `test/run_test.sh`.

The kit builds four synthetic tables with enforced foreign keys and then
exercises:

- check and stage,
- the dependency gate,
- stop and resume,
- time-limit pause and resume,
- content-exact archiving (counts and checksums),
- verify and stats,
- content-exact rollback and close.

It ends with `ALL TESTS PASSED`.

## Safety notes

- Install and test on a non-production database first, with realistic
  volumes, to size the batches.
- Archiving deletes from your source tables. Have a tested backup and check
  undo, redo/FRA and standby capacity before the first window (see
  `00_prereq_dba.sql`).
- Staging refuses a table whose archive already holds rows of the worklist.
  This prevents double archiving.
- `99_uninstall.sql` removes only the engine objects. The tag columns and
  indexes on archive tables stay.

## License

[MIT](LICENSE)
