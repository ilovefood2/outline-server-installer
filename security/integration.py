#!/usr/bin/env python3
"""Exercise the full image on an isolated Docker network with throwaway state."""
import argparse
import json
from pathlib import Path
import secrets
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--image', default='localhost/outline/shadowbox:security-1')
    args = parser.parse_args()
    work = args.work_dir.resolve()
    fixture = work / 'fixture'
    fixture.mkdir(mode=0o700, exist_ok=True)
    state = fixture / 'state'
    state.mkdir(mode=0o700, exist_ok=True)
    prefix = 'security-fixture-' + secrets.token_urlsafe(16)
    cert, key = state / 'certificate.pem', state / 'private-key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                    '-keyout', str(key), '-out', str(cert), '-subj', '/CN=audit.invalid',
                    '-addext', 'subjectAltName=DNS:audit.invalid,IP:10.23.0.2,IP:127.0.0.1'],
                   check=True, capture_output=True)
    key.chmod(0o600)
    (state / 'shadowbox_config.json').write_text(json.dumps({'nextId': 1, 'accessKeys': [{
        'id': '0', 'name': 'retained-fixture', 'password': secrets.token_urlsafe(16),
        'encryptionMethod': 'chacha20-ietf-poly1305', 'port': 80}]}))
    (state / 'shadowbox_server_config.json').write_text(json.dumps({
        'serverId': '00000000-0000-4000-8000-000000000000', 'name': 'security fixture',
        'createdTimestampMs': 1, 'metricsEnabled': False, 'portForNewAccessKeys': 80, 'hostname': '10.23.0.2'}))
    echo = fixture / 'echo.py'
    echo.write_text('''import socketserver,threading
class TCP(socketserver.BaseRequestHandler):
 def handle(self):
  while True:
   data=self.request.recv(8192)
   if not data:return
   self.request.sendall(data)
class UDP(socketserver.BaseRequestHandler):
 def handle(self):self.request[1].sendto(self.request[0],self.client_address)
tcp=socketserver.ThreadingTCPServer(('0.0.0.0',8080),TCP)
udp=socketserver.ThreadingUDPServer(('0.0.0.0',8080),UDP)
threading.Thread(target=udp.serve_forever,daemon=True).start()
tcp.serve_forever()
''')
    suffix = uuid.uuid4().hex[:10]
    network, volume = 'rf-pi-net-' + suffix, 'rf-pi-state-' + suffix
    initializer, server, client = ('rf-pi-' + role + '-' + suffix for role in ('init', 'server', 'client'))
    containers, networks, volumes = [], [], []
    logs = []

    def docker(args, timeout=30):
        result = subprocess.run(['docker'] + args, capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    try:
        docker(['network', 'create', '--internal', '--subnet', '10.23.0.0/24', network]); networks.append(network)
        docker(['volume', 'create', volume]); volumes.append(volume)
        docker(['create', '--name', initializer, '--network', 'none', '--entrypoint', '/bin/sh',
                '--mount', 'type=volume,source=' + volume + ',target=/state', args.image,
                '-c', 'cp -a /fixture/. /state/ && chown -R 31999:31999 /state']); containers.append(initializer)
        docker(['cp', str(state) + '/.', initializer + ':/fixture'])
        docker(['start', '-a', initializer])
        command = ['run', '-d', '--name', server, '--network', network, '--ip', '10.23.0.2',
                   '--sysctl', 'net.ipv4.ip_unprivileged_port_start=1024', '--read-only',
                   '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '1g',
                   '--pids-limit', '256', '--ulimit', 'nofile=8192:8192',
                   '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=64m,uid=31999,gid=31999,mode=1777',
                   '--tmpfs', '/var/lib/libmaxminddb:rw,noexec,nosuid,nodev,size=256m,uid=31999,gid=31999,mode=0700',
                   '--mount', 'type=volume,source=' + volume + ',target=/opt/outline/persisted-state']
        for capability in ('NET_BIND_SERVICE', 'SETUID', 'SETGID', 'SETPCAP'):
            command.extend(['--cap-add', capability])
        for value in ('SB_PUBLIC_IP=10.23.0.2', 'SB_API_ADDRESS=0.0.0.0', 'SB_API_PORT=18501',
                      'SB_API_PREFIX=' + prefix,
                      'SB_CERTIFICATE_FILE=/opt/outline/persisted-state/certificate.pem',
                      'SB_PRIVATE_KEY_FILE=/opt/outline/persisted-state/private-key.pem', 'GOMEMLIMIT=256MiB'):
            command.extend(['-e', value])
        docker(command + [args.image]); containers.append(server)
        docker(['create', '--name', client, '--platform', 'linux/amd64', '--network', network,
                '--ip', '10.23.0.3', '--cap-drop', 'ALL', '--memory', '256m', '--pids-limit', '64',
                '--entrypoint', 'python3', 'routerfirmware-test:local', '/echo.py']); containers.append(client)
        docker(['cp', str(echo), client + ':/echo.py'])
        docker(['cp', str(work / 'probe'), client + ':/probe'])
        docker(['cp', str(cert), client + ':/fixture.crt'])
        docker(['start', client])
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            health = docker(['inspect', server, '--format', '{{.State.Health.Status}}'])
            if health == 'healthy':
                break
            if docker(['inspect', server, '--format', '{{.State.Running}}']) != 'true':
                raise RuntimeError('Shadowbox exited: ' + docker(['logs', server]))
            time.sleep(1)
        else:
            raise RuntimeError('Health check did not pass: ' + docker(['logs', server]))
        output = docker(['exec', client, '/probe', 'https://10.23.0.2:18501/' + prefix,
                         '/fixture.crt', '10.23.0.3:8080'], timeout=55)
        report = json.loads(output)
        docker(['exec', '--user', '31999:31999', server, 'node', '-e', '''
const http=require('http');
const q=http.request({host:'127.0.0.1',port:9090,path:'/api/v1/admin/tsdb/snapshot',method:'POST'},r=>{
 let body='';r.on('data',b=>body+=b);r.on('end',()=>{
  if(r.statusCode<400 || JSON.parse(body).error!=='admin APIs disabled')process.exitCode=1;
 });
});q.on('error',()=>{process.exitCode=1});q.end();
'''])
        report['prometheus_admin_disabled'] = True
        report['docker_health'] = True
        report['processes'] = docker(['top', server, '-eo', 'pid,uid,comm'])
        report['image_id'] = docker(['image', 'inspect', args.image, '--format', '{{.Id}}'])
        (work / 'integration.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
    finally:
        for name in containers:
            captured = subprocess.run(['docker', 'logs', name], capture_output=True, text=True)
            logs.append(name + '\n' + captured.stdout + captured.stderr)
        (work / 'integration.log').write_text('\n'.join(logs))
        for name in reversed(containers):
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
        for name in networks:
            subprocess.run(['docker', 'network', 'rm', name], capture_output=True)
        for name in volumes:
            subprocess.run(['docker', 'volume', 'rm', name], capture_output=True)


if __name__ == '__main__':
    main()
