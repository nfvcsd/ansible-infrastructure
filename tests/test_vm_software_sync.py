"""Offline API regression checks. Run with a Python that has PyYAML and ansible-playbook on PATH."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit
import yaml

REPO = Path(__file__).resolve().parents[1]
platforms = [{'id': 'p1', 'name': 'Ubuntu'}, {'id': 'p2', 'name': 'Windows Server'}, {'id': 'p3', 'name': 'Ubuntu 24.04'}]
versions = []
writes = []
vms = [
    {'id': 'v1', 'name': 'existing', 'platform': {'id': 'p1'}, 'software_version': None},
    {'id': 'v2', 'name': 'missing', 'platform': None, 'software_version': None},
    {'id': 'v3', 'name': 'mismatch', 'platform': {'id': 'p2'}, 'software_version': None},
    {'id': 'v4', 'name': 'unreachable', 'platform': {'id': 'p1'}, 'software_version': None},
    {'id': 'v6', 'name': 'legacy', 'platform': {'id': 'p3'}, 'software_version': None},
    {'id': 'v5', 'name': 'unresolved', 'platform': {'id': 'absent'}, 'software_version': None},
]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        parsed = urlsplit(self.path)
        path, query = parsed.path, parse_qs(parsed.query)
        if path == '/api/virtualization/virtual-machines/':
            result = vms
        elif path.startswith('/api/virtualization/virtual-machines/'):
            return self.reply(next(v for v in vms if v['id'] == path.rstrip('/').split('/')[-1]))
        elif path == '/api/dcim/platforms/':
            result = platforms
        elif path == '/api/dcim/software-versions/':
            result = [v for v in versions if v['platform']['id'] == query['platform'][0] and v['version'] == query['version'][0]]
        elif path == '/api/extras/statuses/':
            result = [{'id': 'active', 'name': 'Active'}]
        else:
            return self.reply({'error': path}, 404)
        self.reply({'next': None, 'results': result})

    def read_body(self):
        return json.loads(self.rfile.read(int(self.headers['Content-Length'])))

    def do_POST(self):
        body = self.read_body()
        writes.append(('POST', self.path, body))
        if self.path == '/api/dcim/platforms/':
            result = {**body, 'id': f'p{len(platforms)+1}'}
            platforms.append(result)
        elif self.path == '/api/dcim/software-versions/':
            result = {**body, 'id': f's{len(versions)+1}', 'platform': {'id': body['platform']}}
            versions.append(result)
        else:
            return self.reply({'error': self.path}, 404)
        self.reply(result, 201)

    def do_PATCH(self):
        body = self.read_body()
        writes.append(('PATCH', self.path, body))
        if self.path.startswith('/api/dcim/software-versions/'):
            version = next(v for v in versions if v['id'] == self.path.rstrip('/').split('/')[-1])
            version.update(body)
            return self.reply(version)
        vm = next(v for v in vms if v['id'] == self.path.rstrip('/').split('/')[-1])
        for key, value in body.items():
            vm[key] = {'id': value} if key in ['platform', 'software_version'] and value is not None else value
        self.reply(vm)

server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as tmp:
        hosts = {v['name']: {'vm_software_detected': {'family': 'Linux', 'distribution': 'Ubuntu', 'version': '24.04', 'alias': 'noble'}} for v in vms}
        hosts['unreachable'] = {}
        hosts['missing']['vm_software_detected'] = {'family': 'Linux', 'distribution': 'Debian', 'version': '24.04', 'alias': 'test-codename'}
        inventory = Path(tmp) / 'inventory.yml'
        inventory.write_text(yaml.safe_dump({'all': {'hosts': {'localhost': {'ansible_connection': 'local'}}, 'children': {'nautobot_vm_guests': {'hosts': hosts}}}}))
        env = {**os.environ, 'NAUTOBOT_URL': f'http://127.0.0.1:{server.server_port}', 'NAUTOBOT_TOKEN': 'mock-only'}
        base = [shutil.which('ansible-playbook') or '/opt/homebrew/bin/ansible-playbook', '-i', str(inventory), str(REPO / 'playbooks/sync-vm-software-versions.yml'), '--limit', 'localhost']
        flags = ['-e', 'nautobot_os_platform_create_enabled=true', '-e', 'nautobot_os_platform_replace_enabled=true']
        sync = ['-e', 'nautobot_software_sync_enabled=true']
        for label, args, expected in [
            ('default audit', [], 0),
            ('platform audit', flags, 0),
            ('check mode', flags + sync + ['--check'], 0),
            ('version-only apply', sync, 2),
            ('create-only apply', ['-e', 'nautobot_os_platform_create_enabled=true'] + sync, 6),
            ('apply', flags + sync, 10),
            ('repeat apply', flags + sync, 10),
        ]:
            run = subprocess.run(base + args, env=env, cwd=tmp, capture_output=True, text=True)
            assert run.returncode == 0, run.stdout + run.stderr
            assert len(writes) == expected, (label, writes)
            assert 'OS_UNAVAILABLE' in run.stdout and 'PLATFORM_UNRESOLVED' in run.stdout
            if label == 'default audit':
                assert 'PLATFORM_OS_MISMATCH' in run.stdout and 'PLATFORM_MISSING' in run.stdout
            if label in ['platform audit', 'check mode']:
                assert 'WOULD_CREATE_AND_ASSIGN_PLATFORM' in run.stdout
            print(f'{label}: passed', flush=True)
        assert len(platforms) == 4 and len(versions) == 2
        assert all(v['software_version'] for v in vms[:3])
        assert {v['alias'] for v in versions} == {'noble', 'test-codename'}
        assert len({v['platform']['id'] for v in versions}) == 2  # Equal numbers on different distributions remain distinct.
        # Repair old aliases, including when the VM already has the version assigned.
        versions[0]['alias'] = 'Ubuntu'
        before = len(writes)
        run = subprocess.run(base + sync, env=env, cwd=tmp, capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
        assert len(writes) == before + 1 and versions[0]['alias'] == 'noble'
        print('existing alias correction: passed', flush=True)
        # Missing codenames must not erase an existing alias.
        for host in hosts.values():
            if 'vm_software_detected' in host:
                host['vm_software_detected']['alias'] = ''
        inventory.write_text(yaml.safe_dump({'all': {'hosts': {'localhost': {'ansible_connection': 'local'}}, 'children': {'nautobot_vm_guests': {'hosts': hosts}}}}))
        before = len(writes)
        run = subprocess.run(base + sync, env=env, cwd=tmp, capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
        assert len(writes) == before and versions[0]['alias'] == 'noble'
        print('unavailable codename preserves alias: passed', flush=True)
finally:
    server.shutdown()
