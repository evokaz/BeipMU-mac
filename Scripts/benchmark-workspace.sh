#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

swift build -c release --product BeipWorkspaceBenchmark
bin_dir=$(swift build -c release --show-bin-path)
benchmark="$bin_dir/BeipWorkspaceBenchmark"

echo "Workspace throughput and resident-memory run"
metrics_dir=$(mktemp -d /tmp/beipmu-workspace-benchmark.XXXXXX)
metrics_file="$metrics_dir/time.txt"
trap 'rm -f "$metrics_file"; rmdir "$metrics_dir"' EXIT HUP INT TERM
/usr/bin/time -l -o "$metrics_file" "$benchmark" "$@"
cat "$metrics_file"

peak_resident=$(awk '/maximum resident set size/ { print $1 }' "$metrics_file")
peak_resident_limit=${BEIPMU_BENCHMARK_MAX_RSS_BYTES:-134217728}
if [ -z "$peak_resident" ] || [ "$peak_resident" -gt "$peak_resident_limit" ]; then
    echo "Workspace benchmark exceeded the $peak_resident_limit-byte RSS budget" >&2
    exit 1
fi

if command -v leaks >/dev/null 2>&1; then
    echo "Workspace allocation leak smoke run"
    leaks -q --atExit -- "$benchmark" \
        --lines 50000 \
        --history-limit 5000 \
        --queries 20000 \
        --minimum-lines-per-second 100000 \
        --minimum-queries-per-second 200000
fi
