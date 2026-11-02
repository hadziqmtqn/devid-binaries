#!/bin/bash
# Download the pinned static-php-cli binary into <work dir>, verified before it ever runs.
set -euo pipefail
WORK="${1:?usage: fetch-spc.sh <work dir>}"
SPC_VERSION=2.8.5
SPC_SHA256_X86_64=e8b798048f62ca4960764196543b60ae703f7174aa418824cf542aeec1d2cd6a

[ "$(uname -m)" = x86_64 ] || { echo "only x86_64 is pinned so far (Devid D-010)" >&2; exit 1; }
mkdir -p "$WORK"
cd "$WORK"
[ -x spc ] && ./spc --version 2>/dev/null | grep -q "$SPC_VERSION" && exit 0
curl -fsSL -o spc.tar.gz "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/spc-macos-x86_64.tar.gz"
echo "$SPC_SHA256_X86_64  spc.tar.gz" | shasum -a 256 -c -
tar xzf spc.tar.gz spc
rm spc.tar.gz
