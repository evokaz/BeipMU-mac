#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_dir/DerivedData"
distribution="$repo_dir/dist"

cd "$repo_dir"
./Scripts/generate-project.sh
xcodebuild \
  -workspace BeipMU.xcodeproj/project.xcworkspace \
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
zip_path="$distribution/BeipMU-macOS-universal.zip"
checksum_path="$zip_path.sha256"
ditto -c -k --keepParent "$app" "$zip_path"
shasum -a 256 "$zip_path" > "$checksum_path"

echo "Created $zip_path"
echo "Created $checksum_path"
