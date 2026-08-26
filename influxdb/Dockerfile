ARG BUILD_FROM
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# Set shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Setup base system
ARG BUILD_ARCH
ARG INFLUXDB_VERSION="1.8.10"
ARG CHRONOGRAF_VERSION="1.10.2"
ARG KAPACITOR_VERSION="1.5.9-1"
# `apt-get upgrade` before the installs. The Debian base we own pins nothing —
# unlike the Alpine bases, whose constraints live in /etc/apk/world — but it is
# BUILT once and then sits: openssl was current the day it was made and is not
# today. The CVE gate blocks the push on exactly that:
#
#   libssl3t64, openssl, openssl-provider-legacy
#   3.5.6-1~deb13u2  ->  3.5.7-1~deb13u2   CVE-2026-14456
#
# Measured on ghcr.io/greenautarky/ga-addon-debian-base-amd64:trixie,
# 2026-08-26: 3 fixable HIGH before, 0 after.
#
# Same symptom as the four Alpine add-ons, different mechanism — which is why
# the Alpine form of this fix was wrong here and broke the build twice before
# anyone measured which distro this add-on actually uses.
# DL3008 wants every apt package pinned to a version. For this image that rule
# is precisely backwards: a pinned package is a package that stops receiving
# security updates, and the CVE gate then blocks the push on it. That is not
# hypothetical — it is what happened on 2026-08-26, and the fix was to STOP
# pinning (see the note above `apt-get upgrade`). The Alpine sibling add-ons
# had the same problem in the form of exact constraints in /etc/apk/world.
#
# SC3009 flags brace expansion as undefined in POSIX sh. This Dockerfile sets
# SHELL to /bin/bash three lines up, so it is not POSIX sh; hadolint does not
# carry that context across.
# hadolint ignore=DL3008,SC3009
RUN \
    apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        libnginx-mod-http-lua \
        luarocks \
        nginx-common \
        procps \
    \
    && luarocks install lua-resty-http 0.15-0 \
    \
    && ARCH="${BUILD_ARCH}" \
    && if [ "${BUILD_ARCH}" = "aarch64" ]; then ARCH="arm64"; fi \
    && if [ "${BUILD_ARCH}" = "armv7" ]; then ARCH="armhf"; fi \
    \
    && curl -J -L -o /tmp/influxdb.deb \
        "https://dl.influxdata.com/influxdb/releases/influxdb_${INFLUXDB_VERSION}_${ARCH}.deb" \
    \
    && curl -J -L -o /tmp/chronograf.deb \
        "https://dl.influxdata.com/chronograf/releases/chronograf_${CHRONOGRAF_VERSION}_${ARCH}.deb" \
    \
    && curl -J -L -o /tmp/kapacitor.deb \
        "https://dl.influxdata.com/kapacitor/releases/kapacitor_${KAPACITOR_VERSION}_${ARCH}.deb" \
    \
    && dpkg --install /tmp/influxdb.deb \
    && dpkg --install /tmp/chronograf.deb \
    && dpkg --install /tmp/kapacitor.deb \
    \
    && rm -fr \
        /tmp/* \
        /etc/nginx \
        /var/{cache,log}/* \
        /var/lib/apt/lists/* \
    \
    && mkdir -p /var/log/nginx \
    && touch /var/log/nginx/error.log


# Copy root filesystem
COPY rootfs /

# Build arguments
ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION

# Labels
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION} \
    maintainer="Franck Nijhof <frenck@addons.community>" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
    org.opencontainers.image.vendor="Home Assistant Community Add-ons" \
    org.opencontainers.image.authors="Franck Nijhof <frenck@addons.community>" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://addons.community" \
    org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.documentation="https://github.com/${BUILD_REPOSITORY}/blob/main/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}