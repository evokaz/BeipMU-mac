#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_dir/.build/ModuleCache"
iterations=${BEIPMU_STRESS_ITERATIONS:-3}
workers=${BEIPMU_STRESS_WORKERS:-4}

case "$iterations" in
    ''|*[!0-9]*|0) echo "BEIPMU_STRESS_ITERATIONS must be a positive integer" >&2; exit 2 ;;
esac
case "$workers" in
    ''|*[!0-9]*|0) echo "BEIPMU_STRESS_WORKERS must be a positive integer" >&2; exit 2 ;;
esac

mkdir -p "$module_cache"
python3 "$repo_dir/Scripts/generate-m10-fixtures.py" --check

iteration=1
while [ "$iteration" -le "$iterations" ]; do
    printf 'Parallel stress iteration %s/%s (%s workers)\n' "$iteration" "$iterations" "$workers"
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift test \
        --package-path "$repo_dir" \
        --disable-sandbox \
        --parallel \
        --num-workers "$workers"
    iteration=$((iteration + 1))
done
