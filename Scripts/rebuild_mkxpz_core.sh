#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mkxp-z core rebuild requires Xcode on macOS." >&2
    exit 2
fi
case "$platform_name" in
    iphoneos|iphonesimulator) ;;
    *) echo "Unsupported Apple platform: $platform_name" >&2; exit 2 ;;
esac

native_include="$project_root/ThirdParty/MKXPZ/Artifacts/native/build-${platform_name}-arm64/include"
angle_include="$project_root/ThirdParty/MKXPZ/Artifacts/angle/${platform_name}/include"
engine_src="$project_root/ThirdParty/MKXPZ/Source"
out_dir="$project_root/ThirdParty/MKXPZ/Artifacts/engine/${platform_name}/lib"
obj_dir="$project_root/.native-build/mkxp-core-${platform_name}"

for required in \
    "$native_include/SDL2/SDL.h" \
    "$native_include/pixman-1/pixman.h" \
    "$native_include/AL/al.h" \
    "$angle_include/EGL/egl.h" \
    "$engine_src/tools/build-core-ios.sh"
do
    [[ -f "$required" ]] || { echo "Missing mkxp-z rebuild input: $required" >&2; exit 3; }
done

mkdir -p "$out_dir" "$obj_dir"

"$engine_src/tools/build-core-ios.sh" \
    --sdk "$platform_name" \
    --arch arm64 \
    --min-os 18.0 \
    --obj "$obj_dir" \
    --out "$out_dir" \
    --include "$native_include" \
    --include "$native_include/AL" \
    --include "$native_include/SDL2" \
    --include "$native_include/pixman-1" \
    --include "$native_include/uchardet" \
    --include "$native_include/freetype2" \
    --include "$angle_include"

[[ -s "$out_dir/libmkxpz-core.a" ]] || {
    echo "mkxp-z core rebuild did not produce libmkxpz-core.a" >&2
    exit 4
}
echo "Rebuilt libmkxpz-core.a for $platform_name/arm64 from engine sources."
