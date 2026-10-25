#!/usr/bin/python3
"""Update the existing updater without changing its watched apps or credentials."""
import argparse
import copy
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

from install_on_pi import digest, inspect, private_write, run

IMAGE = 'nickfedor/watchtower:1.23.2'
IMAGE_IDS = {'sha256:62fb91130ddb493f869cad7e198fa260dd16c5da293ed092cbd5d8781566f7a6',
             'sha256:eb3ecbd909c6196551eba73d20644ce85fe888e8db58d32e586aa5bf302331ff'}
ARCHIVE_SHA = 'd11a8d2ee9dc845ca50ed235f27fcdb560dfc7d2b446f2daa49908c03305f2ae'


class DockerHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/var/run/docker.sock')


def create(configuration):
    connection = DockerHTTP('localhost', timeout=15)
    connection.request('POST', '/v1.44/containers/create?name=watchtower-security-candidate', json.dumps(configuration),
                       {'Content-Type': 'application/json'})
    response = connection.getresponse()
    response.read()
    connection.close()
    if response.status != 201:
        raise RuntimeError('Container creation failed with HTTP ' + str(response.status))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup', type=Path, required=True)
    args = parser.parse_args()
    backup = args.backup.resolve()
    if os.geteuid() != 0 or not backup.is_relative_to('/var/backups') or backup.stat().st_uid != 0:
        raise SystemExit('Use the root-owned verified backup')
    if run(['docker', 'info', '--format', '{{.MemoryLimit}}']) != 'true':
        raise SystemExit('Activate the memory controller before installing resource limits')
    archive = backup / 'watchtower-image.tar'
    if digest(archive) != ARCHIVE_SHA:
        raise SystemExit('Updater archive checksum mismatch')
    old = inspect('watchtower')
    if subprocess.run(['docker', 'inspect', 'watchtower-before-security'], capture_output=True).returncode == 0:
        raise SystemExit('Existing updater rollback container; review before another update')
    if subprocess.run(['docker', 'inspect', 'watchtower-security-candidate'], capture_output=True).returncode == 0:
        raise SystemExit('Existing updater candidate; review before another update')
    private_write(backup / 'watchtower-immediate-before.json', json.dumps(old, indent=2) + '\n')
    run(['docker', 'load', '--input', str(archive)])
    image = json.loads(run(['docker', 'image', 'inspect', IMAGE]))[0]
    if image['Id'] not in IMAGE_IDS or image['Architecture'] != 'arm64':
        raise SystemExit('Unexpected updater image')
    check = subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
                            '--security-opt', 'no-new-privileges', '--memory', '256m', '--pids-limit', '128',
                            '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=64m',
                            '--mount', 'type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly',
                            image['Id'], '--run-once', '--monitor-only', '--no-pull', '--no-restart', '--tlsverify',
                            '--scope', 'security-check-' + uuid.uuid4().hex], capture_output=True, text=True, timeout=60)
    private_write(backup / 'watchtower-api-test.log', check.stdout + check.stderr)
    if check.returncode or 'failed=0' not in check.stdout + check.stderr:
        raise SystemExit('Read-only Docker API test failed; existing updater was left running')
    config = copy.deepcopy(old['Config'])
    config['Image'] = image['Id']
    for key, value in image['Config'].get('Labels', {}).items():
        if key.startswith('org.opencontainers.image.') or key not in config['Labels']:
            config['Labels'][key] = value
    config['Labels']['com.centurylinklabs.watchtower.enable'] = 'false'
    host = copy.deepcopy(old['HostConfig'])
    host.update(ReadonlyRootfs=True, CapDrop=['ALL'], CapAdd=[], SecurityOpt=['no-new-privileges'],
                Memory=268435456, MemoryReservation=67108864, MemorySwap=335544320, PidsLimit=128,
                Tmpfs={'/tmp': 'rw,noexec,nosuid,nodev,size=64m'},
                LogConfig={'Type': 'local', 'Config': {'max-size': '10m', 'max-file': '3'}})
    config['HostConfig'] = host
    create(config)
    renamed = False
    try:
        candidate = inspect('watchtower-security-candidate')
        if candidate['Config']['Cmd'] != old['Config']['Cmd']:
            raise RuntimeError('Existing updater command changed')
        run(['docker', 'update', '--restart=no', 'watchtower'])
        run(['docker', 'stop', '--time', '25', 'watchtower'])
        run(['docker', 'rename', 'watchtower', 'watchtower-before-security']); renamed = True
        run(['docker', 'rename', 'watchtower-security-candidate', 'watchtower'])
        run(['docker', 'start', 'watchtower'])
        for _ in range(75):
            current = inspect('watchtower')
            if current['State'].get('Health', {}).get('Status') == 'healthy':
                break
            if not current['State']['Running']:
                raise RuntimeError('New updater stopped')
            time.sleep(1)
        else:
            raise RuntimeError('New updater did not become healthy')
        previous_env = dict(value.split('=', 1) for value in old['Config']['Env'])
        current_env = dict(value.split('=', 1) for value in current['Config']['Env'])
        if current['Config']['Cmd'] != old['Config']['Cmd'] or any(current_env.get(k) != v for k, v in previous_env.items()):
            raise RuntimeError('Existing updater settings changed')
        result = {'version': '1.23.2', 'healthy': True, 'docker_api_test': True, 'configuration_preserved': True,
                  'readonly': True, 'no_new_privileges': True, 'memory_limit': 268435456, 'rollback_restart': 'no'}
        private_write(backup / 'watchtower-security-status.json', json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    except Exception:
        subprocess.run(['docker', 'rm', '-f', 'watchtower-security-candidate'], capture_output=True)
        if renamed:
            subprocess.run(['docker', 'rm', '-f', 'watchtower'], capture_output=True)
            run(['docker', 'rename', 'watchtower-before-security', 'watchtower'])
        run(['docker', 'update', '--restart=' + old['HostConfig']['RestartPolicy']['Name'], 'watchtower'])
        run(['docker', 'start', 'watchtower'])
        raise


if __name__ == '__main__':
    main()
