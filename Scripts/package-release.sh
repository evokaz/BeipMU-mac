#!/bin/sh
set -eu

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
checksum_name="$zip_name.sha256"
zip_path="$distribution/$zip_name"
checksum_path="$distribution/$checksum_name"
staging=$(mktemp -d "${TMPDIR:-/tmp}/beipmu-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
ditto "$app" "$staging/BeipMU.app"
cp "$repo_dir/LICENSE" "$staging/LICENSE"
cp "$repo_dir/Documentation/DISTRIBUTION.md" "$staging/INSTALL.md"
rm -f "$zip_path" "$checksum_path"
ditto -c -k --norsrc --noextattr --noqtn --noacl "$staging" "$zip_path"
(cd "$distribution" && shasum -a 256 "$zip_name" > "$checksum_name")

echo "Created $zip_path"
echo "Created $checksum_path"
