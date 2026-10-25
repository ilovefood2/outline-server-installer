#!/usr/bin/python3
"""Install a checksum-verified security bundle while retaining Outline identity."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import ssl
import stat
import subprocess
import time
import urllib.request

import yaml

HERE = Path(__file__).resolve().parent
STATE = Path('/opt/outline/persisted-state')
SECURE_STATE = Path('/opt/outline/persisted-state-security')
LEGACY = 'shadowbox-before-security'


def run(args, **kwargs):
    result = subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)
    return result.stdout.strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def private_write(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.security-new')
    temporary.write_text(text)
    temporary.chmod(mode)
    os.replace(temporary, path)


def inspect(name):
    return json.loads(run(['docker', 'inspect', name]))[0]


def key_identity(directory):
    config = json.loads((directory / 'shadowbox_config.json').read_text())
    return config


def sync_state(staging, live=False):
    copied = subprocess.run(['rsync', '--archive', '--hard-links', '--delete', '--no-whole-file', '--',
                             str(STATE) + '/', str(staging) + '/'], capture_output=True)
    # TSDB compaction can remove files during the online copy; the frozen sync must be exact.
    if copied.returncode not in ((0, 24) if live else (0,)):
        raise RuntimeError('State synchronization failed with exit ' + str(copied.returncode))


def restore_checkpoint(staging, name):
    if Path(name).name != name or not name:
        raise RuntimeError('Unsafe metrics checkpoint name')
    data = staging / 'prometheus/data'
    snapshot = data / 'snapshots' / name
    if not snapshot.is_dir() or not any(snapshot.iterdir()):
        raise RuntimeError('Missing metrics checkpoint')
    previous = data.with_name('data-before-security')
    if previous.exists():
        raise RuntimeError('Unexpected existing metrics archive')
    data.rename(previous)
    # Link only inside the new copy; the original rollback database stays independent.
    shutil.copytree(previous / 'snapshots' / name, data, copy_function=os.link)


def manager_request(environment, directory, path):
    certificate = directory / Path(environment['SB_CERTIFICATE_FILE']).name
    context = ssl.create_default_context(cafile=str(certificate))
    context.check_hostname = False
    connection = http.client.HTTPSConnection('10.0.0.33', int(environment['SB_API_PORT']),
                                             context=context, timeout=4)
    connection.connect()
    expected = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate.read_text())).digest()
    actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).digest()
    if actual != expected:
        connection.close()
        raise RuntimeError('Manager certificate pin changed')
    connection.request('GET', '/' + environment['SB_API_PREFIX'] + path)
    response = connection.getresponse()
    payload = response.read(2 * 1024 * 1024)
    connection.close()
    if response.status != 200:
        raise RuntimeError('Manager verification failed')
    return json.loads(payload)


def install_image(backup, manifest):
    old = inspect('shadowbox')
    if any(m.get('Source') == str(SECURE_STATE) for m in old['Mounts']):
        raise RuntimeError('Secure state already active; review before another migration')
    mounts = [m for m in old['Mounts'] if m['Type'] == 'bind' and m['Source'] == str(STATE)]
    if len(mounts) != 1 or SECURE_STATE.exists():
        raise RuntimeError('Unexpected existing state layout')
    if subprocess.run(['docker', 'inspect', LEGACY], capture_output=True).returncode == 0:
        raise RuntimeError('The rollback container name already exists')
    identity = key_identity(STATE)
    server_before = json.loads((STATE / 'shadowbox_server_config.json').read_text())
    certificate_name = Path(dict(v.split('=', 1) for v in old['Config']['Env'] if '=' in v)['SB_CERTIFICATE_FILE']).name
    certificate_before = digest(STATE / certificate_name)
    environment = {k: v for k, v in (x.split('=', 1) for x in old['Config']['Env'] if '=' in x) if k.startswith('SB_')}
    environment['SB_PUBLIC_IP'] = server_before['hostname']
    environment['SB_API_ADDRESS'] = '10.0.0.33'
    if environment.get('SB_ALLOW_PRIVATE_TARGETS') != 'true' or environment.get('SB_ACCESS_KEY_PREFIX') != 'POST%20':
        raise RuntimeError('The authorized LAN/prefix policy changed')
    if len(environment.get('SB_API_PREFIX', '')) < 20:
        raise RuntimeError('Existing Manager secret is missing')
    environment.update(GOMEMLIMIT='256MiB', NODE_OPTIONS='--max-old-space-size=256', LOG_LEVEL='info')
    for name, value in environment.items():
        if any(c in name + value for c in '\r\n\x00'):
            raise RuntimeError('Unsafe environment record')
    env_file = backup / 'secure-container.env'
    private_write(env_file, ''.join(name + '=' + value + '\n' for name, value in environment.items()))
    run(['docker', 'load', '--input', str(HERE / 'shadowbox-image.tar')])
    image = json.loads(run(['docker', 'image', 'inspect', manifest['image_tag']]))[0]
    # Docker's classic and containerd stores expose different IDs for the same export.
    allowed_ids = {manifest['image_id'], manifest['image_config_id']}
    if image['Architecture'] != 'arm64' or image['Os'] != 'linux' or image['Id'] not in allowed_ids:
        raise RuntimeError('Wrong image identity or architecture')
    staging = backup / 'outline-state-staging'
    marker = backup / 'outline-state-staging.json'
    expected_marker = {'source': str(STATE), 'original_image': old['Image']}
    if staging.exists():
        if staging.is_symlink() or not marker.exists() or json.loads(marker.read_text()) != expected_marker:
            raise RuntimeError('Unrecognized state staging directory')
    else:
        staging.mkdir(mode=0o700)
        private_write(marker, json.dumps(expected_marker) + '\n')
    sync_state(staging, live=True)
    request = urllib.request.Request('http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot', method='POST')
    with urllib.request.urlopen(request, timeout=90) as response:
        checkpoint = json.load(response)
    if checkpoint.get('status') != 'success':
        raise RuntimeError('Metrics checkpoint failed')
    checkpoint_name = checkpoint['data']['name']
    private_write(backup / 'metrics-checkpoint.json', json.dumps(checkpoint) + '\n')
    sync_state(staging, live=True)
    renamed = False
    try:
        run(['docker', 'update', '--restart=no', 'shadowbox'])
        run(['docker', 'stop', '--time', '25', 'shadowbox'], timeout=40)
        identity = key_identity(STATE)
        server_before = json.loads((STATE / 'shadowbox_server_config.json').read_text())
        certificate_before = digest(STATE / certificate_name)
        environment['SB_PUBLIC_IP'] = server_before['hostname']
        private_write(env_file, ''.join(name + '=' + value + '\n' for name, value in environment.items()))
        sync_state(staging)
        for path in [staging] + list(staging.rglob('*')):
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise RuntimeError('Unexpected state entry; refusing migration')
        restore_checkpoint(staging, checkpoint_name)
        staging.rename(SECURE_STATE)
        # Root startup scripts must remain outside application-writable state.
        startup = SECURE_STATE / 'start_container.sh'
        if startup.exists():
            startup.unlink()
        for path in [SECURE_STATE] + list(SECURE_STATE.rglob('*')):
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise RuntimeError('Unexpected state entry; refusing migration')
        for path in [SECURE_STATE] + list(SECURE_STATE.rglob('*')):
            os.chown(path, 31999, 31999)
            path.chmod(0o700 if path.is_dir() else 0o600)
        run(['docker', 'rename', 'shadowbox', LEGACY]); renamed = True
        command = ['docker', 'run', '-d', '--name', 'shadowbox', '--restart', 'unless-stopped',
                   '--network', 'host', '--read-only', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges', '--memory', '1g', '--memory-reservation', '256m',
                   '--memory-swap', '1280m', '--pids-limit', '256', '--ulimit', 'nofile=8192:8192',
                   '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=64m,uid=31999,gid=31999,mode=1777',
                   '--tmpfs', '/var/lib/libmaxminddb:rw,noexec,nosuid,nodev,size=256m,uid=31999,gid=31999,mode=0700',
                   '--mount', 'type=bind,source=' + str(SECURE_STATE) + ',target=' + str(STATE),
                   '--env-file', str(env_file), '--label', 'com.centurylinklabs.watchtower.enable=false',
                   '--log-driver', 'local', '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3']
        for capability in ('NET_BIND_SERVICE', 'SETUID', 'SETGID', 'SETPCAP'):
            command.extend(['--cap-add', capability])
        run(command + [image['Id']])
        for _ in range(180):
            current = inspect('shadowbox')
            if current['State'].get('Health', {}).get('Status') == 'healthy':
                break
            if not current['State']['Running']:
                raise RuntimeError('New container stopped before becoming healthy')
            time.sleep(1)
        else:
            raise RuntimeError('New container did not become healthy')
        if key_identity(SECURE_STATE) != identity or digest(SECURE_STATE / certificate_name) != certificate_before:
            raise RuntimeError('Existing keys, settings or certificate changed')
        server_after = json.loads((SECURE_STATE / 'shadowbox_server_config.json').read_text())
        if server_after != server_before:
            raise RuntimeError('Existing server identity/settings changed')
        api = manager_request(environment, SECURE_STATE, '/access-keys')
        expected = {k['id']: (k['name'], k['password'], k['port'], k['encryptionMethod'], k.get('dataLimit'))
                    for k in identity['accessKeys']}
        actual = {k['id']: (k['name'], k['password'], k['port'], k['method'], k.get('dataLimit'))
                  for k in api['accessKeys']}
        if expected != actual or any('&prefix=POST%20' not in k['accessUrl'] or ':80/' not in k['accessUrl']
                                      for k in api['accessKeys']):
            raise RuntimeError('Access-key API did not preserve the existing transport')
        rows = run(['docker', 'top', 'shadowbox', '-eo', 'pid,uid,comm']).splitlines()[1:]
        found = set()
        for row in rows:
            parts = row.split()
            if len(parts) >= 3 and parts[2] in ('node', 'MainThread', 'prometheus', 'outline-ss-serv'):
                if parts[1] != '31999':
                    raise RuntimeError('A network service retained root privileges')
                found.add('node' if parts[2] == 'MainThread' else parts[2])
                if parts[2] == 'outline-ss-serv' and digest(Path('/proc') / parts[0] / 'exe') != manifest['backend_sha256']:
                    raise RuntimeError('The running backend hash does not match the tested build')
        if len(found) != 3:
            raise RuntimeError('Expected service processes are missing')
        return {'healthy': True, 'keys_preserved': len(expected), 'certificate_preserved': True,
                'identity_preserved': True, 'lan_access_preserved': True, 'nonroot_services': True,
                'running_backend_verified': True, 'rollback_container_restart': 'no',
                'metrics_checkpoint_restored': True, 'raw_metrics_files_retained': True}
    except Exception:
        if renamed:
            subprocess.run(['docker', 'rm', '-f', 'shadowbox'], capture_output=True)
            run(['docker', 'rename', LEGACY, 'shadowbox'])
        run(['docker', 'update', '--restart=' + old['HostConfig']['RestartPolicy']['Name'], 'shadowbox'])
        run(['docker', 'start', 'shadowbox'])
        raise


def secure_media_config(data):
    if data.get('authMethod', 'internal') != 'internal':
        raise RuntimeError('Existing media authentication needs a separate migration')
    if any(user.get('user') != 'any' or user.get('pass') for user in data.get('authInternalUsers', [])):
        raise RuntimeError('Preserve configured media credentials; review before migration')
    # Do not enable the new protocol merely by upgrading a legacy configuration.
    data.setdefault('moq', False)
    removed = []
    for name, entry in list(data.get('paths', {}).items()):
        if isinstance(entry, dict) and str(entry.get('recordPath', '')).startswith('/mnt/eufy/cam-recordings/'):
            removed.append(name)
            del data['paths'][name]
    data['authInternalUsers'] = [
        {'user': 'any', 'pass': '', 'ips': ['127.0.0.1', '::1', '10.0.0.33'],
         'permissions': [{'action': 'publish', 'path': ''}]},
        {'user': 'any', 'pass': '', 'ips': ['127.0.0.1', '::1', '10.0.0.0/24', 'fc00::/7'],
         'permissions': [{'action': 'read', 'path': ''}, {'action': 'playback', 'path': ''}]},
        {'user': 'any', 'pass': '', 'ips': ['127.0.0.1', '::1'],
         'permissions': [{'action': x} for x in ('api', 'metrics', 'pprof')]},
    ]
    for field, address in [('apiAddress', '127.0.0.1:9997'), ('metricsAddress', '127.0.0.1:9998'),
                           ('pprofAddress', '127.0.0.1:9999')]:
        if field in data:
            data[field] = address
    return removed


def harden_media(backup):
    config = Path('/opt/mediamtx/mediamtx.yml')
    binary = Path('/opt/mediamtx/mediamtx')
    original_metadata = {path: path.stat() for path in (config, binary)}
    shutil.copy2(binary, backup / 'mediamtx-original')
    (backup / 'mediamtx-original').chmod(0o700)
    shutil.copy2(config, backup / 'mediamtx-original.yml')
    (backup / 'mediamtx-original.yml').chmod(0o600)
    data = yaml.safe_load(config.read_text())
    removed = secure_media_config(data)
    candidate = backup / 'mediamtx-secure.yml'
    private_write(candidate, yaml.safe_dump(data, sort_keys=False))
    check = subprocess.run([str(HERE / 'mediamtx'), '--validate-conf', str(candidate)], capture_output=True, text=True)
    private_write(backup / 'mediamtx-validation.log', check.stdout + check.stderr)
    if check.returncode:
        raise RuntimeError('New media configuration failed validation; see the private log')
    try:
        account = pwd.getpwnam('mediamtx')
        if account.pw_shell not in ('/usr/sbin/nologin', '/bin/false'):
            raise RuntimeError('Existing mediamtx account is not a restricted service account')
    except KeyError:
        run(['useradd', '--system', '--user-group', '--create-home', '--home-dir', '/var/lib/mediamtx',
             '--shell', '/usr/sbin/nologin', 'mediamtx'])
        account = pwd.getpwnam('mediamtx')
    dropin = Path('/etc/systemd/system/mediamtx.service.d/security.conf')
    previous = dropin.read_bytes() if dropin.exists() else None
    run(['systemctl', 'stop', 'mediamtx'])
    try:
        temporary = binary.with_name('mediamtx.security-new')
        shutil.copyfile(HERE / 'mediamtx', temporary); temporary.chmod(0o755); os.replace(temporary, binary)
        private_write(config, candidate.read_text(), 0o640); os.chown(config, 0, account.pw_gid)
        private_write(dropin, (HERE / 'mediamtx-hardening.conf').read_text(), 0o644)
        run(['systemctl', 'daemon-reload']); run(['systemctl', 'start', 'mediamtx'])
        time.sleep(3)
        run(['systemctl', 'is-active', '--quiet', 'mediamtx'])
        pid = run(['systemctl', 'show', 'mediamtx', '-p', 'MainPID', '--value'])
        status = (Path('/proc') / pid / 'status').read_text()
        if ('NoNewPrivs:\t1' not in status or status.split('Uid:\t', 1)[1].split()[0] != str(account.pw_uid)):
            raise RuntimeError('Media privilege isolation did not take effect')
        return {'active': True, 'dedicated_account': True, 'no_new_privileges': True,
                'unused_eufy_paths_removed': len(removed), 'publisher_sources': 'same host only',
                'reader_sources': 'trusted LAN and Outline', 'recording_files_deleted': False}
    except Exception:
        subprocess.run(['systemctl', 'stop', 'mediamtx'], capture_output=True)
        shutil.copy2(backup / 'mediamtx-original', binary)
        shutil.copy2(backup / 'mediamtx-original.yml', config)
        for path, metadata in original_metadata.items():
            os.chown(path, metadata.st_uid, metadata.st_gid)
            path.chmod(stat.S_IMODE(metadata.st_mode))
        if previous is None:
            dropin.unlink(missing_ok=True)
        else:
            dropin.write_bytes(previous)
        run(['systemctl', 'daemon-reload']); run(['systemctl', 'start', 'mediamtx'])
        raise


def install_guard():
    private_write(Path('/etc/pi-guard.nft'), (HERE / 'pi-guard.nft').read_text())
    private_write(Path('/usr/local/sbin/pi-guard-apply'), (HERE / 'apply_guard.py').read_text(), 0o700)
    private_write(Path('/etc/systemd/system/pi-guard.service'), (HERE / 'pi-guard.service').read_text(), 0o644)
    run(['/usr/local/sbin/pi-guard-apply', '--check'])
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', 'pi-guard.service'])
    return {'enabled': True, 'forwarding_chains_changed': False, 'public_data_port': 'TCP/UDP 80',
            'management_sources': 'loopback and trusted LAN'}


def configure_updates():
    private_write(Path('/etc/apt/apt.conf.d/20auto-upgrades'),
                  'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n')
    private_write(Path('/etc/apt/apt.conf.d/52pi-security'),
                  'Unattended-Upgrade::Automatic-Reboot "false";\n'
                  'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";\n')
    run(['systemctl', 'enable', '--now', 'apt-daily.timer', 'apt-daily-upgrade.timer'])
    return {'security_updates_enabled': True, 'automatic_reboot': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0 or platform.machine() != 'aarch64':
        raise SystemExit('Run as root on the target ARM64 Pi')
    mode = HERE.stat()
    if mode.st_uid != 0 or stat.S_IMODE(mode.st_mode) & 0o077:
        raise SystemExit('The verified bundle must be in a private root-owned directory')
    addresses = json.loads(run(['ip', '-j', 'addr']))
    if not any(a.get('local') == '10.0.0.33' for interface in addresses for a in interface.get('addr_info', [])):
        raise SystemExit('Refusing a different host')
    backup = args.backup.resolve()
    if not backup.is_relative_to('/var/backups') or backup.stat().st_uid != 0:
        raise SystemExit('Use the verified root-owned rollback backup')
    progress = json.loads((backup / 'upgrade-status.json').read_text())
    if progress['stage'] != 'complete' or run(['dpkg', '--audit']):
        raise SystemExit('Finish and verify package upgrades before deployment')
    manifest = json.loads((HERE / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if Path(name).name != name or digest(HERE / name) != expected:
            raise SystemExit('Bundle checksum mismatch')
    result = {'image': install_image(backup, manifest)}
    private_write(backup / 'deployment-status.json', json.dumps(result, indent=2) + '\n')
    result['media'] = harden_media(backup)
    private_write(backup / 'deployment-status.json', json.dumps(result, indent=2) + '\n')
    result['firewall'] = install_guard()
    result['updates'] = configure_updates()
    result['monitor_running'] = inspect('amazon-price-monitor')['State']['Running']
    private_write(backup / 'deployment-status.json', json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
