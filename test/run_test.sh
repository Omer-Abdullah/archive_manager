#!/usr/bin/env bash
#
# run_test.sh - end-to-end test of the archiving engine on synthetic tables.
# Run ONLY against a non-production schema where install.sql has been run and
# conf/archive_manager.env points at that schema (DB_USER/DB_TNS or DB_CONNECT, and
# PKG_OWNER). With DB_USER and no DB_PASSWORD the password is asked once here
# and handed to every archive_manager.sh call through ARCH_DB_PASSWORD.
#
# What it proves: check, stage, the dependency gate, stop + resume, time-limit
# pause + resume, content-exact archiving (counts + checksums), verify, stats,
# content-exact rollback, close, and refusal to archive a closed run.
#
set -o errexit -o nounset -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RA="${TEST_DIR}/../bin/archive_manager.sh"
ENV_FILE="${ARCH_ENV_FILE:-${TEST_DIR}/../conf/archive_manager.env}"
[[ -f "${ENV_FILE}" ]] || { echo "settings file not found: ${ENV_FILE}" >&2; exit 2; }
DB_USER="" DB_PASSWORD="" DB_TNS="" DB_CONNECT=""
# shellcheck source=/dev/null
source "${ENV_FILE}"

if [[ -n "${DB_USER}" ]]; then
    [[ -n "${DB_PASSWORD}" ]] || DB_PASSWORD="${ARCH_DB_PASSWORD:-}"
    if [[ -z "${DB_PASSWORD}" ]]; then
        read -r -s -p "Password for ${DB_USER}${DB_TNS:+@${DB_TNS}}: " DB_PASSWORD
        echo
    fi
    [[ -n "${DB_PASSWORD}" && "${DB_PASSWORD}" != *\"* ]] || { echo "empty password or password with a double quote" >&2; exit 2; }
    export ARCH_DB_PASSWORD="${DB_PASSWORD}"      # child archive_manager.sh calls reuse it
    DB_CONNECT="${DB_USER}/\"${DB_PASSWORD}\"${DB_TNS:+@${DB_TNS}}"
fi
[[ -n "${DB_CONNECT}" ]] || { echo "no database login in ${ENV_FILE}" >&2; exit 2; }

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nTEST FAILED: %s\n' "$*" >&2; exit 1; }

# run_ra <allowed exit codes, space separated> <archive_manager.sh args...>
# Leaves the output in OUT and the exit code in RC.
OUT="" RC=0
run_ra() {
    local allowed="$1"; shift
    set +o errexit
    OUT="$("${RA}" "$@" 2>&1)"
    RC=$?
    set -o errexit
    printf '%s\n' "${OUT}"
    [[ " ${allowed} " == *" ${RC} "* ]] || fail "archive_manager.sh $* exited ${RC}, expected one of: ${allowed}"
}

run_sqlfile() {   # file [args...]
    local file="$1"; shift
    (cd "${TEST_DIR}" && {
        echo "WHENEVER SQLERROR EXIT SQL.SQLCODE"
        echo "CONNECT ${DB_CONNECT}"
        echo "@${file} $*"
        echo "EXIT"
    } | sqlplus -S -L /nolog) || fail "${file} failed"
}

step "1. Create synthetic tables, worklists and baseline"
run_sqlfile T01_test_objects.sql

step "2. Load test configuration and prepare archive tables"
run_sqlfile T02_test_config.sql

step "3. Preflight checks"
run_ra "0" -m check -t TST_ORDER_ITEM,TST_BASKET_ITEM,TST_BASKET,TST_ORDER

step "4. Stage a new run"
run_ra "0" -m stage -t TST_ORDER_ITEM,TST_BASKET_ITEM,TST_BASKET,TST_ORDER
RUN_ID="$(printf '%s\n' "${OUT}" | sed -n 's/.*Result: run=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
[[ -n "${RUN_ID}" ]] || fail "could not read the run id"
echo "Run id: ${RUN_ID}"

step "5. Dependency gate: the parent table must be refused before its children"
run_ra "1" -m archive -r "${RUN_ID}" -t TST_ORDER -y

step "6. Stop request while archiving, then resume"
"${RA}" -m archive -r "${RUN_ID}" -y > "${TEST_DIR}/bg_archive.out" 2>&1 &
BG=$!
sleep 3
run_ra "0" -m stop -r "${RUN_ID}"
set +o errexit; wait "${BG}"; BG_RC=$?; set -o errexit
cat "${TEST_DIR}/bg_archive.out"
[[ "${BG_RC}" -eq 4 || "${BG_RC}" -eq 0 ]] || fail "background archive exited ${BG_RC}, expected 4 (stopped) or 0"
echo "Background archive exit code: ${BG_RC} (4 = stopped as requested, 0 = finished first)"

step "7. Resume with a 1-minute time limit until completed"
for _ in $(seq 1 30); do
    run_ra "0 3" -m archive -r "${RUN_ID}" -T 1 -y
    [[ "${RC}" -eq 0 ]] && break
done
[[ "${RC}" -eq 0 ]] || fail "archive did not complete after 30 windows"

step "8. Assert: counts and checksums after archive"
run_sqlfile T03_assert.sql AFTER_ARCHIVE "${RUN_ID}"

step "9. Verify and stats"
run_ra "0" -m verify -r "${RUN_ID}"
run_ra "0" -m stats -r "${RUN_ID}"
run_ra "0" -m status -r "${RUN_ID}"

step "10. Rollback the whole run (parent first)"
for _ in $(seq 1 30); do
    run_ra "0 3" -m rollback -r "${RUN_ID}" -T 1 -y
    [[ "${RC}" -eq 0 ]] && break
done
[[ "${RC}" -eq 0 ]] || fail "rollback did not complete after 30 windows"

step "11. Assert: source identical to baseline after rollback"
run_sqlfile T03_assert.sql AFTER_ROLLBACK "${RUN_ID}"

step "12. Close the run, then make sure a closed run cannot be archived"
run_ra "0" -m close -r "${RUN_ID}" -y
run_ra "5" -m archive -r "${RUN_ID}" -y

rm -f "${TEST_DIR}/bg_archive.out"
printf '\nALL TESTS PASSED (run %s)\n' "${RUN_ID}"
