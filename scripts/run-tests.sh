#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

mkdir -p "$MODULE_CACHE"
cd "$ROOT"
swift test --disable-sandbox
"$ROOT/scripts/test-release-scripts.sh"
