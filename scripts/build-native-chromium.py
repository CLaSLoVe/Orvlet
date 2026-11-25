#!/usr/bin/env python3
"""Build the arm64 native Chromium distribution without launching it.

CEF's renderer sandbox stays enabled. The macOS application sandbox is disabled
because the embedded browser starts its own sandboxed helper processes.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '156.0.32+g3d1f4ab+chromium-156.0.8078.109'
DIRECTORY = f'cef_binary_{VERSION}_macosarm64_minimal'
SHA256 = '43848b43b76f4d27a177be18576e8cd94db5efa87009a6b7b07c6a4be91e15f9'


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        run('cp', '-cR', source, target)


def source_check():
    # Output/research archives are not part of this distribution. Check every
    # shipped source plus the complete finished bundle; never print secret values.
    from credential_check import inspect
    count, findings = 0, []
    for directory in ('Orvlet', 'NativeChromium', 'Tests', 'scripts'):
        for path in (ROOT / directory).rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts and path.name != '.DS_Store':
                count += 1
                findings += inspect(str(path.relative_to(ROOT)), path.read_bytes())
    if findings:
        raise RuntimeError('\n'.join(findings))
    print(f'PASS: {count} application/build/test sources checked for credential artifacts.', flush=True)


def bundle_check(app, cef_archive):
    """Public upstream URL/filter examples trigger secret-pattern heuristics.

    Trust only byte-identical files from the SHA-256-pinned CEF archive.
    Scan every other bundled file with the unchanged credential guard.
    """
    from credential_check import inspect
    expected = {}
    with tarfile.open(cef_archive) as archive:
        prefix = DIRECTORY + '/Release/Chromium Embedded Framework.framework/'
        for item in archive:
            if item.isfile() and item.name.startswith(prefix):
                with archive.extractfile(item) as data:
                    expected['Contents/Frameworks/Chromium Embedded Framework.framework/' + item.name[len(prefix):]] = hashlib.file_digest(data, 'sha256').hexdigest()
    findings, count = [], 0
    seen = set()
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        name = path.relative_to(app).as_posix()
        if name in expected:
            with path.open('rb') as data:
                if hashlib.file_digest(data, 'sha256').hexdigest() != expected[name]:
                    raise RuntimeError('Bundled dependency differs from pinned upstream archive: ' + name)
            seen.add(name)
        else:
            if path.suffix.lower() == '.crx' or 'ChromiumExtensions' in path.parts:
                raise RuntimeError('Browser extensions must be installed by the user: ' + name)
            if path.name == 'manifest.json' and 'manifest_version' in json.loads(path.read_bytes()):
                raise RuntimeError('Unexpected bundled extension manifest: ' + name)
            if path.suffix.lower() == '.zip':
                with zipfile.ZipFile(path) as package:
                    for member in package.namelist():
                        if pathlib.PurePosixPath(member).name == 'manifest.json' and 'manifest_version' in json.loads(package.read(member)):
                            raise RuntimeError('Unexpected bundled extension archive: ' + name)
            findings += inspect(name, path.read_bytes(), bundle=True)
        count += 1
    if expected.keys() - seen:
        raise RuntimeError('Bundled dependency is incomplete')
    if findings:
        raise RuntimeError('\n'.join(findings))
    print(f'PASS: {count} bundled files checked; {len(seen)} match pinned public dependency bytes.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('configuration', choices=['Debug', 'Release'], nargs='?', default='Debug')
    parser.add_argument('--output', type=pathlib.Path, help='Separate Release application destination; never launched')
    parser.add_argument('--build-root', type=pathlib.Path, default=ROOT / '.build-native',
                        help='Isolated native/Xcode build directory for concurrent work')
    args = parser.parse_args()
    args.build_root = args.build_root.resolve()
    source_check()
    if os.uname().machine != 'arm64':
        parser.error('This pinned distribution currently supports Apple silicon')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    cache = ROOT / '.local/cef'
    cache.mkdir(parents=True, exist_ok=True)
    dep, archive = cache / DIRECTORY, cache / (DIRECTORY + '.tar.bz2')
    if not archive.exists():
        url = 'https://cef-builds.spotifycdn.com/' + urllib.parse.quote(archive.name)
        urllib.request.urlretrieve(url, archive)
    with archive.open('rb') as data:
        digest = hashlib.file_digest(data, 'sha256').hexdigest()
    if digest != SHA256:
        raise RuntimeError('CEF archive checksum mismatch')
    if not dep.exists():
        run('tar', '-xjf', archive, '-C', cache)
    build = args.build_root / 'native-clang'
    build.mkdir(parents=True, exist_ok=True)
    flags = ['xcrun', 'clang++', '-std=c++20', '-mmacosx-version-min=14.0',
             '-DCEF_API_VERSION=15600', '-DWRAPPING_CEF_SHARED', '-I', dep,
             '-Wno-deprecated-declarations']
    if args.configuration == 'Debug':
        flags.append('-DDEBUG=1')
    loader = dep / 'libcef_dll/wrapper/libcef_dll_dylib.cc'
    run(*flags, '-fobjc-arc', '-c', ROOT / 'NativeChromium/Runtime.mm', '-o', build / 'Runtime.o')
    run(*flags, '-c', loader, '-o', build / 'Loader.o')
    library = build / 'libOrvletChromium.a'
    run('xcrun', 'libtool', '-static', '-o', library, build / 'Runtime.o', build / 'Loader.o')
    helper = build / 'Orvlet Helper.app'
    (helper / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    run(*flags, '-framework', 'Cocoa', ROOT / 'NativeChromium/Helper.mm', loader,
        dep / 'libcef_dll/wrapper/cef_scoped_library_loader_mac.mm',
        dep / 'libcef_dll/wrapper/cef_scoped_sandbox_context_mac.mm',
        '-o', helper / 'Contents/MacOS/Orvlet Helper')
    with (helper / 'Contents/Info.plist').open('wb') as file:
        plistlib.dump(dict(CFBundleExecutable='Orvlet Helper', CFBundleIdentifier='app.orvlet.chromium.helper',
                          CFBundleName='Orvlet Helper', CFBundlePackageType='APPL', LSUIElement=True,
                          NSHighResolutionCapable=True), file)
    run('xcodebuild', '-quiet', '-project', 'Orvlet.xcodeproj', '-scheme', 'Orvlet',
        '-configuration', args.configuration, '-destination', 'platform=macOS,arch=arm64',
        '-derivedDataPath', args.build_root, 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=NO', 'ENABLE_APP_SANDBOX=NO',
        'CODE_SIGN_ENTITLEMENTS=Orvlet/OrvletBrowserHost.entitlements',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=' + ('DEBUG ' if args.configuration == 'Debug' else '') + 'NATIVE_CHROMIUM',
        'SWIFT_OBJC_BRIDGING_HEADER=' + str(ROOT / 'NativeChromium/Runtime.h'),
        'OTHER_LDFLAGS=' + str(library) + ' -lc++ -ObjC', 'build')
    app = args.build_root / 'Build/Products' / args.configuration / 'Orvlet.app'
    frameworks = app / 'Contents/Frameworks'
    framework = frameworks / 'Chromium Embedded Framework.framework'
    if framework.exists():
        shutil.rmtree(framework)  # Only this build's previous signed dependency copy.
    clone(dep / 'Release/Chromium Embedded Framework.framework', framework)
    run('ditto', helper, frameworks / helper.name)
    # Incremental builds may still contain packages copied by older build scripts.
    extensions = app / 'Contents/Resources/ChromiumExtensions'
    if extensions.exists():
        shutil.rmtree(extensions)
    licenses = app / 'Contents/Resources/ChromiumLicenses'
    licenses.mkdir(parents=True, exist_ok=True)
    run('cp', dep / 'LICENSE.txt', licenses / 'CEF.txt')
    bundle_check(app, archive)
    run('codesign', '--force', '--deep', '--sign', os.environ.get('ORVLET_SIGNING_IDENTITY', '-'),
        '--entitlements', ROOT / 'Orvlet/OrvletBrowserHost.entitlements', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    if args.configuration == 'Release':
        destination = args.output or ROOT / 'dist/Orvlet-Chromium.app'
        old_extensions = destination / 'Contents/Resources/ChromiumExtensions'
        if old_extensions.exists():
            shutil.rmtree(old_extensions)
        run('ditto', app, destination)
        run('codesign', '--verify', '--deep', '--strict', destination)
        app = destination
    print('Built (not launched):', app)


if __name__ == '__main__':
    main()
