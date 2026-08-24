#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Configures Kapacitor.conf
# ==============================================================================

# shellcheck source=/dev/null
source /usr/lib/ga/influx-credentials.sh

bashio::var.json \
    reporting "^$(bashio::config 'reporting')" \
    secret "$(ga_influx_password kapacitor)"\
    | tempio \
        -template /etc/kapacitor/templates/kapacitor.gtpl \
        -out /etc/kapacitor/kapacitor.conf