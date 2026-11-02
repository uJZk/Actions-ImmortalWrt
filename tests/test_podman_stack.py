#!/usr/bin/env python3
"""Exercise recovery and rollback without touching a live Podman installation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'files/usr/bin/podman-stack'
MOCK = r'''#!/usr/bin/env python3
import hashlib, json, os, sys
p = os.environ['MOCK_STATE']
with open(p) as f: s = json.load(f)
a = sys.argv[1:]
c = s['containers']
tags = s.setdefault('tags', {})
def ident(name): return hashlib.sha256(name.encode()).hexdigest()
def resolve(name):
    return next((k for k in c if k == name or ident(k) == name), name)
def save():
    with open(p, 'w') as f: json.dump(s, f)
def fail(message):
    print(message, file=sys.stderr); sys.exit(1)
if a[:2] == ['container', 'exists']:
    sys.exit(0 if a[2] in c else 1)
if a[:2] == ['image', 'inspect']:
    ref = a[-1]
    if ref == 'example:latest': print(s.get('next_image', 'new'))
    elif 'RepoTags' in a[3]: print('\n'.join(k for k,v in tags.items() if v == ref))
    else: print(tags.get(ref, ref))
    sys.exit(0)
if a[0] == 'tag':
    tags[a[2]] = a[1]; save(); sys.exit(0)
if a[0] == 'untag':
    if tags.get(a[2]) != a[1]: fail('tag mismatch')
    del tags[a[2]]; save(); sys.exit(0)
if a[:2] == ['image', 'rm']:
    if any(x['image'] == a[2] for x in c.values()): fail('image in use')
    s.setdefault('removed_images', []).append(a[2]); save(); sys.exit(0)
if a[0] == 'pull': sys.exit(0)
if a[0] == 'inspect':
    fmt, name = a[2], resolve(a[3])
    if name not in c: fail('missing container')
    x = c[name]
    if '.Id' in fmt: print(ident(name))
    elif 'StoppedByUser' in fmt: print('unknown' if s.get('unknown_stopped') else ('true' if x.get('stopped_by_user') else 'false'))
    elif 'RestartPolicy' in fmt: print(x.get('policy', 'no'))
    elif 'AutoRemove' in fmt: print('false')
    elif '.Image' in fmt: print(x['image'])
    elif '.State.Running' in fmt: print('true' if x['running'] else 'false')
    elif '.State.Status' in fmt: print(x.get('status', 'running' if x['running'] else 'exited'))
    elif '.Config.Healthcheck' in fmt: print('yes' if x.get('health') else '')
    elif '.State.Health.Status' in fmt: print('unhealthy')
    sys.exit(0)
if a[0] == 'ps':
    print(' '.join(k for k,v in c.items() if '-a' in a or v['running'])); sys.exit(0)
if a[:2] == ['healthcheck', 'run']: sys.exit(1)
if a[0] == 'create':
    if s.get('fail_create'): fail('create diagnostic')
    c[a[1]] = {'image':s.get('next_image', 'new'), 'running':False}; save(); sys.exit(0)
if a[0] == 'stop':
    if '--service' in a and s.get('fail_service_stop'): fail('unsupported service stop')
    name = resolve(a[-1]); c[name]['running'] = False
    if '--service' not in a: c[name]['stopped_by_user'] = True
elif a[0] == 'rename': c[a[2]] = c.pop(a[1])
elif a[0] == 'start':
    name = resolve(a[1])
    if s.get('fail_start') or (s.get('fail_new_start') and c[name]['image'] == 'new'): fail('start diagnostic')
    c[name]['running'] = True
    if 'stopped_by_user' in c[name]: c[name]['stopped_by_user'] = False
elif a[0] == 'restart':
    if s.get('fail_restart'):
        c[a[1]]['running'] = False; save(); fail('restart diagnostic')
    c[a[1]]['running'] = True
elif a[0] == 'rm': c.pop(a[-1], None)
else: fail('unexpected command: ' + repr(a))
save()
'''

class PodmanStack(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.defs = self.root / 'defs'
        self.defs.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'podman').write_text(MOCK)
        (self.bin / 'podman').chmod(0o755)
        (self.bin / 'logger').write_text('#!/bin/sh\necho "$*" >> "$MOCK_LOG"\n')
        (self.bin / 'logger').chmod(0o755)
        script = SCRIPT.read_text().replace('DEFS_DIR=/etc/podman-stack.d', f'DEFS_DIR={self.defs}').replace('LOCK_DIR=/var/run/podman-stack.lock', f'LOCK_DIR={self.root}/lock').replace('RETRY_DIR=/var/run/podman-stack-retry', f'RETRY_DIR={self.root}/retry')
        self.script = self.root / 'podman-stack'
        self.script.write_text(script)
        self.script.chmod(0o755)
        self.state = self.root / 'state.json'
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'], 'MOCK_STATE': str(self.state), 'MOCK_LOG': str(self.root / 'log')}
        (self.defs / 'app.conf').write_text('NAME=app\nIMAGE=example:latest\ncreate() { podman create "$NAME" "$IMAGE"; }\n')

    def write_state(self, **extra):
        self.state.write_text(json.dumps({'containers': {'app': {'image': 'old', 'running': True}}, **extra}))

    def run_stack(self, *args, ok=True):
        result = subprocess.run([str(self.script), *args], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return json.loads(self.state.read_text())['containers']

    def test_update_success_preserves_state(self):
        self.write_state()
        self.assertEqual(self.run_stack('update'), {'app': {'image':'new', 'running':True}})

    def test_failed_create_and_start_restore_original(self):
        for flag in ('fail_create', 'fail_new_start'):
            with self.subTest(flag=flag):
                self.write_state(**{flag: True})
                restored = self.run_stack('update', ok=False)['app']
                self.assertEqual((restored['image'], restored['running']), ('old', True))
        self.assertIn('start diagnostic', (self.root / 'log').read_text())

    def test_stopped_container_remains_stopped_after_update(self):
        self.write_state()
        s = json.loads(self.state.read_text()); s['containers']['app']['running'] = False; self.state.write_text(json.dumps(s))
        self.assertFalse(self.run_stack('update')['app']['running'])

    def test_failed_health_restart_retries_without_definition(self):
        self.write_state(fail_start=True)
        (self.defs / 'app.conf').unlink()
        state = json.loads(self.state.read_text()); state['containers']['app']['health'] = True; self.state.write_text(json.dumps(state))
        self.assertFalse(self.run_stack('watchdog', ok=False)['app']['running'])
        state = json.loads(self.state.read_text()); state['fail_start'] = False; state['containers']['app']['health'] = False; self.state.write_text(json.dumps(state))
        self.assertTrue(self.run_stack('watchdog')['app']['running'])
        self.assertIn('start diagnostic', (self.root / 'log').read_text())

    def test_explicit_stop_overrides_failed_restart(self):
        self.write_state(fail_start=True)
        state = json.loads(self.state.read_text()); state['containers']['app']['health'] = True; self.state.write_text(json.dumps(state))
        self.run_stack('watchdog', ok=False)
        state = json.loads(self.state.read_text()); state['fail_start'] = False; state['containers']['app']['stopped_by_user'] = True; self.state.write_text(json.dumps(state))
        self.assertFalse(self.run_stack('watchdog')['app']['running'])

    def test_recovery_respects_policy_and_explicit_stop(self):
        for policy, stopped, expected in [('always', False, True), ('unless-stopped', False, True), ('always', True, False), ('no', False, False), ('on-failure', False, False)]:
            with self.subTest(policy=policy, stopped=stopped):
                self.write_state()
                state = json.loads(self.state.read_text()); state['containers']['app'].update(running=False, stopped_by_user=stopped, policy=policy); self.state.write_text(json.dumps(state))
                self.assertEqual(self.run_stack('watchdog')['app']['running'], expected)

    def test_unknown_manual_stop_state_fails_closed(self):
        self.write_state(unknown_stopped=True)
        state = json.loads(self.state.read_text()); state['containers']['app'].update(running=False, policy='always'); self.state.write_text(json.dumps(state))
        self.assertFalse(self.run_stack('watchdog', ok=False)['app']['running'])

    def test_created_container_is_not_started(self):
        self.write_state()
        state = json.loads(self.state.read_text()); state['containers']['app'].update(running=False, status='created', policy='always'); self.state.write_text(json.dumps(state))
        self.assertFalse(self.run_stack('watchdog')['app']['running'])

    def test_unsupported_service_stop_does_not_stop_container(self):
        self.write_state(fail_service_stop=True)
        state = json.loads(self.state.read_text()); state['containers']['app']['health'] = True; self.state.write_text(json.dumps(state))
        self.assertTrue(self.run_stack('watchdog', ok=False)['app']['running'])
        self.assertIn('unsupported service stop', (self.root / 'log').read_text())

    def test_retains_previous_and_only_removes_older_managed_image(self):
        self.write_state()
        self.run_stack('update')
        state = json.loads(self.state.read_text())
        self.assertIn('old', state['tags'].values())
        state['next_image'] = 'newer'
        self.state.write_text(json.dumps(state))
        self.run_stack('update')
        state = json.loads(self.state.read_text())
        self.assertIn('new', state['tags'].values())
        self.assertNotIn('old', state['tags'].values())
        self.assertEqual(state['removed_images'], ['old'])

    def test_older_tagged_or_used_image_is_preserved(self):
        for used in (False, True):
            with self.subTest(used=used):
                # Fresh state and previous-image metadata for each scenario.
                previous = self.defs / '.state' / 'app.previous-image'
                if previous.exists(): previous.unlink()
                self.write_state()
                self.run_stack('update')
                state = json.loads(self.state.read_text())
                state['next_image'] = 'newer'
                if used:
                    state['containers']['other'] = {'image':'old', 'running':True}
                else:
                    state['tags']['localhost/other:keep'] = 'old'
                self.state.write_text(json.dumps(state))
                self.run_stack('update')
                state = json.loads(self.state.read_text())
                self.assertNotIn('old', state.get('removed_images', []))

    def test_existing_backup_blocks_update(self):
        self.write_state()
        s = json.loads(self.state.read_text()); s['containers']['app-podman-stack-backup'] = {'image':'old', 'running':False}; self.state.write_text(json.dumps(s))
        self.assertEqual(self.run_stack('update', ok=False)['app']['image'], 'old')

if __name__ == '__main__':
    unittest.main()
