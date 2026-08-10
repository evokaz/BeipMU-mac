#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: Scripts/package-release.sh [--format zip|dmg|both]

Build and package BeipMU for direct distribution. The default format is zip.
EOF
}

format=zip
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --format." >&2
        usage >&2
        exit 2
      fi
      format=$2
      shift 2
      ;;
    --format=*)
      format=${1#*=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$format" in
  zip|dmg|both)
    ;;
  *)
    echo "Invalid format: $format. Expected zip, dmg, or both." >&2
    usage >&2
    exit 2
    ;;
esac

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_dir/DerivedData"
distribution="$repo_dir/dist"

cd "$repo_dir"
./Scripts/generate-project.sh
xcodebuild \
  -project BeipMU.xcodeproj \
  -scheme BeipMU \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

app="$derived_data/Build/Products/Release/BeipMU.app"
test -d "$app"
main_executable="$app/Contents/MacOS/BeipMU"
script_service_executable="$app/Contents/XPCServices/BeipScriptService.xpc/Contents/MacOS/BeipScriptService"
test -f "$main_executable"
test -f "$script_service_executable"

# Keep the matching dSYMs in DerivedData, but remove build-machine paths and
# other debug records from the binaries that are distributed.
strip -S "$main_executable"
strip -S "$script_service_executable"
codesign --force --deep --sign - "$app"
mkdir -p "$distribution"
zip_name="BeipMU-macOS-universal.zip"
dmg_name="BeipMU-macOS-universal.dmg"
zip_path="$distribution/$zip_name"
dmg_path="$distribution/$dmg_name"
staging=$(mktemp -d "${TMPDIR:-/tmp}/beipmu-release.XXXXXX")
mounted_dmg=

cleanup() {
  if [ -n "$mounted_dmg" ]; then
    hdiutil detach "$mounted_dmg" >/dev/null 2>&1 || true
  fi
  rm -rf "$staging"
}

trap cleanup EXIT HUP INT TERM

private_path_matches() {
  scan_root=$1
  {
    LC_ALL=C find "$scan_root" -type f \
      -exec grep -a -l -E '/Users/[^/]+/|/home/[^/]+/|/private/var/folders/[^/]+/' {} + 2>/dev/null || true
    LC_ALL=C find "$scan_root" -type f \
      -exec grep -a -l -F "$repo_dir" {} + 2>/dev/null || true
    if [ -n "${TMPDIR:-}" ]; then
      LC_ALL=C find "$scan_root" -type f \
        -exec grep -a -l -F "${TMPDIR%/}" {} + 2>/dev/null || true
    fi
  } | sort -u
}

verify_distributable_app() {
  verified_app=$1
  artifact_label=$2
  test -d "$verified_app"

  matches=$(private_path_matches "$verified_app")
  if [ -n "$matches" ]; then
    echo "Refusing to package $artifact_label: private build paths remain in:" >&2
    echo "$matches" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=1 "$verified_app"
  echo "Verified $artifact_label contains no private build paths."
}

verify_distributable_app "$app" "Release app"
ditto "$app" "$staging/BeipMU.app"
cp "$repo_dir/Documentation/DISTRIBUTION.md" "$staging/INSTALL.md"

rm -f \
  "$zip_path" \
  "$zip_path.sha256" \
  "$dmg_path" \
  "$dmg_path.sha256"

create_checksum() {
  artifact_name=$1
  checksum_name="$artifact_name.sha256"
  (cd "$distribution" && shasum -a 256 "$artifact_name" > "$checksum_name")
  echo "Created $distribution/$checksum_name"
}

if [ "$format" = zip ] || [ "$format" = both ]; then
  ditto -c -k --norsrc --noextattr --noqtn --noacl "$staging" "$zip_path"
  zip_verification="$staging/zip-verification"
  mkdir "$zip_verification"
  ditto -x -k "$zip_path" "$zip_verification"
  verify_distributable_app "$zip_verification/BeipMU.app" "$zip_name"
  echo "Created $zip_path"
  create_checksum "$zip_name"
fi

if [ "$format" = dmg ] || [ "$format" = both ]; then
  dmg_staging="$staging/dmg"
  mkdir "$dmg_staging"
  ditto "$app" "$dmg_staging/BeipMU.app"
  ln -s /Applications "$dmg_staging/Applications"
  hdiutil create \
    -volname "BeipMU" \
    -srcfolder "$dmg_staging" \
    -ov \
    -format UDZO \
    "$dmg_path"
  dmg_verification="$staging/dmg-verification"
  mkdir "$dmg_verification"
  hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$dmg_verification" \
    "$dmg_path" >/dev/null
  mounted_dmg="$dmg_verification"
  verify_distributable_app "$dmg_verification/BeipMU.app" "$dmg_name"
  hdiutil detach "$mounted_dmg" >/dev/null
  mounted_dmg=
  echo "Created $dmg_path"
  create_checksum "$dmg_name"
fi
