#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Ren'Py runtime compilation requires Xcode on macOS." >&2
    exit 2
fi
for command_name in xcrun curl unzip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 2
    fi
done
case "$platform_name" in
    iphoneos)
        configuration=release
        ld_platform=ios
        ;;
    iphonesimulator)
        configuration=debug
        ld_platform=ios-simulator
        ;;
    *) echo "Unsupported platform: $platform_name" >&2; exit 2 ;;
esac

"$script_dir/stage_renpy_runtime.sh"
artifact_root="$project_root/ThirdParty/RenPy/Artifacts"
output_dir="$artifact_root/$platform_name"
build_dir="$project_root/.native-build/renpy-$platform_name"
sdk_path="$(xcrun --sdk "$platform_name" --show-sdk-path)"
sdk_version="$(xcrun --sdk "$platform_name" --show-sdk-version)"
mkdir -p "$output_dir" "$build_dir"

build_generation() {
    local generation="$1"
    local python_library="$2"
    local entry="$3"
    local source_dir="$artifact_root/$generation/prebuilt/$configuration"
    local wrapper="$build_dir/$generation-entry.o"
    local output="$output_dir/renpy-$generation.o"
    local exports="$build_dir/$generation-exports.txt"
    local minimum_flag
    if [[ "$platform_name" == "iphoneos" ]]; then
        minimum_flag="-miphoneos-version-min=18.0"
    else
        minimum_flag="-mios-simulator-version-min=18.0"
    fi

    xcrun --sdk "$platform_name" clang -arch arm64 "$minimum_flag" \
        -DYUME_RENPY_ENTRY="$entry" -c \
        "$project_root/ThirdParty/RenPy/renpy_entry.c" -o "$wrapper"

    local names=(renpython renpy "$python_library")
    if [[ "$generation" == "modern" ]]; then
        names+=(assimp)
    fi
    names+=(
        avformat avcodec swscale
        swresample avutil SDL2_image avif aom yuv turbojpeg png16 webp
        harfbuzz brotlidec brotlicommon fribidi freetype ffi ssl crypto lzma
        bz2 z
    )
    local archives=()
    for name in "${names[@]}"; do
        local archive="$source_dir/lib$name.a"
        [[ -f "$archive" ]] || { echo "Missing $archive" >&2; exit 4; }
        archives+=("$archive")
    done

    # Deliberately use normal archive resolution here. -all_load is incorrect:
    # Ren'Py's official archive set contains a few duplicate definitions (for
    # example bundled libffi symbols in the legacy Python archive). The order
    # below matches the official Renios target and pulls the transitive closure
    # rooted at launcher_main without introducing those duplicates.
    xcrun --sdk "$platform_name" ld -r -arch arm64 \
        -platform_version "$ld_platform" 18.0 "$sdk_version" \
        -syslibroot "$sdk_path" \
        "$wrapper" "${archives[@]}" -o "$output.unstripped"
    printf '_%s\n' "$entry" > "$exports"
    xcrun nmedit -s "$exports" "$output.unstripped" -o "$output"
    xcrun lipo -verify_arch arm64 "$output"

    local visible_symbols
    visible_symbols="$(xcrun nm -gUj "$output" | LC_ALL=C sort -u)"
    if [[ "$visible_symbols" != "_$entry" ]]; then
        echo "$output must expose only _$entry; found:" >&2
        printf '%s\n' "$visible_symbols" | head -20 >&2
        exit 5
    fi
    rm -f "$output.unstripped"
}

build_generation modern python3.12 yume_renpy_modern_main
build_generation legacy python2.7 yume_renpy_legacy_main
echo "Built Ren'Py runtime objects for $platform_name."
