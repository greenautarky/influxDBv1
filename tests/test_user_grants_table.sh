#!/usr/bin/env bash
# SC2034: USER_PW is populated here and consumed by write_users_json, which is
#   sourced from the script under test — the linter cannot follow that.
# SC2015: `cond && ok ... || bad ...` is this file's assertion idiom. `ok` and
#   `bad` are printf wrappers that cannot fail, so the C-branch is unreachable.
# SC2317: the stubs below are called indirectly, by the sourced functions.
# NB: a comment whose first word after "#" is the linter's name is parsed as a
#   DIRECTIVE and fails — SC1072/SC1073. Hence the wording above.
# shellcheck disable=SC2034,SC2015,SC2317
# Tests for the per-user credential table in 00_create-db_and_users.sh.
#
# WHAT THIS GUARDS. The add-on hands each consumer a manifest entry AND grants
# that consumer a server-side privilege. When those two disagree, the consumer
# authenticates successfully and is refused on every request afterwards — an
# add-on that starts, connects, and writes nothing, while an InfluxDB client
# reports "Write successful" for the empty batches it is left with. That is the
# hardest shape of this failure to see, so the table is asserted directly.
#
# IT READS THE LIVE SCRIPT, never a copy. A test that re-declares USER_DBS
# would stay green while the real table lost an entry, which is precisely the
# defect it exists to catch. If the extraction stops finding the declarations,
# this FAILS — it never skips.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/../influxdb/rootfs/etc/cont-init.d/00_create-db_and_users.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# ── extract the declarations + functions, everything above the execution ─────
[ -f "${TARGET}" ] || { echo "FATAL: ${TARGET} not found"; exit 1; }

PREAMBLE="$(sed -n '1,/^PER_USER=false/p' "${TARGET}")"
# Fail closed. An extraction that silently found nothing would make every
# assertion below vacuous, and the suite would report success over zero checks.
if ! grep -q 'declare -A USER_DBS=' <<<"${PREAMBLE}"; then
    echo "FATAL: could not find the USER_DBS declaration in ${TARGET}."
    echo "The script was restructured — fix this extraction, do not skip it."
    exit 1
fi
if ! grep -q '^write_users_json()' <<<"${PREAMBLE}"; then
    echo "FATAL: write_users_json() not in the extracted preamble"; exit 1
fi

# ── stubs: enough container to source the declarations ───────────────────────
bashio::log.info()      { STUB_LOG+=("INFO $*"); }
bashio::log.error()     { STUB_LOG+=("ERROR $*"); }
bashio::log.warning()   { STUB_LOG+=("WARN $*"); }
bashio::fs.file_exists(){ [ -f "$1" ]; }
bashio::var.has_value() { [ -n "${1:-}" ]; }
bashio::config.true()   { return 1; }
bashio::exit.nok()      { echo "exit.nok $*"; return 1; }
export -f bashio::log.info bashio::log.error 2>/dev/null || true
STUB_LOG=()

# shellcheck disable=SC1090
source /dev/stdin <<<"${PREAMBLE}"

echo "== every helper survives bashio's errexit + pipefail =="
# THE CHECK THAT WOULD HAVE CAUGHT IT.
#
# bashio runs cont-init scripts with `errexit`, `nounset` and `pipefail`. Under
# those flags a pipeline whose LAST stage exits early — `… | head -c 32` — kills
# the script, because the upstream stage takes SIGPIPE and pipefail reports 141
# even though the output was produced correctly.
#
# gen_password did exactly that, and it is called ONLY in per-user mode, so no
# amount of running the add-on in its default configuration could find it. The
# first time the flag was enabled anywhere, InfluxDB crash-looped and the data
# plane went down. A branch that has never executed is not tested by anything.
#
# So every helper is called here under the same flags the container uses, and
# its exit status is asserted — not just its output.
# One entry today. The loop is the point: a second helper joins the check by
# being added here, and shellcheck's "this loop runs once" is exactly the shape
# we want to keep.
# shellcheck disable=SC2043
for fn in gen_password; do
    out="$(bash -o pipefail -o errexit -c "
        $(sed -n "/^${fn}()/,/^}/p" "${TARGET}")
        ${fn}
    " 2>/dev/null)"; rc=$?
    check "${fn} exits 0 under errexit+pipefail" "${rc}" "0"
    [ "${#out}" -ge 16 ] \
        && ok "${fn} still produces a usable value (${#out} chars)" \
        || bad "${fn} still produces a usable value" "got ${#out} chars"
done

echo "== nothing the provisioning removes is read by a sibling script =="
# THE CHECK THAT WOULD HAVE CAUGHT THE SECOND ONE.
#
# The per-user branch deleted /data/secret, on sound reasoning: a shared secret
# should not linger once per-user mode is on. Three sibling scripts read that
# file — cont-init.d/kapacitor.sh, services.d/kapacitor/run,
# services.d/chronograf/run — so cont-init died and s6 stopped the container.
#
# The class is "one script removes an artefact another one depends on", and it
# is invisible in review because the two live in different files. So: every
# path this script deletes is checked against every path the rootfs reads.
ROOTFS="${SCRIPT_DIR}/../influxdb/rootfs"
[ -d "${ROOTFS}" ] || { echo "FATAL: rootfs not found at ${ROOTFS}"; exit 1; }

deleted="$(grep -oE 'rm -f +(/[A-Za-z0-9_./-]+)' "${TARGET}" | awk '{print $NF}' | sort -u)"
checked_paths=0
for path in ${deleted}; do
    checked_paths=$((checked_paths + 1))
    readers="$(grep -rlF "${path}" "${ROOTFS}/etc" 2>/dev/null \
                | grep -v '00_create-db_and_users' || true)"
    if [ -n "${readers}" ]; then
        bad "provisioning deletes ${path}, which is still read" \
            "$(echo "${readers}" | sed "s|${ROOTFS}||" | tr '\n' ' ')"
    else
        ok "nothing else reads ${path}"
    fi
done
# "No deletions" and "the extractor is broken" are different facts, and the
# first one is legitimate — this branch deletes nothing today. So the EXTRACTOR
# is proven against a fixture instead of inferred from the real count.
_fixture="$(mktemp)"; printf 'foo\nrm -f /data/decoy-path\nbar\n' > "${_fixture}"
_found="$(grep -oE 'rm -f +(/[A-Za-z0-9_./-]+)' "${_fixture}" | awk '{print $NF}')"
rm -f "${_fixture}"
check "the deletion extractor still works (must-fail fixture)" "${_found}" "/data/decoy-path"
ok "real deletions in the provisioning script: ${checked_paths}"

# And the must-fail half on the real subject: a path the rootfs reads must be
# reported if the script ever deletes it again.
_readers="$(grep -rlF '/data/secret' "${ROOTFS}/etc" 2>/dev/null | grep -vc '00_create-db' || echo 0)"
[ "${_readers}" -ge 1 ] \
    && ok "/data/secret still has ${_readers} reader(s) — so deleting it would be caught" \
    || bad "/data/secret has readers" "none found; the guard above would be vacuous"

echo "== the table itself =="

# Every data user has a row, every row belongs to a data user. Two lists that
# describe one truth have to be checked against each other.
missing_rows=""
for u in ${DATA_USERS}; do
    [ -n "${USER_DBS[$u]:-}" ] || missing_rows="${missing_rows} ${u}"
done
check "every DATA_USER has a database row" "${missing_rows}" ""

orphans=""
for u in "${!USER_DBS[@]}"; do
    [[ " ${DATA_USERS} " == *" ${u} "* ]] || orphans="${orphans} ${u}"
done
check "no USER_DBS row without a DATA_USER" "${orphans}" ""

# A data user that is also an admin account defeats the whole split.
overlap=""
for u in ${DATA_USERS}; do
    [[ " ${ADMIN_USERS} " == *" ${u} "* ]] && overlap="${overlap} ${u}"
done
check "no user is both a data user and an admin" "${overlap}" ""

# Coverage before content: an emptied table would pass every loop above.
[ "$(wc -w <<<"${DATA_USERS}")" -ge 4 ] \
    && ok "table is populated ($(wc -w <<<"${DATA_USERS}") data users)" \
    || bad "table is populated" "fewer than 4 data users — did the table lose rows?"

echo "== the consumers ga_manager delivers to =="
# These two add-ons authenticate against this server. A flip that leaves either
# without a user is a device that looks healthy and stores nothing.
for u in ga_default ga_hmvapp; do
    [ -n "${USER_DBS[$u]:-}" ] && ok "${u} exists in the table" \
        || bad "${u} exists in the table" "ga_manager would raise a drift error for it"
done

# Each consumer must cover the databases its own add-on options name.
grep -q 'gd_data' <<<"${USER_DBS[ga_default]:-}" && grep -q 'pd_data' <<<"${USER_DBS[ga_default]:-}" \
    && grep -q 'ga_homeassistant_db' <<<"${USER_DBS[ga_default]:-}" \
    && ok "ga_default covers all three databases its options name" \
    || bad "ga_default covers all three databases its options name" "got [${USER_DBS[ga_default]:-}]"

grep -q 'gd_data' <<<"${USER_DBS[ga_hmvapp]:-}" \
    && grep -q 'ga_homeassistant_db' <<<"${USER_DBS[ga_hmvapp]:-}" \
    && ok "ga_hmvapp covers both databases its options name" \
    || bad "ga_hmvapp covers both databases its options name" "got [${USER_DBS[ga_hmvapp]:-}]"

echo "== the manifest the delivery layer reads =="
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
USERS_JSON="${TMPD}/influx-users.json"
declare -A USER_PW
i=0
for u in ${DATA_USERS} ${ADMIN_USERS}; do
    i=$((i + 1)); USER_PW[$u]="pw-sentinel-${i}-must-not-leak"
done

write_users_json

check "manifest is written" "$([ -f "${USERS_JSON}" ] && echo yes || echo no)" "yes"
check "manifest is 0600" "$(stat -c '%a' "${USERS_JSON}")" "600"
check "manifest carries every user" \
    "$(jq -r '.users | keys | length' "${USERS_JSON}")" \
    "$(( $(wc -w <<<"${DATA_USERS}") + $(wc -w <<<"${ADMIN_USERS}") ))"

# The manifest's databases must be exactly the table's — this is the pair that
# used to be maintained separately.
drift=""
for u in ${DATA_USERS}; do
    # Word splitting is the list format, matching the script under test.
    # shellcheck disable=SC2086
    want="$(printf '%s\n' ${USER_DBS[$u]} | sort | tr '\n' ' ')"
    got="$(jq -r --arg u "$u" '.users[$u].databases[]' "${USERS_JSON}" | sort | tr '\n' ' ')"
    [ "${want}" = "${got}" ] || drift="${drift} ${u}(want:${want}got:${got})"
done
check "manifest databases match the table" "${drift}" ""

check "data users are scope rw, not admin" \
    "$(jq -r --arg d "${DATA_USERS}" '[.users|to_entries[]|select(.value.scope=="admin")|.key]|join(",")' "${USERS_JSON}")" \
    "$(tr ' ' ',' <<<"${ADMIN_USERS}")"

echo "== grant verification goes BOTH ways =="
# The user is the last WORD of the last ARGUMENT ("SHOW GRANTS FOR <user>").
# Not ${*##* }: that applies the removal to each positional parameter
# separately, so it returned "-execute ga_default" and every lookup missed —
# which made the must-fail case below pass for the wrong reason. The must-pass
# case is what caught it.
_stub_user() { local last="${*: -1}"; printf '%s' "${last##* }"; }

# All grants present → clean.
STUB_LOG=()
influx() {
    local user; user="$(_stub_user "$@")"
    echo "database  privilege"
    # shellcheck disable=SC2086
    for d in ${USER_DBS[$user]:-}; do echo "${d}  ALL PRIVILEGES"; done
}
verify_grants
check "no MISSING GRANT when every grant is present" \
    "$(printf '%s\n' "${STUB_LOG[@]}" | grep -c 'MISSING GRANT')" "0"

# One grant absent → named, not swallowed. Red proof for the guard.
STUB_LOG=()
influx() {
    local user; user="$(_stub_user "$@")"
    echo "database  privilege"
    # shellcheck disable=SC2086
    for d in ${USER_DBS[$user]:-}; do
        [ "${user}" = "ga_default" ] && [ "${d}" = "pd_data" ] && continue
        echo "${d}  ALL PRIVILEGES"
    done
}
verify_grants
out="$(printf '%s\n' "${STUB_LOG[@]}")"
grep -q 'MISSING GRANT: ga_default has no privilege on pd_data' <<<"${out}" \
    && ok "a withheld grant is reported, and names the user and the database" \
    || bad "a withheld grant is reported" "log was: ${out}"

# And the count is a count of what was inspected, not of what existed.
grep -qE 'of [0-9]+ required grants are missing' <<<"${out}" \
    && ok "the report states how many pairs were inspected" \
    || bad "the report states how many pairs were inspected" "log was: ${out}"

echo
echo "passed: ${PASS}   failed: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
[ "${PASS}" -ge 10 ] || { echo "FATAL: only ${PASS} assertions ran — suite is too thin to trust"; exit 1; }
