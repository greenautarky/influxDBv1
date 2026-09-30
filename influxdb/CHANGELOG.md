# Changelog

## 0.0.21 (2026-09-30)

- **Chronograf and Kapacitor now come from GreenAutarky's maintenance forks**
  instead of InfluxData's packages: Kapacitor 1.5.9 and Chronograf 1.10.9
  (was 1.10.2), each rebuilt with Go 1.26 and current dependency versions
  (grpc 1.83, current `golang.org/x/*`, among others) for armv7 (hardware
  float), aarch64 and amd64. The release tarballs are pinned by sha256 per
  arch and the build fails closed on a mismatch. Every change in the forks is
  listed in their `GA-PATCHES.md`:
  [kapacitor](https://github.com/greenautarky/kapacitor/blob/v1.5.9-ga.1/GA-PATCHES.md),
  [chronograf](https://github.com/greenautarky/chronograf/blob/v1.10.9-ga.1/GA-PATCHES.md).
- Chronograf 1.10.2 → 1.10.9 is a patch-level update; its BoltDB store gains
  optional fields only. Kapacitor stays at 1.5.9.
- Both remain optional and off by default. No change to the options, the
  credential model, InfluxDB, or its storage format.

## 0.0.20 (2026-09-30)

- **InfluxDB stays at 1.8.10; its toolchain and libraries move.** The
  `influxd`, `influx` and `influx_inspect` source build now uses Go 1.26 instead
  of Go 1.19, and raises grpc (1.26 → 1.83), `golang.org/x/crypto` /
  `golang.org/x/net` / `golang.org/x/text` (2021 → current) and their
  dependencies. `influx_stress` is now built from the same source instead of
  coming from the 2021 vendor package. The armv7 build is still hardware-float
  (GOARM=7) and still fails closed if it is not.
- The image is rebuilt on current Debian 13 packages (`apt-get upgrade` at build
  time, as before).
- No change to the storage format, the configuration, the options or the
  credential model. Chronograf 1.10.2 and Kapacitor 1.5.9 are unchanged (both
  optional and off by default).
