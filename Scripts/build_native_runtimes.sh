#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"

if [[ "${YUME_SKIP_NATIVE_RUNTIME_BUILD:-0}" == "1" ]]; then
    echo "Verifying prepared native runtime artifacts for $platform_name."
    "$script_dir/verify_native_runtimes.sh" "$platform_name"
    exit 0
fi

# A partial aggregate cache is only a source of candidate artifacts. Check
# each component's actual inputs before reusing it, then stamp only builds
# that returned successfully. Provider/Swift/resource edits do not rebuild
# unrelated Python, Ruby, Rust or TVP cores.
fingerprints="$script_dir/native_runtime_fingerprints.py"
if ! python3 "$fingerprints" check mkxp "$platform_name"; then
    "$script_dir/stage_mkxpz_runtime.sh"
    "$script_dir/rebuild_mkxpz_core.sh" "$platform_name"
fi
python3 "$fingerprints" stamp mkxp "$platform_name"
if ! python3 "$fingerprints" check artemis "$platform_name"; then
    "$script_dir/build_art3m1s_runtime.sh" "$platform_name"
fi
python3 "$fingerprints" stamp artemis "$platform_name"
if ! python3 "$fingerprints" check renpy "$platform_name"; then
    "$script_dir/build_renpy_runtime.sh" "$platform_name"
fi
python3 "$fingerprints" stamp renpy "$platform_name"
if ! python3 "$fingerprints" check aether "$platform_name"; then
    "$script_dir/build_aetherkiri_runtime.sh" "$platform_name"
fi
python3 "$fingerprints" stamp aether "$platform_name"
"$script_dir/verify_native_runtimes.sh" "$platform_name"
