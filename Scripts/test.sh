#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_dir/.build/ModuleCache"
mkdir -p "$module_cache"

python3 "$repo_dir/Scripts/generate-parity-items.py" --check
python3 "$repo_dir/Scripts/generate-m10-fixtures.py" --check
python3 "$repo_dir/Scripts/verify-parity-matrix.py" --check
python3 "$repo_dir/Scripts/verify-m10-evidence.py" --contract-only

CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift test --package-path "$repo_dir" --disable-sandbox
