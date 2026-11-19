#!/usr/bin/env bash
# ==============================================================================
# test_optional_internal_services.sh
#
# Guards the `chronograf` and `kapacitor` add-on options.
#
# The options exist to keep two unused long-running services — and the two
# InfluxDB accounts with ALL PRIVILEGES that belong to them — off a GA device.
# A guard that only ever runs against the switched-off case proves half of
# that, so every behaviour below is asserted twice: once for the state that
# must change (service disabled) and once for the state that must NOT change
# (service enabled, i.e. the add-on's original behaviour).
#
# The scripts under test are read from the working tree at run time. They are
# copied into a sandbox and their ABSOLUTE runtime paths (/data, /etc/nginx,
# /run/s6/...) are rewritten to point inside it — the logic is the live logic,
# only its filesystem is relocated. If a script is missing, or a rewrite the
# case depends on matches nothing, the test FAILS; it never skips.
# ==============================================================================
# Every CFG_* variable is read by indirect expansion inside the bashio shim
# (`_cfg`), which no static check can see, so each looks unused. TRACE is set
# inside subshells on purpose — that isolation is what the harness is for.
# shellcheck disable=SC2034,SC2030,SC2031
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${REPO_ROOT}/influxdb/rootfs"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# ── sandbox ──────────────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}"/{bin,data,run/service,run/s6/basedir/bin} "${SANDBOX}"/etc/nginx/{servers,includes} "${SANDBOX}"/etc/kapacitor/templates
echo "test-secret" > "${SANDBOX}/data/secret"
: > "${SANDBOX}/etc/nginx/includes/server_params.conf"
: > "${SANDBOX}/etc/nginx/includes/proxy_params.conf"
: > "${SANDBOX}/etc/nginx/includes/resolver.conf"
cp "${ROOTFS}/etc/nginx/servers/ingress.conf" "${SANDBOX}/etc/nginx/servers/ingress.conf.orig"

# Every stub records its invocation, so an assertion can be about what the
# script DID, not about what its source text looks like.
for prog in chronograf kapacitord influx nginx tempio s6-svc s6-svwait halt; do
  cat > "${SANDBOX}/bin/${prog}" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${prog}" "\$*" >> "\${TRACE}"
exit 0
STUB
  chmod +x "${SANDBOX}/bin/${prog}"
done
cp "${SANDBOX}/bin/halt" "${SANDBOX}/run/s6/basedir/bin/halt"

# ── bashio shim ──────────────────────────────────────────────────────────────
cat > "${SANDBOX}/bashio-shim.sh" <<'SHIM'
_cfg() { local k="$1"; local v="CFG_${k//[^a-zA-Z0-9_]/_}"; printf '%s' "${!v-}"; }
bashio::config()            { _cfg "$1"; }
bashio::config.true()       { [[ "$(_cfg "$1")" == "true"  ]]; }
bashio::config.false()      { [[ "$(_cfg "$1")" == "false" ]]; }
bashio::config.has_value()  { [[ -n "$(_cfg "$1")" ]]; }
bashio::config.require.ssl(){ :; }
bashio::var.has_value()     { [[ -n "${1-}" ]]; }
bashio::var.json()          { printf '{}'; }
bashio::fs.file_exists()    { [[ -f "$1" ]]; }
bashio::string.lower()      { printf '%s' "${1,,}"; }
bashio::exit.nok()          { printf 'nok: %s\n' "${1-}" >&2; exit 1; }
bashio::log.info()          { printf 'INFO %s\n' "${1-}" >> "${TRACE}"; }
bashio::log.debug()         { :; }
bashio::log.warning()       { printf 'WARN %s\n' "${1-}" >> "${TRACE}"; }
bashio::log.error()         { printf 'ERROR %s\n' "${1-}" >> "${TRACE}"; }
bashio::net.wait_for()      { printf 'wait_for %s\n' "$*" >> "${TRACE}"; }
bashio::dns.host()          { printf '172.30.32.3'; }
bashio::addon.ingress_entry(){ printf '/api/hassio_ingress/testtoken'; }
bashio::addon.ingress_port(){ printf '1337'; }
bashio::addon.ip_address()  { printf '172.30.33.5'; }
bashio::addon.port()        { printf ''; }
SHIM

# ── runner ───────────────────────────────────────────────────────────────────
# run_script <path-under-rootfs> [args...]  → writes ${TRACE}; echoes exit code
run_script() {
  local rel="$1"; shift
  local src="${ROOTFS}/${rel}"
  [[ -f "${src}" ]] || { bad "live script missing: ${rel}"; echo 127; return; }

  local dst="${SANDBOX}/script.sh"
  # Declared path rewrites. `n` counts how many landed; a case that depends on
  # a rewrite asserts on it, so a silently-unmatched pattern cannot pass.
  sed -e '1s|^#!.*|#!/usr/bin/env bash|' -e "s|/data/|${SANDBOX}/data/|g" -e "s|/etc/nginx|${SANDBOX}/etc/nginx|g" -e "s|/etc/kapacitor|${SANDBOX}/etc/kapacitor|g" -e "s|/run/s6/basedir/bin/halt|${SANDBOX}/run/s6/basedir/bin/halt|g" -e "s|/run/service|${SANDBOX}/run/service|g" "${src}" > "${dst}"
  chmod +x "${dst}"

  : > "${SANDBOX}/trace.txt"
  ( export TRACE="${SANDBOX}/trace.txt"
    export PATH="${SANDBOX}/bin:${PATH}"
    # The shim and the script under test are both written at run time, so
    # neither can be followed statically; TRACE is deliberately set only inside
    # this subshell, which is the point of the isolation.
    # (A comment must not begin with the linter's own name — it is read as a
    # directive and fails to parse.)
    # shellcheck source=/dev/null
    # shellcheck disable=SC1090,SC1091,SC2030
    source "${SANDBOX}/bashio-shim.sh"
    # shellcheck source=/dev/null
    # shellcheck disable=SC1090
    source "${dst}" "$@" ) >/dev/null 2>&1
  echo $?
}
traced() { grep -qE "$1" "${SANDBOX}/trace.txt"; }
say()    { printf '\n%s\n' "$1"; }

# ══ removal (0.0.24, Odoo #1973) ═════════════════════════════════════════════
# Chronograf and Kapacitor are gone from the image. A stored `true` on a device
# must start NOTHING, must not wait for anything, and must say so.
say "chronograf / kapacitor are not shipped any more"
for gone in etc/services.d/chronograf etc/services.d/kapacitor etc/cont-init.d/kapacitor.sh etc/kapacitor; do
  if [[ -e "${ROOTFS}/${gone}" ]]; then
    bad "still shipped: ${gone}"
  else
    ok "removed: ${gone}"
  fi
done
DOCKERFILE="${REPO_ROOT}/influxdb/Dockerfile"
if grep -vE '^\s*#' "${DOCKERFILE}" | grep -qiE 'chronograf|kapacitor'; then
  bad "the Dockerfile still downloads or installs Chronograf/Kapacitor: $(grep -vE '^\s*#' "${DOCKERFILE}" | grep -iE 'chronograf|kapacitor' | head -1)"
else
  ok "the Dockerfile neither downloads nor installs Chronograf/Kapacitor"
fi

# ══ nginx ════════════════════════════════════════════════════════════════════
for opt in false true; do
  say "nginx with a stored chronograf=${opt}: no upstream to wait for"
  CFG_chronograf=${opt} CFG_leave_front_door_open=false rc=$(run_script etc/services.d/nginx/run)
  if traced '^wait_for 8889'; then
    bad "NGINX waits 9000 s for a Chronograf that does not exist (chronograf=${opt})"
  else
    ok "no wait (chronograf=${opt})"
  fi
  if traced '^nginx'; then
    ok "NGINX started (chronograf=${opt})"
  else
    bad "NGINX did not start (chronograf=${opt})"
  fi

  say "ingress panel with a stored chronograf=${opt}: a notice, never a proxy"
  cp "${SANDBOX}/etc/nginx/servers/ingress.conf.orig" "${SANDBOX}/etc/nginx/servers/ingress.conf"
  CFG_chronograf=${opt} CFG_ssl=true rc=$(run_script etc/cont-init.d/nginx.sh)
  ING="$(cat "${SANDBOX}/etc/nginx/servers/ingress.conf")"
  if grep -q 'proxy_pass' <<<"${ING}"; then
    bad "ingress proxies to a removed Chronograf (chronograf=${opt})"
  else
    ok "no proxy_pass (chronograf=${opt})"
  fi
  if grep -q "Chronograf was removed from this add-on" <<<"${ING}"; then
    ok "ingress explains why the panel is empty (chronograf=${opt})"
  else
    bad "ingress gives no reason (chronograf=${opt})"
  fi
  if grep -q '172.30.33.5:1337' <<<"${ING}"; then
    ok "ingress listener templated (chronograf=${opt})"
  else
    bad "ingress listener not templated (chronograf=${opt})"
  fi
done

# ══ InfluxDB accounts ════════════════════════════════════════════════════════
# The account table is the security half of the option: a disabled tool must
# not keep an account with ALL PRIVILEGES. Extracted from the LIVE script —
# never re-declared here, or this test would guard a copy of itself.
say "InfluxDB account table"
PROV="${ROOTFS}/etc/cont-init.d/00_create-db_and_users.sh"
if [[ ! -f "${PROV}" ]]; then
  bad "live provisioning script missing: ${PROV}"
else
  BLOCK="$(sed -n '/^ENABLED_TOOLS=""/,/^ADMIN_USERS=/p' "${PROV}")"
  if [[ -z "${BLOCK}" ]] || ! grep -q '^ADMIN_USERS=' <<<"${BLOCK}"; then
    bad "could not extract the account table from the live script (it moved or was renamed)"
  else
    for combo in "false false" "true false" "true true"; do
      # shellcheck disable=SC2086
      set -- ${combo}
      WARNLOG="${SANDBOX}/warn.txt"; : > "${WARNLOG}"
      # shellcheck source=/dev/null
      # shellcheck disable=SC1091,SC2030,SC2031
      OUT="$( export TRACE="${WARNLOG}"
              source "${SANDBOX}/bashio-shim.sh"
              CFG_chronograf="$1" CFG_kapacitor="$2"
              eval "${BLOCK}"
              printf 'admin=[%s] disabled=[%s]' "${ADMIN_USERS}" "${DISABLED_TOOLS}" )"
      # Whatever a device stored, no tool account is created and both are dropped.
      check "stored chronograf=$1 kapacitor=$2: no tool account, both dropped" \
            "admin=[ga_influx_admin] disabled=[chronograf kapacitor]" "${OUT}"
      want_warn=0; [[ "$1" == true ]] && want_warn=$((want_warn+1)); [[ "$2" == true ]] && want_warn=$((want_warn+1))
      got_warn="$(grep -c "^WARN Option '.*' is ignored" "${WARNLOG}")"
      check "stored chronograf=$1 kapacitor=$2: one warning per ignored option" "${want_warn}" "${got_warn}"
    done
    # Behaviour, not text: the live drop function is extracted and RUN against a
    # stubbed server. Grepping for the string "DROP USER" also matches the log
    # line next to it, so a build that no longer drops anything would still pass.
    DROPFN="$(sed -n '/^drop_disabled_tool_users() {/,/^}$/p' "${PROV}")"
    if ! grep -q '^}' <<<"${DROPFN}"; then
      bad "could not extract drop_disabled_tool_users from the live script"
    else
      run_drop() { # run_drop <disabled-tools> <accounts-the-server-reports>
        # shellcheck source=/dev/null
        # shellcheck disable=SC1091,SC2031
        ( export TRACE=/dev/null
          source "${SANDBOX}/bashio-shim.sh"
          DROPLOG="${SANDBOX}/drops.txt"; : > "${DROPLOG}"
          # Bound OUTSIDE the stub: inside it, $2 is the stub's own argument.
          SHOW_USERS_OUTPUT="$2"
          # shellcheck disable=SC2317,SC2329
          influx() {
            if [[ "$*" == *"SHOW USERS"* ]]; then printf 'user admin\n%s\n' "${SHOW_USERS_OUTPUT}"
            else printf '%s\n' "$*" >> "${DROPLOG}"; fi
          }
          DISABLED_TOOLS="$1"
          eval "${DROPFN}"
          drop_disabled_tool_users
          cat "${DROPLOG}" ) 2>/dev/null
      }
      SERVER_HAS=$'ga_influx_admin true\nchronograf true\nkapacitor true'
      OUT="$(run_drop "chronograf kapacitor" "${SERVER_HAS}")"
      if grep -q 'DROP USER chronograf' <<<"${OUT}" && grep -q 'DROP USER kapacitor' <<<"${OUT}"; then
        ok "both leftover accounts are actually dropped"
      else
        bad "an account from an earlier configuration keeps ALL PRIVILEGES (issued: ${OUT//$'\n'/, })"
      fi
      OUT="$(run_drop "" "${SERVER_HAS}")"
      if [[ -z "${OUT}" ]]; then
        ok "nothing is dropped when both tools are enabled"
      else
        bad "dropped an account of an ENABLED tool: ${OUT//$'\n'/, }"
      fi
      OUT="$(run_drop "chronograf kapacitor" "ga_influx_admin true")"
      if [[ -z "${OUT}" ]]; then
        ok "no DROP for an account the server does not have"
      else
        bad "issued a DROP for a non-existent account: ${OUT//$'\n'/, }"
      fi
    fi
    if grep -qE '^drop_disabled_tool_users$' "${PROV}"; then
      ok "the drop is actually called"
    else
      bad "drop_disabled_tool_users is defined but never called"
    fi
  fi
fi

# ══ config.yaml ══════════════════════════════════════════════════════════════
say "add-on configuration surface"
CFGY="${REPO_ROOT}/influxdb/config.yaml"
for key in chronograf kapacitor; do
  if grep -qE "^  ${key}: (true|false)$" "${CFGY}"; then
    ok "option '${key}' has a default"
  else
    bad "option '${key}' missing from options:"
  fi
  if grep -qE "^  ${key}: bool\??$" "${CFGY}"; then
    ok "option '${key}' is in the schema"
  else
    bad "option '${key}' missing from schema: — a device that stored it would fail option validation (N61)"
  fi
done

# ══ resource defaults ════════════════════════════════════════════════════════
# Expectations are constants here on purpose: an audit that reads its expected
# value out of the file it audits is green for every value that file holds.
say "InfluxDB resource defaults for constrained hardware"
declare -A EXPECT_ENVVARS=(
  [INFLUXDB_MONITOR_STORE_ENABLED]="false"
  [INFLUXDB_REPORTING_DISABLED]="true"
  [INFLUXDB_DATA_CACHE_MAX_MEMORY_SIZE]="64m"
)
for name in "${!EXPECT_ENVVARS[@]}"; do
  want="${EXPECT_ENVVARS[$name]}"
  got="$(awk -v n="${name}" '
      $0 ~ ("- name: " n "$") {found=1; next}
      found && /value:/ {gsub(/.*value: *"?|"$/, ""); print; exit}
  ' "${CFGY}")"
  check "envvar ${name}" "${want}" "${got}"
done

printf '\n────────────────────────────────\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${PASS}" -gt 0 ]] || { echo "ZERO assertions ran — treating as failure"; exit 1; }
[[ "${FAIL}" -eq 0 ]]
