#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

record_marker="$repo_dir/UITests/.record-baselines"
record_root=""
rm -f "$record_marker"
cleanup() {
    rm -f "$record_marker"
    case "$record_root" in
        /tmp/beipmu-ui-baselines.*) rm -rf "$record_root" ;;
    esac
}
if [ "${BEIPMU_RECORD_BASELINES:-0}" = "1" ]; then
    record_root=$(mktemp -d /tmp/beipmu-ui-baselines.XXXXXX)
    : > "$record_marker"
    trap cleanup EXIT HUP INT TERM

    result_bundle="$record_root/BeipMU-UI.xcresult"
    attachment_dir="$record_root/attachments"
    xcodebuild \
        -project BeipMU.xcodeproj \
        -scheme BeipMU \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath DerivedData-UI \
        -only-testing:BeipMUXCUITests \
        -resultBundlePath "$result_bundle" \
        test
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$attachment_dir"
    python3 Scripts/extract-ui-baselines.py \
        "$attachment_dir" \
        "$repo_dir/UITests/Baselines"
else
    xcodebuild \
        -project BeipMU.xcodeproj \
        -scheme BeipMU \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath DerivedData-UI \
        -only-testing:BeipMUXCUITests \
        test
fi
