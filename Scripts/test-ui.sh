#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

record_marker="$repo_dir/UITests/.record-baselines"
record_root=""
evidence_root=${BEIPMU_EVIDENCE_DIR:-}
scale_result="${TMPDIR:-/tmp}/beipmu-m10-scale-ui-result.json"
rm -f "$record_marker"
rm -f "$scale_result"
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
    if [ -n "$evidence_root" ]; then
        ui_evidence="$evidence_root/ui-tests"
        result_bundle="$ui_evidence/BeipMU-UI.xcresult"
        if [ -e "$ui_evidence" ]; then
            echo "Evidence destination already exists: $ui_evidence" >&2
            exit 2
        fi
        mkdir -p "$ui_evidence"
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
            --output-path "$ui_evidence/attachments"
        if [ -f "$scale_result" ]; then
            cp "$scale_result" "$ui_evidence/ui-scale-result.json"
        fi
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
fi
