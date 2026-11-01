#!/usr/bin/env python3
"""Check publishable Git files without printing potential secret contents."""
from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REVIEWED_IMAGES = {"docs/assets/compact-timer.png", "docs/assets/command-window.png"}
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
    if any(p.startswith('.build') or p in {'.local', '.backups', 'dist', 'DerivedData', 'build', 'xcuserdata', '__pycache__', '.aws', '.codex', '.agents', '.venv'} for p in parts):
        return True
    if any(p.endswith(('.app', '.dSYM', '.xcarchive', '.xcresult')) for p in parts):
        return True
    if path.name in {'.DS_Store', 'bridge.json'} or (path.name.startswith('.env') and path.name != '.env.example'):
        return True
    if path.suffix in {'.p12', '.p8', '.pem', '.key', '.mobileprovision', '.provisionprofile', '.xcuserstate', '.pyc', '.log', '.jsonl', '.zip', '.gz'}:
        return True
    if name.startswith('Tests/') and path.suffix == '.json':
        return True
    if path.name.endswith('.local.xcconfig') or path.name.startswith(('credentials', 'secrets')):
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
        if len(data) > 1_000_000:
            findings.append(f'{name}: file exceeds the source-tree size limit')
        if name in REVIEWED_IMAGES:
            if not data.startswith(b'\x89PNG\r\n\x1a\n'):
                findings.append(f'{name}: expected reviewed PNG')
            continue
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
