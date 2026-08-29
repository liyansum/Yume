# Yume iOS stub. The bundled Ren'Py python imports this from site.py.
# The original module uses pyobjus against macOS Foundation paths and
# class Log, which abort on device.
from __future__ import print_function, absolute_import


class _NullLog(object):
    def write(self, _data):
        return None

    def flush(self):
        return None

    def __call__(self, *args, **kwargs):
        return None

    def __getattr__(self, _name):
        return self


Log = _NullLog()
NSLog = _NullLog()
