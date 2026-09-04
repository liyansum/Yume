#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
archive_input="${1:-}"

if [[ -z "$archive_input" ]]; then
    echo "Usage: $0 /path/to/Yume-native-runtime-cache-*.tar" >&2
    exit 64
fi

archive_dir="$(cd "$(dirname "$archive_input")" && pwd)"
archive_name="$(basename "$archive_input")"
archive="$archive_dir/$archive_name"
checksum="$archive.sha256"

if [[ ! -f "$archive" ]]; then
    echo "Native runtime cache archive not found: $archive" >&2
    exit 66
fi

if [[ ! -f "$checksum" ]]; then
    echo "Native runtime cache checksum not found: $checksum" >&2
    exit 66
fi

if command -v shasum >/dev/null 2>&1; then
    (cd "$archive_dir" && shasum -a 256 -c "$(basename "$checksum")")
elif command -v sha256sum >/dev/null 2>&1; then
    (cd "$archive_dir" && sha256sum -c "$(basename "$checksum")")
else
    echo "Neither shasum nor sha256sum is available." >&2
    exit 69
fi

if ! /usr/bin/tar -tf "$archive" | awk '
    function allowed(path) {
        return path == "ThirdParty/AetherKiri/Artifacts" ||
               index(path, "ThirdParty/AetherKiri/Artifacts/") == 1 ||
               path == "ThirdParty/MKXPZ/Artifacts" ||
               index(path, "ThirdParty/MKXPZ/Artifacts/") == 1 ||
               path == "ThirdParty/RenPy/Artifacts" ||
               index(path, "ThirdParty/RenPy/Artifacts/") == 1 ||
               path == "ThirdParty/Art3m1s/Artifacts" ||
               index(path, "ThirdParty/Art3m1s/Artifacts/") == 1
    }
    /^\// || /(^|\/)\.\.(\/|$)/ || !allowed($0) {
        print "Unsafe or unexpected cache entry: " $0 > "/dev/stderr"
        invalid = 1
    }
    END { exit invalid }
'; then
    echo "Refusing to extract an invalid native runtime cache archive." >&2
    exit 65
fi

/usr/bin/tar -xf "$archive" -C "$project_root"
echo "Restored native runtime artifacts into $project_root/ThirdParty."
echo "On macOS, run Scripts/verify_native_runtimes.sh iphoneos before building."
