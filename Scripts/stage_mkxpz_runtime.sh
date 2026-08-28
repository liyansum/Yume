#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
download_root="$project_root/.native-build/downloads"
artifact_root="$project_root/ThirdParty/MKXPZ/Artifacts"

for command_name in curl tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 2
    fi
done

native_url="https://github.com/mateo-m/empo-deps/releases/download/native-2026-08-20/native-ios-prebuilt.tar.gz"
native_sha="b1e01ee9550b56cffddd6c2bd492f1685e6a02db1d61ba1e4e3de060e8632fb0"
angle_url="https://github.com/mateo-m/empo-deps/releases/download/angle-2026-05-04/angle-ios-prebuilt.tar.gz"
angle_sha="0cd2b87b132b2c1344fe356ebcb57fa6ec63675d33d6fa11deb8a16bd57d3b9c"
engine_url="https://github.com/mateo-m/mkxp-z-apple-mobile/releases/download/engine-2026-08-20/engine-ios-prebuilt.tar.gz"
engine_sha="f7a201ced4315ade34df15bc47c5f1449f7f56a050a4eae04049924d6be4ca80"

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

fetch() {
    local name="$1"
    local url="$2"
    local expected="$3"
    local archive="$download_root/$name.tar.gz"
    if [[ ! -f "$archive" ]] || [[ "$(sha256_file "$archive")" != "$expected" ]]; then
        rm -f "$archive"
        curl --location --fail --retry 3 --output "$archive.tmp" "$url"
        if [[ "$(sha256_file "$archive.tmp")" != "$expected" ]]; then
            rm -f "$archive.tmp"
            echo "$name archive checksum mismatch" >&2
            exit 3
        fi
        mv "$archive.tmp" "$archive"
    fi
}

mkdir -p "$download_root" "$artifact_root"
fetch native "$native_url" "$native_sha"
fetch angle "$angle_url" "$angle_sha"
fetch engine "$engine_url" "$engine_sha"

stamp="$artifact_root/.artifact-version"
version="native-2026-08-20 angle-2026-05-04 engine-2026-08-20"
if [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$version" ]] &&
   [[ -f "$artifact_root/native/build-iphoneos-arm64/lib/mkxp18-merged.o" ]] &&
   [[ -f "$artifact_root/native/build-iphonesimulator-arm64/lib/mkxp31-merged.o" ]] &&
   [[ -f "$artifact_root/angle/iphoneos/lib/libANGLE_static.a" ]] &&
   [[ -f "$artifact_root/engine/iphoneos/lib/libmkxpz-core.a" ]]; then
    echo "mkxp-z runtime artifacts are up to date."
    exit 0
fi

staging="$artifact_root.staging"
rm -rf "$staging"
mkdir -p "$staging/native" "$staging/angle" "$staging/engine"
tar -xzf "$download_root/native.tar.gz" -C "$staging/native" 2>/dev/null
tar -xzf "$download_root/angle.tar.gz" -C "$staging/angle" 2>/dev/null
tar -xzf "$download_root/engine.tar.gz" -C "$staging/engine" 2>/dev/null
find "$staging" -name '._*' -delete
echo "$version" > "$staging/.artifact-version"
rm -rf "$artifact_root"
mv "$staging" "$artifact_root"
echo "Staged mkxp-z iOS runtime artifacts."
