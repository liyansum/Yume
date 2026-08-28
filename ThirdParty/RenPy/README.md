# Ren'Py iOS runtimes

Yume ships two isolated Ren'Py runtime images: Ren'Py 8.5.3 with Python 3.12
and Ren'Py 7.8.7 with Python 2.7. Both use the official Renios archives from
renpy.org. Release URLs and SHA-256 digests are recorded in
`ThirdParty/RuntimeDependencies.lock.json`.

`Scripts/stage_renpy_runtime.sh` downloads and verifies the official static
libraries. `Scripts/build_renpy_runtime.sh` merges each generation into a
separate Mach-O object and makes its internal Python symbols private, allowing
both generations to coexist in one executable. SDL is deliberately supplied
by Yume's shared, patched mobile SDL build.

The generated Python homes under `ThirdParty/BundledResources/Runtimes/RenPy*` were
produced with the matching official SDK's `ios_create` command. They contain
only engine/runtime files; imported game content is selected with Ren'Py's
`--basedir` option at launch. The corresponding upstream license notices are
bundled beside each runtime.

Yume's small distributor patch routes saves through `RENPY_PATH_TO_SAVES` and
executes `base/environment.txt` before importing Ren'Py. That policy replaces
Python's public and low-level socket constructors/resolver with offline-only
implementations. `Scripts/copy_bundled_resources.sh` preserves the complete
Python-home directory trees when Xcode assembles the app bundle.
