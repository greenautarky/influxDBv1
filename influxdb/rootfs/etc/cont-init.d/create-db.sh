#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Ensure a user for Chronograf & Kapacitor exists within InfluxDB
# ==============================================================================
bashio::log.info "Creating Database homeassistant"
influx -execute \
    "CREATE DATABASE homeassistant" \
         &> /dev/null || true

bashio::log.info "Creating Database homeassistant"
influx -execute \
    "CREATE DATABASE ga_telegraf" \
         &> /dev/null || true
