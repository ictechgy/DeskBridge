# SPDX-License-Identifier: GPL-3.0-only
"""Fresh synthetic fixtures only. Never starts Sunshine or opens a desktop/port."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from policy import Failure, address, allowed_download_url, arguments, child_environment, invitation, select_addresses, validate_session, web_credentials, validate_web_credentials
from runtime import OwnedHost, Store, StrictRedirect, TransferControl, cleanup_owned, digest_file, download, publish_new, save_package, trusted_program
import hashlib


class HostChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='deskbridge-linux-synthetic-')
        self.base = Path(self.temp.name).resolve()
        self.store = Store(self.base / 'private')
    def tearDown(self):
        self.store.close(); self.temp.cleanup()
    def rejects(self, operation):
        with self.assertRaises((Failure, OSError, ValueError)): operation()

    def test_scope(self):
        env = {'DISPLAY': ':1', 'XDG_SESSION_TYPE': 'x11'}
        validate_session({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, env)
        for release, arch, uid, change in [({'ID': 'debian', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '26.04'}, 'x86_64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'aarch64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 0, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'XDG_SESSION_TYPE': 'wayland'}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'WAYLAND_DISPLAY': 'wayland-0'}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'DISPLAY': ''})]:
            with self.subTest(change=change, arch=arch): self.rejects(lambda: validate_session(release, arch, uid, dict(env, **change)))

    def test_invitation(self):
        text = invitation('개발 Linux & +', ['192.168.50.20', '100.80.10.20'])
        self.assertIn('v=2', text); self.assertIn('platform=linux', text); self.assertIn('%26', text)
        for values in ([], ['8.8.8.8'], ['192.168.01.20'], ['192.168.1.20'] * 2, ['192.168.1.' + str(i) for i in range(1, 10)]):
            self.rejects(lambda: invitation('Linux', values))
        for name in ('', 'bad\nname', 'bad\u202ename', 'x' * 65): self.rejects(lambda: invitation(name, ['10.0.0.1']))

    def test_metadata(self):
        rows = [{'flags': ['UP'], 'addr_info': [{'family': 'inet', 'local': a} for a in ['10.0.0.1', '100.80.10.20', '169.254.1.1', '8.8.8.8']]},
                {'flags': [], 'addr_info': [{'family': 'inet', 'local': '192.168.1.2'}]}]
        self.assertEqual(select_addresses(json.dumps(rows)), ['10.0.0.1', '100.80.10.20'])
        self.rejects(lambda: select_addresses(' ' * 262145))
        self.rejects(lambda: select_addresses(json.dumps([{}] * 129)))

    def test_address_candidates_exclude_containers_not_real_bridges_or_vpn(self):
        def row(name, value, flags=['UP']):
            return dict(ifname=name, flags=flags, addr_info=[dict(family='inet', local=value)])
        rows = [row('docker0', '172.17.0.1'), row('br-abcdef', '172.18.0.1'), row('virbr0', '192.168.122.1'),
                row('veth123', '10.2.0.1'), row('eno1', '192.168.1.8'), row('tailscale0', '100.80.1.8'),
                row('br0', '10.20.0.8'), row('eno2', '172.20.0.8', ['UP', 'NO-CARRIER'])]
        self.assertEqual(select_addresses(json.dumps(rows)), ['10.20.0.8', '192.168.1.8', '100.80.1.8'])

    def test_mandatory_cli(self):
        args = arguments(self.store.root, 'Linux Desktop')
        for value in ('capture=x11', 'lan_encryption_mode=2', 'wan_encryption_mode=2', 'upnp=disabled',
                      'origin_web_ui_allowed=pc', 'controller=disabled', 'log_path=/dev/null'): self.assertIn(value, args)
        for name in ('x#x', 'x\ny', 'x=y', 'x[y'): self.rejects(lambda: arguments(self.store.root, name))
        self.rejects(lambda: arguments('/tmp/bad\npath', 'Linux'))
        self.store.prepare()
        self.assertEqual(json.loads((self.store.root / 'apps.json').read_text())['apps'], [{'name': 'Desktop', 'cmd': ''}])

    def test_environment(self):
        env = child_environment({'HOME': '/synthetic', 'DISPLAY': ':1', 'LD_PRELOAD': 'bad', 'PYTHONPATH': 'bad',
            'CONFIGURATION_DIRECTORY': '/bad', 'SUNSHINE_MIGRATE_CONFIG': '1', 'XDG_CONFIG_HOME': '/bad', 'PATH': '/bad', 'WAYLAND_DISPLAY': 'bad'}, self.store.root)
        self.assertEqual(env['HOME'], '/synthetic'); self.assertEqual(env['PATH'], '/usr/bin:/bin')
        self.assertEqual(env['XDG_CONFIG_HOME'], str(self.store.root) + '/xdg')
        for key in ('LD_PRELOAD', 'PYTHONPATH', 'CONFIGURATION_DIRECTORY', 'SUNSHINE_MIGRATE_CONFIG', 'WAYLAND_DISPLAY'): self.assertNotIn(key, env)

    def test_storage_no_adoption_or_overlap(self):
        other = self.base / 'unowned'; other.mkdir(mode=0o700)
        self.rejects(lambda: Store(other))
        try: Store(other)
        except Failure as error: self.assertEqual(error.key, 'storage')
        self.assertFalse((other / '.owner').exists())
        self.rejects(lambda: Store(self.store.root))
        self.store.close(); self.store = Store(self.base / 'private')
        self.store.prepare(); self.store.validate()

    def test_storage_link_and_permissions(self):
        secret = self.base / 'new-synthetic-secret'; secret.write_bytes(b'synthetic')
        link = self.store.root / 'linked'; link.symlink_to(secret)
        self.rejects(self.store.validate); link.unlink()
        os.link(secret, link); self.rejects(self.store.validate); link.unlink()
        Store.write_new(link, b'synthetic'); link.chmod(0o644)
        self.rejects(self.store.validate); link.chmod(0o600)
        self.store.validate()
        self.rejects(lambda: Store.write_new(link, b'replace'))
        self.assertEqual(link.read_bytes(), b'synthetic')

    def test_credentials_exist_before_launch_without_plaintext_or_reset(self):
        password, salt = 'Synthetic-password-42!', '0123456789ABCDEF'
        value = json.loads(web_credentials('deskbridge', password, salt))
        self.assertEqual(value['password'], 'F55578F96AAE2127B01A4BB740A88BE284A34515B359E6960C1003F05B189FA9')
        validate_web_credentials(json.dumps(value))
        path = self.store.root / 'web-credentials.json'
        self.rejects(lambda: self.store.prepare_web_credentials('deskbridge', 'short'))
        self.assertFalse(path.exists())
        self.store.prepare_web_credentials('deskbridge', password)
        original = path.read_bytes(); self.assertNotIn(password.encode(), original)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600); self.assertEqual(path.stat().st_nlink, 1)
        self.store.prepare_web_credentials('other', 'Different-password-42!'); self.assertEqual(path.read_bytes(), original)
        path.write_bytes(b'{}')
        self.rejects(lambda: self.store.prepare_web_credentials('deskbridge', password))
        self.assertEqual(path.read_bytes(), b'{}')
        value['username'] = ''; self.rejects(lambda: validate_web_credentials(json.dumps(value)))

    def test_only_upstream_public_certificate_permissions_are_tightened(self):
        certificate = self.store.root / 'credentials/cacert.pem'
        certificate.write_bytes(b'SYNTHETIC PUBLIC CERTIFICATE'); certificate.chmod(0o644)
        self.store.validate(); self.assertEqual(certificate.stat().st_mode & 0o777, 0o600)
        certificate.chmod(0o666); self.rejects(self.store.validate)
        self.assertEqual(certificate.stat().st_mode & 0o777, 0o666)
        certificate.unlink(); certificate.symlink_to(self.base / 'not-read')
        self.rejects(self.store.validate)

    def test_redirects(self):
        self.assertTrue(allowed_download_url('https://release-assets.githubusercontent.com/a'))
        for url in ('http://github.com/a', 'https://github.com.evil/a', 'https://user@github.com/a', 'https://github.com:80/a', 'file:///etc/passwd', 'https://github.com/a#fragment'):
            self.assertFalse(allowed_download_url(url))
            self.rejects(lambda: StrictRedirect().redirect_request(None, None, 302, '', {}, url))

    def fixture_download(self, data, declared=None, url='https://github.com/fixture'):
        pin = dict(url='https://github.com/fixture', version='synthetic', bytes=8, sha256=hashlib.sha256(b'fixture!').hexdigest())
        class Response(io.BytesIO):
            status = 200
            def __init__(self):
                super().__init__(data); self.url = url; self.headers = {} if declared is None else {'Content-Length': str(declared)}
        class Opener:
            def open(self, *_args, **_kwargs): return Response()
        return pin, Opener()

    def test_download_integrity_publish_and_collision(self):
        pin, opener = self.fixture_download(b'fixture!', 8)
        path = download(pin, self.store, threading.Event(), opener=opener)
        self.assertEqual(path.read_bytes(), b'fixture!'); self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(download(pin, self.store, threading.Event(), opener=opener), path)
        path.write_bytes(b'tampered'); self.rejects(lambda: download(pin, self.store, threading.Event(), opener=opener))
        self.assertEqual(path.read_bytes(), b'tampered')
        with self.assertRaises(Failure) as caught: download(pin, self.store, threading.Event(), opener=opener)
        self.assertEqual(caught.exception.key, 'download_collision')
        path.unlink()
        self.assertEqual(download(pin, self.store, threading.Event(), opener=opener).read_bytes(), b'fixture!')

    def test_atomic_publish_and_verified_export_never_replace_or_make_links(self):
        source, target = self.base / 'new-source', self.base / 'new-target'
        source.write_bytes(b'new'); target.write_bytes(b'existing')
        self.rejects(lambda: publish_new(source, target))
        self.assertEqual(source.read_bytes(), b'new'); self.assertEqual(target.read_bytes(), b'existing')
        target.unlink(); publish_new(source, target)
        self.assertFalse(source.exists()); self.assertEqual(target.stat().st_nlink, 1)
        pin, opener = self.fixture_download(b'fixture!', 8)
        package = download(pin, self.store, threading.Event(), opener=opener)
        exported = save_package(pin, package, self.base / 'visible package.deb')
        self.assertEqual(exported.read_bytes(), b'fixture!'); self.assertEqual(exported.stat().st_nlink, 1)
        with self.assertRaises(Failure) as caught: save_package(pin, package, exported)
        self.assertEqual(caught.exception.key, 'collision')
        self.store.validate()
        self.store.close(); self.store = Store(self.base / 'private'); self.store.validate()

    def test_missing_system_program_is_install_error(self):
        with self.assertRaises(Failure) as caught: trusted_program(self.base / 'missing-program')
        self.assertEqual(caught.exception.key, 'install')

    def test_nonreaping_child_retains_ownership_and_failed_cleanup(self):
        events = []; host = OwnedHost()
        class Child:
            pid = 12345
            def wait(self, timeout):
                if timeout > 1: raise AssertionError('unbounded reap')
                raise subprocess.TimeoutExpired('synthetic', timeout)
        host.child = Child()
        with patch.object(host, '_exited', return_value=True), patch('runtime.os.killpg') as kill:
            cleanup_owned(host, None, lambda: events.append('quit'), lambda: events.append('failed'))
            self.assertEqual(kill.call_count, 2)  # TERM then KILL; no post-reap/retry signal.
        self.assertEqual(events, ['failed']); self.assertIsNotNone(host.child)
        host.child = None

    def test_download_failures_cleanup(self):
        for data, declared, url in ((b'short', None, 'https://github.com/a'), (b'fixture!extra', None, 'https://github.com/a'),
                                    (b'bad!!!!!', None, 'https://github.com/a'), (b'fixture!', 7, 'https://github.com/a'),
                                    (b'fixture!', 8, 'http://github.com/a')):
            pin, opener = self.fixture_download(data, declared, url)
            self.rejects(lambda: download(pin, self.store, threading.Event(), opener=opener))
            self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])
        pin, opener = self.fixture_download(b'fixture!', 8)
        cancel = threading.Event(); cancel.set()
        self.rejects(lambda: download(pin, self.store, cancel, opener=opener))
        self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])

    def blocked_transfer(self, cancel, control):
        # An inert socket substitute lets the watchdog interrupt a blocked receive.
        gate = threading.Event()
        class Socket:
            def shutdown(self, how): gate.set()
        class Response(io.BytesIO):
            status, url, headers = 200, 'https://github.com/fixture', {}
            def read1(self, size):
                if not gate.wait(2): raise AssertionError('watchdog failed to interrupt active I/O')
                raise OSError('synthetic receive interrupted')
        class Opener:
            def open(self, *_args, **_kwargs):
                control.attach(Socket()); return Response()
        pin, unused = self.fixture_download(b'fixture!', 8)
        began = time.monotonic()
        with self.assertRaises(Failure) as caught:
            download(pin, self.store, cancel, opener=Opener(), control=control)
        self.assertLess(time.monotonic() - began, 1)
        self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])
        return caught.exception.key

    def test_cancel_interrupts_active_receive(self):
        cancel = threading.Event(); control = TransferControl(cancel)
        timer = threading.Timer(0.05, cancel.set); timer.start()
        try: self.assertEqual(self.blocked_transfer(cancel, control), 'cancel')
        finally: timer.join(); control.close()

    def test_deadline_interrupts_active_receive(self):
        cancel = threading.Event(); control = TransferControl(cancel, seconds=0.05)
        try: self.assertEqual(self.blocked_transfer(cancel, control), 'download')
        finally: control.close()

    def test_shutdown_finalizes_after_lost_ownership(self):
        events = []
        class Host:
            child = None
            def stop(self): events.append('stop'); raise Failure('exit')
        class Storage:
            def close(self): events.append('close')
        cleanup_owned(Host(), Storage(), lambda: events.append('quit'), lambda: events.append('failed'))
        self.assertEqual(events, ['stop', 'close', 'quit'])

    def test_shutdown_keeps_owned_host_visible_on_unexpected_stop_failure(self):
        events = []
        host = OwnedHost()
        class Child:
            pid = 12345  # Never signalled: killpg is an injected inert failure below.
        class Storage:
            def close(self): events.append('close')
        host.child = Child()
        with patch.object(host, '_exited', return_value=False), patch('runtime.os.killpg', side_effect=PermissionError('synthetic stop denied')):
            cleanup_owned(host, Storage(), lambda: events.append('quit'), lambda: events.append('failed'))
        self.assertEqual(events, ['failed'])
        self.assertIsNotNone(host.child)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux WNOWAIT process ownership')
    def test_only_owned_inert_process_is_stopped(self):
        host = OwnedHost()
        foreign = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        host.child = child
        try:
            self.assertTrue(host.alive()); host.stop()
            self.assertIsNone(host.child); self.assertIsNotNone(child.returncode)
            self.assertIsNone(foreign.poll()); host.stop()
        finally:
            foreign.terminate(); foreign.wait()
            if host.child is not None: host.stop()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux WNOWAIT process ownership')
    def test_lost_child_ownership_never_signals_pid(self):
        host = OwnedHost()
        child = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        child.wait(); host.child = child  # Simulate an unexpected external reaper.
        with patch('runtime.os.killpg') as kill:
            self.rejects(host.stop)
            kill.assert_not_called(); self.assertIsNone(host.child)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux owner lifetime pipe')
    def test_creator_worker_return_does_not_end_share_but_owner_death_does(self):
        import select
        marker = self.base / 'fresh-engine-pid'
        owner_code = '''import sys,threading,time
sys.path.insert(0,sys.argv[1])
from runtime import OwnedHost
host=OwnedHost()
engine="import os,time; from pathlib import Path; Path("+repr(sys.argv[2])+").write_text(str(os.getpid())); time.sleep(30)"
thread=threading.Thread(target=lambda:host._spawn([sys.executable,'-c',engine],{'PATH':'/usr/bin:/bin'}))
thread.start();thread.join()
print(host.child.pid,flush=True)
sys.stdin.read()
'''
        owner = subprocess.Popen([sys.executable, '-c', owner_code, str(Path(__file__).resolve().parents[1]), str(marker)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        pidfds = []
        try:
            self.assertTrue(select.select([owner.stdout], [], [], 5)[0])
            supervisor_pid = int(owner.stdout.readline())
            for _ in range(100):
                if marker.exists(): break
                time.sleep(0.02)
            self.assertTrue(marker.exists(), 'short creator worker killed the share')
            engine_pid = int(marker.read_text())
            pidfds = [os.pidfd_open(pid) for pid in (supervisor_pid, engine_pid)]
            self.assertFalse(select.select(pidfds, [], [], 0.1)[0], 'share died while owner alive')
            owner.kill(); owner.wait(timeout=2)
            for fd in pidfds: self.assertTrue(select.select([fd], [], [], 3)[0], 'share survived owner death')
        finally:
            if owner.poll() is None: owner.kill(); owner.wait(timeout=2)
            for fd in pidfds: os.close(fd)
            owner.stdin.close(); owner.stdout.close()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux supervisor group stop')
    def test_supervised_inert_engine_normal_and_stubborn_stop(self):
        for stubborn in (False, True):
            host = OwnedHost(); marker = self.base / ('engine-' + str(stubborn))
            code = 'import signal,time; from pathlib import Path; ' + ('signal.signal(signal.SIGTERM,signal.SIG_IGN); ' if stubborn else '') + 'Path(' + repr(str(marker)) + ').write_text("ready"); time.sleep(30)'
            try:
                host._spawn([sys.executable, '-c', code], {'PATH': '/usr/bin:/bin'})
                for _ in range(100):
                    if marker.exists(): break
                    time.sleep(0.02)
                self.assertTrue(marker.exists()); began = time.monotonic()
                host.stop(); self.assertLess(time.monotonic() - began, 4.5)
                self.assertIsNone(host.child); self.assertIsNone(host.lifetime_writer)
            finally:
                if host.child is not None: host.stop()


    def test_ui_monitor_and_shutdown_retry_with_inert_adapters(self):
        # Execute actual method bodies with no GTK import, Window, screen or event loop.
        import ast
        from types import SimpleNamespace
        source = Path(__file__).resolve().parents[1] / 'ui.py'
        tree = ast.parse(source.read_text())
        window = next(item for item in tree.body if isinstance(item, ast.ClassDef) and item.name == 'Window')
        methods = [item for item in window.body if isinstance(item, ast.FunctionDef) and item.name in ('monitor', 'shutdown_failed', 'controls')]
        class Thread:
            def __init__(self, target, **_): self.target = target
            def start(self): self.target()
        namespace = dict(GLib=SimpleNamespace(idle_add=lambda callback, *args: callback(*args)),
                         threading=SimpleNamespace(Thread=Thread), Failure=Failure)
        exec(compile(ast.Module(body=methods, type_ignores=[]), str(source), 'exec'), namespace)
        for retained in (False, True):
            def alive(): raise Failure('exit') if not retained else OSError('synthetic')
            state = SimpleNamespace(generation=1, host=SimpleNamespace(alive=alive, child=object() if retained else None),
                                    status=SimpleNamespace(set_text=lambda text: None), controls=lambda: None)
            namespace['monitor'](state, 1)
            self.assertEqual(state.running, retained)
        calls = []
        state = SimpleNamespace(generation=2, host=SimpleNamespace(child=object()), status=SimpleNamespace(set_text=lambda text: None),
                                controls=lambda: None, monitor=lambda epoch: calls.append(epoch))
        namespace['shutdown_failed'](state)
        self.assertTrue(state.running); self.assertEqual(calls, [2])
        class Button:
            def set_sensitive(self, value): self.enabled = value
        state = SimpleNamespace(busy=True, running=False, closing=False, package=None, qr_bytes=None, operation_kind='download')
        for name in ('download_button','start_button','refresh_button','install_button','export_button','stop_button','web_button','save_button','name','admin_name','admin_password','cancel_button'):
            setattr(state, name, Button())
        namespace['controls'](state); self.assertTrue(state.cancel_button.enabled)
        state.operation_kind = None
        namespace['controls'](state); self.assertFalse(state.cancel_button.enabled)


if __name__ == '__main__': unittest.main()
