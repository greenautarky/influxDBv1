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

# ══ chronograf ═══════════════════════════════════════════════════════════════
say "chronograf disabled  (the behaviour this option exists for)"
CFG_chronograf=false CFG_kapacitor=false CFG_reporting=true rc=$(run_script etc/services.d/chronograf/run)
if traced '^s6-svc -O .*/run/service/chronograf$'; then
  ok "s6-svc -O keeps the service down"
else
  bad "s6-svc -O was not called — the supervisor would restart it in a loop"
fi
if traced '^chronograf '; then
  bad "chronograf was started anyway"
else
  ok "chronograf binary not executed"
fi

say "chronograf enabled   (must-pass: original behaviour intact)"
CFG_chronograf=true CFG_kapacitor=true CFG_reporting=true rc=$(run_script etc/services.d/chronograf/run)
if traced '^chronograf .*--influxdb-url=http://localhost:8086'; then
  ok "chronograf started with its InfluxDB URL"
else
  bad "chronograf did not start when enabled"
fi
if traced '^s6-svc -O'; then
  bad "service was taken down although enabled"
else
  ok "service not taken down"
fi

say "chronograf enabled, kapacitor disabled"
CFG_chronograf=true CFG_kapacitor=false CFG_reporting=true rc=$(run_script etc/services.d/chronograf/run)
if traced '^chronograf .*--kapacitor-url'; then
  bad "--kapacitor-url passed to a Kapacitor that is off"
else
  ok "no --kapacitor-url when Kapacitor is off"
fi
if traced '^s6-svwait .*kapacitor'; then
  bad "waited for a Kapacitor that never starts"
else
  ok "no s6-svwait on a disabled Kapacitor"
fi

say "chronograf finish"
CFG_chronograf=false rc=$(run_script etc/services.d/chronograf/finish 1)
check "clean exit when disabled (exit 1 must not halt the add-on)" "0" "${rc}"
if traced 'halt'; then
  bad "add-on halted although the service was switched off"
else
  ok "add-on not halted"
fi
CFG_chronograf=true rc=$(run_script etc/services.d/chronograf/finish 1)
if traced 'halt'; then
  ok "a real crash still halts the add-on when enabled"
else
  bad "crash handling lost — a crashed Chronograf no longer halts the add-on"
fi

# ══ kapacitor ════════════════════════════════════════════════════════════════
say "kapacitor disabled"
CFG_kapacitor=false rc=$(run_script etc/services.d/kapacitor/run)
if traced '^s6-svc -O .*/run/service/kapacitor$'; then
  ok "s6-svc -O keeps the service down"
else
  bad "s6-svc -O was not called"
fi
if traced '^kapacitord'; then
  bad "kapacitord was started anyway"
else
  ok "kapacitord not executed"
fi

say "kapacitor enabled    (must-pass)"
CFG_kapacitor=true rc=$(run_script etc/services.d/kapacitor/run)
if traced '^kapacitord'; then
  ok "kapacitord started"
else
  bad "kapacitord did not start when enabled"
fi

say "kapacitor configuration (cont-init)"
CFG_kapacitor=false CFG_reporting=true rc=$(run_script etc/cont-init.d/kapacitor.sh)
check "cont-init exits 0 when disabled" "0" "${rc}"
if traced '^tempio'; then
  bad "kapacitor.conf rendered although disabled"
else
  ok "kapacitor.conf not rendered"
fi
CFG_kapacitor=true CFG_reporting=true rc=$(run_script etc/cont-init.d/kapacitor.sh)
if traced '^tempio'; then
  ok "kapacitor.conf rendered when enabled"
else
  bad "kapacitor.conf not rendered when enabled"
fi

# ══ nginx ════════════════════════════════════════════════════════════════════
say "nginx must not block on an upstream that never comes up"
CFG_chronograf=false CFG_leave_front_door_open=false rc=$(run_script etc/services.d/nginx/run)
if traced '^wait_for 8889'; then
  bad "NGINX waits 9000 s for a disabled Chronograf"
else
  ok "no wait when disabled"
fi
if traced '^nginx'; then
  ok "NGINX started"
else
  bad "NGINX did not start"
fi
CFG_chronograf=true CFG_leave_front_door_open=false rc=$(run_script etc/services.d/nginx/run)
if traced '^wait_for 8889'; then
  ok "NGINX still waits for Chronograf when enabled"
else
  bad "wait lost when enabled"
fi

say "ingress panel answers instead of proxying to a dead port"
cp "${SANDBOX}/etc/nginx/servers/ingress.conf.orig" "${SANDBOX}/etc/nginx/servers/ingress.conf"
CFG_chronograf=false CFG_ssl=true rc=$(run_script etc/cont-init.d/nginx.sh)
ING="$(cat "${SANDBOX}/etc/nginx/servers/ingress.conf")"
if grep -q 'proxy_pass' <<<"${ING}"; then
  bad "ingress still proxies to a stopped Chronograf"
else
  ok "no proxy_pass when Chronograf is off"
fi
if grep -q "switched off by the add-on option" <<<"${ING}"; then
  ok "ingress explains why the panel is empty"
else
  bad "ingress gives no reason"
fi
cp "${SANDBOX}/etc/nginx/servers/ingress.conf.orig" "${SANDBOX}/etc/nginx/servers/ingress.conf"
CFG_chronograf=true CFG_ssl=true rc=$(run_script etc/cont-init.d/nginx.sh)
if grep -q 'proxy_pass http://backend' "${SANDBOX}/etc/nginx/servers/ingress.conf"; then
  ok "ingress proxies normally when enabled"
else
  bad "ingress proxy lost when enabled"
fi
if grep -q '172.30.33.5:1337' "${SANDBOX}/etc/nginx/servers/ingress.conf"; then
  ok "ingress listener still templated"
else
  bad "ingress listener not templated"
fi

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
      # shellcheck source=/dev/null
      # shellcheck disable=SC1091,SC2030,SC2031
      OUT="$( export TRACE=/dev/null
              source "${SANDBOX}/bashio-shim.sh"
              CFG_chronograf="$1" CFG_kapacitor="$2"
              eval "${BLOCK}"
              printf 'admin=[%s] disabled=[%s]' "${ADMIN_USERS}" "${DISABLED_TOOLS}" )"
      case "${combo}" in
        "false false") check "both off"        "admin=[ga_influx_admin] disabled=[chronograf kapacitor]" "${OUT}" ;;
        "true false")  check "chronograf only" "admin=[ga_influx_admin chronograf] disabled=[kapacitor]" "${OUT}" ;;
        "true true")   check "both on"         "admin=[ga_influx_admin chronograf kapacitor] disabled=[]" "${OUT}" ;;
      esac
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
          # shellcheck disable=SC2317
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
    bad "option '${key}' missing from schema: — the Supervisor would drop it"
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
