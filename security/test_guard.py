#!/usr/bin/env python3
"""Packet-test the exact input policy in disposable Docker network namespaces."""
import json
from pathlib import Path
import subprocess
import uuid

HERE = Path(__file__).resolve().parent


def docker(args):
    result = subprocess.run(['docker'] + args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    suffix = uuid.uuid4().hex[:10]
    networks, containers = [], []
    image = 'outline-pi-guard-test:local'
    server, trusted, other = ('pi-guard-' + role + '-' + suffix for role in ('server', 'trusted', 'other'))
    try:
        for name, subnet, ipv6 in (('trusted', '10.0.0.0/24', 'fd42:520:100::/64'),
                                   ('other', '198.18.0.0/24', '2001:db8:520::/64')):
            network = 'pi-guard-' + name + '-' + suffix
            docker(['network', 'create', '--internal', '--ipv6', '--subnet', subnet, '--subnet', ipv6, network])
            networks.append(network)
        docker(['create', '--name', server, '--network', networks[0], '--ip', '10.0.0.33',
                '--ip6', 'fd42:520:100::33', '--cap-add', 'NET_ADMIN', image, 'python3', '-u', '-c', '''
import socket,socketserver,threading,time
class TCP(socketserver.ThreadingTCPServer):
 address_family=socket.AF_INET6
 allow_reuse_address=True
class UDP(socketserver.ThreadingUDPServer):address_family=socket.AF_INET6
class T(socketserver.BaseRequestHandler):
 def handle(self):self.request.sendall(b'OK')
class U(socketserver.BaseRequestHandler):
 def handle(self):self.request[1].sendto(self.request[0],self.client_address)
for cls,handler,ports in ((TCP,T,(22,80,18501,9090)),(UDP,U,(80,8000))):
 for port in ports:
  srv=cls(('::',port),handler)
  threading.Thread(target=srv.serve_forever,daemon=True).start()
print('ready',flush=True)
while True:time.sleep(60)
''']); containers.append(server)
        docker(['network', 'connect', '--ip', '198.18.0.3', '--ip6', '2001:db8:520::3', networks[1], server])
        docker(['start', server])
        for name, network, ipv4, ipv6 in ((trusted, networks[0], '10.0.0.42', 'fd42:520:100::42'),
                                           (other, networks[1], '198.18.0.2', '2001:db8:520::2')):
            docker(['run', '-d', '--name', name, '--network', network, '--ip', ipv4, '--ip6', ipv6,
                    '--cap-drop', 'ALL', image, 'sleep', '600']); containers.append(name)
        docker(['exec', server, 'python3', '-c',
                "import socket; s=socket.create_connection(('127.0.0.1',80),5); assert s.recv(2)==b'OK'"])
        for source, destination in ((trusted, '10.0.0.33'), (other, '198.18.0.3')):
            docker(['exec', source, 'python3', '-c',
                    "import socket; s=socket.create_connection(('" + destination + "',18501),5); assert s.recv(2)==b'OK'"])
        docker(['cp', str(HERE / 'pi-guard.nft'), server + ':/etc/pi-guard.nft'])
        docker(['cp', str(HERE / 'apply_guard.py'), server + ':/apply_guard.py'])
        docker(['exec', server, 'chown', '0:0', '/etc/pi-guard.nft'])
        docker(['exec', server, 'chmod', '600', '/etc/pi-guard.nft'])
        docker(['exec', server, 'nft', 'add', 'table', 'inet', 'unrelated'])
        docker(['exec', server, 'nft', 'add', 'chain', 'inet', 'unrelated', 'forward',
                '{ type filter hook forward priority 0; policy accept; }'])
        original = docker(['exec', server, 'nft', 'list', 'table', 'inet', 'unrelated'])
        docker(['exec', server, 'python3', '/apply_guard.py', '--check'])
        for _ in range(2):
            docker(['exec', server, 'python3', '/apply_guard.py'])
        assert docker(['exec', server, 'nft', 'list', 'table', 'inet', 'unrelated']) == original
        report = {'unrelated_forward_table_preserved': True, 'atomic_reapply': True}
        for name, destinations, allowed in ((trusted, ('10.0.0.33', 'fd42:520:100::33'), True),
                                              (other, ('198.18.0.3', '2001:db8:520::3'), False)):
            for destination in destinations:
                output = docker(['exec', name, 'python3', '-c', '''
import json,socket,sys
host=sys.argv[1]; family=socket.AF_INET6 if ':' in host else socket.AF_INET
results={}
for port in (22,80,18501,9090):
 try:
  with socket.create_connection((host,port),.6) as s:results['tcp'+str(port)]=s.recv(2)==b'OK'
 except (TimeoutError,OSError):results['tcp'+str(port)]=False
for port in (80,8000):
 with socket.socket(family,socket.SOCK_DGRAM) as s:
  s.settimeout(.6);s.sendto(b'test',(host,port))
  try:results['udp'+str(port)]=s.recv(4)==b'test'
  except (TimeoutError,OSError):results['udp'+str(port)]=False
print(json.dumps(results))
''', destination])
                results = json.loads(output)
                assert results == {'tcp22': allowed, 'tcp80': True, 'tcp18501': allowed,
                                   'tcp9090': False, 'udp80': True, 'udp8000': allowed}, (destination, results)
                report[destination] = results
        print(json.dumps(report, indent=2))
    finally:
        for name in reversed(containers):
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
        for name in reversed(networks):
            subprocess.run(['docker', 'network', 'rm', name], capture_output=True)


if __name__ == '__main__':
    main()
