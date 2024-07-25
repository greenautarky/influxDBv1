#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Ensure a user for Chronograf & Kapacitor exists within InfluxDB
# ==============================================================================
declare secret

# If secret file exists, skip this script TODO: find a better way to manage the script execution and change of the config
if bashio::fs.file_exists "/data/secret"; then
    bashio::log.info "Skipping user creation, since secret exists..."
    exit 0
fi

# Generate secret based on the Hass.io token
secret="${SUPERVISOR_TOKEN:21:32}"

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

influx -execute \
    "CREATE USER chronograf WITH PASSWORD '${secret}'" \
         &> /dev/null || true

bashio::log.info "Creating user ga_telegraf"
influx -execute \
    "CREATE USER ga_telegraf WITH PASSWORD ga_telegraf" \
         &> /dev/null || true

bashio::log.info "Setting user rights to ga_telegraf"
influx -execute \
    "GRANT ALL PRIVILEGES TO ga_telegraf" \
        &> /dev/null || true

bashio::log.info "Creating user ga_grafana"
influx -execute \
    "CREATE USER ga_grafana WITH PASSWORD ga_grafana" \
         &> /dev/null || true

bashio::log.info "Setting user rights to ga_grafana: Read Only"
influx -execute \
    "GRANT READ ON ga_grafana TO ga_telegraf" \
        &> /dev/null || true

influx -execute \
    "SET PASSWORD FOR chronograf = '${secret}'" \
         &> /dev/null || true

influx -execute \
    "GRANT ALL PRIVILEGES TO chronograf" \
        &> /dev/null || true

influx -execute \
    "CREATE USER kapacitor WITH PASSWORD '${secret}'" \
        &> /dev/null || true

influx -execute \
    "SET PASSWORD FOR kapacitor = '${secret}'" \
        &> /dev/null || true

influx -execute \
    "GRANT ALL PRIVILEGES TO kapacitor" \
        &> /dev/null || true

kill "$(pgrep influxd)" >/dev/null 2>&1

# Save secret for future use
echo "${secret}" > /data/secret
