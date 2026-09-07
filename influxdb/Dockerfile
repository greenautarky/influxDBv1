ARG BUILD_FROM
ARG BUILD_ARCH
ARG INFLUXDB_VERSION="1.8.10"

# ── influxd/influx/influx_inspect built from source with GOARM=7 on armv7 ─────
# InfluxData's official armhf .deb is built GOARM=5 — software floating point on
# hardware that has VFPv3/VFPv4/NEON. On an iHost that is ~18% of one core at
# idle, dominated by the internal monitor's HyperLogLog cardinality math.
# Building v1.8.10 from its own tag with GOARM=7 uses the FPU and drops idle to
# ~3%. aarch64/amd64 have no softfloat variant; they are built from the same tag
# for provenance and to remove the unverifiable vendor binary uniformly.
# The build FAILS CLOSED if the armv7 binary still links the software-float path.
# hadolint ignore=DL3006
FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.19-bookworm AS influxbuild
ARG BUILD_ARCH
ARG INFLUXDB_VERSION
# hadolint ignore=DL3003
RUN set -eux; \
    git clone --depth 1 --branch "v${INFLUXDB_VERSION}" https://github.com/influxdata/influxdb.git /src; \
    cd /src; \
    case "${BUILD_ARCH}" in \
      armv7)   export GOARCH=arm GOARM=7 ;; \
      aarch64) export GOARCH=arm64 ;; \
      amd64)   export GOARCH=amd64 ;; \
      *) echo "unsupported BUILD_ARCH: ${BUILD_ARCH}"; exit 1 ;; \
    esac; \
    export CGO_ENABLED=0 GOOS=linux GOFLAGS=-mod=mod; \
    for c in influxd influx influx_inspect; do \
      go build -trimpath -ldflags "-s -w -X main.version=${INFLUXDB_VERSION}" -o "/out/${c}" "./cmd/${c}"; \
    done; \
    # Red/green proof, in the build: GOARM=7 dead-code-eliminates the softfloat
    # path, GOARM<7 links it. If it is still present on armv7, the rebuild did
    # not take — fail rather than ship a binary that is no better than the deb.
    if [ "${BUILD_ARCH}" = "armv7" ]; then \
      if grep -aq "runtime.fadd64" /out/influxd; then \
        echo "FAIL: armv7 influxd still links the software-float path (GOARM<7)"; exit 1; \
      fi; \
      echo "OK: armv7 influxd is hardware-float (GOARM=7, no runtime.fadd64)"; \
    fi

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


# Replace the vendor influx binaries (GOARM=5 on armv7) with our GOARM=7 source
# build. Chronograf/Kapacitor stay from the .deb — they are already hardware-fp
# and are optional/off by default anyway.
COPY --from=influxbuild /out/influxd /usr/bin/influxd
COPY --from=influxbuild /out/influx /usr/bin/influx
COPY --from=influxbuild /out/influx_inspect /usr/bin/influx_inspect

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