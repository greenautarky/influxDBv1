#!/usr/bin/env python3
"""Start the REAL add-on image and prove that nobody is served without a credential.

The image runs unmodified (s6, cont-init, services); only the Supervisor API is
a stub. From container start until STEADY_EXTRA seconds after the server answers
an authenticated request, every ~0.5 s a peer sends a query and a write, each
with a wrong password and without any credential. ANY 2xx is a failure.

Coverage, not exit code: a run counts only if probes were sent between the
"credential mode" log line (init begins) and "Starting the InfluxDB" (init over),
and if the steady state was really reached.

  run.py --image IMG                     fresh data dir, both credential modes
  run.py --image IMG --upgrade-from OLD  data dir created by OLD, both modes
  run.py ... --expect-open               must-flag: exit 0 only if a 2xx was seen
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import yaml

HERE = pathlib.Path(__file__).resolve().parent
CONFIG = yaml.safe_load((HERE / "../../influxdb/config.yaml").read_text())
TOKEN = "t" * 21 + "LegacySharedSecret0123456789abcd" + "x" * 11
STUB_IMAGE = "python:3.13-slim"
STEADY_EXTRA = 30
START_TIMEOUT = 300
DB = "ga_homeassistant_db"
ADMIN = "ga_influx_admin"
failures = []
checks = 0


def check(ok, msg, detail=""):
    global checks
    checks += 1
    print(("  ok    " if ok else "  FAIL  ") + msg + (f"  [{detail}]" if detail else ""), flush=True)
    if not ok:
        failures.append(msg)


def docker(*args, ok=True):
    r = subprocess.run(["docker", *args], capture_output=True, text=True)
    if ok and r.returncode:
        sys.exit(f"FATAL: docker {' '.join(args)[:200]}: {r.stderr.strip()[:400]}")
    return r.stdout + (r.stderr if args[0] == "logs" else "")


def http(ip, method, path, params, body=None):
    url = f"http://{ip}:8086{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, data=body, method=method)
    try:
        with urllib.request.urlopen(req, timeout=2) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except OSError:
        return 0, ""  # refused / reset / timeout: not served


class Addon:
    def __init__(self, image, per_user, volume):
        self.id = uuid.uuid4().hex[:8]
        self.net, self.stub, self.name = (f"{p}-{self.id}" for p in ("swnet", "swstub", "swinflux"))
        options = dict(CONFIG["options"], per_user_secrets=per_user)
        docker("network", "create", self.net)
        docker("run", "-d", "--name", self.stub, "--network", self.net, "--network-alias", "supervisor",
               "-e", f"ADDON_OPTIONS={json.dumps(options)}", "-v", f"{HERE}/supervisor_stub.py:/s.py:ro",
               STUB_IMAGE, "python3", "-u", "/s.py")
        time.sleep(2)
        docker("create", "--name", self.name, "--network", self.net, "-e", f"SUPERVISOR_TOKEN={TOKEN}",
               "-v", f"{volume}:/data", "--tmpfs", "/share", image)
        self.t0 = time.time()
        docker("start", self.name)
        fmt = "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"
        self.ip = docker("inspect", "-f", fmt, self.name).strip()

    def logs(self):
        return docker("logs", "-t", self.name, ok=False)

    def log_time(self, needle):
        for line in self.logs().splitlines():
            if needle in line:
                m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{1,6})", line)
                return datetime.datetime.fromisoformat(m[1] + "+00:00").timestamp()
        return None

    def password(self, per_user):
        path, key = ("/data/influx-users.json", True) if per_user else ("/data/secret", False)
        raw = docker("exec", self.name, "cat", path, ok=False)
        try:
            return json.loads(raw)["users"][ADMIN]["password"] if key else raw.strip()
        except (ValueError, KeyError):
            return ""

    def stop(self):
        docker("stop", "-t", "60", self.name, ok=False)
        docker("rm", "-f", "-v", self.name, self.stub, ok=False)
        docker("network", "rm", self.net, ok=False)


PROBES = {
    "query wrong password": ("GET", "/query", {"q": "SHOW DATABASES", "u": ADMIN, "p": "wrong"}, None),
    "query no credential": ("GET", "/query", {"q": "SHOW DATABASES"}, None),
    "write wrong password": ("POST", "/write", {"db": DB, "u": ADMIN, "p": "wrong"}, b"probe v=1"),
    "write no credential": ("POST", "/write", {"db": DB}, b"probe v=1"),
}


def wait_steady(addon, per_user, probe):
    """Probe until STEADY_EXTRA s after the first authenticated 200. -> (steady time, samples)"""
    samples, steady = [], None
    while time.time() - addon.t0 < START_TIMEOUT:
        if probe:
            for name, (m, p, q, b) in PROBES.items():
                samples.append((time.time(), name, http(addon.ip, m, p, q, b)[0]))
        if steady is None and addon.log_time("Starting the InfluxDB"):
            pw = addon.password(per_user)
            if pw and http(addon.ip, "GET", "/query", {"q": "SHOW DATABASES", "u": ADMIN, "p": pw})[0] == 200:
                steady = time.time()
        if steady and (not probe or time.time() - steady > STEADY_EXTRA):
            break
        time.sleep(0.5)
    return steady, samples


def scenario(image, per_user, old):
    label = f"{'per-user' if per_user else 'legacy'} secrets, " + (f"data dir from {old}" if old else "fresh data dir")
    print(f"== {label} ==", flush=True)
    volume = f"swdata-{uuid.uuid4().hex[:8]}"
    docker("volume", "create", volume)
    old_manifest = None
    try:
        if old:
            a = Addon(old, per_user, volume)
            steady, _ = wait_steady(a, per_user, probe=False)
            pw = a.password(per_user)
            st = http(a.ip, "POST", "/write", {"db": DB, "u": ADMIN, "p": pw}, b"upgrade v=42")[0]
            check(bool(steady) and st == 204, f"{label}: old image starts and stores a point", f"write {st}")
            old_manifest = pw
            a.stop()
        a = Addon(image, per_user, volume)
        try:
            steady, samples = wait_steady(a, per_user, probe=True)
            check(steady is not None, f"{label}: steady state reached",
                  f"{steady - a.t0:.1f} s" if steady else a.logs()[-600:])
            served = [(t, n, s) for t, n, s in samples if 200 <= s < 300]
            b, e = a.log_time("credential mode"), a.log_time("Starting the InfluxDB")
            inside = [t for t, _, _ in samples if b and e and b <= t <= e]
            after = [t for t, _, _ in samples if steady and t > steady]
            check(len(inside) >= 8, f"{label}: probes sent while init ran", f"{len(inside)}")
            check(len(after) >= 40, f"{label}: probes sent after steady state", f"{len(after)}")
            span = f"{served[0][0] - a.t0:.1f}..{served[-1][0] - a.t0:.1f} s" if served else ""
            kinds = {n: sum(1 for _, x, _ in served if x == n) for n in PROBES}
            check(not served, f"{label}: no unauthenticated request is ever served",
                  f"{len(served)} of {len(samples)} served {span} {kinds}" if served else f"0 of {len(samples)}")
            pw = a.password(per_user)
            ok = {"u": ADMIN, "p": pw}
            bad = {"u": ADMIN, "p": "wrong"}
            got = [http(a.ip, "POST", "/write", {"db": DB, **ok}, b"authd v=1")[0],
                   http(a.ip, "GET", "/query", {"q": "SHOW DATABASES", **ok})[0],
                   http(a.ip, "POST", "/write", {"db": DB, **bad}, b"authd v=1")[0],
                   http(a.ip, "GET", "/query", {"q": "SHOW DATABASES", **bad})[0],
                   http(a.ip, "GET", "/query", {"q": "SHOW DATABASES"})[0]]
            check(got == [204, 200, 401, 401, 401], f"{label}: write/query ok, wrong/none refused", str(got))
            users = http(a.ip, "GET", "/query", {"q": "SHOW USERS", **ok})[1]
            want = ["ga_ha_influx_user", "ga_telegraf"] + (["ga_default", "ga_hmvapp"] if per_user else [])
            check(all(f'"{u}"' in users for u in want), f"{label}: users provisioned", ",".join(want))
            if per_user:
                check("Verified 7 user/database grants" in a.logs(), f"{label}: grants verified by the add-on")
            n = docker("exec", a.name, "pgrep", "-c", "influxd", ok=False).strip()
            check(n == "1", f"{label}: exactly one influxd runs (the init one is gone)", n)
            if old:
                check(pw == old_manifest, f"{label}: credential unchanged by the upgrade")
                out = http(a.ip, "GET", "/query", {"db": DB, "q": "SELECT v FROM upgrade", **ok})[1]
                check(",42]" in out, f"{label}: the old point is still readable")
            print(f"        init took {e - b:.1f} s" if b and e else "        init time unknown", flush=True)
        finally:
            a.stop()
    finally:
        docker("volume", "rm", "-f", volume, ok=False)
    return bool(served)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--upgrade-from", default="")
    ap.add_argument("--expect-open", action="store_true")
    ap.add_argument("--mode", choices=["both", "per-user", "legacy"], default="both")
    a = ap.parse_args()
    modes = {"both": (True, False), "per-user": (True,), "legacy": (False,)}[a.mode]
    opened = [scenario(a.image, m, a.upgrade_from) for m in modes]
    print(f"start_window: {checks} checks, {len(failures)} failed")
    if a.expect_open:
        others = [f for f in failures if "ever served" not in f]
        good = all(opened) and not others
        print("must-flag: " + ("the test flags this image, and only for the window" if good else f"NOT proven {others}"))
        return 0 if good else 1
    if checks < 7 * len(modes):
        print("FATAL: too few checks ran")
        return 2
    return 1 if failures else 0


sys.exit(main())
