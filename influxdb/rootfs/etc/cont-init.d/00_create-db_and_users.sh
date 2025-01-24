#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Ensure a user for Chronograf & Kapacitor exists within InfluxDB
# ==============================================================================
declare secret

# Generate or reuse secret based on the Hass.io token
if bashio::fs.file_exists "/data/secret"; then
    secret=$(cat /data/secret)
else
    secret="${SUPERVISOR_TOKEN:21:32}"
    echo "${secret}" > /data/secret
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

# Create or update users
create_or_update_user "ga_influx_admin" "${secret}"
create_or_update_user "ga_telegraf" "${secret}"
create_or_update_user "ga_ha_influx_user" "${secret}"
create_or_update_user "ga_grafana" "ga_grafana"
create_or_update_user "ga_glances" "ga_glances"
create_or_update_user "chronograf" "${secret}"
create_or_update_user "kapacitor" "${secret}"

# Grant privileges
influx -execute "GRANT ALL PRIVILEGES TO ga_influx_admin" &> /dev/null || true
influx -execute "GRANT ALL PRIVILEGES TO ga_telegraf" &> /dev/null || true
influx -execute "GRANT ALL PRIVILEGES TO ga_glances" &> /dev/null || true
influx -execute "GRANT READ ON ga_telegraf TO ga_grafana" &> /dev/null || true
influx -execute "GRANT READ ON ga_homeassistant_db TO ga_grafana" &> /dev/null || true
influx -execute "GRANT ALL ON ga_homeassistant_db TO ga_ha_influx_user" &> /dev/null || true
influx -execute "GRANT ALL PRIVILEGES TO chronograf" &> /dev/null || true
influx -execute "GRANT ALL PRIVILEGES TO kapacitor" &> /dev/null || true

kill "$(pgrep influxd)" >/dev/null 2>&1
