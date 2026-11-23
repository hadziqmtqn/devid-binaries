#!/usr/bin/env python3
"""Database binaries for Devid (D-058): pinned versions, upstream lookups and the db release manifest.

db/versions.json pins every version, and the SHA-256 of each MySQL archive (Oracle publishes only
an MD5 on a download page that refuses scripts, so a pin is reviewed in its pull request). MySQL is
pinned per platform: Oracle stopped building for Intel Macs after 8.4.11 and 9.7.4, so those stay on
their last build while the other platforms move on.
MongoDB's SHA-256 comes from its own full.json, PostgreSQL's from the .sha256 file next to the source
and mongosh's from the digest GitHub records for the release asset.

  scripts/db.py series <engine>                 the pinned series, one per line (mysql, postgresql, mongodb)
  scripts/db.py version <engine> [<series>] [<os-arch>]
                                                the pinned version (mongosh has no series; MySQL needs <os-arch>)
  scripts/db.py mysql-sha256 <series> <os-arch> the pinned SHA-256 of one MySQL archive
  scripts/db.py source <name>                   "<version> <url> <sha256>" of a pinned source (openssl, libaio, numactl)
  scripts/db.py mongodb-asset <version> <os> <arch>
                                                "<url> <sha256>" of the official MongoDB Community archive
  scripts/db.py matrix                          the release workflow's job matrix as JSON (in $GITHUB_OUTPUT too)
  scripts/db.py manifest --tag T [--dist dist] [--repo owner/name]
                                                write manifest.json and checksums.txt for the db release
  scripts/db.py check                           report newer upstream versions and series, changes nothing
  scripts/db.py --self-test
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSIONS = ROOT / "db" / "versions.json"
ENGINES = ["mysql", "postgresql", "mongodb"]
# Devid's arch keys (platform::arch_key()): bare arch on macOS, os-arch on Linux, as in manifest.py.
TARGETS = [
    {"os": "darwin", "arch": "x86_64", "key": "x86_64", "runner": "macos-15-intel"},
    {"os": "darwin", "arch": "arm64", "key": "arm64", "runner": "macos-15"},
    {"os": "linux", "arch": "x86_64", "key": "linux-x86_64", "runner": "ubuntu-24.04"},
]
# mysql-9.7.4-darwin-arm64.tar.gz / postgresql-17.12-linux-x86_64.tar.gz / mongosh-2.14.3-darwin-x86_64.tar.gz
NAME = re.compile(r"^(?P<tool>mysql|postgresql|mongodb|mongosh)-(?P<version>\d+\.\d+(?:\.\d+)?)"
                  r"-(?P<os>darwin|linux)-(?P<arch>x86_64|arm64)\.tar\.gz$")


def pins():
    return json.loads(VERSIONS.read_text())


def series_of(engine, version):
    """'9.7.4' -> '9.7' (MySQL, MongoDB); '17.12' -> '17' (PostgreSQL)."""
    parts = version.split(".")
    return parts[0] if engine == "postgresql" else ".".join(parts[:2])


def pinned_version(p, engine, series=None, os_arch=None):
    """MySQL is pinned per platform ("darwin-x86_64", ...), the others per series."""
    if engine == "mongosh":
        return p["mongosh"]
    if engine == "mysql":
        return p["mysql"][series][os_arch]["version"]
    return p[engine][series]


def get(url, accept="application/json"):
    headers = {"User-Agent": "devid-binaries", "Accept": accept}
    if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
        return r.read()


def exists(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "devid-binaries"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200 and int(r.headers.get("Content-Length") or 0) > 1_000_000
    except urllib.error.HTTPError:
        return False


def vtuple(v):
    return tuple(int(p) for p in v.split("."))


# MongoDB --------------------------------------------------------------------------------------

def mongodb_full():
    return json.loads(get("https://downloads.mongodb.org/full.json"))


def mongodb_pick(full, version, os_name, arch):
    """The Community archive: macOS's "base" edition; on Linux the Ubuntu 22.04 build, which also
    runs on 24.04 and Debian 12 (MongoDB publishes no generic Linux build since 4.4)."""
    target, edition, want_arch = {
        ("darwin", "x86_64"): ("macos", "base", "x86_64"),
        ("darwin", "arm64"): ("macos", "base", "arm64"),
        ("linux", "x86_64"): ("ubuntu2204", "targeted", "x86_64"),
    }[(os_name, arch)]
    for v in full["versions"]:
        if v["version"] != version:
            continue
        for dl in v["downloads"]:
            if dl.get("target") == target and dl.get("edition") == edition and dl.get("arch") == want_arch:
                a = dl["archive"]
                if not re.fullmatch(r"[0-9a-f]{64}", a.get("sha256", "")):
                    raise SystemExit(f"mongodb {version} {target}: no sha256 in full.json")
                return a["url"], a["sha256"]
        raise SystemExit(f"mongodb {version}: no {edition} build for {target} {want_arch}")
    raise SystemExit(f"mongodb {version}: not in full.json")


def mongodb_latest(full):
    """{series: newest production version} for every series with a macOS and an Ubuntu 22.04 build."""
    out = {}
    for v in full["versions"]:
        if not v.get("production_release") or v.get("release_candidate"):
            continue
        targets = {(d.get("target"), d.get("edition")) for d in v["downloads"]}
        if ("macos", "base") not in targets or ("ubuntu2204", "targeted") not in targets:
            continue
        s = series_of("mongodb", v["version"])
        if s not in out or vtuple(v["version"]) > vtuple(out[s]):
            out[s] = v["version"]
    return out


# Upstream report ------------------------------------------------------------------------------

def postgresql_upstream():
    """{major: newest version} for every major postgresql.org still supports."""
    return {str(v["major"]): f"{v['major']}.{v['latestMinor']}"
            for v in json.loads(get("https://www.postgresql.org/versions.json"))
            if v.get("supported") and int(str(v["major"]).split(".")[0]) >= 10}


def mysql_url(version, os_name, arch):
    series = series_of("mysql", version)
    name = {
        ("darwin", "x86_64"): f"mysql-{version}-macos15-x86_64.tar.gz",
        ("darwin", "arm64"): f"mysql-{version}-macos15-arm64.tar.gz",
        ("linux", "x86_64"): f"mysql-{version}-linux-glibc2.28-x86_64-minimal.tar.xz",
    }[(os_name, arch)]
    return f"https://cdn.mysql.com/Downloads/MySQL-{series}/{name}"


def mysql_newer(version, os_name, arch, probe=exists, look_ahead=4):
    """The newest patch release after <version> that Oracle's CDN serves for one platform, or None.
    Oracle publishes no machine-readable release list, so the next few patch numbers are probed."""
    major, minor, patch = vtuple(version)
    newest = None
    for p in range(patch + 1, patch + 1 + look_ahead):
        candidate = f"{major}.{minor}.{p}"
        if probe(mysql_url(candidate, os_name, arch)):
            newest = candidate
    return newest


def check():
    p = pins()
    lines = ["## Database binaries (Devid D-058): upstream check, nothing changes", ""]
    up = postgresql_upstream()
    for major, want in sorted(up.items(), key=lambda kv: int(kv[0])):
        have = p["postgresql"].get(major)
        if not have:
            lines.append(f"- new PostgreSQL series **{major}** ({want}): add it to `db/versions.json`")
        elif vtuple(want) > vtuple(have):
            lines.append(f"- PostgreSQL {major}: {have} -> **{want}**")
    for major in p["postgresql"]:
        if major not in up:
            lines.append(f"- PostgreSQL {major} is no longer supported upstream: consider dropping it")
    latest = mongodb_latest(mongodb_full())
    for s, have in p["mongodb"].items():
        want = latest.get(s)
        if want and vtuple(want) > vtuple(have):
            lines.append(f"- MongoDB {s}: {have} -> **{want}**")
    newest_series = max(latest, key=vtuple)
    if newest_series not in p["mongodb"] and newest_series.endswith(".0"):
        lines.append(f"- new MongoDB major **{newest_series}** ({latest[newest_series]}): add it to `db/versions.json`")
    mongosh = json.loads(get("https://api.github.com/repos/mongodb-js/mongosh/releases/latest"))["tag_name"].removeprefix("v")
    if vtuple(mongosh) > vtuple(p["mongosh"]):
        lines.append(f"- mongosh: {p['mongosh']} -> **{mongosh}**")
    for s, builds in p["mysql"].items():
        for t in TARGETS:
            have = builds[f"{t['os']}-{t['arch']}"]["version"]
            newer = mysql_newer(have, t["os"], t["arch"])
            if newer:
                lines.append(f"- MySQL {s} on {t['os']}-{t['arch']}: {have} -> **{newer}** (pin its SHA-256; "
                             "compare its MD5 with Oracle's download page)")
    if len(lines) == 2:
        lines.append("- every pinned database is on its newest release")
    lines += ["", "MySQL series are not discovered automatically: check Oracle's LTS and Innovation releases by hand."]
    return "\n".join(lines) + "\n"


# Release --------------------------------------------------------------------------------------

def matrix(p):
    """The release workflow's jobs: per target, one for every MySQL series, one for mongosh and every
    MongoDB series (mongosh then queries each server), and one per PostgreSQL series (a build)."""
    include = []
    for t in TARGETS:
        include.append({**t, "engine": "mysql", "series": ""})
        include.append({**t, "engine": "mongodb", "series": ""})
        for s in p["postgresql"]:
            include.append({**t, "engine": "postgresql", "series": s})
    return {"include": include}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_manifest(dist, tag, repo, p):
    """{"schema": 1, "tag", "repo", "generated",
        "mysql": {"8.4": {"version": "8.4.13", "arch": {"arm64": {"version": "8.4.13", "url", "sha256", "size"},
                                                        "x86_64": {"version": "8.4.11", ...}}}},
        "postgresql": {...}, "mongodb": {...}, "mongosh": {"version", "arch": {...}}}
    Every arch entry has its own "version"; only MySQL's may differ from the series' newest."""
    manifest = {"schema": 1, "tag": tag, "repo": repo,
                "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    sums = []
    for path in sorted(pathlib.Path(dist).glob("*.tar.gz")):
        m = NAME.match(path.name)
        if not m:
            sys.exit(f"unexpected artifact name: {path.name}")
        tool, version = m["tool"], m["version"]
        key = m["arch"] if m["os"] == "darwin" else f"{m['os']}-{m['arch']}"
        digest = sha256(path)
        sums.append(f"{digest}  {path.name}")
        entry = {"version": version, "url": f"https://github.com/{repo}/releases/download/{tag}/{path.name}",
                 "sha256": digest, "size": path.stat().st_size}
        if tool == "mongosh":
            slot = manifest.setdefault("mongosh", {"version": version, "arch": {}})
        else:
            s = series_of(tool, version)
            if s not in p[tool]:
                sys.exit(f"{path.name}: series {s} is not in db/versions.json")
            slot = manifest.setdefault(tool, {}).setdefault(s, {"version": version, "arch": {}})
        os_arch = f"{m['os']}-{m['arch']}"
        if pinned_version(p, tool, None if tool == "mongosh" else series_of(tool, version), os_arch) != version:
            sys.exit(f"{path.name}: db/versions.json pins another version")
        if key in slot["arch"]:
            sys.exit(f"two {tool} builds for {key}: {slot['arch'][key]['version']} / {version}")
        if tool == "mysql":
            # Per platform: the entry's "version" is the newest; each arch entry has its own.
            if vtuple(version) > vtuple(slot["version"]):
                slot["version"] = version
        elif slot["version"] != version:
            sys.exit(f"two versions of {tool} {slot['version']} / {version} in one release")
        slot["arch"][key] = entry
    if not sums:
        sys.exit(f"no artifacts in {dist}")
    want = {t["key"] for t in TARGETS}
    for tool in ENGINES:
        for s in p[tool]:
            have = set(manifest.get(tool, {}).get(s, {}).get("arch", {}))
            if have != want:
                sys.exit(f"{tool} {s}: builds for {sorted(have)}, expected {sorted(want)}")
    if set(manifest.get("mongosh", {}).get("arch", {})) != want:
        sys.exit("mongosh: a target is missing")
    return manifest, "\n".join(sums) + "\n"


# Self-test ------------------------------------------------------------------------------------

def self_test():
    import tempfile

    p = pins()
    assert set(p) >= set(ENGINES) | {"mongosh", "sources"}
    for s, builds in p["mysql"].items():
        assert set(builds) == {"darwin-x86_64", "darwin-arm64", "linux-x86_64"}, s
        for b in builds.values():
            assert series_of("mysql", b["version"]) == s and re.fullmatch(r"[0-9a-f]{64}", b["sha256"]), b
    for engine in ("postgresql", "mongodb"):
        for s, v in p[engine].items():
            assert series_of(engine, v) == s, (engine, s, v)
    for src in p["sources"].values():
        assert re.fullmatch(r"[0-9a-f]{64}", src["sha256"]) and src["url"].startswith("https://")
    assert series_of("postgresql", "17.12") == "17" and series_of("mysql", "9.7.4") == "9.7"
    assert NAME.match("postgresql-17.12-linux-x86_64.tar.gz")["version"] == "17.12"
    assert NAME.match("mongodb-9.0.8-darwin-arm64.tar.gz")["tool"] == "mongodb"
    assert not NAME.match("mysql-9.7.4-windows-x86_64.tar.gz") and not NAME.match("php-8.4.1-darwin-arm64.tar.gz")
    assert mysql_url("9.7.4", "linux", "x86_64").endswith("/MySQL-9.7/mysql-9.7.4-linux-glibc2.28-x86_64-minimal.tar.xz")
    assert mysql_newer("9.7.4", "darwin", "arm64", probe=lambda u: "9.7.5-macos15-arm64" in u or "9.7.7-" in u) == "9.7.7"
    assert mysql_newer("9.7.4", "darwin", "x86_64", probe=lambda u: "9.7.5-macos15-arm64" in u) is None
    assert mysql_newer("9.7.4", "linux", "x86_64", probe=lambda u: False) is None

    def dl(target, edition, arch, h="a" * 64):
        return {"target": target, "edition": edition, "arch": arch,
                "archive": {"url": f"https://x/{target}-{arch}.tgz", "sha256": h}}
    full = {"versions": [
        {"version": "9.0.9", "production_release": True, "downloads": [
            dl("macos", "base", "arm64"), dl("macos", "base", "x86_64", "b" * 64), dl("ubuntu2204", "targeted", "x86_64")]},
        {"version": "9.0.8", "production_release": True, "downloads": [
            dl("macos", "enterprise", "arm64", "e" * 64), dl("macos", "base", "arm64", "c" * 64),
            dl("ubuntu2204", "targeted", "x86_64")]},
        {"version": "9.1.0-rc0", "production_release": False, "downloads": []},
    ]}
    assert mongodb_pick(full, "9.0.8", "darwin", "arm64") == ("https://x/macos-arm64.tgz", "c" * 64)
    assert mongodb_pick(full, "9.0.9", "darwin", "x86_64")[1] == "b" * 64
    assert mongodb_latest(full) == {"9.0": "9.0.9"}
    for bad in [("9.0.8", "darwin", "x86_64"), ("8.0.1", "darwin", "arm64")]:
        try:
            mongodb_pick(full, *bad)
            raise AssertionError(f"mongodb_pick accepted {bad}")
        except SystemExit:
            pass

    m = matrix(p)["include"]
    assert len(m) == 3 * (2 + len(p["postgresql"])) and {j["key"] for j in m} == {"x86_64", "arm64", "linux-x86_64"}

    small = {"mysql": {"8.4": {"darwin-x86_64": {"version": "8.4.11"}, "darwin-arm64": {"version": "8.4.13"},
                               "linux-x86_64": {"version": "8.4.13"}},
                       "9.7": {k: {"version": "9.7.4"} for k in ["darwin-x86_64", "darwin-arm64", "linux-x86_64"]}},
             "postgresql": {"17": "17.12"}, "mongodb": {}, "mongosh": "2.14.3"}
    with tempfile.TemporaryDirectory() as d:
        names = [f"{tool}-{v}-{os_arch}.tar.gz" for tool, v in [("mysql", "9.7.4"), ("postgresql", "17.12"), ("mongosh", "2.14.3")]
                 for os_arch in ["darwin-x86_64", "darwin-arm64", "linux-x86_64"]]
        names += ["mysql-8.4.11-darwin-x86_64.tar.gz", "mysql-8.4.13-darwin-arm64.tar.gz", "mysql-8.4.13-linux-x86_64.tar.gz"]
        for n_ in names:
            (pathlib.Path(d) / n_).write_bytes(n_.encode())
        man, sums = build_manifest(d, "db-t1", "o/r", small)
        assert set(man["mysql"]["9.7"]["arch"]) == {"x86_64", "arm64", "linux-x86_64"}
        assert man["postgresql"]["17"]["version"] == "17.12" and man["mongosh"]["version"] == "2.14.3"
        e = man["mysql"]["9.7"]["arch"]["linux-x86_64"]
        assert e["url"] == "https://github.com/o/r/releases/download/db-t1/mysql-9.7.4-linux-x86_64.tar.gz"
        assert e["sha256"] == hashlib.sha256(b"mysql-9.7.4-linux-x86_64.tar.gz").hexdigest()
        assert sums.count("\n") == 12
        m84 = man["mysql"]["8.4"]
        assert m84["version"] == "8.4.13" and m84["arch"]["x86_64"]["version"] == "8.4.11"
        assert m84["arch"]["arm64"]["url"].endswith("/mysql-8.4.13-darwin-arm64.tar.gz")
        assert man["postgresql"]["17"]["arch"]["arm64"]["version"] == "17.12"
        (pathlib.Path(d) / "mysql-8.4.12-darwin-arm64.tar.gz").write_bytes(b"x")
        try:
            build_manifest(d, "db-t1", "o/r", small)  # not the pinned version, and a second arm64 build
            raise AssertionError("an unpinned MySQL version was accepted")
        except SystemExit:
            pass
        (pathlib.Path(d) / "mysql-8.4.12-darwin-arm64.tar.gz").unlink()
        (pathlib.Path(d) / "postgresql-17.12-linux-x86_64.tar.gz").unlink()
        try:
            build_manifest(d, "db-t1", "o/r", small)  # a target is missing
            raise AssertionError("a missing target was accepted")
        except SystemExit:
            pass
        (pathlib.Path(d) / "postgresql-17.12-linux-x86_64.tar.gz").write_bytes(b"x")
        (pathlib.Path(d) / "postgresql-16.4-linux-x86_64.tar.gz").write_bytes(b"x")
        try:
            build_manifest(d, "db-t1", "o/r", small)  # series 16 is not pinned
            raise AssertionError("an unpinned series was accepted")
        except SystemExit:
            pass
    print("db.py self-test ok")


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    p = pins()
    if len(args) == 2 and args[0] == "series":
        print("\n".join(p[args[1]]))
    elif len(args) in (2, 3, 4) and args[0] == "version":
        print(pinned_version(p, *args[1:]))
    elif len(args) == 3 and args[0] == "mysql-sha256":
        print(p["mysql"][args[1]][args[2]]["sha256"])
    elif len(args) == 2 and args[0] == "source":
        s = p["sources"][args[1]]
        print(s["version"], s["url"], s["sha256"])
    elif len(args) == 4 and args[0] == "mongodb-asset":
        print(*mongodb_pick(mongodb_full(), *args[1:]))
    elif args == ["matrix"]:
        out = json.dumps(matrix(p))
        print(out)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"matrix={out}\n")
    elif args and args[0] == "manifest":
        ap = argparse.ArgumentParser(prog="db.py manifest")
        ap.add_argument("--tag", required=True)
        ap.add_argument("--dist", default="dist")
        ap.add_argument("--repo", default="hadziqmtqn/devid-binaries")
        a = ap.parse_args(args[1:])
        manifest, sums = build_manifest(a.dist, a.tag, a.repo, p)
        pathlib.Path(a.dist, "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        pathlib.Path(a.dist, "checksums.txt").write_text(sums)
        print(json.dumps(manifest, indent=2))
    elif args == ["check"]:
        report = check()
        print(report, end="")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
                f.write(report)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
