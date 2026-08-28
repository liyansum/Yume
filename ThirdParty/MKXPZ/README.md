# mkxp-z iOS runtime

Yume embeds the public iOS fork of
[mkxp-z](https://github.com/mateo-m/mkxp-z-apple-mobile) at commit
`6d0d51034fe1474a5c42e24b6790bee2383d53a7`. The corresponding engine,
native dependency, and ANGLE archives are staged by
`Scripts/stage_mkxpz_runtime.sh`; their release URLs and SHA-256 digests are
recorded in `ThirdParty/RuntimeDependencies.lock.json`.

The runtime provides RGSS1, RGSS2, and RGSS3 compatibility through isolated
Ruby 1.8, 1.9, and 3.1 bindings. Yume selects the binding from the imported
game and forces networking off. The engine is intentionally one-shot within
an app process because SDL and the embedded Ruby VMs own process-global state.

`Source/` retains the engine source and GPL-2.0-or-later license text.
`EmpoDependencies/` retains the public build recipes and Ruby/SDL patches used
to produce the pinned native dependencies. Generated `Artifacts/` are ignored
from version control and reproduced from the checksum-verified release files.
