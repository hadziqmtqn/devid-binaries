#!/bin/bash
# Download the pinned static-php-cli binary into <work dir>, verified before it ever runs.
set -euo pipefail
WORK="${1:?usage: fetch-spc.sh <work dir>}"
SPC_VERSION=2.8.5
case "$(uname -m)" in
  x86_64) SPC_ASSET=spc-macos-x86_64.tar.gz SPC_SHA256=e8b798048f62ca4960764196543b60ae703f7174aa418824cf542aeec1d2cd6a ;;
  arm64) SPC_ASSET=spc-macos-aarch64.tar.gz SPC_SHA256=acf2f25d56d0cbf8e65aa82e5054fef555f7be7c5c38046c6e0819f266d83225 ;;
  *) echo "no static-php-cli pinned for $(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$WORK"
cd "$WORK"
# Capture first: `cmd | grep -q` under pipefail fails on SIGPIPE (see build-php.sh).
[ -x spc ] && grep -q "$SPC_VERSION" <<<"$(./spc --version 2>/dev/null)" && exit 0
curl -fsSL -o spc.tar.gz "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/$SPC_ASSET"
echo "$SPC_SHA256  spc.tar.gz" | shasum -a 256 -c -
tar xzf spc.tar.gz spc
rm spc.tar.gz
