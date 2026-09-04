#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"

if [[ "${YUME_SKIP_NATIVE_RUNTIME_BUILD:-0}" == "1" ]]; then
    echo "Reusing exact-key native runtime artifacts for $platform_name."
    "$script_dir/verify_native_runtimes.sh" "$platform_name"
    exit 0
fi

"$script_dir/stage_mkxpz_runtime.sh"
"$script_dir/build_art3m1s_runtime.sh" "$platform_name"
"$script_dir/rebuild_mkxpz_core.sh" "$platform_name"
"$script_dir/build_renpy_runtime.sh" "$platform_name"
"$script_dir/build_aetherkiri_runtime.sh" "$platform_name"
"$script_dir/verify_native_runtimes.sh" "$platform_name"
