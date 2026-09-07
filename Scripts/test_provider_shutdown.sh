#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
compiler="${CXX:-$(command -v clang++ || command -v c++ || true)}"
if [[ -z "$compiler" && -x /opt/yume-swift/usr/bin/clang++ ]]; then
    compiler=/opt/yume-swift/usr/bin/clang++
fi
[[ -n "$compiler" ]] || { echo 'C++17 compiler required for provider lifecycle tests.' >&2; exit 2; }
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
api_root="$project_root/ThirdParty/AetherKiri/Source/bridge/engine_api"
"$compiler" -std=c++17 -pthread -I "$api_root/include" -I "$api_root/src" \
    "$script_dir/Tests/provider_shutdown.cpp" "$api_root/src/engine_api.cpp" \
    "$api_root/src/engine_api_dispatch.cpp" "$api_root/src/engine_runtime_provider.cpp" \
    -o "$test_root/provider-shutdown"
"$test_root/provider-shutdown"
echo 'Provider shutdown fault-injection checks passed.'
