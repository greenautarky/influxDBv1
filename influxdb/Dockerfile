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
#
# Toolchain and libraries: v1.8.10's own go.mod dates from 2021 (grpc 1.26,
# golang.org/x/* from 2021) and the build used Go 1.19. The source build now
# uses a current Go and raises the network/crypto libraries to the floors below
# (Go's minimal version selection lifts their own dependencies with them). The
# InfluxDB code, its storage engine and its configuration are unchanged — only
# the compiler and the libraries it links move. influx_stress is built here too,
# so no binary from the 2021 vendor .deb remains in /usr/bin/influx*.
# The build FAILS CLOSED if `go get` cannot apply a floor, and asserts the
# floors are in go.mod before compiling.
# hadolint ignore=DL3006
FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.26-bookworm AS influxbuild
ARG BUILD_ARCH
ARG INFLUXDB_VERSION
ARG GRPC_FLOOR="v1.83.2"
ARG XCRYPTO_FLOOR="v0.55.0"
ARG OTELSDK_FLOOR="v1.44.0"
ARG GOJOSE_FLOOR="v4.1.4"
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
    export CGO_ENABLED=0 GOOS=linux GOFLAGS=-mod=mod GOTOOLCHAIN=local; \
    go get \
      "google.golang.org/grpc@${GRPC_FLOOR}" \
      "golang.org/x/crypto@${XCRYPTO_FLOOR}" \
      "go.opentelemetry.io/otel/sdk@${OTELSDK_FLOOR}" \
      "github.com/go-jose/go-jose/v4@${GOJOSE_FLOOR}"; \
    grep -q "google.golang.org/grpc ${GRPC_FLOOR}" go.mod; \
    grep -q "golang.org/x/crypto ${XCRYPTO_FLOOR}" go.mod; \
    for c in influxd influx influx_inspect influx_stress; do \
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
# Chronograf and Kapacitor come from GreenAutarky's maintenance forks, not from
# InfluxData's packages. InfluxData's last armhf builds are Kapacitor 1.5.9
# (2021, Go 1.15) and Chronograf 1.10.9; the forks keep exactly those releases
# and rebuild them with Go 1.26 and current dependency versions, for all three
# arches. Every change is listed in GA-PATCHES.md in each fork:
#   https://github.com/greenautarky/kapacitor   (branch ga/1.5.9-patched)
#   https://github.com/greenautarky/chronograf  (branch ga/1.10.9-patched)
# The tarballs are pinned by sha256 per arch; the build FAILS CLOSED on a
# mismatch. To move to a new fork release, change the tag and all six hashes
# from the release's SHA256SUMS.
ARG CHRONOGRAF_RELEASE="1.10.9-ga.1"
ARG KAPACITOR_RELEASE="1.5.9-ga.1"
ARG CHRONOGRAF_SHA256_ARMV7="f15ab0d067deca2dfca1111fee9ea901764a445321aba12d44c10e513e326da4"
ARG CHRONOGRAF_SHA256_AARCH64="5a76d8e55ab32885d40741ea58d18b184ac3abdf01fd97d03490e163de9764b1"
ARG CHRONOGRAF_SHA256_AMD64="9494ec75e1cafe6562d82c1602f64793a9c79517bdb430e3c28ee34e7a8ee1ba"
ARG KAPACITOR_SHA256_ARMV7="222af37660439842de6e29fef1694008f46942b54906de487297df3355739017"
ARG KAPACITOR_SHA256_AARCH64="41b92240d802e2e065c8ef1cfb94722a69270ade3ce9f30eba29f5001f7bf749"
ARG KAPACITOR_SHA256_AMD64="79d0fb253d7a8194d0eefdaa9ab1911df6f6c473de93e9e38a431c56eba94380"
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
    && dpkg --install /tmp/influxdb.deb \
    \
    && case "${BUILD_ARCH}" in \
         armv7)   CHR_SHA="${CHRONOGRAF_SHA256_ARMV7}";   KAP_SHA="${KAPACITOR_SHA256_ARMV7}" ;; \
         aarch64) CHR_SHA="${CHRONOGRAF_SHA256_AARCH64}"; KAP_SHA="${KAPACITOR_SHA256_AARCH64}" ;; \
         amd64)   CHR_SHA="${CHRONOGRAF_SHA256_AMD64}";   KAP_SHA="${KAPACITOR_SHA256_AMD64}" ;; \
         *) echo "unsupported BUILD_ARCH: ${BUILD_ARCH}"; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/chronograf.tar.gz \
        "https://github.com/greenautarky/chronograf/releases/download/v${CHRONOGRAF_RELEASE}/chronograf-${CHRONOGRAF_RELEASE}-linux-${BUILD_ARCH}.tar.gz" \
    && curl -fsSL -o /tmp/kapacitor.tar.gz \
        "https://github.com/greenautarky/kapacitor/releases/download/v${KAPACITOR_RELEASE}/kapacitor-${KAPACITOR_RELEASE}-linux-${BUILD_ARCH}.tar.gz" \
    && echo "${CHR_SHA}  /tmp/chronograf.tar.gz" | sha256sum -c - \
    && echo "${KAP_SHA}  /tmp/kapacitor.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/chronograf /tmp/kapacitor \
    && tar -xzf /tmp/chronograf.tar.gz -C /tmp/chronograf \
    && tar -xzf /tmp/kapacitor.tar.gz -C /tmp/kapacitor \
    && install -m 0755 /tmp/chronograf/usr/bin/chronograf /tmp/chronograf/usr/bin/chronoctl /usr/bin/ \
    && install -m 0755 /tmp/kapacitor/usr/bin/kapacitord /tmp/kapacitor/usr/bin/kapacitor /tmp/kapacitor/usr/bin/tickfmt /usr/bin/ \
    && mkdir -p /usr/share/chronograf /etc/kapacitor \
    && cp -r /tmp/chronograf/usr/share/chronograf/canned /tmp/chronograf/usr/share/chronograf/protoboards /usr/share/chronograf/ \
    && install -m 0644 /tmp/kapacitor/etc/kapacitor/kapacitor.conf /etc/kapacitor/kapacitor.conf \
    # Same system accounts and home directories the upstream packages created.
    && useradd --system -U -M -d /var/lib/chronograf -s /bin/false chronograf \
    && useradd --system -U -M -d /var/lib/kapacitor -s /bin/false kapacitor \
    && install -d -o chronograf -g chronograf /var/lib/chronograf \
    && install -d -o kapacitor -g kapacitor /var/lib/kapacitor \
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
# build (current Go toolchain, see the build stage). Chronograf/Kapacitor are
# installed above from the pinned fork releases (hardware-float on armv7) and
# stay optional and off by default.
COPY --from=influxbuild /out/influxd /usr/bin/influxd
COPY --from=influxbuild /out/influx /usr/bin/influx
COPY --from=influxbuild /out/influx_inspect /usr/bin/influx_inspect
COPY --from=influxbuild /out/influx_stress /usr/bin/influx_stress

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