#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"
architecture="${CURRENT_ARCH:-arm64}"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "Native runtime verification requires Xcode on macOS." >&2
    exit 2
fi
case "$platform_name" in
    iphoneos|iphonesimulator) ;;
    *) echo "Unsupported Apple platform: $platform_name" >&2; exit 2 ;;
esac
if [[ "$architecture" != "arm64" ]]; then
    echo "Yume's pinned native runtimes currently require an arm64 build destination." >&2
    exit 2
fi

mkxp_lib="$project_root/ThirdParty/MKXPZ/Artifacts/native/build-$platform_name-arm64/lib"
angle_lib="$project_root/ThirdParty/MKXPZ/Artifacts/angle/$platform_name/lib"
engine_lib="$project_root/ThirdParty/MKXPZ/Artifacts/engine/$platform_name/lib"
renpy_lib="$project_root/ThirdParty/RenPy/Artifacts/$platform_name"
aether_lib="$project_root/ThirdParty/AetherKiri/Artifacts/$platform_name"

artifacts=(
    "$aether_lib/libYumeAetherKiri.a"
    "$engine_lib/libmkxpz-core.a"
    "$mkxp_lib/mkxp18-merged.o"
    "$mkxp_lib/mkxp19-merged.o"
    "$mkxp_lib/mkxp31-merged.o"
    "$mkxp_lib/libSDL2.a"
    "$angle_lib/libANGLE_static.a"
    "$angle_lib/libEGL_static.a"
    "$angle_lib/libGLESv2_static.a"
    "$renpy_lib/renpy-modern.o"
    "$renpy_lib/renpy-legacy.o"
)
for artifact in "${artifacts[@]}"; do
    [[ -s "$artifact" ]] || { echo "Native runtime artifact is missing: $artifact" >&2; exit 3; }
    xcrun lipo "$artifact" -verify_arch arm64
done

require_symbol() {
    local artifact="$1"
    local symbol="$2"
    if ! xcrun nm "$artifact" 2>/dev/null | grep -Eq "[[:space:]]_$symbol$"; then
        echo "Required native symbol _$symbol is missing from $artifact" >&2
        exit 4
    fi
}

require_symbol "$aether_lib/libYumeAetherKiri.a" engine_create
require_symbol "$aether_lib/libYumeAetherKiri.a" engine_open_game_async
require_symbol "$engine_lib/libmkxpz-core.a" SDL_main
require_symbol "$engine_lib/libmkxpz-core.a" mkxp_resetSessionState
require_symbol "$engine_lib/libmkxpz-core.a" mkxp_getSDLUIKitWindow
require_symbol "$mkxp_lib/mkxp18-merged.o" mkxp_get_script_binding_18
require_symbol "$mkxp_lib/mkxp19-merged.o" mkxp_get_script_binding_19
require_symbol "$mkxp_lib/mkxp31-merged.o" mkxp_get_script_binding_31
require_symbol "$mkxp_lib/libSDL2.a" SDL_SetMainReady
require_symbol "$mkxp_lib/libSDL2.a" SDL_PushEvent
require_symbol "$mkxp_lib/libSDL2.a" SDL_GetKeyboardFocus
require_symbol "$mkxp_lib/libSDL2.a" SDL_GetWindowFromID
require_symbol "$mkxp_lib/libSDL2.a" SDL_GetWindowWMInfo
require_symbol "$renpy_lib/renpy-modern.o" yume_renpy_modern_main
require_symbol "$renpy_lib/renpy-legacy.o" yume_renpy_legacy_main

echo "Verified native runtime artifacts for $platform_name/arm64."
