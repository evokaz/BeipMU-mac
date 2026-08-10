#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

line_count=${BEIPMU_APP_SOAK_LINES:-50000}
hold_seconds=${BEIPMU_APP_SOAK_HOLD_SECONDS:-10}
history_limit=${BEIPMU_APP_SOAK_HISTORY_LIMIT:-10000}
max_rss_bytes=${BEIPMU_APP_SOAK_MAX_RSS_BYTES:-268435456}
report_only=${BEIPMU_PERFORMANCE_REPORT_ONLY:-0}
case "$report_only" in
    0) verifier_mode="" ;;
    1) verifier_mode="--report-only" ;;
    *) echo "BEIPMU_PERFORMANCE_REPORT_ONLY must be 0 or 1" >&2; exit 2 ;;
esac
if [ -n "${BEIPMU_EVIDENCE_DIR:-}" ]; then
    record_root="$BEIPMU_EVIDENCE_DIR/app-soak"
    if [ -e "$record_root" ]; then
        echo "Evidence destination already exists: $record_root" >&2
        exit 2
    fi
    mkdir -p "$record_root"
    keep_artifacts=1
else
    record_root=$(mktemp -d /tmp/beipmu-app-soak.XXXXXX)
    keep_artifacts=${BEIPMU_KEEP_APP_SOAK_ARTIFACTS:-0}
fi
ui_state_root=$(mktemp -d /tmp/beipmu-app-soak-state.XXXXXX)
ui_defaults_suite="org.beipmu.BeipMU.UIProfile.$(basename "$ui_state_root")"
app_pid=""

cleanup() {
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    if [ "$keep_artifacts" = "1" ]; then
        printf 'Preserved Instruments artifacts at %s\n' "$record_root"
    else
        case "$record_root" in
            /tmp/beipmu-app-soak.*) rm -rf "$record_root" ;;
        esac
    fi
    defaults delete "$ui_defaults_suite" >/dev/null 2>&1 || true
    case "$ui_state_root" in
        /tmp/beipmu-app-soak-state.*) rm -rf "$ui_state_root" ;;
    esac
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
    BEIPMU_UI_TEST_STATE_DIRECTORY="$ui_state_root" \
    BEIPMU_UI_TEST_DEFAULTS_SUITE="$ui_defaults_suite" \
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
BEIPMU_UI_TEST_STATE_DIRECTORY="$ui_state_root" \
BEIPMU_UI_TEST_DEFAULTS_SUITE="$ui_defaults_suite" \
BEIPMU_PERFORMANCE_SOAK=1 \
BEIPMU_PERFORMANCE_SOAK_LINES="${BEIPMU_APP_LEAK_LINES:-10000}" \
BEIPMU_PERFORMANCE_SOAK_HOLD_SECONDS=1 \
BEIPMU_PERFORMANCE_SOAK_HISTORY_LIMIT="$history_limit" \
    leaks -q --atExit -- "$app_binary" >"$leaks_path" 2>&1 || true

if python3 Scripts/verify-app-soak.py \
    "$stdout_path" \
    "$toc_path" \
    "$leaks_path" \
    "$line_count" \
    "$history_limit" \
    "$max_rss_bytes" \
    ${verifier_mode:+"$verifier_mode"} >"$record_root/verification.txt"; then
    cat "$record_root/verification.txt"
else
    status=$?
    cat "$record_root/verification.txt"
    exit "$status"
fi
