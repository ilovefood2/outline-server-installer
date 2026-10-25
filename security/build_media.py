#!/usr/bin/env python3
"""Rebuild MediaMTX with the pinned runtime and dependency security fixes."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = '914e39535ece709919ac325aaeed98d394ed9093'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, default=ROOT / '.build/secure-mediamtx')
    args = parser.parse_args()
    source, work = args.source_dir.resolve(), args.work_dir.resolve()
    if not work.is_relative_to(ROOT / '.build') or source.is_relative_to(work):
        raise ValueError('Use an owned .build directory separate from the source checkout')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('Unexpected MediaMTX source revision')
    work.mkdir(parents=True, exist_ok=True)
    tree = work / 'source'
    if tree.exists():
        shutil.rmtree(tree)
    tree.mkdir()
    archive = subprocess.check_output(['git', '-C', str(source), 'archive', REVISION])
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        stream.extractall(tree, filter='data')
    for name in ('go.mod', 'go.sum'):
        shutil.copyfile(ROOT / 'security' / ('mediamtx-' + name), tree / name)
    environment = dict(os.environ, GOTOOLCHAIN='go1.27.3', GIT_CEILING_DIRECTORIES=str(work))
    subprocess.run(['go', 'generate', './internal/core', './internal/servers/hls',
                    './internal/staticsources/rpicamera'], cwd=tree, env=environment, check=True)
    (tree / 'internal/core/VERSION').write_text('v1.21.2-security.1')
    subprocess.run(['go', 'test', './internal/auth', './internal/conf'],
                   cwd=tree, env=environment, check=True)
    subprocess.run(['go', 'build', '-trimpath', '-buildvcs=false', '-ldflags=-s -w',
                    '-o', str(work / 'mediamtx'), '.'], cwd=tree,
                   env=dict(environment, CGO_ENABLED='0', GOOS='linux', GOARCH='arm64'), check=True)
    with (work / 'mediamtx').open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    receipt = {'revision': REVISION, 'go_toolchain': 'go1.27.3', 'sha256': checksum}
    (work / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
