#!/usr/bin/env python3
"""Newest upstream versions of what Devid ships, and whether the current release is behind.

  scripts/upstream.py nginx|caddy|php-8.4    print one version (used by the build scripts)
  scripts/upstream.py --compare manifest.json print what is newer upstream; sets changed=true/false
                                              in $GITHUB_OUTPUT when run in Actions
  scripts/upstream.py --self-test

Sources: php.net's release API; GitHub releases of nginx/nginx (stable = even minor, e.g.
1.30.x; odd minors are mainline) and caddyserver/caddy (latest, no prereleases).
Set GITHUB_TOKEN to avoid GitHub's anonymous API rate limit.
"""

import json
import os
import sys
import urllib.request

PHP_MINORS = ["8.3", "8.4", "8.5"]  # Devid D-009


def get_json(url):
    headers = {"User-Agent": "devid-binaries", "Accept": "application/json"}
    if "api.github.com" in url and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return json.load(r)


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


def self_test():
    assert newest_stable_nginx(["release-1.31.8", "release-1.30.6", "release-1.30.10", "release-1.28.9"]) == "1.30.10"
    assert newest_stable_nginx(["release-1.31.8"]) is None
    manifest = {"php": {"8.4": {"version": "8.4.27"}, "8.5": {"version": "8.5.12"}},
                "nginx": {"version": "1.30.6"}, "caddy": {"version": "2.11.7"}}
    up = {"php-8.3": "8.3.36", "php-8.4": "8.4.28", "php-8.5": "8.5.12", "nginx": "1.30.6", "caddy": "2.12.0"}
    assert behind(manifest, up) == [("php 8.3", "0.0.0", "8.3.36"), ("php 8.4", "8.4.27", "8.4.28"), ("caddy", "2.11.7", "2.12.0")]
    assert behind(manifest, {"php-8.4": "8.4.27", "nginx": "1.30.6"}) == []
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
    if len(args) == 1:
        version = latest(args[0])
        if not version:
            raise SystemExit(f"no version found for {args[0]}")
        print(version)
        return
    raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
