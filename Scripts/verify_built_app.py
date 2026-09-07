#!/usr/bin/env python3
"""Validate the actual App/IPA resources before handing a build to testers."""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def verify(read, expected_revision, expected_build=None):
    info = plistlib.loads(read('Info.plist'))
    metadata = json.loads(read('YumeBuildInfo.json'))
    if metadata['sourceRevision'] != expected_revision or metadata['sourceDirty'] != 'false':
        raise ValueError('App provenance does not identify the clean requested revision')
    if expected_build and str(info['CFBundleVersion']) != expected_build:
        raise ValueError('App build number does not match the requested build')
    if str(info['CFBundleVersion']) != metadata['buildNumber']:
        raise ValueError('Info.plist and build metadata disagree on build number')
    binary = read('Yume')
    magic, cpu, _, filetype = struct.unpack_from('<IIII', binary)
    if (magic, cpu, filetype) != (0xfeedfacf, 0x100000c, 2):
        raise ValueError('Expected a thin arm64 Mach-O executable')
    for resource in ('WebRuntimeSupport.js', 'Runtimes/RenPyModern/base/main.py',
                     'Runtimes/RenPyLegacy/base/main.py', 'Runtimes/Ruffle/index.html'):
        source = ROOT / ('YumeApp/Resources' if resource == 'WebRuntimeSupport.js' else 'ThirdParty/BundledResources') / resource
        if read(resource) != source.read_bytes():
            raise ValueError('Missing/stale runtime resource: ' + resource)
    for name in ('YumeANGLE', 'libEGL', 'libGLESv2'):
        if not read('Frameworks/' + name + '.framework/' + name):
            raise ValueError('Empty ANGLE framework: ' + name)
    for language in ('en', 'ja', 'zh-Hans', 'zh-Hant'):
        if not read(language + '.lproj/Localizable.strings'):
            raise ValueError('Missing localization: ' + language)
    print('Verified App resources and provenance:', expected_revision, 'build', info['CFBundleVersion'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--build')
    args = parser.parse_args()
    if args.app.is_dir():
        verify(lambda name: (args.app / name).read_bytes(), args.revision, args.build)
    else:
        with zipfile.ZipFile(args.app) as archive:
            verify(lambda name: archive.read('Payload/Yume.app/' + name), args.revision, args.build)
