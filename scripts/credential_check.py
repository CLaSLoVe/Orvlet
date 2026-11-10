#!/usr/bin/env python3
"""Fail closed on credential artifacts; diagnostics never print matched values."""
import argparse
import json
import subprocess
from pathlib import Path

from repository_check import ROOT, SECRET_PATTERNS, candidate_files, forbidden_path


def inspect(name, data, bundle=False):
    findings = []
    leaf = Path(name).name.lower()
    private = (leaf.startswith(('credentials', '.credentials', 'secrets')) or
               leaf == 'bridge.json' or (leaf.startswith('.env') and leaf != '.env.example'))
    if private or (not bundle and forbidden_path(name)):
        findings.append(f'{name}: private/local artifact; contents omitted')
    text = data.decode('utf-8', errors='ignore')
    for label, pattern in SECRET_PATTERNS.items():
        if label.startswith('personal '):
            continue
        if pattern.search(text):
            findings.append(f'{name}: {label}; value omitted')
    # Catch a renamed copy of our local store even for providers with opaque keys.
    if name.endswith('.json'):
        try:
            value = json.loads(text)
            if isinstance(value, dict) and any(
                isinstance(v, str) and v and (k in {'main', 'fast'} or k.startswith(('main.profile.', 'fast.')))
                for k, v in value.items()
            ):
                findings.append(f'{name}: local credential map; values omitted')
        except (ValueError, TypeError):
            pass
    return findings


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--staged', action='store_true')
    group.add_argument('--history', action='store_true')
    group.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    findings, count = [], 0
    if args.bundle:
        if not args.bundle.is_dir():
            parser.error('App bundle does not exist')
        entries = ((p.relative_to(args.bundle).as_posix(), p.read_bytes()) for p in args.bundle.rglob('*') if p.is_file())
    elif args.history:
        # Scan all reachable committed blobs, including earlier revisions that a
        # clean final tree would otherwise hide. No remote/network operation.
        entries = []
        for line in git('rev-list', '--objects', '--all').decode().splitlines():
            oid, _, name = line.partition(' ')
            if name and git('cat-file', '-t', oid).strip() == b'blob':
                entries.append((name, git('cat-file', 'blob', oid)))
    elif args.staged:
        entries = []
        for record in git('ls-files', '--stage', '-z').decode().split('\0'):
            if not record:
                continue
            metadata, name = record.split('\t', 1)
            mode, oid, stage = metadata.split()
            if mode == '120000' or stage != '0':
                findings.append(f'{name}: unresolved or redirected index entry')
            elif mode != '160000':
                entries.append((name, git('cat-file', 'blob', oid)))
    else:
        entries = []
        for name in candidate_files():
            path = ROOT / name
            if path.is_symlink():
                findings.append(f'{name}: redirected source file')
            elif path.is_file():
                entries.append((name, path.read_bytes()))
    for name, data in entries:
        count += 1
        findings.extend(inspect(name, data, bundle=bool(args.bundle)))
    if findings:
        print('\n'.join(sorted(set(findings))))
        print('FAIL: credentials check blocked this action; values were not printed.')
        return 1
    print(f'PASS: {count} files checked for credential artifacts and common secret patterns.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
