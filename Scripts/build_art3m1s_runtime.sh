#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"
lock_file="$project_root/ThirdParty/RuntimeDependencies.lock.json"
source_root="$project_root/.native-build/art3m1s/source"
artifact_root="$project_root/ThirdParty/Art3m1s/Artifacts/$platform_name"
core_archive="$artifact_root/libart3m1s_core.a"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "art3m1s iOS runtime requires Xcode on macOS." >&2
    exit 2
fi
for command_name in git cargo rustup python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required art3m1s build tool is unavailable: $command_name" >&2
        exit 2
    }
done

source_url="$(python3 - "$lock_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
item = next(value for value in data["dependencies"] if value["id"] == "art3m1s-core")
print(item["source"])
PY
)"
source_commit="$(python3 - "$lock_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
item = next(value for value in data["dependencies"] if value["id"] == "art3m1s-core")
print(item["commit"])
PY
)"

case "$platform_name" in
    iphoneos)
        sdk="iphoneos"
        rust_target="aarch64-apple-ios"
        minimum_flag="-miphoneos-version-min=18.0"
        ;;
    iphonesimulator)
        sdk="iphonesimulator"
        rust_target="aarch64-apple-ios-sim"
        minimum_flag="-mios-simulator-version-min=18.0"
        ;;
    *) echo "Unsupported Apple platform: $platform_name" >&2; exit 2 ;;
esac

if [[ ! -d "$source_root/.git" ]]; then
    mkdir -p "$(dirname "$source_root")"
    git clone --filter=blob:none "$source_url" "$source_root"
fi
git -C "$source_root" fetch --depth=1 origin "$source_commit"
git -C "$source_root" checkout --detach "$source_commit"
git -C "$source_root" submodule update --init --recursive --depth=1

rustup target add "$rust_target"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export CARGO_TARGET_DIR="$project_root/.native-build/art3m1s/target"
cargo rustc --manifest-path "$source_root/Cargo.toml" --release \
    --target "$rust_target" --lib -- --crate-type staticlib

built_archive="$CARGO_TARGET_DIR/$rust_target/release/libart3m1s_core.a"
[[ -s "$built_archive" ]] || { echo "art3m1s static archive was not produced." >&2; exit 3; }
mkdir -p "$artifact_root"
/usr/bin/ditto --noqtn "$built_archive" "$core_archive"

# art3m1s currently loads ANGLE by Framework path on iOS. Yume's existing
# ANGLE dependency is static, so expose it once through a central dylib and
# two tiny re-export frameworks. This avoids loading two independent ANGLE
# states and keeps the runtime compatible with the upstream FFI unchanged.
angle_lib="$project_root/ThirdParty/MKXPZ/Artifacts/angle/$platform_name/lib"
for archive in libANGLE_static.a libEGL_static.a libGLESv2_static.a; do
    [[ -s "$angle_lib/$archive" ]] || { echo "Missing ANGLE archive: $archive" >&2; exit 3; }
done
framework_root="$artifact_root/Frameworks"
central="$framework_root/YumeANGLE.framework/YumeANGLE"
mkdir -p "$(dirname "$central")"
sdk_root="$(xcrun --sdk "$sdk" --show-sdk-path)"
xcrun --sdk "$sdk" clang++ -dynamiclib -arch arm64 -isysroot "$sdk_root" \
    "$minimum_flag" -Wl,-all_load \
    "$angle_lib/libEGL_static.a" "$angle_lib/libGLESv2_static.a" \
    "$angle_lib/libANGLE_static.a" -Wl,-noall_load \
    -Wl,-install_name,@rpath/YumeANGLE.framework/YumeANGLE \
    -framework Foundation -framework CoreGraphics -framework IOSurface \
    -framework Metal -framework QuartzCore -o "$central"

for wrapper in libEGL libGLESv2; do
    wrapper_binary="$framework_root/$wrapper.framework/$wrapper"
    mkdir -p "$(dirname "$wrapper_binary")"
    xcrun --sdk "$sdk" clang -dynamiclib -arch arm64 -isysroot "$sdk_root" \
        "$minimum_flag" -Wl,-install_name,@rpath/$wrapper.framework/$wrapper \
        -Wl,-reexport_library,"$central" -o "$wrapper_binary"
done

for framework_name in YumeANGLE libEGL libGLESv2; do
    framework="$framework_root/$framework_name.framework"
    framework_identifier="$(printf '%s' "$framework_name" | tr '[:upper:]' '[:lower:]')"
    /usr/bin/ditto --noqtn "$script_dir/Support/RuntimeFrameworkInfo.plist" \
        "$framework/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $framework_name" \
        -c "Set :CFBundleName $framework_name" \
        -c "Set :CFBundleIdentifier com.yume.runtime.$framework_identifier" \
        "$framework/Info.plist"
done

xcrun lipo "$core_archive" -verify_arch arm64
for binary in "$central" "$framework_root/libEGL.framework/libEGL" \
              "$framework_root/libGLESv2.framework/libGLESv2"; do
    xcrun lipo "$binary" -verify_arch arm64
done
echo "Built art3m1s runtime: $core_archive"
