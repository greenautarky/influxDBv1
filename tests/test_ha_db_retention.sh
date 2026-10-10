#!/usr/bin/env bash
# ==============================================================================
# test_ha_db_retention.sh — ga_homeassistant_db gets a bounded retention from
# the option, gd_data never does, and a failed ALTER is loud.
#
# The functions under test are EXTRACTED from the live init script at run time
# (never copied here); the extraction fails the test when it finds nothing.
# `influx` is a stub that records every statement and answers SHOW RETENTION
# POLICIES with an autogen policy.
# ==============================================================================
# Stubs are called indirectly (from the sourced functions), which shellcheck
# cannot see; the A && B || C lines report ok/bad and both are side-effect only.
# shellcheck disable=SC2317,SC2015
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/influxdb/rootfs/etc/cont-init.d/00_create-db_and_users.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
extract() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$SCRIPT"; }
for fn in set_retention_policy apply_ha_db_retention; do
  body="$(extract "$fn")"
  [ -n "$body" ] || { echo "FAIL: function $fn not found in $SCRIPT"; exit 1; }
  printf '%s\n' "$body" >> "$W/funcs.sh"
done
# ...and the script must actually CALL it, not only define it.
grep -qE '^apply_ha_db_retention[[:space:]]*$' "$SCRIPT" && ok "init script calls apply_ha_db_retention" || bad "init script never calls apply_ha_db_retention"

run() {  # run <option value or __unset__> [influx exit code for ALTER]
  local opt="$1" alter_rc="${2:-0}"
  : > "$W/trace"
  (
    influx() {
      echo "influx $*" >> "$W/trace"
      case "$*" in
        *"SHOW RETENTION POLICIES"*) printf 'name\tduration\nautogen\t0s\n' ;;
        *ALTER*) return "$alter_rc" ;;
      esac
    }
    bashio::config() { [ "$opt" = __unset__ ] || printf '%s' "$opt"; }
    bashio::log.info() { echo "INFO $*" >> "$W/trace"; }
    bashio::log.warning() { echo "WARN $*" >> "$W/trace"; }
    bashio::log.error() { echo "ERROR $*" >> "$W/trace"; }
    # shellcheck disable=SC1091
    . "$W/funcs.sh"
    apply_ha_db_retention
  )
}
alter() { grep -c 'ALTER RETENTION POLICY autogen ON ga_homeassistant_db DURATION '"$1"' ' "$W/trace"; }

run __unset__; [ "$(alter 90d)" = 1 ] && ok "default: ga_homeassistant_db -> 90d" || bad "default did not ALTER to 90d: $(cat "$W/trace")"
run 30d;       [ "$(alter 30d)" = 1 ] && ok "option 30d applied" || bad "30d not applied"
run INF;       [ "$(alter INF)" = 1 ] && ok "option INF switches retention off" || bad "INF not applied"
run 3x;        { ! grep -q ALTER "$W/trace" && grep -q '^WARN .*3x' "$W/trace"; } && ok "invalid value: no ALTER, warning logged" || bad "invalid value handled wrongly: $(cat "$W/trace")"
run "90d; DROP DATABASE gd_data"; ! grep -q '^influx .*DROP' "$W/trace" && ok "injection-shaped value refused" || bad "injection reached influx"
run 90d 1;     grep -q '^ERROR .*FAILED' "$W/trace" && ok "a failed ALTER is logged at error" || bad "failed ALTER was silent"
for v in __unset__ 30d INF; do run "$v"; done
grep -rq 'ON gd_data' "$W/trace" && bad "gd_data was touched" || ok "gd_data never gets a retention"

echo "pass=$PASS fail=$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
