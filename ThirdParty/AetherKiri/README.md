# AetherKiri runtime source

This directory vendors the public, source-available parts of
[AetherKiri](https://github.com/AetherKiri/AetherKiri) at commit
`dc2776046aabdd90ed08b938d0a604baaff58e52`. The bundled OnscripterYuri
submodule is pinned at `21a1b3e5ab958af2ae7c07b50326ddd13f08ff1f`.

Yume builds the engine as a statically linked iOS archive. The Godot host,
demo application, tests, and unavailable private optional packages are not
included. Two small integration changes are maintained locally:

- build the public OnscripterYuri provider whenever the C engine API is built;
- omit the optional private PSD plugin when its source package is absent.

The runtime is GPL-3.0-or-later. Combining it with Yume means the distributed
application is provided under GPL-3.0-or-later. Upstream and third-party
license texts are retained under `Source/`.
