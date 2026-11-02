#!/usr/bin/env python3
"""Write manifest.json and checksums.txt for the artifacts in dist/.

Devid reads manifest.json to find, download and verify binaries:

  {"schema": 1, "tag": "2026.11.02", "repo": "hadziqmtqn/devid-binaries",
   "php":   {"8.4": {"version": "8.4.27", "arch": {"x86_64": {"url": ..., "sha256": ..., "size": ...}}}},
   "nginx": {"version": "1.30.6", "arch": {...}}}

Usage: scripts/manifest.py --tag 2026.11.02 [--dist dist] [--repo owner/name]
       scripts/manifest.py --self-test
"""

import argparse
import hashlib
import json
import pathlib
import re
import sys
from datetime import datetime, timezone

# php-8.4.27-darwin-x86_64.tar.gz / nginx-1.30.6-darwin-x86_64.tar.gz / caddy-2.11.7-darwin-x86_64.tar.gz
NAME = re.compile(r"^(?P<tool>php|nginx|caddy)-(?P<version>\d+\.\d+\.\d+)-darwin-(?P<arch>x86_64|arm64)\.tar\.gz$")


def parse(name):
    m = NAME.match(name)
    return (m["tool"], m["version"], m["arch"]) if m else None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build(dist, tag, repo):
    manifest = {
        "schema": 1,
        "tag": tag,
        "repo": repo,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "php": {},
    }
    sums = []
    for path in sorted(pathlib.Path(dist).glob("*.tar.gz")):
        parsed = parse(path.name)
        if not parsed:
            sys.exit(f"unexpected artifact name: {path.name}")
        tool, version, arch = parsed
        digest = sha256(path)
        sums.append(f"{digest}  {path.name}")
        entry = {
            "url": f"https://github.com/{repo}/releases/download/{tag}/{path.name}",
            "sha256": digest,
            "size": path.stat().st_size,
        }
        if tool == "php":
            minor = ".".join(version.split(".")[:2])
            slot = manifest["php"].setdefault(minor, {"version": version, "arch": {}})
        else:
            slot = manifest.setdefault(tool, {"version": version, "arch": {}})
        if slot["version"] != version:
            sys.exit(f"two versions of {tool} {slot['version']} / {version} in one release")
        slot["arch"][arch] = entry
    if not sums:
        sys.exit(f"no artifacts in {dist}")
    return manifest, "\n".join(sums) + "\n"


def self_test():
    import tempfile

    assert parse("php-8.4.27-darwin-x86_64.tar.gz") == ("php", "8.4.27", "x86_64")
    assert parse("nginx-1.30.6-darwin-arm64.tar.gz") == ("nginx", "1.30.6", "arm64")
    assert parse("php-8.4.27-linux-x86_64.tar.gz") is None
    assert parse("evil-1.0.0-darwin-x86_64.tar.gz") is None
    with tempfile.TemporaryDirectory() as d:
        for n in ["php-8.4.27-darwin-x86_64.tar.gz", "php-8.5.12-darwin-x86_64.tar.gz", "nginx-1.30.6-darwin-x86_64.tar.gz"]:
            (pathlib.Path(d) / n).write_bytes(n.encode())
        m, sums = build(d, "t1", "o/r")
        assert set(m["php"]) == {"8.4", "8.5"} and m["php"]["8.4"]["version"] == "8.4.27"
        e = m["nginx"]["arch"]["x86_64"]
        assert e["url"] == "https://github.com/o/r/releases/download/t1/nginx-1.30.6-darwin-x86_64.tar.gz"
        assert e["sha256"] == hashlib.sha256(b"nginx-1.30.6-darwin-x86_64.tar.gz").hexdigest()
        assert sums.count("\n") == 3 and "  php-8.5.12-darwin-x86_64.tar.gz" in sums
    print("manifest.py self-test ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag")
    ap.add_argument("--dist", default="dist")
    ap.add_argument("--repo", default="hadziqmtqn/devid-binaries")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.tag:
        ap.error("--tag is required")
    manifest, sums = build(args.dist, args.tag, args.repo)
    pathlib.Path(args.dist, "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    pathlib.Path(args.dist, "checksums.txt").write_text(sums)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
