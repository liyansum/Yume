#!/usr/bin/env python3
"""Cache invalidation regression checks using an isolated Git repository."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("fingerprints", Path(__file__).with_name("native_runtime_fingerprints.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="yume-cache-test-") as directory:
    module.ROOT = Path(directory)
    def git(*args):
        return subprocess.check_output(["git", "-C", directory, *args], stderr=subprocess.DEVNULL).strip()
    def write(relative, content):
        path = module.ROOT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    git("init", "-q")
    git("config", "user.name", "Yume Test")
    git("config", "user.email", "test@example.invalid")
    write(module.LOCK, "frozen dependencies")
    write("ThirdParty/AetherKiri/Source/test.cpp", "old source")
    write("Scripts/stage_mkxpz_runtime.sh", "frozen ANGLE inputs")
    git("add", ".")
    git("commit", "-qm", "fixture")
    revision = git("rev-parse", "HEAD").decode()
    baseline = {key: module.fingerprint(key, "iphoneos") for key in module.INPUTS}
    for key in baseline:
        assert baseline[key] == module.fingerprint(key, "iphoneos", revision)
        assert baseline[key] != module.fingerprint(key, "iphonesimulator")
    write("YumeApp/Host.swift", "host-only edits do not rebuild cores")
    assert baseline == {key: module.fingerprint(key, "iphoneos") for key in module.INPUTS}
    write("ThirdParty/AetherKiri/Source/test.cpp", "changed source")
    assert baseline["aether"] != module.fingerprint("aether", "iphoneos")
    for key in ("mkxp", "renpy", "artemis"):
        assert baseline[key] == module.fingerprint(key, "iphoneos")
    git("checkout", "--", "ThirdParty/AetherKiri/Source/test.cpp")
    write("ThirdParty/AetherKiri/Source/new.cpp", "untracked source")
    assert baseline["aether"] != module.fingerprint("aether", "iphoneos")
    (module.ROOT / "ThirdParty/AetherKiri/Source/new.cpp").unlink()
    (module.ROOT / "ThirdParty/AetherKiri/Source/test.cpp").unlink()
    assert baseline["aether"] != module.fingerprint("aether", "iphoneos")
    write("Scripts/stage_mkxpz_runtime.sh", "new ANGLE")
    assert baseline["mkxp"] != module.fingerprint("mkxp", "iphoneos")
    assert baseline["artemis"] != module.fingerprint("artemis", "iphoneos")

print("Native cache invalidation checks passed.")
