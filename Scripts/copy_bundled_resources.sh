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

required_outputs=(
    "$destination_root/Runtimes/RenPyModern/base/main.py"
    "$destination_root/Runtimes/RenPyLegacy/base/main.py"
    "$destination_root/Runtimes/Ruffle/ruffle.js"
    "$destination_root/Runtimes/AetherKiri/default.otf"
    "$destination_root/Ruby/3.1.0/English.rb"
    "$destination_root/Assets.bundle/Shaders/simple.frag"
)
for output in "${required_outputs[@]}"; do
    [[ -s "$output" ]] || { echo "Bundled resource copy is incomplete: $output" >&2; exit 4; }
done

echo "Copied directory-sensitive runtime resources into the app bundle."
