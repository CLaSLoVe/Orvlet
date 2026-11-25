#!/usr/bin/env python3
"""Check publishable Git files without printing potential secret contents."""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REVIEWED_IMAGES = {
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_128x128@1x.png": "6df0d415bbff94240f77ac78516908cdb2a3ccbc30e05bfbbf6a74ae4c3ccc0a",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png": "72efe02614772bf341d4946922f46b4a9fe617b9cac8c948bce019ea99096d69",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_16x16@1x.png": "96f5e5992655830d0c424457743514c904d609992daa69e6a3df8aa171efd1a1",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png": "3be437304584e7c5f270464c900f691bf385311feb9c668f7784603da1db21b7",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_256x256@1x.png": "72efe02614772bf341d4946922f46b4a9fe617b9cac8c948bce019ea99096d69",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png": "551d2aa5ab0ea99862c3bd51b87aaf7aa0e027cbd1b84af15b83d536e2d89266",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_32x32@1x.png": "3be437304584e7c5f270464c900f691bf385311feb9c668f7784603da1db21b7",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png": "b68abce04a4e0e3077e799f58bc53f6556b3e90ed5a09b7ce5bff0b1cc5315e6",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png": "551d2aa5ab0ea99862c3bd51b87aaf7aa0e027cbd1b84af15b83d536e2d89266",
    "Orvlet/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png": "093a054364cfbe7ac2097497e908f7aedc538085a8d4cdc3864782cbf329e8b2",
    "Orvlet/Assets.xcassets/StatusMark.imageset/status@1x.png": "c57520d02d4ee6c53f305661f087c396eb060e287f1b6dd40e94d465358daa23",
    "Orvlet/Assets.xcassets/StatusMark.imageset/status@2x.png": "709d7c1204165b3557cc9139039f5faf9f9f78e86d552aa9968c0dd53c381363",
    "docs/assets/command-window.png": "bb6bcde1c57505bafb821da939301e68eb62daf2e26281ba9e383cb4e6b13cf9",
    "docs/assets/compact-timer.png": "5d90a2241c77b50b27625c661298e5d711c054baa655f8754f9a5f19f1a5ce06",
    "docs/assets/generative-ui.png": "1f1fdcf807adbe076844e0ddd405388e97e1b41dbb8a8f44878a187596416b7c",
    "docs/assets/generative-ui.zh-CN.png": "44055bd33ecfc079130a7c4d1d1c6c7ddb2bd2d78909414208888318191df5ef",
    "docs/brand/orvlet-icon.png": "551d2aa5ab0ea99862c3bd51b87aaf7aa0e027cbd1b84af15b83d536e2d89266",
    "docs/brand/orvlet-identity.png": "cbac5348115d64157b8f511961408a8c4a93584b275b99a5a027201d9dcd9c7b",
}
SECRET_PATTERNS = {
    "provider key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "literal bearer token": re.compile(r"Bearer\s+[A-Za-z0-9_.-]{32,}"),
    "credential URL": re.compile(r"https?://[^\s/:]+:[^\s/@]+@"),
    "literal credential field": re.compile(r'''["'](?:api_key|apiKey|token|secret|password)["']\s*:\s*["'][A-Za-z0-9_+/.=-]{24,}["']'''),
    "personal absolute path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "personal signing team": re.compile(r"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*;"),
}


def forbidden_path(name: str) -> bool:
    path = PurePosixPath(name)
    parts = path.parts
    if any(p.startswith('.build') or p in {'.local', '.backups', 'output', 'tmp', 'dist', 'DerivedData', 'build', 'xcuserdata', '__pycache__', '.aws', '.codex', '.agents', '.venv'} for p in parts):
        return True
    if any(p.endswith(('.app', '.dSYM', '.xcarchive', '.xcresult')) for p in parts):
        return True
    if path.name in {'.DS_Store', 'bridge.json'} or (path.name.startswith('.env') and path.name != '.env.example'):
        return True
    if path.suffix in {'.p12', '.p8', '.pem', '.key', '.mobileprovision', '.provisionprofile', '.xcuserstate', '.pyc', '.log', '.jsonl', '.zip', '.gz'}:
        return True
    if name.startswith('Tests/') and path.suffix == '.json':
        return True
    if path.name.endswith('.local.xcconfig') or path.name.lower().startswith(('credentials', '.credentials', 'secrets')):
        return True
    return False


def inspect_text(name: str, text: str) -> list[str]:
    findings = []
    for label, pattern in SECRET_PATTERNS.items():
        for match in pattern.finditer(text):
            line = text.count('\n', 0, match.start()) + 1
            findings.append(f'{name}:{line}: {label}; value omitted')
    return findings


def candidate_files() -> list[str]:
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT, check=True, capture_output=True)
    return sorted(set(result.stdout.decode().rstrip('\0').split('\0')) - {''})


def main() -> int:
    try:
        names = candidate_files()
    except subprocess.CalledProcessError:
        print('Initialize a local Git repository before running this check.', file=sys.stderr)
        return 2
    findings = []
    # The upload candidate is the index, so do not bless a cleaned working copy
    # while an older, different version remains staged.
    unstaged = subprocess.run(['git', 'diff', '--name-only', '-z'], cwd=ROOT, check=True, capture_output=True).stdout.decode().split('\0')
    findings += [f'{name}: staged and working contents differ; review and stage the intended version' for name in unstaged if name]
    total = 0
    required = {'README.md', 'README.zh-CN.md', 'SECURITY.md', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md', '.gitignore', 'Orvlet.xcodeproj/project.pbxproj', 'Orvlet.xcodeproj/xcshareddata/xcschemes/Orvlet.xcscheme'}
    findings += [f'Missing required file: {p}' for p in sorted(required - set(names))]
    for name in names:
        path = ROOT / name
        if forbidden_path(name):
            findings.append(f'{name}: local/private/generated artifact is in the candidate set')
            continue
        if path.is_symlink():
            findings.append(f'{name}: review symlink before publication')
            continue
        if not path.is_file():
            findings.append(f'{name}: tracked file is missing; stage its deletion or restore it')
            continue
        data = path.read_bytes()
        total += len(data)
        if name in REVIEWED_IMAGES:
            if hashlib.sha256(data).hexdigest() != REVIEWED_IMAGES[name]:
                findings.append(f'{name}: reviewed artwork changed; inspect the new file before updating its digest')
            continue
        if len(data) > 1_000_000:
            findings.append(f'{name}: file exceeds the source-tree size limit')
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            findings.append(f'{name}: unreviewed binary file')
            continue
        findings += inspect_text(name, text)
        try:
            if path.suffix == '.json':
                json.loads(text)
            if path.suffix in {'.plist', '.entitlements'}:
                plistlib.loads(data)
            if path.suffix in {'.xcscheme', '.xcworkspacedata'}:
                ET.fromstring(text)
        except (ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
            findings.append(f'{name}: invalid structured file ({type(error).__name__})')
        if path.suffix == '.md':
            links = re.findall(r'\]\(([^)]+)\)', text) + re.findall(r'<img\s+[^>]*src="([^"]+)"', text)
            for link in links:
                target = link.split('#', 1)[0]
                if not target or re.match(r'[a-zA-Z]+:', target):
                    continue
                resolved = (path.parent / unquote(target)).resolve()
                if not resolved.is_relative_to(ROOT) or not resolved.exists():
                    findings.append(f'{name}: broken or outside-repository documentation link')
                elif resolved.is_file() and resolved.relative_to(ROOT).as_posix() not in names:
                    findings.append(f'{name}: documentation links to an excluded file')
    runtime = ROOT / 'Orvlet/Resources/browser.js'
    extension = ROOT / 'integrations/browser/browser.js'
    if runtime.read_bytes() != extension.read_bytes():
        findings.append('Bundled and extension browser scripts differ; review and synchronize them')
    ignored_probes = ['.build/keep', '.build-old/keep', 'dist/Orvlet.app/keep', '.backups/keep', '.local/report.json', '.env', 'bridge.json', 'test.p12', 'Orvlet.xcodeproj/xcuserdata/user/state', 'Tests/report.jsonl']
    for probe in ignored_probes:
        if subprocess.run(['git', 'check-ignore', '--quiet', '--no-index', probe], cwd=ROOT).returncode != 0:
            findings.append(f'.gitignore does not exclude expected private artifact class: {probe}')
    if findings:
        print('\n'.join(findings), file=sys.stderr)
        print(f'FAIL: {len(findings)} finding(s); potential values were not printed.', file=sys.stderr)
        return 1
    print(f'PASS: {len(names)} candidate files, {total / 1024:.0f} KiB. Publication exclusions, common secret patterns, structured files and local docs checked.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
