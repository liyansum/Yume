#!/usr/bin/env python3
"""Exercise the bundled 7/8 draw hook with a renderer, without an iOS Python VM."""
import os
from pathlib import Path
import tempfile
import textwrap
from types import SimpleNamespace
from unittest.mock import patch

root = Path(__file__).resolve().parent.parent
for band in ("Modern", "Legacy"):
    source = (root / f"ThirdParty/BundledResources/Runtimes/RenPy{band}/base/main.py").read_text()
    hook = source[source.index("    _yume_original_import_all ="):source.index('    _yume_log("bootstrap.call.begin"')]
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"RENPY_LOGDIR": directory}):
        calls = []
        class Interface:
            def draw_screen(self, widget, video, draw):
                calls.append(draw)
                if widget == "error":
                    raise RuntimeError("renderer failed")
                return "render-result"
        renpy = SimpleNamespace(
            import_all=lambda: "import-result",
            display=SimpleNamespace(core=SimpleNamespace(Interface=Interface)),
            config=SimpleNamespace(screen_width=800, screen_height=600))
        namespace = {"renpy": renpy, "os": os, "_yume_log": lambda *a, **kw: None}
        exec(compile(textwrap.dedent(hook), f"{band}-frame-hook", "exec"), namespace)
        assert renpy.import_all() == "import-result"
        interface = Interface()
        marker = Path(directory) / "renpy-first-frame.txt"
        assert interface.draw_screen(None, False, False) == "render-result"
        assert not marker.exists(), "render preparation must not be marked as a frame"
        try:
            interface.draw_screen("error", False, True)
            raise AssertionError("The wrapper swallowed a renderer exception")
        except RuntimeError:
            pass
        assert not marker.exists(), "failed submission must not mark the first frame"
        assert interface.draw_screen(None, False, True) == "render-result"
        assert marker.read_text() == "renderer-submitted 800x600\n"
        marker.unlink()
        interface.draw_screen(None, False, True)
        assert not marker.exists(), "the hook should report once, without IO on every frame"
print("Ren'Py 7/8 bootstrap draw-hook checks passed.")
