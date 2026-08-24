#!/usr/bin/env bash
# Self-test for the LIVE provisioning script.
#
# It sources influxdb/rootfs/etc/cont-init.d/00_create-db_and_users.sh — the
# real one, never a copy. A test that re-declares the consumer table would stay
# green while the shipped script drifted, which is the failure class it exists
# to catch. If it cannot find the script it FAILS; it never skips.
#
# bashio and influx are stubbed because neither exists outside the add-on image.
# The SUBJECT — the consumer table, the manifest, the grants, the fail-closed
# behaviour — is never stubbed.
set -uo pipefail
# shellcheck disable=SC2015  # ok()/bad() always return 0, so `A && ok || bad` is safe here

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
LIVE="${ROOT}/influxdb/rootfs/etc/cont-init.d/00_create-db_and_users.sh"

echo "=== InfluxDB provisioning self-test ==="
echo "  Live script: ${LIVE}"
[[ -f "$LIVE" ]] || { echo "::error::FATAL — live script not found. Refusing to skip."; exit 1; }
command -v jq >/dev/null || { echo "::error::FATAL — jq required"; exit 1; }

fails=0
ok()  { echo "  PASS  $1"; }
bad() { echo "::error::  FAIL  $1"; fails=$((fails+1)); }

# --- harness ---------------------------------------------------------------
# One run of the live script against stubs. FAIL_ON=<substring> makes the influx
# stub reject the first statement containing it, which is how the fail-closed
# assertions are driven.
run_script() {
  local work="$1" fail_on="${2:-}"
  mkdir -p "${work}/data" "${work}/share" "${work}/bin"

  cat > "${work}/bin/bashio" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${work}/stub.sh" <<EOF
bashio::log.info()    { echo "INFO  \$*"; }
bashio::log.warning() { echo "WARN  \$*"; }
bashio::log.error()   { echo "ERROR \$*"; }
bashio::exit.nok()    { echo "NOK   \$*"; exit 1; }
bashio::fs.file_exists() { [[ -e "\$1" ]]; }
bashio::var.has_value()  { [[ -n "\${1:-}" ]]; }
influxd() { :; }
EOF
  cat > "${work}/bin/influx" <<EOF
#!/usr/bin/env bash
stmt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-execute" ]] && stmt="\$2"; shift; done
echo "\$stmt" >> "${work}/statements.log"
if [[ -n "${fail_on}" && "\$stmt" == *"${fail_on}"* ]]; then
  echo "ERR: simulated influx rejection" >&2; exit 1
fi
case "\$stmt" in
  "SHOW DATABASES") printf 'name: databases\nname\n' ;;
  "SHOW USERS")     printf 'user admin\n---- -----\n' ;;
esac
exit 0
EOF
  chmod +x "${work}/bin/influx" "${work}/bin/bashio"

  # Rewrite only the absolute paths, so the test can run unprivileged. The
  # LOGIC is untouched — this is a chroot substitute, not a second copy.
  sed -e "s#^USERS_JSON=.*#USERS_JSON=\"${work}/data/influx-users.json\"#" \
      -e "s#^LEGACY_SECRET=.*#LEGACY_SECRET=\"${work}/data/secret\"#" \
      -e "s#^LEGACY_SHARE_SECRET=.*#LEGACY_SHARE_SECRET=\"${work}/share/influxdb_password.yaml\"#" \
      "$LIVE" > "${work}/subject.sh"

  ( set +e
    export PATH="${work}/bin:$PATH"
    # shellcheck disable=SC1090
    bash -c "source '${work}/stub.sh'; source '${work}/subject.sh'" > "${work}/out.log" 2>&1
    echo $? > "${work}/rc" )
}

# --- 1. happy path ---------------------------------------------------------
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# Seed BOTH legacy artefacts, then assert they are really there before the run.
# Without this pre-assertion, "the legacy file was removed" passes trivially on
# a file that never existed — a check that cannot go red, which is worse than no
# check because it reads as evidence. Caught by exactly that happening here.
mkdir -p "${W}/data" "${W}/share"
printf 'old-shared-secret\n' > "${W}/data/secret"
printf "ga_influxdbv1_token: 'old'\n" > "${W}/share/influxdb_password.yaml"
[[ -s "${W}/data/secret" && -s "${W}/share/influxdb_password.yaml" ]] \
  || { echo "::error::FATAL — could not seed the legacy artefacts; the removal assertions would be vacuous"; exit 1; }
run_script "$W"
RC=$(cat "${W}/rc")
M="${W}/data/influx-users.json"

[[ "$RC" -eq 0 ]] && ok "clean run exits 0" || { bad "clean run exited ${RC}"; sed 's/^/      /' "${W}/out.log"; }

if [[ -f "$M" ]]; then
  ok "manifest written"
  [[ "$(stat -c %a "$M")" == "600" ]] && ok "manifest is 0600" || bad "manifest mode is $(stat -c %a "$M"), expected 600"
  n=$(jq '.users | length' "$M")
  [[ "$n" -eq 5 ]] && ok "one entry per consumer (${n})" || bad "manifest has ${n} users, expected 5"
  # The grant the DATABASE will enforce and the scope the MANIFEST advertises
  # must agree — that is the whole point of deriving both from one table.
  jq -e '.users.ga_default.databases == ["gd_data","pd_data"]' "$M" >/dev/null \
    && ok "ga_default is scoped to gd_data+pd_data" || bad "ga_default databases wrong: $(jq -c '.users.ga_default' "$M")"
  jq -e '.users.ga_ha_influx_user.databases == ["ga_homeassistant_db"]' "$M" >/dev/null \
    && ok "ga_ha_influx_user is scoped to ga_homeassistant_db only" || bad "ga_ha_influx_user databases wrong"
  jq -e '.users.ga_influx_admin.scope == "admin"' "$M" >/dev/null \
    && ok "ga_influx_admin keeps admin scope" || bad "admin scope wrong"
  # Distinct secrets is the entire premise. One shared password would satisfy
  # every other assertion here.
  d=$(jq -r '[.users[].password] | unique | length' "$M")
  [[ "$d" -eq 5 ]] && ok "all five passwords are distinct" || bad "only ${d} distinct passwords — the shared-secret model is back"
  jq -e '[.users[].password] | all(test("^[A-Za-z0-9]{32}$"))' "$M" >/dev/null \
    && ok "passwords are 32-char alphanumeric" || bad "password shape wrong"
else
  bad "no manifest written"
fi

[[ ! -f "${W}/data/secret" ]] && ok "legacy /data/secret removed" || bad "legacy /data/secret still present"
[[ ! -f "${W}/share/influxdb_password.yaml" ]] && ok "legacy /share mirror removed" || bad "legacy /share mirror still present"

S="${W}/statements.log"
grep -q "GRANT ALL ON gd_data TO ga_default" "$S" && ok "per-database GRANT issued for ga_default" || bad "per-database GRANT missing"
grep -qE "CREATE USER ga_default WITH PASSWORD '[^']+'$" "$S" \
  && ok "data user created WITHOUT admin privileges" || bad "data user created with ALL PRIVILEGES — least privilege lost"
grep -q "GRANT ALL PRIVILEGES TO ga_ha_influx_user" "$S" \
  && bad "ga_ha_influx_user was granted admin" || ok "no admin grant leaked to a data user"
grep -q "CREATE DATABASE ga_telegraf" "$S" && bad "retired database ga_telegraf still created" || ok "retired databases not created"
grep -q "DROP DATABASE" "$S" && bad "script issues DROP DATABASE — destroys data unattended" || ok "no DROP DATABASE anywhere"

# --- 2. reuse: a second run must not churn credentials ----------------------
cp "$M" "${W}/first.json"
run_script "$W"
if jq -e --slurpfile a "${W}/first.json" '.users == $a[0].users' "$M" >/dev/null 2>&1; then
  ok "second run reuses the existing credentials (consumers keep working)"
else
  bad "second run regenerated credentials — every consumer holding one would break"
fi

# --- 3. fail closed --------------------------------------------------------
# The regression this replaces: every statement ended in `|| true`, so a
# rejected CREATE USER produced a healthy-looking add-on with a credential
# nobody could use.
W2=$(mktemp -d); trap 'rm -rf "$W" "$W2"' EXIT
run_script "$W2" "CREATE USER"
RC2=$(cat "${W2}/rc")
[[ "$RC2" -ne 0 ]] && ok "a rejected CREATE USER stops the add-on (exit ${RC2})" \
  || bad "a rejected CREATE USER was swallowed — exit 0, fail-open regression"
grep -q "NOK" "${W2}/out.log" && ok "…and it says so, via bashio::exit.nok" || bad "failed without saying why"

W3=$(mktemp -d); trap 'rm -rf "$W" "$W2" "$W3"' EXIT
run_script "$W3" "GRANT ALL ON gd_data"
[[ "$(cat "${W3}/rc")" -ne 0 ]] && ok "a rejected GRANT stops the add-on" \
  || bad "a rejected GRANT was swallowed — a user would exist with no access"

echo
if [[ "$fails" -gt 0 ]]; then echo "=== ${fails} failure(s) ==="; exit 1; fi
echo "=== all provisioning assertions green ==="
