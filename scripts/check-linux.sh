#!/bin/bash
# Checks for every ELF file a Linux release ships (Devid D-057, Phase 12 L1):
# - it needs only glibc's own libraries (no libstdc++, no library from the build machine);
# - no glibc symbol is newer than <glibc min>, so older distros run it;
# - no rpath or runpath points into the build machine.
# With "static" in place of a glibc version, each file must have no dynamic part at all (nginx).
#   scripts/check-linux.sh <glibc min | static> <file...>
set -euo pipefail
MIN="${1:?usage: check-linux.sh <glibc min | static> <file...>}"
shift
fail=0
for f in "$@"; do
  # Capture first: with pipefail, `cmd | grep -q` fails when grep exits early (see build-php.sh).
  dyn="$(readelf -d "$f" 2>&1)"
  segments="$(readelf -l "$f" 2>&1)"
  if [ "$MIN" = static ]; then
    if grep -q INTERP <<<"$segments" || grep -q '(NEEDED)' <<<"$dyn"; then
      echo "FAIL: $f is not fully static" >&2; fail=1
    fi
    continue
  fi
  needed="$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn")"
  other="$(grep -vxE 'lib(c|m|dl|pthread|rt|util|resolv)\.so\.[0-9]+|ld-linux-x86-64\.so\.2' <<<"$needed" || true)"
  if [ -n "$other" ]; then
    echo "FAIL: $f links libraries outside glibc: $(tr '\n' ' ' <<<"$other")" >&2; fail=1
  fi
  if grep -qE '\((RPATH|RUNPATH)\)' <<<"$dyn"; then
    echo "FAIL: $f has an rpath: $(grep -E '\((RPATH|RUNPATH)\)' <<<"$dyn")" >&2; fail=1
  fi
  symbols="$(objdump -T "$f")"
  newest="$(grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$symbols" | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"
  if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$MIN" | sort -V | tail -1)" != "$MIN" ]; then
    echo "FAIL: $f needs glibc $newest, newer than $MIN" >&2; fail=1
  fi
done
exit "$fail"
