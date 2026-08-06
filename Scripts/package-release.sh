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
codesign --force --deep --sign - "$app"
mkdir -p "$distribution"
zip_name="BeipMU-macOS-universal.zip"
dmg_name="BeipMU-macOS-universal.dmg"
zip_path="$distribution/$zip_name"
dmg_path="$distribution/$dmg_name"
staging=$(mktemp -d "${TMPDIR:-/tmp}/beipmu-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
ditto "$app" "$staging/BeipMU.app"

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
  echo "Created $dmg_path"
  create_checksum "$dmg_name"
fi
