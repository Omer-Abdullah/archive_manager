#!/usr/bin/env bash
#
# archive_manager.sh - command-line utility for archive_manager, a batch
# archive-and-purge engine for Oracle tables.
# Calls PKG_ARCHIVE_MANAGER through SQL*Plus. All archiving logic, state and logging
# live in the database; this script validates options, asks for confirmation,
# runs one execution, writes a log file and returns a meaningful exit code.
#
# Tested with bash 4.2 (RHEL 7.9). See usage() or README.md.
#
set -o errexit -o nounset -o pipefail

readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ENV_FILE="${ARCH_ENV_FILE:-${SCRIPT_DIR}/../conf/archive_manager.env}"

# Exit codes
readonly RC_OK=0 RC_FAILED=1 RC_USAGE=2 RC_PAUSED=3 RC_STOPPED=4 RC_SQLPLUS=5

# Defaults, overridden by the env file
DB_USER=""          # user/password login (DB_PASSWORD, ARCH_DB_PASSWORD or a prompt)
DB_PASSWORD=""
DB_TNS=""           # TNS alias or //host:port/service; empty = local instance (ORACLE_SID)
DB_CONNECT=""       # wallet login "/@alias"; used only when DB_USER is empty
PKG_OWNER=""         # schema owning PKG_ARCHIVE_MANAGER; empty = DB_USER
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_RETENTION_DAYS=90
ALERT_CMD=""

usage() {
    cat <<'USAGE'
Usage: archive_manager.sh -m MODE [options]

Modes
  check     validate configuration and table structures (no changes)
  stage     select the rows of a run; read-only on business tables
            (without -r a new run is created)
  archive   copy + delete staged rows batch by batch           (-r required)
  rollback  move a run's archived rows back, last batch first  (-r required)
  verify    count leftovers in source and rows in archive      (-r required)
  stats     gather optimizer stats on completed tables         (-r required)
  status    show runs (no -r) or one run's progress (-r)
  stop      ask running executions of a run to stop after the current batch
  close     close a run and drop its staging data              (-r required)

Options
  -r, --run ID           run id
  -t, --tables LIST      comma list of tables (default: all enabled, in order)
  -b, --batch-size N     stage only: rows per batch (1,000 - 2,000,000)
  -T, --max-minutes N    stop cleanly before N minutes have passed (status PAUSED)
  -u, --user USER        database user, overrides DB_USER (password: DB_PASSWORD,
                         ARCH_DB_PASSWORD or a prompt)
  -d, --db TNS           TNS alias or //host:port/service, overrides DB_TNS
  -c, --connect STRING   full connect string, overrides everything (e.g. /@alias)
  -f, --force            close: close even with unfinished tables
  -n, --dry-run          show the plan for stage/archive/rollback, change nothing
  -y, --yes              do not ask for confirmation (required when not on a terminal)
  -h, --help             this help
  -v, --verbose          check: show every warning and note per table
  -V, --version          versions of this script and of the database package

Exit codes
  0 completed   1 failed   2 usage error   3 paused (time limit)   4 stopped   5 SQL*Plus/connection error

Examples
  archive_manager.sh -m check
  archive_manager.sh -m check -u ARCH_OWNER -d MYDB   # prompts for the password
  archive_manager.sh -m stage                         # new run, all enabled tables
  archive_manager.sh -m archive -r 7 -T 200 -y        # one maintenance window
  archive_manager.sh -m status -r 7
  archive_manager.sh -m stop -r 7
  archive_manager.sh -m rollback -r 7 -t ORDERS
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit "${RC_USAGE}"
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE="" RUN_ID="" TABLES="" BATCH_SIZE="" MAX_MINUTES="" CONNECT_OVERRIDE="" USER_OVERRIDE="" TNS_OVERRIDE=""
FORCE="N" DRY_RUN=0 ASSUME_YES=0 SHOW_VERSION=0 VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)        [[ $# -ge 2 ]] || die "$1 needs a value"; MODE="$2"; shift 2 ;;
        -r|--run)         [[ $# -ge 2 ]] || die "$1 needs a value"; RUN_ID="$2"; shift 2 ;;
        -t|--tables)      [[ $# -ge 2 ]] || die "$1 needs a value"; TABLES="$2"; shift 2 ;;
        -b|--batch-size)  [[ $# -ge 2 ]] || die "$1 needs a value"; BATCH_SIZE="$2"; shift 2 ;;
        -T|--max-minutes) [[ $# -ge 2 ]] || die "$1 needs a value"; MAX_MINUTES="$2"; shift 2 ;;
        -u|--user)        [[ $# -ge 2 ]] || die "$1 needs a value"; USER_OVERRIDE="$2"; shift 2 ;;
        -d|--db)          [[ $# -ge 2 ]] || die "$1 needs a value"; TNS_OVERRIDE="$2"; shift 2 ;;
        -c|--connect)     [[ $# -ge 2 ]] || die "$1 needs a value"; CONNECT_OVERRIDE="$2"; shift 2 ;;
        -f|--force)       FORCE="Y"; shift ;;
        -n|--dry-run)     DRY_RUN=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -v|--verbose)     VERBOSE=1; shift ;;
        -V|--version)     SHOW_VERSION=1; shift ;;
        -h|--help)        usage; exit "${RC_OK}" ;;
        *)                usage >&2; die "unknown option: $1" ;;
    esac
done

ENV_PASSWORD="${ARCH_DB_PASSWORD:-}"   # optional: exported by the caller
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    ENV_PERM="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || echo 600)"
    if [[ -n "${DB_PASSWORD}" && "${ENV_PERM: -2}" != "00" ]]; then
        echo "WARNING: ${ENV_FILE} holds a password and is readable by others; run: chmod 600 ${ENV_FILE}" >&2
    fi
fi
[[ -n "${USER_OVERRIDE}" ]] && DB_USER="${USER_OVERRIDE}"
[[ -n "${TNS_OVERRIDE}" ]]  && DB_TNS="${TNS_OVERRIDE}"

[[ -n "${PKG_OWNER}" ]] || PKG_OWNER="${DB_USER}"
[[ -n "${PKG_OWNER}" ]] || die "PKG_OWNER and DB_USER are both empty: set them in ${ENV_FILE} (copy it from conf/archive_manager.env.example), or use -u USER"
[[ "${PKG_OWNER}" =~ ^[A-Za-z][A-Za-z0-9_\$#]{0,127}$ ]] || die "PKG_OWNER '${PKG_OWNER}' is not a valid schema name"
PKG_OWNER="$(echo "${PKG_OWNER}" | tr '[:lower:]' '[:upper:]')"

if [[ "${SHOW_VERSION}" -eq 0 ]]; then
    MODE="$(echo "${MODE}" | tr '[:upper:]' '[:lower:]')"
    case "${MODE}" in
        check|stage|archive|rollback|verify|stats|status|stop|close) ;;
        "") usage >&2; die "-m/--mode is required" ;;
        *)  die "unknown mode '${MODE}'" ;;
    esac
fi

if [[ -n "${RUN_ID}" ]]; then
    [[ "${RUN_ID}" =~ ^[1-9][0-9]{0,17}$ ]] || die "-r must be a positive integer"
fi
case "${MODE}" in
    archive|rollback|verify|stats|stop|close)
        [[ -n "${RUN_ID}" ]] || die "mode ${MODE} needs -r RUN_ID" ;;
esac

if [[ -n "${TABLES}" ]]; then
    TABLES="$(echo "${TABLES}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    [[ "${TABLES}" =~ ^[A-Z0-9_\$#]+(,[A-Z0-9_\$#]+)*$ ]] || die "-t must be a comma list of table names"
fi

if [[ -n "${BATCH_SIZE}" ]]; then
    [[ "${MODE}" == "stage" ]] || die "-b applies to mode stage only (batches are fixed at staging)"
    if ! [[ "${BATCH_SIZE}" =~ ^[0-9]{4,7}$ ]] || (( BATCH_SIZE < 1000 || BATCH_SIZE > 2000000 )); then
        die "-b must be between 1000 and 2000000"
    fi
fi

if [[ -n "${MAX_MINUTES}" ]]; then
    if ! [[ "${MAX_MINUTES}" =~ ^[0-9]{1,4}$ ]] || (( MAX_MINUTES < 1 || MAX_MINUTES > 1440 )); then
        die "-T must be between 1 and 1440"
    fi
fi

[[ "${FORCE}" == "Y" && "${MODE}" != "close" ]] && die "-f applies to mode close only"

# SQL literals (values are validated above, so they are safe to embed)
sql_or_null() { if [[ -n "$1" ]]; then echo "$1"; else echo "NULL"; fi; }
RUN_SQL="$(sql_or_null "${RUN_ID}")"
BATCH_SQL="$(sql_or_null "${BATCH_SIZE}")"
MINUTES_SQL="$(sql_or_null "${MAX_MINUTES}")"
if [[ -n "${TABLES}" ]]; then TABLES_SQL="'${TABLES}'"; else TABLES_SQL="NULL"; fi
MODE_UC="$(echo "${MODE}" | tr '[:lower:]' '[:upper:]')"

# ---------------------------------------------------------------------------
# Database connection (resolved after option checks, so a typo never prompts)
#   1. -c STRING                      used as is
#   2. DB_USER / -u  (+ DB_TNS / -d)  user/password; password from DB_PASSWORD,
#                                     then ARCH_DB_PASSWORD, then a prompt
#   3. DB_CONNECT                     wallet, e.g. /@MYDB
# The password is never written to the log or shown on screen.
# ---------------------------------------------------------------------------
command -v sqlplus >/dev/null 2>&1 || die "sqlplus not found in PATH (set ORACLE_HOME/PATH in your profile or in ${ENV_FILE})"

mask_connect() {   # user/pass@tns -> user/***@tns
    local s="$1" user tns=""
    [[ "${s}" == */* ]] || { echo "${s}"; return; }
    user="${s%%/*}"
    [[ "${s}" == *@* ]] && tns="@${s##*@}"
    echo "${user}/***${tns}"
}

if [[ -n "${CONNECT_OVERRIDE}" ]]; then
    DB_CONNECT="${CONNECT_OVERRIDE}"
    DISPLAY_CONNECT="$(mask_connect "${DB_CONNECT}")"
elif [[ -n "${DB_USER}" ]]; then
    [[ "${DB_USER}" =~ ^[A-Za-z][A-Za-z0-9_\$#]{0,127}$ ]] || die "DB_USER '${DB_USER}' is not a valid user name"
    [[ -z "${DB_TNS}" || "${DB_TNS}" =~ ^[^[:space:]\"\']+$ ]] || die "DB_TNS '${DB_TNS}' must not contain spaces or quotes"
    [[ -n "${DB_PASSWORD}" ]] || DB_PASSWORD="${ENV_PASSWORD}"
    if [[ -z "${DB_PASSWORD}" ]]; then
        [[ -t 0 ]] || die "no password for ${DB_USER}: set DB_PASSWORD in ${ENV_FILE} or export ARCH_DB_PASSWORD (not on a terminal, cannot prompt)"
        read -r -s -p "Password for ${DB_USER}${DB_TNS:+@${DB_TNS}}: " DB_PASSWORD
        echo
        [[ -n "${DB_PASSWORD}" ]] || die "empty password"
    fi
    [[ "${DB_PASSWORD}" != *\"* ]] || die "the password contains a double quote (\"), which SQL*Plus cannot pass; use a wallet or change the password"
    DB_CONNECT="${DB_USER}/\"${DB_PASSWORD}\"${DB_TNS:+@${DB_TNS}}"
    DISPLAY_CONNECT="${DB_USER}/***${DB_TNS:+@${DB_TNS}}"
elif [[ -n "${DB_CONNECT}" ]]; then
    DISPLAY_CONNECT="$(mask_connect "${DB_CONNECT}")"
else
    if [[ ! -f "${ENV_FILE}" ]]; then
        die "settings file not found: ${ENV_FILE}
       Create it:  cp ${SCRIPT_DIR}/../conf/archive_manager.env.example ${ENV_FILE}
       then set DB_USER and DB_TNS in it (or run with -u USER [-d TNS])"
    fi
    die "no database login: set DB_USER (and DB_TNS) or DB_CONNECT in ${ENV_FILE}, or use -u USER [-d TNS]"
fi

# ---------------------------------------------------------------------------
# Log file
# ---------------------------------------------------------------------------
mkdir -p "${LOG_DIR}" || die "cannot create LOG_DIR ${LOG_DIR}"
LOG_FILE="${LOG_DIR}/archive_manager_$(date +%Y%m%d_%H%M%S)_${MODE:-version}_r${RUN_ID:-new}_$$.log"
find "${LOG_DIR}" -maxdepth 1 -name 'archive_manager_*.log' -mtime +"${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

log() {
    echo "$(date '+%F %T') $*" | tee -a "${LOG_FILE}"
}

# Run SQL text ($1) through SQL*Plus; output goes to the log and stdout
# ($2 = "quiet": log only, the caller decides what to show).
# Returns SQL*Plus's exit code. The connect string is sent on stdin, so it
# never shows up in "ps".
SQL_OUT=""
run_sql() {
    local rc
    SQL_OUT="$(mktemp)"
    set +o errexit
    {
        echo "WHENEVER OSERROR EXIT 9"
        echo "WHENEVER SQLERROR EXIT SQL.SQLCODE"
        echo "CONNECT ${DB_CONNECT}"
        echo "SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED"
        echo "SET FEEDBACK OFF VERIFY OFF HEADING ON PAGESIZE 200 LINESIZE 250 TRIMOUT ON TAB OFF"
        echo "ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';"
        echo "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';"
        printf '%s\n' "$1"
        echo "EXIT"
    } | sqlplus -S -L /nolog > "${SQL_OUT}" 2>&1
    rc=$?
    set -o errexit
    if [[ "${2:-}" == "quiet" ]]; then
        cat "${SQL_OUT}" >> "${LOG_FILE}"
    else
        tee -a "${LOG_FILE}" < "${SQL_OUT}"
    fi
    return "${rc}"
}
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { [[ -n "${SQL_OUT}" ]] && rm -f "${SQL_OUT}"; return 0; }
trap cleanup EXIT

alert() {   # status run exec message
    if [[ -n "${ALERT_CMD}" ]]; then
        # shellcheck disable=SC2094  # the log path is only passed as an argument
        "${ALERT_CMD}" "$1" "$2" "$3" "${LOG_FILE}" "$4" >> "${LOG_FILE}" 2>&1 \
            || log "WARNING: alert command failed"
    fi
}

# ---------------------------------------------------------------------------
# Read-only modes
# ---------------------------------------------------------------------------
if [[ "${SHOW_VERSION}" -eq 1 ]]; then
    echo "archive_manager.sh ${VERSION}"
    run_sql "COLUMN engine FORMAT A40
SELECT 'PKG_ARCHIVE_MANAGER ' || ${PKG_OWNER}.pkg_archive_manager.version AS engine FROM dual;" || exit "${RC_SQLPLUS}"
    exit "${RC_OK}"
fi

if [[ "${MODE}" == "status" ]]; then
    if [[ -z "${RUN_ID}" ]]; then
        SQL="COLUMN created_by FORMAT A16
SELECT run_id, status, TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at, created_by, tables_in_run, tables_completed, tables_failed,
       rows_staged, rows_deleted, rows_restored
  FROM ${PKG_OWNER}.v_archive_run ORDER BY run_id DESC FETCH FIRST 10 ROWS ONLY;
SELECT exec_id, run_id, mode_name, status, TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') AS started_at,
       TO_CHAR(last_activity, 'YYYY-MM-DD HH24:MI:SS') AS last_activity, no_progress_15min
  FROM ${PKG_OWNER}.v_archive_exec WHERE status = 'RUNNING';"
    else
        SQL="COLUMN table_name FORMAT A28
COLUMN last_error FORMAT A60 TRUNCATED
COLUMN message FORMAT A70 WORD_WRAPPED
COLUMN batches FORMAT A13
COLUMN verify_result FORMAT A8 HEADING VERIFY
COLUMN no_progress_15min FORMAT A7 HEADING STALLED
COLUMN stop_requested FORMAT A4 HEADING STOP
PROMPT Tables
SELECT table_order, table_name, status, CAST(batches_done || '/' || batches_total AS VARCHAR2(13)) AS batches, pct_archived,
       rows_deleted, rows_restored, avg_batch_sec, eta_minutes, verify_result, last_error
  FROM ${PKG_OWNER}.v_archive_progress WHERE run_id = ${RUN_SQL} ORDER BY table_order;
PROMPT Executions
SELECT exec_id, mode_name, status, TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') AS started_at,
       TO_CHAR(ended_at, 'YYYY-MM-DD HH24:MI:SS') AS ended_at, no_progress_15min, stop_requested, message
  FROM ${PKG_OWNER}.v_archive_exec WHERE run_id = ${RUN_SQL} ORDER BY exec_id DESC FETCH FIRST 10 ROWS ONLY;
PROMPT Recent warnings and errors
SELECT TO_CHAR(log_time, 'YYYY-MM-DD HH24:MI:SS') AS log_time, table_name, batch_no, log_level, message
  FROM ${PKG_OWNER}.archive_log WHERE run_id = ${RUN_SQL} AND log_level <> 'INFO'
 ORDER BY log_id DESC FETCH FIRST 10 ROWS ONLY;"
    fi
    run_sql "${SQL}" || exit "${RC_SQLPLUS}"
    exit "${RC_OK}"
fi

if [[ "${MODE}" == "stop" ]]; then
    log "Requesting stop for run ${RUN_ID}"
    run_sql "EXEC ${PKG_OWNER}.pkg_archive_manager.request_stop(p_run_id => ${RUN_SQL})" || exit "${RC_SQLPLUS}"
    exit "${RC_OK}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    case "${MODE}" in stage|archive|rollback) ;; *) die "-n applies to stage, archive and rollback" ;; esac
    ORDER_DIR="ASC"; [[ "${MODE}" == "rollback" ]] && ORDER_DIR="DESC"
    log "DRY RUN: plan for mode ${MODE}, run ${RUN_ID:-new}, tables ${TABLES:-all enabled}"
    # Header: the run must exist (archive/rollback/stage -r); warn about
    # tables named with -t that are not configured or disabled, and about
    # tables staged in the run but disabled now.
    DRY_SQL="DECLARE
    v_status  VARCHAR2(10);
    v_created VARCHAR2(20);
    v_staged  NUMBER;
    v_text    VARCHAR2(4000);
    v_csv     VARCHAR2(4000) := ${TABLES_SQL};
    v_name    VARCHAR2(128);
    v_flag    VARCHAR2(1);
BEGIN
    IF ${RUN_SQL} IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('New run: stage will create it');
    ELSE
        BEGIN
            SELECT status, TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') INTO v_status, v_created
              FROM ${PKG_OWNER}.archive_run WHERE run_id = ${RUN_SQL};
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20057, 'Run ${RUN_ID} not found');
        END;
        SELECT COUNT(*) INTO v_staged FROM ${PKG_OWNER}.archive_run_state WHERE run_id = ${RUN_SQL};
        DBMS_OUTPUT.PUT_LINE('Run ${RUN_ID}: ' || v_status || ', created ' || v_created || ', '
                             || v_staged || ' table(s) staged');
        IF v_status = 'CLOSED' AND '${MODE}' IN ('stage', 'archive') THEN
            DBMS_OUTPUT.PUT_LINE('WARNING: run ${RUN_ID} is CLOSED; ${MODE} will be refused');
        END IF;
        SELECT LISTAGG(s.table_name, ', ') WITHIN GROUP (ORDER BY c.table_order)
          INTO v_text
          FROM ${PKG_OWNER}.archive_run_state s
          JOIN ${PKG_OWNER}.archive_table_config c ON c.table_name = s.table_name
         WHERE s.run_id = ${RUN_SQL} AND c.enabled_flag <> 'Y';
        IF v_text IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('WARNING: staged in this run but disabled now (not shown below): ' || v_text);
        END IF;
    END IF;
    IF v_csv IS NOT NULL THEN
        FOR i IN 1 .. REGEXP_COUNT(v_csv, '[^,]+') LOOP
            v_name := REGEXP_SUBSTR(v_csv, '[^,]+', 1, i);
            BEGIN
                SELECT enabled_flag INTO v_flag FROM ${PKG_OWNER}.archive_table_config WHERE table_name = v_name;
                IF v_flag <> 'Y' THEN
                    DBMS_OUTPUT.PUT_LINE('WARNING: ' || v_name || ' is disabled; ${MODE} will refuse it');
                END IF;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    DBMS_OUTPUT.PUT_LINE('WARNING: ' || v_name || ' is not in ARCHIVE_TABLE_CONFIG');
            END;
        END LOOP;
    END IF;
END;
/
COLUMN table_name FORMAT A28
COLUMN depends_on FORMAT A40 TRUNCATED
SELECT c.table_order, c.table_name, c.batch_size, c.parallel_degree, NVL(c.depends_on, '(lower order)') AS depends_on,
       NVL(s.status, 'NOT STAGED') AS run_status, s.batches_total, s.batches_done, s.batches_restored
  FROM ${PKG_OWNER}.archive_table_config c
  LEFT JOIN ${PKG_OWNER}.archive_run_state s ON s.table_name = c.table_name AND s.run_id = ${RUN_SQL}
 WHERE c.enabled_flag = 'Y'
   AND (${TABLES_SQL} IS NULL OR INSTR(',' || ${TABLES_SQL} || ',', ',' || c.table_name || ',') > 0)
 ORDER BY c.table_order ${ORDER_DIR};"
    DRY_RC=0
    run_sql "${DRY_SQL}" quiet || DRY_RC=$?
    if [[ "${DRY_RC}" -ne 0 ]]; then
        ENGINE_ERR="$(grep -m 1 -oE 'ORA-20057: .*' "${SQL_OUT}" || true)"
        [[ -n "${ENGINE_ERR}" ]] && die "run ${RUN_ID} not found (check the id with: -m status)"
        cat "${SQL_OUT}"
        exit "${RC_SQLPLUS}"
    fi
    cat "${SQL_OUT}"
    exit "${RC_OK}"
fi

# ---------------------------------------------------------------------------
# Confirmation for modes that change business data or drop staging data
# ---------------------------------------------------------------------------
if [[ "${MODE}" =~ ^(archive|rollback|close)$ && "${ASSUME_YES}" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
        die "mode ${MODE} needs confirmation; not on a terminal, so add -y"
    fi
    echo "About to run ${MODE^^} on run ${RUN_ID} (connect ${DISPLAY_CONNECT}), tables: ${TABLES:-all enabled}"
    read -r -p "Type the run id to continue: " answer
    [[ "${answer}" == "${RUN_ID}" ]] || { echo "Not confirmed; nothing done."; exit "${RC_USAGE}"; }
fi

# ---------------------------------------------------------------------------
# One execution of the engine
# ---------------------------------------------------------------------------
log "archive_manager.sh ${VERSION}: connect=${DISPLAY_CONNECT} mode=${MODE} run=${RUN_ID:-new} tables=${TABLES:-all} batch=${BATCH_SIZE:-config} max_minutes=${MAX_MINUTES:-none} force=${FORCE}"

JOB_SQL="VARIABLE b_run    NUMBER
VARIABLE b_exec   NUMBER
VARIABLE b_status VARCHAR2(20)
VARIABLE b_msg    VARCHAR2(4000)
BEGIN
    :b_run := ${RUN_SQL};
    ${PKG_OWNER}.pkg_archive_manager.run_job(
        p_mode        => '${MODE_UC}',
        p_run_id      => :b_run,
        p_table_csv   => ${TABLES_SQL},
        p_batch_size  => ${BATCH_SQL},
        p_max_minutes => ${MINUTES_SQL},
        p_force       => '${FORCE}',
        p_exec_id     => :b_exec,
        p_status      => :b_status,
        p_message     => :b_msg);
    DBMS_OUTPUT.PUT_LINE('RESULT|' || :b_run || '|' || :b_exec || '|' || :b_status || '|' || :b_msg);
END;
/"

# "|| ..." keeps errexit from ending the script on a SQL*Plus error code
SQLPLUS_RC=0
run_sql "${JOB_SQL}" quiet || SQLPLUS_RC=$?

RESULT_LINE="$(grep '^RESULT|' "${SQL_OUT}" | tail -n 1 || true)"
if [[ "${SQLPLUS_RC}" -ne 0 || -z "${RESULT_LINE}" ]]; then
    # Engine refusal (ORA-20000..20999 raised before an execution started):
    # one clean line on screen; the full SQL*Plus output is in the log file.
    ENGINE_ERR="$(grep -m 1 -oE 'ORA-20[0-9]{3}: .*' "${SQL_OUT}" || true)"
    if [[ -n "${ENGINE_ERR}" ]]; then
        log "Refused by the engine: ${ENGINE_ERR}"
        alert "FAILED" "${RUN_ID:-?}" "?" "${ENGINE_ERR}"
    else
        cat "${SQL_OUT}"
        FIRST_ORA="$(grep -m 1 -oE '(ORA|SP2|TNS)-[0-9]+: .*' "${SQL_OUT}" || true)"
        log "SQL*Plus ended with code ${SQLPLUS_RC} and no result${FIRST_ORA:+: ${FIRST_ORA}} (connection, parameter or privilege error); see output above"
        alert "FAILED" "${RUN_ID:-?}" "?" "SQL*Plus error ${SQLPLUS_RC}${FIRST_ORA:+: ${FIRST_ORA}}"
    fi
    exit "${RC_SQLPLUS}"
fi

# Check mode: turn the package's CHK/CHKT lines into a short summary.
#   default: one line per table, ERROR and WARN lines (except the known
#            implicit-conversion warning, which is reported once at the end)
#   -v:      every finding, including INFO notes
check_summary() {
    awk -F'|' -v verbose="${VERBOSE}" '
        $1 == "CHK" {
            key = $3
            if ($4 == "IMPLICIT") { implicit++; if (!verbose) next }
            if ($2 == "INFO" && !verbose) next
            msg = $5; for (i = 6; i <= NF; i++) msg = msg "|" $i
            detail[key] = detail[key] sprintf("    %-6s %s\n", $2, msg)
            next
        }
        $1 == "CHKT" {
            n++; names[n] = $2
            state = ($3 == "Y") ? "yes" : "no"
            res = ($4 > 0) ? "ERROR" : "OK"
            errors += $4; warns += $5
            if ($4 > 0) bad++
            printf "%-32s %-8s %-6s %6d %8d\n", $2, state, res, $4, $5
            printf "%s", detail[$2]
            next
        }
        BEGIN { printf "%-32s %-8s %-6s %6s %8s\n", "TABLE", "ENABLED", "RESULT", "ERRORS", "WARNINGS" }
        END {
            print ""
            if (implicit > 0 && !verbose)
                printf "Note: %d table(s) join a NUMBER worklist to a VARCHAR2 column (implicit conversion; consider JOIN_CAST).\n", implicit
            if (bad > 0)
                printf "Check FAILED: %d error(s) in %d of %d table(s). Fix them, then run check again.\n", errors, bad, n
            else
                printf "Check OK: %d table(s), 0 errors, %d warning(s).\n", n, warns
            if (!verbose) print "Details: add -v, or see the log file."
        }' "${SQL_OUT}"
}

IFS='|' read -r _ R_RUN R_EXEC R_STATUS R_MSG <<< "${RESULT_LINE}"
if [[ "${MODE}" == "check" ]]; then
    check_summary | tee -a "${LOG_FILE}"
    log "Result: exec=${R_EXEC} status=${R_STATUS}"
else
    grep -v '^RESULT|' "${SQL_OUT}" || true
    log "Result: run=${R_RUN} exec=${R_EXEC} status=${R_STATUS}${R_MSG:+ message=${R_MSG}}"
fi

case "${R_STATUS}" in
    COMPLETED) exit "${RC_OK}" ;;
    PAUSED)    log "Time limit reached; continue in the next window with: -m ${MODE} -r ${R_RUN}"; exit "${RC_PAUSED}" ;;
    STOPPED)   alert "STOPPED" "${R_RUN}" "${R_EXEC}" "${R_MSG:-stop requested}"; exit "${RC_STOPPED}" ;;
    *)         alert "FAILED" "${R_RUN}" "${R_EXEC}" "${R_MSG:-}"; exit "${RC_FAILED}" ;;
esac
