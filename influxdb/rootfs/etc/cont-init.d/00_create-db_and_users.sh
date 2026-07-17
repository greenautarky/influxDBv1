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
    write_share_secret "${secret}"

    for u in ga_influx_admin ga_telegraf ga_ha_influx_user chronograf kapacitor; do
        USER_PW[$u]="${secret}"
    done
}

# ─── Per-user distinct-secret mode (target) ──────────────────────────────────
# Passwords persist in /data/influx-users.json so they are stable across
# restarts (a rotation = delete the file). Reuse existing values; generate
# only the missing ones so adding a user later doesn't churn the others.
provision_per_user_secrets() {
    local u existing
    for u in ga_influx_admin ga_ha_influx_user ga_telegraf chronograf kapacitor; do
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

    # ga_ha_influx_user is shared by default_addon (delivered via the manifest
    # + ga_manager) AND the HA Core InfluxDB integration (which still reads
    # /share via `!secret` — its cutover to /config secrets is a later step,
    # Odoo #549/#550). So keep the /share file in sync with this user's NOW
    # DISTINCT password, otherwise flipping to per-user mode would 401 HA Core.
    # /share elimination is Phase 3, after HA Core is migrated.
    write_share_secret "${USER_PW[ga_ha_influx_user]}"
}

# Mirror a single password into the HA `!secret` file under SECRET_KEY.
write_share_secret() {
    local pw="$1" yaml_secret line
    yaml_secret="${pw//\'/\'\'}"
    line="${SECRET_KEY}: '${yaml_secret}'"
    touch "${SECRETS_YAML}"
    if grep -qE "^[[:space:]]*${SECRET_KEY}:" "${SECRETS_YAML}"; then
        sed -i -E "s|^[[:space:]]*${SECRET_KEY}:.*|${line}|" "${SECRETS_YAML}"
    else
        printf '\n# Managed by GA add-on\n%s\n' "${line}" >> "${SECRETS_YAML}"
    fi
    bashio::log.info "Ensured ${SECRETS_YAML} contains ${SECRET_KEY}"
}

# Emit the addon-private hand-off file consumed by ga_manager's cross-addon
# delivery. Scopes describe the least-privilege grant applied below so the
# delivery layer can route each consumer its own credential.
write_users_json() {
    local tmp
    tmp="$(mktemp)"
    jq -n \
        --arg host "${INFLUX_HOST}" \
        --argjson port "${INFLUX_PORT}" \
        --arg ha_pw "${USER_PW[ga_ha_influx_user]}" \
        --arg admin_pw "${USER_PW[ga_influx_admin]}" \
        --arg tel_pw "${USER_PW[ga_telegraf]}" \
        --arg chr_pw "${USER_PW[chronograf]}" \
        --arg kap_pw "${USER_PW[kapacitor]}" \
        '{
          version: 1,
          host: $host,
          port: $port,
          users: {
            ga_ha_influx_user: { password: $ha_pw,    databases: ["ga_homeassistant_db","gd_data","pd_data"], scope: "rw" },
            ga_influx_admin:   { password: $admin_pw, databases: [],                       scope: "admin" },
            ga_telegraf:       { password: $tel_pw,   databases: ["ga_telegraf"],          scope: "rw" },
            chronograf:        { password: $chr_pw,   databases: [],                       scope: "admin" },
            kapacitor:         { password: $kap_pw,   databases: [],                       scope: "admin" }
          }
        }' > "${tmp}"
    install -m 0600 "${tmp}" "${USERS_JSON}"
    rm -f "${tmp}"
    bashio::log.info "Wrote per-user credential manifest ${USERS_JSON} (0600)"
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
    # Pre-create the data databases so the least-privileged ga_ha_influx_user
    # never needs admin to CREATE them at first write.
    create_database "gd_data"
    create_database "pd_data"

    # Create/rotate the data users with their DISTINCT passwords. Created
    # WITHOUT admin (plain CREATE USER); admin is granted explicitly below only
    # where required, so the data users stay least-privilege.
    for u in ga_ha_influx_user ga_telegraf; do
        influx -execute "CREATE USER ${u} WITH PASSWORD '${USER_PW[$u]}'" &> /dev/null || \
        influx -execute "SET PASSWORD FOR ${u} = '${USER_PW[$u]}'" &> /dev/null || true
    done
    for u in ga_influx_admin chronograf kapacitor; do
        create_or_update_user "${u}" "${USER_PW[$u]}"
    done

    # ga_ha_influx_user is the single data user shared by default_addon and the
    # HA Core integration (decision 2026-07-17): grant it the DBs both touch —
    # ga_homeassistant_db (HA Core writes, default_addon reads) + gd_data/pd_data
    # (default_addon writes). Admin tooling stays admin.
    influx -execute "GRANT ALL ON ga_homeassistant_db TO ga_ha_influx_user" &> /dev/null || true
    influx -execute "GRANT ALL ON gd_data TO ga_ha_influx_user" &> /dev/null || true
    influx -execute "GRANT ALL ON pd_data TO ga_ha_influx_user" &> /dev/null || true
    influx -execute "GRANT ALL ON ga_telegraf TO ga_telegraf" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO ga_influx_admin" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO chronograf" &> /dev/null || true
    influx -execute "GRANT ALL PRIVILEGES TO kapacitor" &> /dev/null || true
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
