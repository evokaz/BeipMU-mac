#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_dir/.build/ModuleCache"
mkdir -p "$module_cache"

python3 "$repo_dir/Scripts/generate-m10-fixtures.py" --check

CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift test --package-path "$repo_dir" --disable-sandbox
