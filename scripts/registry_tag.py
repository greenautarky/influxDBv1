#!/usr/bin/env python3
"""Tags in a registry: look one up, or point a new tag at existing bytes.

A released version tag is written once. This is the one place that decides it:

  registry_tag.py digest REPO TAG          print the digest; exit 0 exists, 1 absent
  registry_tag.py promote REPO TAG DIGEST  put TAG on the manifest DIGEST (no rebuild)
                                           exit 0 done or already equal, 1 refused

Exit 2 = could not look (auth, network, unexpected answer): never "absent".
REPO is host/path, e.g. ghcr.io/greenautarky/ga_influxdbv1-armv7. Credentials
come from REGISTRY_USER / REGISTRY_TOKEN. A host on 127.0.0.1 is spoken to over
http (tests only).
"""
import base64
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ACCEPT = ", ".join(
    f"application/vnd.{t}+json"
    for t in (
        "docker.distribution.manifest.v2",
        "docker.distribution.manifest.list.v2",
        "oci.image.manifest.v1",
        "oci.image.index.v1",
    )
)


class CannotLook(Exception):
    pass


class Registry:
    def __init__(self, repo):
        self.host, self.path = repo.split("/", 1)
        scheme = "http" if self.host.startswith("127.0.0.1") else "https"
        self.base = f"{scheme}://{self.host}/v2/{self.path}/manifests/"
        self.token = None

    def call(self, method, ref, body=None, ctype=None, retry=True):
        headers = {"Accept": ACCEPT}
        if ctype:
            headers["Content-Type"] = ctype
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + ref, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            if e.code == 401 and retry:
                self.login(e.headers.get("WWW-Authenticate", ""), method)
                return self.call(method, ref, body, ctype, retry=False)
            return e.code, e.headers, e.read()
        except OSError as e:
            raise CannotLook(f"{method} {ref}: {e}") from e

    def login(self, challenge, method):
        p = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        if "realm" not in p:
            raise CannotLook(f"no usable auth challenge: {challenge!r}")
        scope = f"repository:{self.path}:{'pull,push' if method == 'PUT' else 'pull'}"
        q = urllib.parse.urlencode({"service": p.get("service", ""), "scope": scope})
        req = urllib.request.Request(f"{p['realm']}?{q}")
        user, secret = os.environ.get("REGISTRY_USER"), os.environ.get("REGISTRY_TOKEN")
        if user and secret:
            basic = base64.b64encode(f"{user}:{secret}".encode()).decode()
            req.add_header("Authorization", f"Basic {basic}")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
        except (OSError, ValueError) as e:
            raise CannotLook(f"token: {e}") from e
        self.token = d.get("token") or d.get("access_token")

    def get(self, ref):
        """(digest, media type, bytes), or None if the registry says it is not there."""
        status, headers, body = self.call("GET", ref)
        if status == 404:
            return None
        if status != 200:
            raise CannotLook(f"GET {ref}: HTTP {status}")
        return "sha256:" + hashlib.sha256(body).hexdigest(), headers.get("Content-Type"), body


def promote(reg, tag, digest):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        print(f"refused: {digest!r} is not a full sha256 digest")
        return 1
    have = reg.get(tag)
    if have:
        if have[0] == digest:
            print(f"{tag} already is {digest}")
            return 0
        print(f"refused: {tag} exists as {have[0]}, a released tag is not moved to {digest}")
        return 1
    src = reg.get(digest)
    if src is None or src[0] != digest:
        print(f"refused: no manifest {digest} in {reg.path}")
        return 1
    status, _, body = reg.call("PUT", tag, src[2], src[1])
    if status not in (200, 201):
        raise CannotLook(f"PUT {tag}: HTTP {status} {body[:200]!r}")
    now = reg.get(tag)
    if now is None or now[0] != digest:
        raise CannotLook(f"after the write {tag} is {now and now[0]}, want {digest}")
    print(f"{tag} = {digest}")
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "digest":
            got = Registry(argv[1]).get(argv[2])
            print(got[0] if got else "absent")
            return 0 if got else 1
        if len(argv) == 4 and argv[0] == "promote":
            return promote(Registry(argv[1]), argv[2], argv[3])
    except CannotLook as e:
        print(f"CANNOT LOOK: {e}", file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
