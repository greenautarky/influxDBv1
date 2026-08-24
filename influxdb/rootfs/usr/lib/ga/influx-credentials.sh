#!/usr/bin/env bash
# Read one consumer's credential out of the add-on-private manifest.
#
# ONE reader, sourced by every service that needs a credential. The previous
# model had each service open /data/secret itself, which is why the per-user
# work stalled: the file was deleted by the new provisioning path and three
# services still read it, so flipping the mode would have left Chronograf and
# Kapacitor authenticating with an empty password against an auth-enabled
# InfluxDB — and their wait loops would have reported "done waiting, starting
# anyway" rather than failing.
#
# Fails loudly. A credential that could not be read is not an empty password.

GA_INFLUX_MANIFEST="${GA_INFLUX_MANIFEST:-/data/influx-users.json}"

ga_influx_password() {
    local user="$1" pw
    if [[ ! -f "${GA_INFLUX_MANIFEST}" ]]; then
        bashio::log.error "credential manifest ${GA_INFLUX_MANIFEST} is missing"
        bashio::exit.nok "cannot start ${user} consumer without its credential"
    fi
    pw="$(jq -r --arg u "${user}" '.users[$u].password // empty' "${GA_INFLUX_MANIFEST}")"
    if [[ -z "${pw}" ]]; then
        bashio::log.error "no credential for '${user}' in ${GA_INFLUX_MANIFEST}"
        bashio::exit.nok "cannot start ${user} consumer without its credential"
    fi
    printf '%s' "${pw}"
}
