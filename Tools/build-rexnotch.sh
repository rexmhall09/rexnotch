#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${REXNOTCH_DERIVED_DATA:-$repo_root/build/DerivedData}"
output_dir="${REXNOTCH_OUTPUT_DIR:-$repo_root/build}"

xcodebuild -project "$repo_root/boringNotch.xcodeproj" \
  -scheme boringNotch -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build

source_app="$derived_data/Build/Products/Release/RexNotch.app"
mkdir -p "$output_dir"
destination_app="$output_dir/RexNotch.app"
ditto "$source_app" "$destination_app"

# The upstream MediaRemote adapter carries a different embedded signature.
codesign --force --sign - "$destination_app/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign - --entitlements "$repo_root/boringNotch/boringNotch.entitlements" "$destination_app"
codesign --verify --deep --strict "$destination_app"
echo "$destination_app"
