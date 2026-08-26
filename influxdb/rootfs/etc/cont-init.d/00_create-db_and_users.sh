#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Ensure databases + users exist within InfluxDB.
#
# Two credential modes, selected by the `per_user_secrets` addon option:
#
#   per_user_secrets: false  (DEFAULT — unchanged legacy behaviour)
#     All users share ONE password derived from the Supervisor token and are
#     granted ALL PRIVILEGES. The shared secret is mirrored to
#     /share/influxdb_password.yaml for consumers that read it via `!secret`.
#
#   per_user_secrets: true   (target state — ADR-0002/0003 device-local plane)
#     Each user gets a DISTINCT random password, persisted addon-private in
#     /data/influx-users.json (0600, reused across restarts), with
#     LEAST-PRIVILEGE grants for the two data users. The JSON file is the
#     hand-off point for ga_manager's cross-addon delivery (it pushes each
#     consumer its own credential — default_addon via addon options, HA Core
#     via /config secrets). No shared secret, nothing written under /share.
#
# The mode is a flag so this ships as a pure no-op (flag false) and the flip
# is a config-only change once the consumers are wired — see Odoo #548 /
# ADR-0003. Provisioning runs against the auth-off temp influxd started here
# (this cont-init runs before influxdb.sh flips auth-enabled), so no admin
# bootstrap credential is needed in either mode.
# ==============================================================================

SECRETS_YAML="/share/influxdb_password.yaml"
SECRET_KEY="ga_influxdbv1_token"
USERS_JSON="/data/influx-users.json"
INFLUX_HOST="99f1cad4-ga-influxdbv1"
INFLUX_PORT=8086

# Alphanumeric only → safe inside InfluxQL single-quoted strings and in the
# plain sed/`!secret` extraction consumers use (no quoting needed downstream).
gen_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
}

declare -A USER_PW

# ─── Legacy shared-secret mode (default) ─────────────────────────────────────
provision_legacy_secret() {
    local secret yaml_secret line u
    if bashio::fs.file_exists "/data/secret"; then
        secret="$(cat /data/secret)"
    else
        secret="${SUPERVISOR_TOKEN:21:32}"
        printf '%s\n' "${secret}" > /data/secret
    fi

    # Mirror the shared secret to the HA secrets file for `!secret` consumers.
    yaml_secret="${secret//\'/\'\'}"
    line="${SECRET_KEY}: '${yaml_secret}'"
    touch "${SECRETS_YAML}"
    # A live admin credential on the addon<->host bridge must not be
    # world-readable. 600 covers both the fresh-create case (umask gives 644)
    # and a pre-existing 644 file; sed -i below preserves these perms.
    chmod 600 "${SECRETS_YAML}"
    if grep -qE "^[[:space:]]*${SECRET_KEY}:" "${SECRETS_YAML}"; then
        sed -i -E "s|^[[:space:]]*${SECRET_KEY}:.*|${line}|" "${SECRETS_YAML}"
    else
        printf '\n# Managed by GA add-on\n%s\n' "${line}" >> "${SECRETS_YAML}"
    fi
    bashio::log.info "Ensured ${SECRETS_YAML} contains ${SECRET_KEY}"

    for u in ga_influx_admin ga_telegraf ga_ha_influx_user chronograf kapacitor; do
        USER_PW[$u]="${secret}"
    done
}

# ─── Who may touch what: ONE declaration ────────────────────────────────────
# Read by the manifest writer, the database creation, the GRANT block and the
# verification below. Previously the manifest listed a user's databases and the
# GRANT block granted them, separately — two sources for one truth, which can
# only ever agree by hand. A consumer whose manifest entry and server-side
# privilege disagree authenticates successfully and is then refused on every
# request, which is the hardest shape of this failure to see.
#
# Databases are what each consumer is CONFIGURED for (its own add-on options),
# not a guess at what it uses. Narrowing any of these from read/write to
# read-only is a second step and needs a measurement, not an assumption: the
# server's access log tells us which (user, database) pairs ever POST /write.
declare -A USER_DBS=(
    [ga_ha_influx_user]="ga_homeassistant_db"
    [ga_default]="ga_homeassistant_db gd_data pd_data"
    [ga_hmvapp]="ga_homeassistant_db gd_data"
    [ga_telegraf]="ga_telegraf"
)
DATA_USERS="ga_ha_influx_user ga_default ga_hmvapp ga_telegraf"
ADMIN_USERS="ga_influx_admin chronograf kapacitor"

# ─── Per-user distinct-secret mode (target) ──────────────────────────────────
# Passwords persist in /data/influx-users.json so they are stable across
# restarts (a rotation = delete the file). Reuse existing values; generate
# only the missing ones so adding a user later doesn't churn the others.
provision_per_user_secrets() {
    local u existing
    for u in ${ADMIN_USERS} ${DATA_USERS}; do
        existing=""
        if bashio::fs.file_exists "${USERS_JSON}"; then
            existing="$(jq -r --arg u "$u" '.users[$u].password // empty' "${USERS_JSON}" 2>/dev/null)"
        fi
        if bashio::var.has_value "${existing}"; then
            USER_PW[$u]="${existing}"
        else
            USER_PW[$u]="$(gen_password)"
        fi
    done
    write_users_json
    # A stale shared-secret file must not linger as a real credential once we
    # are in per-user mode (auth is enforced against the per-user passwords).
    bashio::fs.file_exists "/data/secret" && rm -f /data/secret
}

# Emit the addon-private hand-off file consumed by ga_manager's cross-addon
# delivery. Scopes describe the least-privilege grant applied below so the
# delivery layer can route each consumer its own credential.
write_users_json() {
    local tmp users u dbs
    tmp="$(mktemp)"
    users="{}"

    for u in ${DATA_USERS}; do
        # Word splitting is the list format here.
        # shellcheck disable=SC2086
        dbs="$(printf '%s\n' ${USER_DBS[$u]} | jq -R . | jq -s -c .)"
        users="$(jq -c --arg u "$u" --arg pw "${USER_PW[$u]}" \
                       --argjson dbs "${dbs}" \
                    '.[$u] = {password: $pw, databases: $dbs, scope: "rw"}' \
                    <<<"${users}")"
    done
    for u in ${ADMIN_USERS}; do
        users="$(jq -c --arg u "$u" --arg pw "${USER_PW[$u]}" \
                    '.[$u] = {password: $pw, databases: [], scope: "admin"}' \
                    <<<"${users}")"
    done

    jq -n --arg host "${INFLUX_HOST}" --argjson port "${INFLUX_PORT}" \
          --argjson users "${users}" \
        '{version: 1, host: $host, port: $port, users: $users}' > "${tmp}"
    install -m 0600 "${tmp}" "${USERS_JSON}"
    rm -f "${tmp}"
    # Names, never values. The count is what makes a truncated manifest visible.
    bashio::log.info "Wrote per-user credential manifest ${USERS_JSON} (0600): \
$(jq -r '.users | keys | length' "${USERS_JSON}") users — \
$(jq -r '.users | keys | join(", ")' "${USERS_JSON}")"
}

# Confirm the server actually applied what the manifest promises. A GRANT that
# silently did not land leaves a consumer able to authenticate and refused on
# every request — the add-on starts, connects, and writes nothing.
verify_grants() {
    local u db shown missing=0 checked=0
    for u in ${DATA_USERS}; do
        shown="$(influx -execute "SHOW GRANTS FOR ${u}" 2>/dev/null)"
        # shellcheck disable=SC2086
        for db in ${USER_DBS[$u]}; do
            checked=$((checked + 1))
            if ! grep -qE "(^|[[:space:]])${db}([[:space:]]|$)" <<<"${shown}"; then
                bashio::log.error "MISSING GRANT: ${u} has no privilege on ${db}"
                missing=$((missing + 1))
            fi
        done
    done
    # Coverage, not exit code: a verification that inspected nothing is a
    # failure wearing the colour of success.
    if [ "${checked}" -eq 0 ]; then
        bashio::log.error "grant verification inspected ZERO pairs — the user/database table is empty"
        return
    fi
    if [ "${missing}" -gt 0 ]; then
        bashio::log.error "${missing} of ${checked} required grants are missing; \
those consumers will authenticate and then be refused on every request"
    else
        bashio::log.info "Verified ${checked} user/database grants"
    fi
}

PER_USER=false
if bashio::config.true 'per_user_secrets'; then
    PER_USER=true
    bashio::log.info "InfluxDB credential mode: per-user distinct secrets (least-privilege)"
    provision_per_user_secrets
else
    bashio::log.info "InfluxDB credential mode: legacy shared secret"
    provision_legacy_secret
fi

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

# Function to create database if it doesn't exist
create_database() {
    local db="$1"
    if ! influx -execute "SHOW DATABASES" | grep -q "^${db}$"; then
        bashio::log.info "Creating Database ${db}"
        influx -execute "CREATE DATABASE ${db}" &> /dev/null || true
    else
        bashio::log.info "Database ${db} already exists, skipping creation."
    fi
}

# Function to set retention policy
set_retention_policy() {
    local db="$1"
    local duration="$2"
    if influx -execute "SHOW RETENTION POLICIES ON ${db}" | grep -q "autogen"; then
        bashio::log.info "Setting retention policy for database ${db} to ${duration}"
        influx -execute "ALTER RETENTION POLICY autogen ON ${db} DURATION ${duration} REPLICATION 1 DEFAULT" &> /dev/null || true
    else
        bashio::log.info "Retention policy already set for database ${db}"
    fi
}

# Function to create or update a user
create_or_update_user() {
    local user="$1"
    local password="$2"
    influx -execute "SHOW USERS" | grep -q "^${user}" && \
        bashio::log.info "Updating password for user ${user}" || \
        bashio::log.info "Creating user ${user}"
    influx -execute "CREATE USER ${user} WITH PASSWORD '${password}' WITH ALL PRIVILEGES" &> /dev/null || \
    influx -execute "SET PASSWORD FOR ${user} = '${password}'" &> /dev/null || true
}

# Create Databases
create_database "ga_homeassistant_db"
create_database "ga_telegraf"
create_database "ga_glances"

# Set retention policy for ga_glances
set_retention_policy "ga_glances" "7d"

if [[ "${PER_USER}" == "true" ]]; then
    # Pre-create every database named in the table, so a least-privileged
    # consumer never needs admin to CREATE one at its first write. Derived
    # from USER_DBS rather than listed again: a database added to a user's row
    # and forgotten here is a 404 on that consumer's first request.
    for db in $(printf '%s\n' "${USER_DBS[@]}" | tr ' ' '\n' | sort -u); do
        create_database "${db}"
    done

    # Create/rotate every user with its DISTINCT password. Data users are
    # created WITHOUT admin here (plain CREATE USER); admin is granted
    # explicitly below only to the tooling accounts that need it.
    for u in ${DATA_USERS}; do
        influx -execute "CREATE USER ${u} WITH PASSWORD '${USER_PW[$u]}'" &> /dev/null || \
        influx -execute "SET PASSWORD FOR ${u} = '${USER_PW[$u]}'" &> /dev/null || true
    done
    for u in ${ADMIN_USERS}; do
        create_or_update_user "${u}" "${USER_PW[$u]}"
    done

    # Least-privilege grants, straight from the table above. A failure here is
    # reported: it is the difference between a consumer that works and one
    # that authenticates and is then refused on every request.
    for u in ${DATA_USERS}; do
        # shellcheck disable=SC2086
        for db in ${USER_DBS[$u]}; do
            influx -execute "GRANT ALL ON ${db} TO ${u}" &> /dev/null || \
                bashio::log.error "GRANT ALL ON ${db} TO ${u} failed"
        done
    done
    for u in ${ADMIN_USERS}; do
        influx -execute "GRANT ALL PRIVILEGES TO ${u}" &> /dev/null || \
            bashio::log.error "GRANT ALL PRIVILEGES TO ${u} failed"
    done

    verify_grants
else
    # Legacy: every user shares the same password + ALL PRIVILEGES.
    create_or_update_user "ga_influx_admin" "${USER_PW[ga_influx_admin]}"
    create_or_update_user "ga_telegraf" "${USER_PW[ga_telegraf]}"
    create_or_update_user "ga_ha_influx_user" "${USER_PW[ga_ha_influx_user]}"
    create_or_update_user "chronograf" "${USER_PW[chronograf]}"
    create_or_update_user "kapacitor" "${USER_PW[kapacitor]}"

    influx -execute "GRANT ALL PRIVILEGES TO ga_influx_admin" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO ga_telegraf" &> /dev/null || true
    influx -execute "GRANT ALL ON ga_homeassistant_db TO ga_ha_influx_user" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO chronograf" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO kapacitor" &> /dev/null || true
fi

kill "$(pgrep influxd)" >/dev/null 2>&1
