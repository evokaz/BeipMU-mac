#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

line_count=${BEIPMU_APP_SOAK_LINES:-50000}
hold_seconds=${BEIPMU_APP_SOAK_HOLD_SECONDS:-10}
history_limit=${BEIPMU_APP_SOAK_HISTORY_LIMIT:-10000}
max_rss_bytes=${BEIPMU_APP_SOAK_MAX_RSS_BYTES:-268435456}
record_root=$(mktemp -d /tmp/beipmu-app-soak.XXXXXX)
app_pid=""

cleanup() {
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    if [ "${BEIPMU_KEEP_APP_SOAK_ARTIFACTS:-0}" = "1" ]; then
        printf 'Preserved Instruments artifacts at %s\n' "$record_root"
    else
        case "$record_root" in
            /tmp/beipmu-app-soak.*) rm -rf "$record_root" ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

xcodebuild \
    -project BeipMU.xcodeproj \
    -scheme BeipMU \
    -configuration Release \
    -derivedDataPath DerivedData-Soak \
    build \
    -quiet

app_binary="$repo_dir/DerivedData-Soak/Build/Products/Release/BeipMU.app/Contents/MacOS/BeipMU"
trace_path="$record_root/BeipMU-Time-Profiler.trace"
stdout_path="$record_root/BeipMU.stdout"
stderr_path="$record_root/BeipMU.stderr"
toc_path="$record_root/trace-toc.xml"
leaks_path="$record_root/leaks.txt"

env \
    BEIPMU_UI_TESTING=1 \
    BEIPMU_UI_TEST_RESET=1 \
    BEIPMU_PERFORMANCE_SOAK=1 \
    BEIPMU_PERFORMANCE_SOAK_START_DELAY_SECONDS=3 \
    BEIPMU_PERFORMANCE_SOAK_LINES="$line_count" \
    BEIPMU_PERFORMANCE_SOAK_HOLD_SECONDS="$hold_seconds" \
    BEIPMU_PERFORMANCE_SOAK_HISTORY_LIMIT="$history_limit" \
    "$app_binary" >"$stdout_path" 2>"$stderr_path" &
app_pid=$!

xcrun xctrace record \
    --template 'Time Profiler' \
    --output "$trace_path" \
    --time-limit 180s \
    --no-prompt \
    --attach "$app_pid"
wait "$app_pid"
app_pid=""

xcrun xctrace export --input "$trace_path" --toc --output "$toc_path"

BEIPMU_UI_TESTING=1 \
BEIPMU_UI_TEST_RESET=1 \
BEIPMU_PERFORMANCE_SOAK=1 \
BEIPMU_PERFORMANCE_SOAK_LINES="${BEIPMU_APP_LEAK_LINES:-10000}" \
BEIPMU_PERFORMANCE_SOAK_HOLD_SECONDS=1 \
BEIPMU_PERFORMANCE_SOAK_HISTORY_LIMIT="$history_limit" \
    leaks -q --atExit -- "$app_binary" >"$leaks_path" 2>&1 || true

python3 Scripts/verify-app-soak.py \
    "$stdout_path" \
    "$toc_path" \
    "$leaks_path" \
    "$line_count" \
    "$history_limit" \
    "$max_rss_bytes"
