#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Ensure a user for Chronograf & Kapacitor exists within InfluxDB
# ==============================================================================
declare secret

# If secret file exists, skip this script
if bashio::fs.file_exists "/data/secret"; then
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

# Create Databases
bashio::log.info "Creating Database homeassistant"

### Create Databases
influx -execute \
    "CREATE DATABASE homeassistant" \
         &> /dev/null || true

bashio::log.info "Creating Database ga_telegraf"
influx -execute \
    "CREATE DATABASE ga_telegraf" \
         &> /dev/null || true

### Create Users

# Create user ga_influx_admin
influx -execute \
    "CREATE USER ga_influx_admin WITH PASSWORD '${secret}'" \
         &> /dev/null || true

# Create user ga_telegraf
influx -execute \
    "CREATE USER ga_telegraf WITH PASSWORD '${secret}'" \
         &> /dev/null || true

# Create user homeassistant
influx -execute \
    "CREATE USER homeassistant WITH PASSWORD '${secret}'" \
         &> /dev/null || true

# Create user ga_grafana
influx -execute \
    "CREATE USER ga_grafana WITH PASSWORD 'ga_grafana'" \
         &> /dev/null || true

#### Define Rights for Users ####

influx -execute \
    "GRANT ALL PRIVILEGES TO ga_influx_admin" \
        &> /dev/null || true

influx -execute \
    "GRANT ALL PRIVILEGES TO ga_telegraf" \
        &> /dev/null || true


influx -execute \
    "GRANT READ ON ga_telegraf TO ga_grafana" \
        &> /dev/null || true

influx -execute \
    "GRANT READ ON homeassistant TO ga_grafana" \
        &> /dev/null || true

influx -execute \
    "CREATE USER chronograf WITH PASSWORD '${secret}'" \
         &> /dev/null || true


influx -execute \
    "GRANT ALL PRIVILEGES TO chronograf" \
        &> /dev/null || true

influx -execute \
    "GRANT ALL ON homeassistant TO homeassistant" \
        &> /dev/null || true

influx -execute \
    "CREATE USER kapacitor WITH PASSWORD '${secret}'" \
        &> /dev/null || true

influx -execute \
    "GRANT ALL PRIVILEGES TO kapacitor" \
        &> /dev/null || true

kill "$(pgrep influxd)" >/dev/null 2>&1

# Save secret for future use
echo "${secret}" > /data/secret