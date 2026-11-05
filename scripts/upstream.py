#!/usr/bin/env python3
"""Newest upstream versions of what Devid ships, and whether the current release is behind.

  scripts/upstream.py nginx|caddy|php-8.4    print one version (used by the build scripts)
  scripts/upstream.py --compare manifest.json print what is newer upstream; sets changed=true/false
                                              in $GITHUB_OUTPUT when run in Actions
  scripts/upstream.py --catalog               report for review (Devid Phase 6 E6), changes nothing:
                                              newer stable releases of the catalog's PECL recipes,
                                              a newer ImageMagick for imagick, and popular PIE
                                              packages for macOS and NTS PHP that are not in the
                                              catalog; also written to $GITHUB_STEP_SUMMARY
  scripts/upstream.py --self-test

Sources: php.net's release API; GitHub releases of nginx/nginx (stable = even minor, e.g.
1.30.x; odd minors are mainline) and caddyserver/caddy (latest, no prereleases).
Set GITHUB_TOKEN to avoid GitHub's anonymous API rate limit.
"""

import json
import os
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent

PHP_MINORS = ["8.3", "8.4", "8.5"]  # Devid D-009


def get(url):
    headers = {"User-Agent": "devid-binaries", "Accept": "application/json"}
    if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return r.read()


def get_json(url):
    return json.loads(get(url))


def vtuple(v):
    return tuple(int(p) for p in v.split("."))


def newest_stable_nginx(tags):
    """'release-1.30.6' style tags -> newest version with an even minor (stable branch)."""
    versions = []
    for tag in tags:
        v = tag.removeprefix("release-")
        parts = v.split(".")
        if len(parts) == 3 and all(p.isdigit() for p in parts) and int(parts[1]) % 2 == 0:
            versions.append(v)
    return max(versions, key=vtuple) if versions else None


def latest(tool):
    if tool.startswith("php-"):
        return get_json(f"https://www.php.net/releases/?json&version={tool[4:]}")["version"]
    if tool == "nginx":
        releases = get_json("https://api.github.com/repos/nginx/nginx/releases?per_page=30")
        return newest_stable_nginx(r["tag_name"] for r in releases if not r["prerelease"])
    if tool == "caddy":
        return get_json("https://api.github.com/repos/caddyserver/caddy/releases/latest")["tag_name"].removeprefix("v")
    raise SystemExit(f"unknown tool {tool}")


def behind(manifest, upstream):
    """(what, have, want) for every upstream version newer than the manifest's."""
    out = []
    for minor in PHP_MINORS:
        have = manifest.get("php", {}).get(minor, {}).get("version", "0.0.0")
        want = upstream.get(f"php-{minor}")
        if want and vtuple(want) > vtuple(have):
            out.append((f"php {minor}", have, want))
    for tool in ["nginx", "caddy"]:
        have = manifest.get(tool, {}).get("version", "0.0.0")
        want = upstream.get(tool)
        if want and vtuple(want) > vtuple(have):
            out.append((tool, have, want))
    return out


def vparts(v):
    """'7.1.2-35' -> (7, 1, 2, 35); '3.2.16' -> (3, 2, 16)."""
    return tuple(int(p) for p in re.split(r"[.-]", v))


def plain(v):
    """A final release number: '3.2.16' or '7.1.2-35', not '3.2.17RC1' or '6.3.0alpha'."""
    return re.fullmatch(r"\d+(\.\d+)+(-\d+)?", v) is not None


def recipes():
    """{name: recipe text} for extensions/*.sh."""
    return {p.stem: p.read_text() for p in sorted((ROOT / "extensions").glob("*.sh"))}


def pecl_pins(text):
    """(PECL package, newest final version pinned) of a recipe, or None (php-src recipes)."""
    m = re.search(r"pecl\.php\.net/get/([A-Za-z0-9_]+)-\$VERSION", text)
    versions = [v for v in re.findall(r"VERSION=([0-9][\w.]*)", text) if plain(v)]
    return (m[1], max(versions, key=vparts)) if m and versions else None


def pecl_newest_stable(xml):
    """Newest final release in PECL's allreleases.xml. PECL also calls some RCs 'stable'
    (igbinary 3.2.17RC1), so the version itself must be final too."""
    for v, state in re.findall(r"<v>([^<]+)</v>\s*<s>([^<]+)</s>", xml):
        if state == "stable" and plain(v):
            return v
    return None


def shipped_names():
    """Extensions in Devid's PHP build (EXT and SHARED in build-php.sh): never PIE candidates."""
    text = (ROOT / "scripts" / "build-php.sh").read_text()
    names = set()
    for var in ("EXT", "SHARED"):
        m = re.search(rf'^{var}="([^"]+)"', text, re.M)
        names |= set(m[1].split(",")) if m else set()
    return names


def pie_ok(meta):
    """True when a package's newest version may run on macOS with NTS PHP (PIE metadata)."""
    ext = meta.get("php-ext") or {}
    families = [f.lower() for f in ext.get("os-families", [])]
    excluded = [f.lower() for f in ext.get("os-families-exclude", [])]
    return (not families or "darwin" in families) and "darwin" not in excluded and ext.get("support-nts", True)


def catalog_report(limit=25):
    lines = ["## Catalog (Devid Phase 6 E6): review only, nothing changes", ""]
    found = False
    for name, text in recipes().items():
        pin = pecl_pins(text)
        if not pin:
            continue
        package, have = pin
        want = pecl_newest_stable(get(f"https://pecl.php.net/rest/r/{package.lower()}/allreleases.xml").decode())
        if want and vparts(want) > vparts(have):
            found = True
            lines.append(f"- newer stable on PECL: **{name}** {have} -> {want} (update `extensions/{name}.sh`)")
    m = re.search(r"IM_VERSION=([\w.-]+)", recipes().get("imagick", ""))
    if m:
        tag = get_json("https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest")["tag_name"]
        if plain(tag) and vparts(tag) > vparts(m[1]):
            found = True
            lines.append(f"- newer ImageMagick: {m[1]} -> {tag} (check that the SVG patch still applies, "
                         "or drop it if ImageMagick/ImageMagick#9093 is fixed)")
    if not found:
        lines.append("- every recipe is on its newest stable release")
    known = set(recipes()) | shipped_names()
    packages = []
    for page in range(1, 6):
        data = get_json(f"https://packagist.org/search.json?type=php-ext&per_page=100&page={page}")
        packages += data.get("results", [])
        if not data.get("next"):
            break
    packages.sort(key=lambda p: p.get("downloads", 0), reverse=True)
    lines += ["", f"### PIE packages for macOS and NTS PHP, not in the catalog (most downloaded {limit})", "",
              "| Package | Extension | Downloads | Description |", "|---|---|---|---|"]
    shown = 0
    for p in packages:
        if shown >= limit:
            break
        try:
            versions = get_json(f"https://repo.packagist.org/p2/{p['name']}.json")["packages"][p["name"]]
        except Exception:
            continue
        meta = versions[0] if versions else {}
        ext = (meta.get("php-ext") or {}).get("extension-name") or p["name"].split("/")[-1]
        ext = ext.removeprefix("ext-")
        if ext in known or not pie_ok(meta):
            continue
        shown += 1
        desc = (p.get("description") or "").replace("|", "/")[:80]
        lines.append(f"| {p['name']} | {ext} | {p.get('downloads', 0)} | {desc} |")
    lines += ["", "Adding one is a reviewed recipe PR (`extensions/<name>.sh`); the catalog workflow builds and tests it."]
    return "\n".join(lines) + "\n"


def self_test():
    assert newest_stable_nginx(["release-1.31.8", "release-1.30.6", "release-1.30.10", "release-1.28.9"]) == "1.30.10"
    assert newest_stable_nginx(["release-1.31.8"]) is None
    manifest = {"php": {"8.4": {"version": "8.4.27"}, "8.5": {"version": "8.5.12"}},
                "nginx": {"version": "1.30.6"}, "caddy": {"version": "2.11.7"}}
    up = {"php-8.3": "8.3.36", "php-8.4": "8.4.28", "php-8.5": "8.5.12", "nginx": "1.30.6", "caddy": "2.12.0"}
    assert behind(manifest, up) == [("php 8.3", "0.0.0", "8.3.36"), ("php 8.4", "8.4.27", "8.4.28"), ("caddy", "2.11.7", "2.12.0")]
    assert behind(manifest, {"php-8.4": "8.4.27", "nginx": "1.30.6"}) == []
    # Catalog report helpers.
    assert plain("3.2.16") and plain("7.1.2-35") and not plain("3.2.17RC1") and not plain("6.3.0alpha")
    assert vparts("7.1.2-36") > vparts("7.1.2-35") and vparts("3.2.17") > vparts("3.2.16")
    pinned = 'if x; then\n  VERSION=3.2.17RC1 SHA256=a\nelse\n  VERSION=3.2.16 SHA256=b\nfi\nURL="https://pecl.php.net/get/igbinary-$VERSION.tgz"\n'
    assert pecl_pins(pinned) == ("igbinary", "3.2.16")
    assert pecl_pins("URL=php-src\n") is None
    xml = "<r><v>3.2.17RC1</v><s>stable</s></r><r><v>3.2.16</v><s>stable</s></r>"
    assert pecl_newest_stable(xml) == "3.2.16"
    assert pecl_newest_stable("<r><v>6.3.0RC1</v><s>alpha</s></r><r><v>6.2.4</v><s>stable</s></r>") == "6.2.4"
    assert pie_ok({}) and pie_ok({"php-ext": {"os-families": ["linux", "darwin"]}})
    assert not pie_ok({"php-ext": {"os-families": ["linux"]}})
    assert not pie_ok({"php-ext": {"os-families-exclude": ["darwin"]}})
    assert not pie_ok({"php-ext": {"support-nts": False}})
    assert {"apcu", "imagick", "ldap", "mongodb"} <= set(recipes()) and {"redis", "xdebug", "gd"} <= shipped_names()
    print("upstream.py self-test ok")


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if len(args) == 2 and args[0] == "--compare":
        manifest = json.load(open(args[1]))
        upstream = {t: latest(t) for t in [f"php-{m}" for m in PHP_MINORS] + ["nginx", "caddy"]}
        diffs = behind(manifest, upstream)
        print(f"release {manifest.get('tag')}; upstream {json.dumps(upstream)}")
        for what, have, want in diffs:
            print(f"newer upstream: {what} {have} -> {want}")
        if not diffs:
            print("release is up to date")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"changed={'true' if diffs else 'false'}\n")
        return
    if args == ["--catalog"]:
        report = catalog_report()
        print(report, end="")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
                f.write(report)
        return
    if len(args) == 1:
        version = latest(args[0])
        if not version:
            raise SystemExit(f"no version found for {args[0]}")
        print(version)
        return
    raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
