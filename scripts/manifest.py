#!/usr/bin/env python3
"""Write manifest.json and checksums.txt for the artifacts in dist/.

Devid reads manifest.json to find, download and verify binaries:

  {"schema": 1, "tag": "2026.11.02", "repo": "hadziqmtqn/devid-binaries",
   "php":   {"8.4": {"version": "8.4.27", "arch": {"x86_64": {"url": ..., "sha256": ..., "size": ...}}}},
   "nginx": {"version": "1.30.6", "arch": {...}},
   "extensions": {"8.4": {"apcu": {"version": "5.1.28", "type": "extension", "file": "apcu.so",
                                   "php_api": "20240924", "license": ..., "source": ..., "env": {},
                                   "arch": {"x86_64": {"url": ..., "sha256": ..., "size": ...}}}}}}

Extension archives (scripts/build-ext.sh) carry ext.json, which must agree with their file name.

Usage: scripts/manifest.py --tag 2026.11.02 [--dist dist] [--repo owner/name]
       scripts/manifest.py --self-test
"""

import argparse
import hashlib
import json
import pathlib
import re
import sys
import tarfile
from datetime import datetime, timezone

# php-8.4.27-darwin-x86_64.tar.gz / nginx-1.30.6-darwin-x86_64.tar.gz / caddy-2.11.7-darwin-x86_64.tar.gz
NAME = re.compile(r"^(?P<tool>php|nginx|caddy)-(?P<version>\d+\.\d+\.\d+)-darwin-(?P<arch>x86_64|arm64)\.tar\.gz$")
# ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz
EXT = re.compile(r"^ext-(?P<name>[a-z0-9_]+)-(?P<version>\d[\w.+]*(?:-\d[\w.+]*)*?)-php(?P<php>\d+\.\d+)-darwin-(?P<arch>x86_64|arm64)\.tar\.gz$")
EXT_FIELDS = ("version", "type", "file", "php_api", "license", "source", "source_sha256", "env")


def parse(name):
    m = NAME.match(name)
    return (m["tool"], m["version"], m["arch"]) if m else None


def parse_ext(name):
    m = EXT.match(name)
    return (m["name"], m["version"], m["php"], m["arch"]) if m else None


def ext_info(path, name, version, php):
    """ext.json from the archive, checked against the file name."""
    with tarfile.open(path, "r:gz") as tar:
        member = tar.extractfile("./ext.json")
        if member is None:
            sys.exit(f"{path.name}: no ext.json")
        info = json.load(member)
    want = {"name": name, "version": version, "php": php, "file": f"{name}.so"}
    for key, value in want.items():
        if info.get(key) != value:
            sys.exit(f"{path.name}: ext.json {key} is {info.get(key)!r}, expected {value!r}")
    if info.get("type") not in ("extension", "zend_extension"):
        sys.exit(f"{path.name}: ext.json type is {info.get('type')!r}")
    return info


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
        parsed, ext = parse(path.name), parse_ext(path.name)
        if not parsed and not ext:
            sys.exit(f"unexpected artifact name: {path.name}")
        digest = sha256(path)
        sums.append(f"{digest}  {path.name}")
        entry = {
            "url": f"https://github.com/{repo}/releases/download/{tag}/{path.name}",
            "sha256": digest,
            "size": path.stat().st_size,
        }
        if ext:
            name, version, php, arch = ext
            info = ext_info(path, name, version, php)
            slot = manifest.setdefault("extensions", {}).setdefault(php, {}).setdefault(
                name, {**{k: info.get(k) for k in EXT_FIELDS}, "arch": {}})
            if slot["version"] != version:
                sys.exit(f"two versions of extension {name} for PHP {php}: {slot['version']} / {version}")
            slot["arch"][arch] = entry
            continue
        tool, version, arch = parsed
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
    for php in manifest.get("extensions", {}):
        if php not in manifest["php"]:
            sys.exit(f"extensions built for PHP {php}, but the release has no PHP {php}")
    return manifest, "\n".join(sums) + "\n"


def self_test():
    import tempfile

    assert parse("php-8.4.27-darwin-x86_64.tar.gz") == ("php", "8.4.27", "x86_64")
    assert parse("nginx-1.30.6-darwin-arm64.tar.gz") == ("nginx", "1.30.6", "arm64")
    assert parse("php-8.4.27-linux-x86_64.tar.gz") is None
    assert parse("evil-1.0.0-darwin-x86_64.tar.gz") is None
    assert parse_ext("ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz") == ("apcu", "5.1.28", "8.4", "x86_64")
    assert parse_ext("ext-ldap-8.4.27-php8.4-darwin-arm64.tar.gz") == ("ldap", "8.4.27", "8.4", "arm64")
    assert parse_ext("ext-pdo_sqlsrv-5.12.0-php8.3-darwin-x86_64.tar.gz")[0] == "pdo_sqlsrv"
    assert parse_ext("ext-Evil-1.0-php8.4-darwin-x86_64.tar.gz") is None
    assert parse_ext("ext-apcu-5.1.28-darwin-x86_64.tar.gz") is None
    assert parse("ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz") is None

    def ext_archive(d, file_name, info):
        import io

        data = json.dumps(info).encode()
        with tarfile.open(pathlib.Path(d) / file_name, "w:gz") as tar:
            member = tarfile.TarInfo("./ext.json")
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))

    good = {"name": "apcu", "version": "5.1.28", "php": "8.4", "php_api": "20240924", "type": "extension",
            "file": "apcu.so", "license": "PHP-3.01", "source": "https://pecl.php.net/get/apcu-5.1.28.tgz",
            "source_sha256": "ab", "env": {}}
    with tempfile.TemporaryDirectory() as d:
        for n in ["php-8.4.27-darwin-x86_64.tar.gz", "php-8.5.12-darwin-x86_64.tar.gz", "nginx-1.30.6-darwin-x86_64.tar.gz"]:
            (pathlib.Path(d) / n).write_bytes(n.encode())
        m, sums = build(d, "t1", "o/r")
        assert set(m["php"]) == {"8.4", "8.5"} and m["php"]["8.4"]["version"] == "8.4.27"
        e = m["nginx"]["arch"]["x86_64"]
        assert e["url"] == "https://github.com/o/r/releases/download/t1/nginx-1.30.6-darwin-x86_64.tar.gz"
        assert e["sha256"] == hashlib.sha256(b"nginx-1.30.6-darwin-x86_64.tar.gz").hexdigest()
        assert sums.count("\n") == 3 and "  php-8.5.12-darwin-x86_64.tar.gz" in sums
        assert "extensions" not in m
        ext_archive(d, "ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz", good)
        m, sums = build(d, "t1", "o/r")
        a = m["extensions"]["8.4"]["apcu"]
        assert a["version"] == "5.1.28" and a["type"] == "extension" and a["php_api"] == "20240924"
        assert a["arch"]["x86_64"]["url"].endswith("/t1/ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz")
        assert sums.count("\n") == 4

    def refused(info, file_name="ext-apcu-5.1.28-php8.4-darwin-x86_64.tar.gz", php="php-8.4.27-darwin-x86_64.tar.gz"):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / php).write_bytes(b"php")
            ext_archive(d, file_name, info)
            try:
                build(d, "t1", "o/r")
            except SystemExit:
                return True
            return False

    assert not refused(good)
    assert refused({**good, "version": "5.1.27"})            # ext.json disagrees with the file name
    assert refused({**good, "type": "module"})
    assert refused({**good, "file": "../../evil.so"})
    assert refused(good, php="php-8.5.12-darwin-x86_64.tar.gz")  # no PHP 8.4 in the release
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
