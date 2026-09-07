#!/usr/bin/env python3
"""Write provenance as a real resource; Xcode omits arbitrary INFOPLIST_KEYs."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def metadata():
    try:
        revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL).decode().strip()
        dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=normal', '--', 'YumeApp', 'YumeCore/Sources', 'ThirdParty', 'Scripts']))
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = 'unrecorded', True
    requested = os.environ.get('YUME_SOURCE_REVISION')
    if requested:
        if revision != 'unrecorded' and requested != revision:
            raise ValueError('Requested build revision does not match the checkout')
        revision = requested
    return {'schemaVersion': 1, 'sourceRevision': revision, 'sourceDirty': str(dirty).lower(),
            'buildNumber': os.environ.get('CURRENT_PROJECT_VERSION', 'local'),
            'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'xcodeBuild': os.environ.get('XCODE_PRODUCT_BUILD_VERSION', 'unrecorded')}


if __name__ == '__main__':
    output = Path(sys.argv[1])
    output.write_text(json.dumps(metadata(), indent=2, sort_keys=True) + '\n')
