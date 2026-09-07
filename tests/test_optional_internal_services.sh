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
mkdir -p "${SANDBOX}"/{bin,data,run/service,run/s6/basedir/bin} \
         "${SANDBOX}"/etc/nginx/{servers,includes} \
         "${SANDBOX}"/etc/kapacitor/templates
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
  sed -e '1s|^#!.*|#!/usr/bin/env bash|' \
      -e "s|/data/|${SANDBOX}/data/|g" \
      -e "s|/etc/nginx|${SANDBOX}/etc/nginx|g" \
      -e "s|/etc/kapacitor|${SANDBOX}/etc/kapacitor|g" \
      -e "s|/run/s6/basedir/bin/halt|${SANDBOX}/run/s6/basedir/bin/halt|g" \
      -e "s|/run/service|${SANDBOX}/run/service|g" \
      "${src}" > "${dst}"
  chmod +x "${dst}"

  TRACE="${SANDBOX}/trace.txt" : > "${SANDBOX}/trace.txt"
  ( export TRACE="${SANDBOX}/trace.txt"
    export PATH="${SANDBOX}/bin:${PATH}"
    # shellcheck disable=SC1090
    source "${SANDBOX}/bashio-shim.sh"
    source "${dst}" "$@" ) >/dev/null 2>&1
  echo $?
}
traced() { grep -qE "$1" "${SANDBOX}/trace.txt"; }
say()    { printf '\n%s\n' "$1"; }

# ══ chronograf ═══════════════════════════════════════════════════════════════
say "chronograf disabled  (the behaviour this option exists for)"
CFG_chronograf=false CFG_kapacitor=false CFG_reporting=true \
  rc=$(run_script etc/services.d/chronograf/run)
traced '^s6-svc -O .*/run/service/chronograf$' && ok "s6-svc -O keeps the service down" \
  || bad "s6-svc -O was not called — the supervisor would restart it in a loop"
traced '^chronograf ' && bad "chronograf was started anyway" || ok "chronograf binary not executed"

say "chronograf enabled   (must-pass: original behaviour intact)"
CFG_chronograf=true CFG_kapacitor=true CFG_reporting=true \
  rc=$(run_script etc/services.d/chronograf/run)
traced '^chronograf .*--influxdb-url=http://localhost:8086' && ok "chronograf started with its InfluxDB URL" \
  || bad "chronograf did not start when enabled"
traced '^s6-svc -O' && bad "service was taken down although enabled" || ok "service not taken down"

say "chronograf enabled, kapacitor disabled"
CFG_chronograf=true CFG_kapacitor=false CFG_reporting=true \
  rc=$(run_script etc/services.d/chronograf/run)
traced '^chronograf .*--kapacitor-url' && bad "--kapacitor-url passed to a Kapacitor that is off" \
  || ok "no --kapacitor-url when Kapacitor is off"
traced '^s6-svwait .*kapacitor' && bad "waited for a Kapacitor that never starts" \
  || ok "no s6-svwait on a disabled Kapacitor"

say "chronograf finish"
CFG_chronograf=false rc=$(run_script etc/services.d/chronograf/finish 1)
check "clean exit when disabled (exit 1 must not halt the add-on)" "0" "${rc}"
traced 'halt' && bad "add-on halted although the service was switched off" || ok "add-on not halted"
CFG_chronograf=true rc=$(run_script etc/services.d/chronograf/finish 1)
traced 'halt' && ok "a real crash still halts the add-on when enabled" \
  || bad "crash handling lost — a crashed Chronograf no longer halts the add-on"

# ══ kapacitor ════════════════════════════════════════════════════════════════
say "kapacitor disabled"
CFG_kapacitor=false rc=$(run_script etc/services.d/kapacitor/run)
traced '^s6-svc -O .*/run/service/kapacitor$' && ok "s6-svc -O keeps the service down" \
  || bad "s6-svc -O was not called"
traced '^kapacitord' && bad "kapacitord was started anyway" || ok "kapacitord not executed"

say "kapacitor enabled    (must-pass)"
CFG_kapacitor=true rc=$(run_script etc/services.d/kapacitor/run)
traced '^kapacitord' && ok "kapacitord started" || bad "kapacitord did not start when enabled"

say "kapacitor configuration (cont-init)"
CFG_kapacitor=false CFG_reporting=true rc=$(run_script etc/cont-init.d/kapacitor.sh)
check "cont-init exits 0 when disabled" "0" "${rc}"
traced '^tempio' && bad "kapacitor.conf rendered although disabled" || ok "kapacitor.conf not rendered"
CFG_kapacitor=true CFG_reporting=true rc=$(run_script etc/cont-init.d/kapacitor.sh)
traced '^tempio' && ok "kapacitor.conf rendered when enabled" || bad "kapacitor.conf not rendered when enabled"

# ══ nginx ════════════════════════════════════════════════════════════════════
say "nginx must not block on an upstream that never comes up"
CFG_chronograf=false CFG_leave_front_door_open=false rc=$(run_script etc/services.d/nginx/run)
traced '^wait_for 8889' && bad "NGINX waits 9000 s for a disabled Chronograf" || ok "no wait when disabled"
traced '^nginx' && ok "NGINX started" || bad "NGINX did not start"
CFG_chronograf=true CFG_leave_front_door_open=false rc=$(run_script etc/services.d/nginx/run)
traced '^wait_for 8889' && ok "NGINX still waits for Chronograf when enabled" || bad "wait lost when enabled"

say "ingress panel answers instead of proxying to a dead port"
cp "${SANDBOX}/etc/nginx/servers/ingress.conf.orig" "${SANDBOX}/etc/nginx/servers/ingress.conf"
CFG_chronograf=false CFG_ssl=true rc=$(run_script etc/cont-init.d/nginx.sh)
ING="$(cat "${SANDBOX}/etc/nginx/servers/ingress.conf")"
grep -q 'proxy_pass' <<<"${ING}" && bad "ingress still proxies to a stopped Chronograf" \
  || ok "no proxy_pass when Chronograf is off"
grep -q "switched off by the add-on option" <<<"${ING}" && ok "ingress explains why the panel is empty" \
  || bad "ingress gives no reason"
cp "${SANDBOX}/etc/nginx/servers/ingress.conf.orig" "${SANDBOX}/etc/nginx/servers/ingress.conf"
CFG_chronograf=true CFG_ssl=true rc=$(run_script etc/cont-init.d/nginx.sh)
grep -q 'proxy_pass http://backend' "${SANDBOX}/etc/nginx/servers/ingress.conf" \
  && ok "ingress proxies normally when enabled" || bad "ingress proxy lost when enabled"
grep -q '172.30.33.5:1337' "${SANDBOX}/etc/nginx/servers/ingress.conf" \
  && ok "ingress listener still templated" || bad "ingress listener not templated"

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
      set -- ${combo}
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
    grep -q 'DROP USER' "${PROV}" && ok "a leftover account is dropped, not just skipped" \
      || bad "no DROP USER — an account from an earlier configuration keeps ALL PRIVILEGES"
    grep -q 'drop_disabled_tool_users$' "${PROV}" && ok "the drop is actually called" \
      || bad "drop_disabled_tool_users is defined but never called"
  fi
fi

# ══ config.yaml ══════════════════════════════════════════════════════════════
say "add-on configuration surface"
CFGY="${REPO_ROOT}/influxdb/config.yaml"
for key in chronograf kapacitor; do
  grep -qE "^  ${key}: (true|false)$" "${CFGY}" && ok "option '${key}' has a default" \
    || bad "option '${key}' missing from options:"
  grep -qE "^  ${key}: bool\??$" "${CFGY}" && ok "option '${key}' is in the schema" \
    || bad "option '${key}' missing from schema: — the Supervisor would drop it"
done

printf '\n────────────────────────────────\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${PASS}" -gt 0 ]] || { echo "ZERO assertions ran — treating as failure"; exit 1; }
[[ "${FAIL}" -eq 0 ]]
