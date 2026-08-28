#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
download_root="$project_root/.native-build/downloads"
artifact_root="$project_root/ThirdParty/RenPy/Artifacts"

for command_name in curl unzip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 2
    fi
done

modern_url="https://www.renpy.org/dl/8.5.3/renpy-8.5.3-renios.zip"
modern_sha="c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b"
legacy_url="https://www.renpy.org/dl/7.8.7/renpy-7.8.7-renios.zip"
legacy_sha="faaabec4ec65efa8803a5a7222f6e40183c5fe8354c1ee4eeb78e978826cee86"

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
    local archive="$download_root/$name.zip"
    if [[ ! -f "$archive" ]] || [[ "$(sha256_file "$archive")" != "$expected" ]]; then
        rm -f "$archive" "$archive.tmp"
        curl --location --fail --retry 3 --output "$archive.tmp" "$url"
        [[ "$(sha256_file "$archive.tmp")" == "$expected" ]] || {
            rm -f "$archive.tmp"
            echo "$name archive checksum mismatch" >&2
            exit 3
        }
        mv "$archive.tmp" "$archive"
    fi
}

mkdir -p "$download_root" "$artifact_root"
fetch renpy-modern "$modern_url" "$modern_sha"
fetch renpy-legacy "$legacy_url" "$legacy_sha"

version="renpy-8.5.3 renpy-7.8.7"
stamp="$artifact_root/.artifact-version"
if [[ -f "$stamp" ]] && [[ "$(<"$stamp")" == "$version" ]] &&
   [[ -f "$artifact_root/modern/prebuilt/release/libpython3.12.a" ]] &&
   [[ -f "$artifact_root/legacy/prebuilt/release/libpython2.7.a" ]]; then
    echo "Ren'Py runtime artifacts are up to date."
    exit 0
fi

staging="$artifact_root.staging"
rm -rf "$staging"
mkdir -p "$staging/modern" "$staging/legacy"
unzip -q "$download_root/renpy-modern.zip" 'renios/prototype/prebuilt/*' -d "$staging/modern"
unzip -q "$download_root/renpy-legacy.zip" 'renios/prototype/prebuilt/*' -d "$staging/legacy"
mv "$staging/modern/renios/prototype/prebuilt" "$staging/modern/prebuilt"
mv "$staging/legacy/renios/prototype/prebuilt" "$staging/legacy/prebuilt"
rm -rf "$staging/modern/renios" "$staging/legacy/renios"
echo "$version" > "$staging/.artifact-version"
rm -rf "$artifact_root"
mv "$staging" "$artifact_root"
echo "Staged Ren'Py iOS runtime artifacts."
