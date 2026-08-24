#!/command/with-contenv bashio
# ==============================================================================
# GreenAutarky InfluxDB add-on — database + credential provisioning
#
# ONE USER PER CONSUMER. No shared secret, no file under /share.
#
# This replaced a model in which five users shared a single password derived
# from a slice of the Supervisor token, every one of them WITH ALL PRIVILEGES,
# mirrored in clear text to /share/influxdb_password.yaml — a live admin
# credential on the add-on<->host bridge, readable by every `share:rw` add-on.
# Measured on a device 2026-08-18; the decision to cut rather than migrate is
# recorded in Odoo #682 (all devices are being replaced, so the new major only
# has to be right for NEW devices).
#
# HOW IT WORKS
#   Each consumer gets its own user with its own random password and grants on
#   only the databases it uses. The passwords live in /data/influx-users.json
#   (0600, add-on private), which is also the hand-off point: ga_manager reads
#   it and delivers each consumer its own credential into that consumer's own
#   add-on options. Nothing is written where another add-on can read it.
#
#   Passwords persist across restarts because consumers hold them; regenerating
#   on every start would silently break every consumer that cached one. A
#   rotation is therefore an explicit act: delete the file and restart.
#
# FAIL CLOSED
#   Every InfluxQL statement here is checked. The previous version ended each
#   one with `|| true`, so a failed CREATE USER or SET PASSWORD was invisible —
#   the add-on came up looking healthy with a credential nobody could use, and
#   the consumers only discovered it at their next write. A provisioning step
#   that did not succeed now stops the add-on.
# ==============================================================================

USERS_JSON="/data/influx-users.json"
LEGACY_SECRET="/data/secret"
LEGACY_SHARE_SECRET="/share/influxdb_password.yaml"
INFLUX_HOST="99f1cad4-ga-influxdbv1"
INFLUX_PORT=8086

# The consumer table IS the design. Adding a consumer means adding a row here
# and nothing else: the manifest, the user, and the grants all derive from it.
#
#   <user>|<comma-separated databases, or ADMIN>|<what reads it>
CONSUMERS=(
    "ga_ha_influx_user|ga_homeassistant_db|Home Assistant Core recorder"
    "ga_default|gd_data,pd_data|ga_default_addon"
    "ga_influx_admin|ADMIN|operator / maintenance"
    "chronograf|ADMIN|bundled Chronograf UI"
    "kapacitor|ADMIN|bundled Kapacitor"
)

# Users this add-on used to create and no longer does. They are DROPPED rather
# than left alone: an abandoned user keeps its old password and, in the previous
# model, ALL PRIVILEGES — a credential nobody owns is worse than no credential.
RETIRED_USERS=(ga_telegraf)

# Alphanumeric only → safe inside InfluxQL single-quoted strings and in the
# plain extraction consumers use, so no quoting rules travel downstream.
gen_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
}

declare -A USER_PW
declare -A USER_DBS

parse_consumers() {
    local row user dbs
    for row in "${CONSUMERS[@]}"; do
        user="${row%%|*}"
        dbs="${row#*|}"; dbs="${dbs%%|*}"
        USER_DBS[$user]="$dbs"
    done
}

# Reuse what is already provisioned, generate only what is missing. Adding a
# consumer later must not churn the credentials the existing ones hold.
load_or_generate_passwords() {
    local user existing
    for user in "${!USER_DBS[@]}"; do
        existing=""
        if bashio::fs.file_exists "${USERS_JSON}"; then
            existing="$(jq -r --arg u "$user" '.users[$u].password // empty' "${USERS_JSON}" 2>/dev/null)"
        fi
        if bashio::var.has_value "${existing}"; then
            USER_PW[$user]="${existing}"
        else
            USER_PW[$user]="$(gen_password)"
            bashio::log.info "Generated a new credential for ${user}"
        fi
    done
}

# The manifest ga_manager reads. `scope` and `databases` describe the grant that
# is actually applied below, so the delivery layer routes on the same facts the
# database enforces rather than on a second, hand-kept list.
write_manifest() {
    local tmp user entry
    tmp="$(mktemp)"
    entry="$(jq -n '{}')"
    for user in "${!USER_DBS[@]}"; do
        if [[ "${USER_DBS[$user]}" == "ADMIN" ]]; then
            entry="$(jq --arg u "$user" --arg p "${USER_PW[$user]}" \
                '.[$u] = {password:$p, databases:[], scope:"admin"}' <<< "$entry")"
        else
            entry="$(jq --arg u "$user" --arg p "${USER_PW[$user]}" --arg d "${USER_DBS[$user]}" \
                '.[$u] = {password:$p, databases:($d|split(",")), scope:"rw"}' <<< "$entry")"
        fi
    done
    jq -n --arg host "${INFLUX_HOST}" --argjson port "${INFLUX_PORT}" --argjson users "$entry" \
        '{version:2, host:$host, port:$port, users:$users}' > "${tmp}" \
        || bashio::exit.nok "could not render ${USERS_JSON}"
    install -m 0600 "${tmp}" "${USERS_JSON}" \
        || bashio::exit.nok "could not install ${USERS_JSON}"
    rm -f "${tmp}"
    bashio::log.info "Wrote per-consumer credential manifest ${USERS_JSON} (0600)"
}

# The two artefacts of the shared-secret model. Both are removed, not merely
# stopped being updated: a stale credential file that still looks live is worse
# than one that is gone, because nothing tells a reader it is dead.
drop_legacy_secret_artifacts() {
    if bashio::fs.file_exists "${LEGACY_SECRET}"; then
        rm -f "${LEGACY_SECRET}" \
            && bashio::log.info "Removed the legacy shared secret ${LEGACY_SECRET}"
    fi
    if bashio::fs.file_exists "${LEGACY_SHARE_SECRET}"; then
        rm -f "${LEGACY_SHARE_SECRET}" \
            && bashio::log.info "Removed the legacy shared secret mirror ${LEGACY_SHARE_SECRET}"
    fi
}

parse_consumers
load_or_generate_passwords
write_manifest
drop_legacy_secret_artifacts

exec 3< <(influxd)

sleep 3

for i in {1800..0}; do
    if influx -execute "SHOW DATABASES" > /dev/null 2>&1; then
        break;
    fi
    bashio::log.info "InfluxDB init process in progress..."
    sleep 5
done

if [[ "$i" = 0 ]]; then
    bashio::exit.nok "InfluxDB init process failed."
fi

# Every statement goes through here. No `|| true`: a provisioning error stops
# the add-on rather than producing a healthy-looking container whose consumers
# cannot authenticate.
influx_exec() {
    local what="$1" stmt="$2" err
    if ! err="$(influx -execute "${stmt}" 2>&1)"; then
        bashio::log.error "${what} failed: ${err}"
        bashio::exit.nok "InfluxDB provisioning failed at: ${what}"
    fi
}

user_exists() {
    influx -execute "SHOW USERS" 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx "$1"
}

create_database() {
    local db="$1"
    if influx -execute "SHOW DATABASES" 2>/dev/null | grep -qx "${db}"; then
        bashio::log.info "Database ${db} already exists"
    else
        bashio::log.info "Creating database ${db}"
        influx_exec "create database ${db}" "CREATE DATABASE ${db}"
    fi
}

set_retention_policy() {
    local db="$1" duration="$2"
    influx_exec "retention policy on ${db}" \
        "ALTER RETENTION POLICY autogen ON ${db} DURATION ${duration} REPLICATION 1 DEFAULT"
}

# Create every database a consumer is granted on, so a least-privileged user
# never needs admin just to create its own database at first write.
for user in "${!USER_DBS[@]}"; do
    [[ "${USER_DBS[$user]}" == "ADMIN" ]] && continue
    IFS=',' read -ra _dbs <<< "${USER_DBS[$user]}"
    for db in "${_dbs[@]}"; do
        create_database "${db}"
    done
done

# Users. Created WITHOUT privileges; admin is granted explicitly below and only
# where the consumer table says so, so a data user cannot quietly become admin
# by being created that way.
for user in "${!USER_DBS[@]}"; do
    if user_exists "${user}"; then
        bashio::log.info "Updating password for ${user}"
        influx_exec "set password for ${user}" "SET PASSWORD FOR ${user} = '${USER_PW[$user]}'"
    else
        bashio::log.info "Creating user ${user}"
        influx_exec "create user ${user}" "CREATE USER ${user} WITH PASSWORD '${USER_PW[$user]}'"
    fi
done

# Grants, straight off the consumer table.
for user in "${!USER_DBS[@]}"; do
    if [[ "${USER_DBS[$user]}" == "ADMIN" ]]; then
        influx_exec "grant admin to ${user}" "GRANT ALL PRIVILEGES TO ${user}"
    else
        IFS=',' read -ra _dbs <<< "${USER_DBS[$user]}"
        for db in "${_dbs[@]}"; do
            influx_exec "grant ${user} on ${db}" "GRANT ALL ON ${db} TO ${user}"
        done
    fi
done

# Retire users this add-on no longer provisions. Dropping a USER destroys no
# data; leaving one behind leaves a credential with the old shared password.
for user in "${RETIRED_USERS[@]}"; do
    if user_exists "${user}"; then
        bashio::log.warning "Dropping retired user ${user} (no longer provisioned)"
        influx_exec "drop retired user ${user}" "DROP USER ${user}"
    fi
done

# Databases are NOT dropped, deliberately. ga_glances and ga_telegraf are no
# longer created, but DROP DATABASE destroys data irreversibly and this script
# runs unattended on every start — the wrong place for that. An empty database
# costs nothing; a wrong DROP cannot be undone.

bashio::log.info "InfluxDB provisioning complete: ${#USER_DBS[@]} consumers, per-database grants, no shared secret"
