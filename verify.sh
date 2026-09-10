#!/bin/bash
#
# Builds and runs the runtime verification harness (Tools/MacDuoProbe).
# It compiles the shader, runs the real blur + composite pipeline against a
# synthetic frame, and checks that the keystone warp actually moves pixels.
#
#   ./verify.sh                 checks only
#   ./verify.sh <output-dir>    also writes preview PNGs of the effect
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$ROOT/.scratch"

cd "$ROOT"
mkdir -p "$SCRATCH"

export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-modules"
export SWIFT_MODULECACHE_PATH="$SCRATCH/swift-modules"

echo "==> Regenerating embedded shader source"
python3 Tools/embed-shader.py

SWIFT_FLAGS=(--scratch-path "$SCRATCH" --disable-sandbox)

echo "==> Building"
swift build -c release "${SWIFT_FLAGS[@]}"
BIN_PATH="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)"

if [[ $# -ge 1 ]]; then
  export MACDUO_PROBE_OUT="$1"
  echo "==> Preview frames will be written to $1"
fi

echo "==> Running probe"
"$BIN_PATH/MacDuoProbe"
