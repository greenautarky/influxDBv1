#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: InfluxDB
# Configures NGINX for use with the Chronograf
# ==============================================================================
declare port
declare certfile
declare dns_host
declare ingress_interface
declare ingress_port
declare ingress_entry
declare keyfile

port=$(bashio::addon.port 80)
ingress_entry=$(bashio::addon.ingress_entry)
if bashio::var.has_value "${port}"; then
    bashio::config.require.ssl

    if bashio::config.true 'ssl'; then
        certfile=$(bashio::config 'certfile')
        keyfile=$(bashio::config 'keyfile')

        mv /etc/nginx/servers/direct-ssl.disabled /etc/nginx/servers/direct.conf
        sed -i "s#%%certfile%%#${certfile}#g" /etc/nginx/servers/direct.conf
        sed -i "s#%%keyfile%%#${keyfile}#g" /etc/nginx/servers/direct.conf

    else
        mv /etc/nginx/servers/direct.disabled /etc/nginx/servers/direct.conf
    fi

    sed -i "s#%%ingress_entry%%#${ingress_entry}#g" /etc/nginx/servers/direct.conf
fi

ingress_port=$(bashio::addon.ingress_port)
ingress_interface=$(bashio::addon.ip_address)
sed -i "s/%%port%%/${ingress_port}/g" /etc/nginx/servers/ingress.conf
sed -i "s/%%interface%%/${ingress_interface}/g" /etc/nginx/servers/ingress.conf
sed -i "s#%%ingress_entry%%#${ingress_entry}#g" /etc/nginx/servers/ingress.conf

# With Chronograf disabled there is no upstream behind the ingress panel. A
# proxy_pass to a dead port answers 502 after a timeout, which reads as a
# fault; answering immediately with the reason does not.
if ! bashio::config.true 'chronograf'; then
    cat > /etc/nginx/servers/ingress.conf <<EOF
server {
    listen ${ingress_interface}:${ingress_port} default_server;

    include /etc/nginx/includes/server_params.conf;

    location / {
        allow   172.30.32.2;
        deny    all;

        default_type text/plain;
        return 200 "Chronograf is switched off by the add-on option 'chronograf'.\nInfluxDB itself is unaffected and serves its API on port 8086.\n";
    }
}
EOF
fi

dns_host=$(bashio::dns.host)
sed -i "s/%%dns_host%%/${dns_host}/g" /etc/nginx/includes/resolver.conf
