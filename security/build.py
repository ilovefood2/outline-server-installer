#!/usr/bin/env python3
"""Build the hardened Pi Shadowbox image without modifying the legacy checkout."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
SECURITY = ROOT / 'security'
UPSTREAM = '067d0d47aedac94a3888a127fa6c65f2f53b9987'
GO = 'go1.27.3'
PROMETHEUS_SHA = 'ceb6d21493c37ca0b4513b147642797c68cf39a0f50a444d50e1e80c74f21b26'
NODE_IMAGE = 'node@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53'


def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def manager_tests(work):
    source, deps = work / 'upstream/src/shadowbox', work / 'deps'
    config = json.loads((source / 'tsconfig.json').read_text())
    config['compilerOptions'].update(rootDir=str(source), outDir=str(work / 'unit-tests'))
    config['include'] = ['**/*.spec.ts', 'types/**/*.d.ts']
    config['exclude'] = ['node_modules', 'build']
    path = source / 'tsconfig.security-tests.json'
    path.write_text(json.dumps(config))
    run([str(deps / 'node_modules/.bin/tsc'), '-p', str(path)])
    name = 'pi-manager-tests-' + uuid.uuid4().hex[:10]
    try:
        run(['docker', 'create', '--name', name, '--network', 'none', '--cap-drop', 'ALL',
             '--memory', '512m', '--pids-limit', '64', '-e', 'NODE_PATH=/deps/node_modules',
             '--entrypoint', 'node', NODE_IMAGE, '/deps/node_modules/jasmine/bin/jasmine.js', '/tests/**/*.spec.js'])
        run(['docker', 'cp', str(work / 'unit-tests'), name + ':/tests'])
        run(['docker', 'cp', str(deps), name + ':/deps'])
        run(['docker', 'start', '-a', name])
        if subprocess.check_output(['docker', 'inspect', name, '--format', '{{.State.ExitCode}}'], text=True).strip() != '0':
            raise RuntimeError('Linux Manager unit tests failed')
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=ROOT / '.build/outline-server')
    parser.add_argument('--work-dir', type=Path, default=ROOT / '.build/secure-shadowbox')
    parser.add_argument('--tag', default='localhost/outline/shadowbox:security-1')
    args = parser.parse_args()
    source, work = args.source_dir.resolve(), args.work_dir.resolve()
    if not work.is_relative_to(ROOT / '.build') or source.is_relative_to(work):
        raise ValueError('Use an owned .build directory separate from the source checkout')
    work.mkdir(parents=True, exist_ok=True)
    source_commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if source_commit != UPSTREAM:
        raise ValueError('Unexpected upstream source revision')
    environment = dict(os.environ, GOTOOLCHAIN=GO, GIT_CEILING_DIRECTORIES=str(work))
    upstream, backend, deps = (work / name for name in ('upstream', 'backend', 'deps'))
    for directory in (upstream, backend):
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir()
    archive = subprocess.check_output(['git', '-C', str(source), 'archive', UPSTREAM])
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        stream.extractall(upstream, filter='data')
    for patch in (ROOT / 'patches/outline-server-v1.12.3.patch', SECURITY / 'shadowbox-security.patch'):
        run(['git', 'apply', '--check', str(patch)], cwd=upstream, env=environment)
        run(['git', 'apply', str(patch)], cwd=upstream, env=environment)
    for name in ('go.mod', 'go.sum', 'tools.go'):
        shutil.copyfile(SECURITY / 'backend-deps' / name, backend / name)
    run(['go', 'mod', 'vendor'], cwd=backend, env=environment)
    for patch in (ROOT / 'patches/outline-ss-server-v1.7.3.patch',
                  SECURITY / 'server-ready.patch', SECURITY / 'server-security.patch'):
        run(['git', 'apply', '--check', str(patch)], cwd=backend, env=environment)
        run(['git', 'apply', str(patch)], cwd=backend, env=environment)
    run(['go', 'test', '-mod=vendor', '-race',
         'github.com/Jigsaw-Code/outline-ss-server/service',
         'github.com/Jigsaw-Code/outline-ss-server/cmd/outline-ss-server'], cwd=backend, env=environment)
    run(['go', 'build', '-mod=vendor', '-trimpath', '-buildvcs=false',
         '-ldflags=-s -w -X main.version=1.7.3-security.1', '-o', str(work / 'outline-ss-server'),
         'github.com/Jigsaw-Code/outline-ss-server/cmd/outline-ss-server'], cwd=backend,
        env=dict(environment, GOOS='linux', GOARCH='arm64', CGO_ENABLED='0'))
    deps.mkdir(exist_ok=True)
    for name in ('package.json', 'package-lock.json'):
        shutil.copyfile(SECURITY / name, deps / name)
    run(['npm', 'ci', '--ignore-scripts', '--no-fund', '--no-audit'], cwd=deps)
    run(['npm', 'audit', '--omit=dev'], cwd=deps)
    (upstream / 'node_modules').symlink_to(deps / 'node_modules', target_is_directory=True)
    shadowbox = upstream / 'src/shadowbox'
    (shadowbox / 'tsconfig.json').write_text(json.dumps({
        'compilerOptions': {'target': 'es2020', 'module': 'commonjs', 'moduleResolution': 'node',
                            'noImplicitAny': False, 'noImplicitThis': True, 'resolveJsonModule': True,
                            'sourceMap': False, 'skipLibCheck': True},
        'include': ['server/main.ts', 'types/**/*.d.ts'], 'exclude': ['**/*.spec.ts', 'node_modules', 'build'],
    }, indent=2) + '\n')
    run([str(deps / 'node_modules/.bin/webpack'), '--config', str(shadowbox / 'webpack.config.js'),
         '--output-path', str(work / 'app')], cwd=upstream, env=dict(environment, SB_VERSION='1.12.3'))
    manager_tests(work)
    prometheus = work / 'prometheus-3.15.1.linux-arm64.tar.gz'
    if not prometheus.exists():
        url = 'https://github.com/prometheus/prometheus/releases/download/v3.15.1/' + prometheus.name
        with urllib.request.urlopen(url, timeout=30) as response, prometheus.open('wb') as output:
            shutil.copyfileobj(response, output)
    if digest(prometheus) != PROMETHEUS_SHA:
        raise ValueError('Prometheus asset checksum mismatch')
    context = work / 'image'
    if context.exists():
        shutil.rmtree(context)
    (context / 'bin').mkdir(parents=True)
    (context / 'licenses').mkdir()
    with tarfile.open(prometheus) as stream:
        for name in ('prometheus', 'LICENSE', 'NOTICE'):
            destination = context / ('bin/prometheus' if name == 'prometheus' else 'licenses/prometheus-' + name)
            destination.write_bytes(stream.extractfile('prometheus-3.15.1.linux-arm64/' + name).read())
    shutil.copyfile(work / 'outline-ss-server', context / 'bin/outline-ss-server')
    shutil.copytree(work / 'app', context / 'app')
    shutil.copyfile(upstream / 'LICENSE', context / 'licenses/outline-LICENSE')
    for name in ('package.json', 'package-lock.json', 'Dockerfile', 'entrypoint.sh', 'start.sh', 'health.js'):
        shutil.copyfile(SECURITY / name, context / name)
    updater = (shadowbox / 'scripts/update_mmdb.sh').read_text().replace(
        'curl --fail --silent', 'curl --fail --silent --connect-timeout 5 --max-time 60 --max-filesize 52428800')
    (context / 'update_mmdb.sh').write_text(updater)
    for name in ('entrypoint.sh', 'start.sh', 'update_mmdb.sh', 'bin/prometheus', 'bin/outline-ss-server'):
        (context / name).chmod(0o755)
    run(['docker', 'build', '--platform', 'linux/arm64', '-t', args.tag, str(context)])
    receipt = {'tag': args.tag, 'upstream_commit': UPSTREAM, 'go_toolchain': GO,
               'backend_sha256': digest(context / 'bin/outline-ss-server'),
               'node': '24.22.1', 'prometheus': '3.15.1', 'production_npm_audit': 'passed',
               'image_id': subprocess.check_output(['docker', 'image', 'inspect', args.tag,
                                                   '--format', '{{.Id}}'], text=True).strip()}
    (work / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
