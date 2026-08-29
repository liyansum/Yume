#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
swift_bin="${YUME_SWIFT_BIN:-$(command -v swift || true)}"
swiftc_bin="${YUME_SWIFTC_BIN:-$(command -v swiftc || true)}"
if [[ -z "$swift_bin" && -x /opt/yume-swift/usr/bin/swift ]]; then
    swift_bin=/opt/yume-swift/usr/bin/swift
fi
if [[ -z "$swiftc_bin" && -x /opt/yume-swift/usr/bin/swiftc ]]; then
    swiftc_bin=/opt/yume-swift/usr/bin/swiftc
fi

for command_name in python3 git; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 2
    fi
done
if [[ -z "$swift_bin" || -z "$swiftc_bin" ]]; then
    echo "Swift 6 is required. Set YUME_SWIFT_BIN and YUME_SWIFTC_BIN if needed." >&2
    exit 2
fi

cd "$project_root"
python3 -m json.tool ThirdParty/RuntimeDependencies.lock.json >/dev/null
if ! "$swift_bin" --version | grep -Eq 'Swift version 6\.|Swift version 7\.'; then
    echo "Yume requires Swift 6 or newer." >&2
    exit 2
fi

required_resources=(
    ThirdParty/BundledResources/Runtimes/AetherKiri/default.otf
    ThirdParty/BundledResources/Runtimes/RenPyModern/base/main.py
    ThirdParty/BundledResources/Runtimes/RenPyModern/base/environment.txt
    ThirdParty/BundledResources/Runtimes/RenPyLegacy/base/main.py
    ThirdParty/BundledResources/Runtimes/RenPyLegacy/base/environment.txt
    ThirdParty/BundledResources/Runtimes/Ruffle/index.html
    ThirdParty/BundledResources/Runtimes/Ruffle/ruffle.js
    ThirdParty/BundledResources/Assets.bundle/Shaders/simple.frag
    ThirdParty/BundledResources/Ruby/1.8/English.rb
    ThirdParty/BundledResources/Ruby/1.9.1/English.rb
    ThirdParty/BundledResources/Ruby/3.1.0/English.rb
    Scripts/rebuild_mkxpz_core.sh
)
for resource in "${required_resources[@]}"; do
    if [[ ! -s "$resource" ]]; then
        echo "Required bundled resource is missing or empty: $resource" >&2
        exit 3
    fi
done

python3 - <<'PY'
from pathlib import Path

root = Path.cwd().resolve()
trees = [root / "YumeApp" / "Resources", root / "ThirdParty"]
for tree in trees:
    for path in tree.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise SystemExit(f"Symlink escapes the project: {path}")

for obsolete in ("Runtimes", "Ruby", "Assets.bundle"):
    if (root / "YumeApp" / "Resources" / obsolete).exists():
        raise SystemExit(f"Directory-sensitive resources must not be auto-flattened by Xcode: {obsolete}")

runtime_root = root / "ThirdParty" / "BundledResources" / "Runtimes"
for generation in ("RenPyModern", "RenPyLegacy"):
    for relative in ("base/main.py", "base/environment.txt"):
        path = runtime_root / generation / relative
        compile(path.read_bytes(), str(path), "exec")

project_text = (root / "Yume.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
required_project_fragments = (
    "Copy Runtime Resource Trees",
    "copy_bundled_resources.sh",
    "build_native_runtimes.sh",
    "renpy-modern.o",
    "renpy-legacy.o",
    "libYumeAetherKiri.a",
    "libmkxpz-core.a",
)
for fragment in required_project_fragments:
    if fragment not in project_text:
        raise SystemExit(f"Xcode project is missing required integration: {fragment}")

languages = ["en", "ja", "zh-Hans", "zh-Hant"]
key_sets = {}
for language in languages:
    file = root / "YumeApp" / "Resources" / f"{language}.lproj" / "Localizable.strings"
    keys = set()
    for line in file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith('"') and '" =' in stripped:
            keys.add(stripped.split('"', 2)[1])
    key_sets[language] = keys
baseline = key_sets["en"]
for language, keys in key_sets.items():
    if keys != baseline:
        missing = sorted(baseline - keys)
        extra = sorted(keys - baseline)
        raise SystemExit(f"Localization keys differ for {language}: missing={missing}, extra={extra}")
PY

swift_sources=()
while IFS= read -r swift_source; do
    swift_sources+=("$swift_source")
done < <(find YumeApp YumeCore/Sources YumeCore/Tests -type f -name '*.swift' | LC_ALL=C sort)
"$swiftc_bin" -frontend -parse "${swift_sources[@]}"
"$swift_bin" test --package-path YumeCore
git diff --check

echo "Yume pre-test verification passed."
