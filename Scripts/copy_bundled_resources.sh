#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
source_root="$project_root/ThirdParty/BundledResources"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "This script must run from an Xcode target build phase." >&2
    exit 2
fi
if [[ ! -x /usr/bin/ditto ]]; then
    echo "The macOS ditto tool is required." >&2
    exit 2
fi

destination_root="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$destination_root"
for directory_name in Runtimes Ruby Assets.bundle; do
    source="$source_root/$directory_name"
    destination="$destination_root/$directory_name"
    [[ -d "$source" ]] || { echo "Missing bundled resource tree: $source" >&2; exit 3; }
    rm -rf "$destination"
    /usr/bin/ditto --noqtn "$source" "$destination"
done

art3m1s_frameworks="$project_root/ThirdParty/Art3m1s/Artifacts/${PLATFORM_NAME:-iphoneos}/Frameworks"
framework_destination="$TARGET_BUILD_DIR/${FRAMEWORKS_FOLDER_PATH:-$UNLOCALIZED_RESOURCES_FOLDER_PATH/Frameworks}"
[[ -d "$art3m1s_frameworks" ]] || {
    echo "Missing art3m1s ANGLE frameworks: $art3m1s_frameworks" >&2
    exit 3
}
mkdir -p "$framework_destination"
for framework in YumeANGLE.framework libEGL.framework libGLESv2.framework; do
    rm -rf "$framework_destination/$framework"
    /usr/bin/ditto --noqtn "$art3m1s_frameworks/$framework" \
        "$framework_destination/$framework"
done
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" &&
      -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    for framework in YumeANGLE.framework libEGL.framework libGLESv2.framework; do
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --preserve-metadata=identifier,entitlements,flags \
            "$framework_destination/$framework"
    done
fi

required_outputs=(
    "$destination_root/Runtimes/RenPyModern/base/main.py"
    "$destination_root/Runtimes/RenPyModern/base/lib/python3.12/site.pyc"
    "$destination_root/Runtimes/RenPyLegacy/base/main.py"
    "$destination_root/Runtimes/RenPyLegacy/base/lib/python2.7/site.pyo"
    "$destination_root/Runtimes/Ruffle/ruffle.js"
    "$destination_root/Runtimes/AetherKiri/default.otf"
    "$destination_root/Ruby/3.1.0/English.rb"
    "$destination_root/Assets.bundle/Shaders/simple.frag"
    "$framework_destination/YumeANGLE.framework/YumeANGLE"
    "$framework_destination/libEGL.framework/libEGL"
    "$framework_destination/libGLESv2.framework/libGLESv2"
)
for output in "${required_outputs[@]}"; do
    [[ -s "$output" ]] || { echo "Bundled resource copy is incomplete: $output" >&2; exit 4; }
done

echo "Copied directory-sensitive runtime resources into the app bundle."
