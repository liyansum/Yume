#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
source_root="$project_root/ThirdParty/AetherKiri/Source"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"
requested_arch="${CURRENT_ARCH:-arm64}"
jobs="${YUME_NATIVE_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "AetherKiri iOS runtime must be built on macOS." >&2
    exit 2
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "CMake 3.28 or newer is required to build AetherKiri." >&2
    exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo "The Xcode command-line tools are required to build AetherKiri." >&2
    exit 2
fi

case "$platform_name" in
    iphoneos)
        sdk="iphoneos"
        triplet="arm64-ios"
        architecture="arm64"
        ;;
    iphonesimulator)
        sdk="iphonesimulator"
        architecture="$requested_arch"
        if [[ "$architecture" == "x86_64" ]]; then
            triplet="x64-ios-simulator"
        else
            architecture="arm64"
            triplet="arm64-ios-simulator"
        fi
        ;;
    *)
        echo "Unsupported Apple platform: $platform_name" >&2
        exit 2
        ;;
esac

artifact_dir="$project_root/ThirdParty/AetherKiri/Artifacts/$platform_name"
artifact="$artifact_dir/libYumeAetherKiri.a"
build_root="$project_root/.native-build/aetherkiri/${platform_name}-${architecture}"
vcpkg_root="${YUME_VCPKG_ROOT:-$project_root/.native-build/vcpkg}"

if [[ -f "$artifact" ]] &&
   ! find "$source_root" -type f -newer "$artifact" -print -quit | grep -q .; then
    echo "AetherKiri runtime is up to date: $artifact"
    exit 0
fi

# Xcode shell phases export the active iPhone SDK and target flags globally.
# vcpkg also builds host tools (pkgconf, meson helpers) which must remain
# runnable macOS executables, so prevent those target settings from leaking
# into host builds. The iOS target is fully described by the CMake options and
# overlay triplet below.
unset SDKROOT CC CXX LD AR AS NM RANLIB STRIP
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET

mkdir -p "$(dirname "$vcpkg_root")" "$artifact_dir"
if [[ ! -f "$vcpkg_root/.vcpkg-root" ]]; then
    if [[ -e "$vcpkg_root" ]]; then
        echo "Invalid VCPKG root: $vcpkg_root" >&2
        exit 2
    fi
    git clone --filter=blob:none https://github.com/microsoft/vcpkg.git "$vcpkg_root"
fi
vcpkg_baseline="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["default-registry"]["baseline"])' "$source_root/vcpkg-configuration.json")"
git -C "$vcpkg_root" fetch --depth=1 origin "$vcpkg_baseline"
git -C "$vcpkg_root" checkout --detach "$vcpkg_baseline"
if [[ ! -x "$vcpkg_root/vcpkg" ]]; then
    "$vcpkg_root/bootstrap-vcpkg.sh" -disableMetrics
fi

export VCPKG_ROOT="$vcpkg_root"
export VCPKG_DEFAULT_BINARY_CACHE="${VCPKG_DEFAULT_BINARY_CACHE:-$project_root/.native-build/vcpkg-binary-cache}"
mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
cmake -S "$source_root" -B "$build_root" --fresh \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_TOOLCHAIN_FILE="$vcpkg_root/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET="$triplet" \
    -DVCPKG_OVERLAY_TRIPLETS="$source_root/vcpkg/triplets" \
    -DVCPKG_BUILD_TYPE=release \
    -DBUILD_ENGINE_API=ON \
    -DBUILD_GODOT_EXTENSION=OFF \
    -DBUILD_GPU_BRIDGE=OFF \
    -DBUILD_TOOLS=OFF \
    -DENABLE_TESTS=OFF \
    -DAETHERKIRI_ENABLE_ONSCRIPTER=ON \
    -DAETHERKIRI_ENABLE_INTERNAL=OFF
cmake --build "$build_root" --parallel "$jobs"

archive_list="$build_root/yume-runtime-archives.txt"
find "$build_root" -type f -name '*.a' \
    ! -path '*/CMakeFiles/*' \
    ! -name 'libSDL2main.a' \
    ! -name 'libSDL2.a' \
    ! -name 'libSDL2_image.a' \
    ! -name 'libSDL2_ttf.a' \
    ! -name 'libcrypto.a' \
    ! -name 'libssl.a' \
    ! -name 'libfreetype.a' \
    ! -name 'libogg.a' \
    ! -name 'libopenal.a' \
    ! -name 'libpng.a' \
    ! -name 'libpng16.a' \
    ! -name 'libvorbis.a' \
    ! -name 'libvorbisfile.a' \
    ! -name 'libgodot-cpp*.a' \
    | LC_ALL=C sort > "$archive_list"
if [[ ! -s "$archive_list" ]]; then
    echo "AetherKiri build produced no static archives." >&2
    exit 3
fi
if [[ ! -f "$build_root/bridge/engine_api/libengine_api.a" ]]; then
    echo "AetherKiri engine API archive is missing." >&2
    exit 3
fi
if [[ ! -f "$build_root/bridge/onscripter_runtime/libaether_onscripter_runtime.a" ]]; then
    echo "AetherKiri OnscripterYuri archive is missing." >&2
    exit 3
fi

temporary_artifact="$artifact.tmp"
runtime_archives=()
while IFS= read -r archive; do
    runtime_archives+=("$archive")
done < "$archive_list"
xcrun libtool -static -o "$temporary_artifact" "${runtime_archives[@]}"
xcrun lipo "$temporary_artifact" -verify_arch "$architecture"
mv "$temporary_artifact" "$artifact"
echo "Built AetherKiri runtime: $artifact"
