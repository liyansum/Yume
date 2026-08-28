#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_name="${1:-${PLATFORM_NAME:-iphoneos}}"

"$script_dir/stage_mkxpz_runtime.sh"
"$script_dir/build_renpy_runtime.sh" "$platform_name"
"$script_dir/build_aetherkiri_runtime.sh" "$platform_name"
"$script_dir/verify_native_runtimes.sh" "$platform_name"
