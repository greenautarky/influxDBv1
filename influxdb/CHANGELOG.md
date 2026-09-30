# Changelog

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
