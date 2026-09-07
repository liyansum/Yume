#!/usr/bin/env python3
"""Validate each native cache component against its own build inputs.

An aggregate Actions cache may be a partial match. Never infer validity from
its presence; compare the component manifest (or the explicitly identified
legacy cache's commit) before reusing any native output.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCK = "ThirdParty/RuntimeDependencies.lock.json"
INPUTS = {
    "mkxp": [LOCK, "Scripts/stage_mkxpz_runtime.sh", "Scripts/rebuild_mkxpz_core.sh", "ThirdParty/MKXPZ/Source", "ThirdParty/MKXPZ/EmpoDependencies"],
    "renpy": [LOCK, "Scripts/stage_renpy_runtime.sh", "Scripts/build_renpy_runtime.sh", "ThirdParty/RenPy/renpy_entry.c"],
    "aether": [LOCK, "Scripts/build_aetherkiri_runtime.sh", "ThirdParty/AetherKiri/Source"],
    "artemis": [LOCK, "Scripts/build_art3m1s_runtime.sh", "Scripts/Support/RuntimeFrameworkInfo.plist", "Scripts/stage_mkxpz_runtime.sh", "ThirdParty/MKXPZ/EmpoDependencies"],
}
DIRECTORIES = {"mkxp": "MKXPZ", "renpy": "RenPy", "aether": "AetherKiri", "artemis": "Art3m1s"}

def git(*args, input=None):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], input=input)

def fingerprint(component, platform, revision=None):
    paths = INPUTS[component]
    if revision:
        records = git("ls-tree", "-r", "-z", revision, "--", *paths).split(b"\0")
        entries = []
        for record in filter(None, records):
            info, name = record.split(b"\t", 1)
            entries.append((name, info.split()[2]))
    else:
        names = sorted(set(filter(None, git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *paths).split(b"\0"))))
        names = [name for name in names if (ROOT / os.fsdecode(name)).is_file()]
        # --stdin-paths avoids thousands of git processes while hashing the
        # actual working tree, including uncommitted edits and new sources.
        if any(b"\n" in name or b'"' in name for name in names):
            raise ValueError("Unsupported native input filename")
        hashes = git("hash-object", "--stdin-paths", input=b"\n".join(names) + b"\n").splitlines()
        entries = list(zip(names, hashes))
    toolchain = subprocess.check_output(["xcodebuild", "-version"]).strip() if sys.platform == "darwin" else b"linux-test"
    digest = hashlib.sha256(b"yume-native-inputs-v1\0" + platform.encode() + b"\0" + toolchain)
    for name, value in sorted(entries):
        digest.update(b"\0" + name + b"\0" + value)
    return digest.hexdigest()

def main():
    command, component, platform = sys.argv[1:]
    directory = ROOT / "ThirdParty" / DIRECTORIES[component] / "Artifacts"
    manifest = directory / ("yume-inputs-" + platform + ".json")
    current = fingerprint(component, platform)
    if command == "stamp":
        directory.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({"fingerprint": current, "component": component, "platform": platform}, indent=2) + "\n")
        return
    if command != "check":
        raise ValueError("Expected check or stamp")
    if manifest.is_file():
        try:
            valid = json.loads(manifest.read_text())["fingerprint"] == current
        except (ValueError, KeyError):
            valid = False
    else:
        # Only supplied when Actions restored the specifically audited old
        # combined cache, whose outputs predate these manifests.
        seed = os.environ.get("YUME_NATIVE_LEGACY_CACHE_COMMIT")
        valid = bool(seed) and current == fingerprint(component, platform, seed)
    required = {
        "mkxp": [f"engine/{platform}/lib/libmkxpz-core.a", f"native/build-{platform}-arm64/lib/libSDL2.a", f"angle/{platform}/lib/libANGLE_static.a"],
        "renpy": [f"{platform}/renpy-modern.o", f"{platform}/renpy-legacy.o"],
        "aether": [f"{platform}/libYumeAetherKiri.a"],
        "artemis": [f"{platform}/libart3m1s_core.a", f"{platform}/Frameworks/YumeANGLE.framework/YumeANGLE"],
    }[component]
    valid = valid and all((directory / item).is_file() and (directory / item).stat().st_size for item in required)
    print(f"{component}: {'reuse' if valid else 'rebuild'} ({current[:12]})")
    sys.exit(0 if valid else 1)

if __name__ == "__main__":
    main()
