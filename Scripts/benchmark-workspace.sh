#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

swift build -c release --product BeipWorkspaceBenchmark
bin_dir=$(swift build -c release --show-bin-path)
benchmark="$bin_dir/BeipWorkspaceBenchmark"
report_only=${BEIPMU_PERFORMANCE_REPORT_ONLY:-0}
case "$report_only" in
    0) benchmark_mode="" ;;
    1) benchmark_mode="--report-only" ;;
    *) echo "BEIPMU_PERFORMANCE_REPORT_ONLY must be 0 or 1" >&2; exit 2 ;;
esac

echo "Workspace throughput and resident-memory run"
if [ -n "${BEIPMU_EVIDENCE_DIR:-}" ]; then
    metrics_dir="$BEIPMU_EVIDENCE_DIR/workspace-benchmark"
    if [ -e "$metrics_dir" ]; then
        echo "Evidence destination already exists: $metrics_dir" >&2
        exit 2
    fi
    mkdir -p "$metrics_dir"
    preserve_metrics=1
else
    metrics_dir=$(mktemp -d /tmp/beipmu-workspace-benchmark.XXXXXX)
    preserve_metrics=0
fi
metrics_file="$metrics_dir/time.txt"
report_file="$metrics_dir/report.json"
leaks_file="$metrics_dir/leaks.txt"
cleanup() {
    if [ "$preserve_metrics" = "0" ]; then
        rm -f "$metrics_file" "$report_file" "$leaks_file"
        rmdir "$metrics_dir"
    else
        printf 'Preserved workspace benchmark evidence at %s\n' "$metrics_dir"
    fi
}
trap cleanup EXIT HUP INT TERM
/usr/bin/time -l -o "$metrics_file" "$benchmark" ${benchmark_mode:+"$benchmark_mode"} "$@" >"$report_file"
cat "$report_file"
cat "$metrics_file"

peak_resident=$(awk '/maximum resident set size/ { print $1 }' "$metrics_file")
peak_resident_limit=${BEIPMU_BENCHMARK_MAX_RSS_BYTES:-134217728}
if [ "$report_only" = "0" ] && { [ -z "$peak_resident" ] || [ "$peak_resident" -gt "$peak_resident_limit" ]; }; then
    echo "Workspace benchmark exceeded the $peak_resident_limit-byte RSS budget" >&2
    exit 1
fi
if [ "$report_only" = "1" ]; then
    printf 'Report only: RSS measured at %s bytes (reference budget %s bytes)\n' "${peak_resident:-unknown}" "$peak_resident_limit"
fi

if command -v leaks >/dev/null 2>&1; then
    echo "Workspace allocation leak smoke run"
    if leaks -q --atExit -- "$benchmark" ${benchmark_mode:+"$benchmark_mode"} \
        --lines 50000 \
        --history-limit 5000 \
        --queries 20000 \
        --minimum-lines-per-second 100000 \
        --minimum-queries-per-second 200000 >"$leaks_file" 2>&1; then
        cat "$leaks_file"
    else
        status=$?
        cat "$leaks_file"
        exit "$status"
    fi
fi
