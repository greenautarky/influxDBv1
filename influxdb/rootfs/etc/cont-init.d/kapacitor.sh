#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Configures Kapacitor.conf
# ==============================================================================

if ! bashio::config.true 'kapacitor'; then
    bashio::log.info "Kapacitor is disabled by add-on configuration; skipping its configuration."
    exit 0
fi

bashio::var.json \
    reporting "^$(bashio::config 'reporting')" \
    secret "$(</data/secret)"\
    | tempio \
        -template /etc/kapacitor/templates/kapacitor.gtpl \
        -out /etc/kapacitor/kapacitor.conf