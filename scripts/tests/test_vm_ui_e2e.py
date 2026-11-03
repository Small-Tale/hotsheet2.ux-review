"""VM UI runner (HS2-GR8A2A): transfer helper against a real local server, and the host
wrapper's preflight with a fake prlctl, without a guest or app launch."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]

FAKE_PRLCTL = r'''
import os, sys
args = sys.argv[1:]
if args[:2] == ['list', '-i']:
    print('State: ' + os.environ['VM_STATE'])
    sys.exit(0)
if args[0] == 'exec':
    command = args[2]
    counter = os.environ.get('VM_COUNTER')
    if counter:
        count = int(open(counter).read() or 0) + 1 if os.path.exists(counter) else 1
        open(counter, 'w').write(str(count))
        if count <= int(os.environ.get('VM_CONNECT_FAILS', '0')):
            print(os.environ['VM_FAIL_TEXT'], file=sys.stderr)
            sys.exit(255)
    if 'stat -f %Su /dev/console' in command:
        print('user=' + os.environ['VM_USER'])
        print('uid=' + os.environ['VM_UID'])
        print('locked=' + os.environ['VM_LOCKED'])
        print('xcode=' + os.environ['VM_XCODE'])
        sys.exit(int(os.environ.get('VM_EXEC_EXIT', '0')))
    if 'NSScreen' in command:
        print(os.environ['VM_SCREEN'])
        sys.exit(0)
    sys.exit(97)  # Preflight must stop before sync in these tests.
sys.exit(98)
'''


class TransferHelperTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='uxreview-vm-transfer-')
        root = Path(self.directory.name)
        self.serve, self.receive = root / 'serve', root / 'receive'
        self.serve.mkdir()
        (self.serve / 'src.tgz').write_bytes(b'payload' * 1000)
        (root / 'secret').write_text('outside')
        self.process = subprocess.Popen(
            [sys.executable, '-B', str(ROOT / 'scripts/vm_transfer.py'), '--bind', '127.0.0.1',
             '--serve', str(self.serve), '--receive', str(self.receive), '--idle-timeout', '30'],
            stdout=subprocess.PIPE, text=True)
        self.url = 'http://127.0.0.1:' + self.process.stdout.readline().strip()

    def tearDown(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        self.process.stdout.close()
        self.directory.cleanup()

    def request(self, path, method='GET', data=None):
        request = urllib.request.Request(self.url + path, data=data, method=method)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            error.close()
            return error.code, b''

    def test_serves_only_staged_files(self):
        self.assertEqual(self.request('/src.tgz'), (200, b'payload' * 1000))
        self.assertEqual(self.request('/missing')[0], 404)
        for path in ('/../secret', '/%2e%2e/secret', '/.hidden', '/a/b'):
            with self.subTest(path=path):
                self.assertIn(self.request(path)[0], (400, 404))

    def test_idle_helper_exits_on_its_own(self):
        with tempfile.TemporaryDirectory(prefix='uxreview-vm-idle-') as directory:
            process = subprocess.run(
                [sys.executable, '-B', str(ROOT / 'scripts/vm_transfer.py'), '--bind', '127.0.0.1',
                 '--serve', directory, '--receive', directory, '--idle-timeout', '0.5'],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertTrue(process.stdout.strip().isdigit())

    def test_put_stores_upload_and_replaces_previous(self):
        self.assertEqual(self.request('/run.tgz', 'PUT', b'first')[0], 201)
        self.assertEqual(self.request('/run.tgz', 'PUT', b'second')[0], 201)
        self.assertEqual((self.receive / 'run.tgz').read_bytes(), b'second')
        self.assertFalse((self.receive / 'run.tgz.partial').exists())
        self.assertEqual(self.request('/../escape', 'PUT', b'x')[0], 400)
        self.assertEqual(sorted(p.name for p in self.receive.iterdir()), ['run.tgz'])


class VMWrapperPreflightTests(unittest.TestCase):
    def run_wrapper(self, *, vm='Test VM', state='running', user='testing', uid='501',
                    locked='0', xcode='1', exec_exit='0', connect_fails=0,
                    fail_text='PrlVm_TerminalConnect: PrlJob_Wait: PRL_ERR_IO_STOPPED',
                    screen='1440 812'):
        with tempfile.TemporaryDirectory(prefix='uxreview-vm-wrapper-') as directory:
            tools = Path(directory) / 'bin'
            xcodegen = Path(directory) / 'xcodegen' / 'bin'
            tools.mkdir()
            xcodegen.mkdir(parents=True)
            for tool, body in ((tools / 'prlctl', FAKE_PRLCTL),
                               (xcodegen / 'xcodegen', 'import sys; sys.exit(0)')):
                tool.write_text(f'#!{sys.executable}\n' + body)
                tool.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                               TMPDIR=directory, HOTSHEET_CLI='/usr/bin/true', UXREVIEW_UI_VM=vm,
                               XCODEGEN=str(xcodegen / 'xcodegen'), UXREVIEW_UI_VM_HOST_IP='127.0.0.1',
                               UXREVIEW_UI_VM_RETRY_DELAY='0',
                               VM_STATE=state, VM_USER=user, VM_UID=uid, VM_LOCKED=locked,
                               VM_XCODE=xcode, VM_EXEC_EXIT=exec_exit, VM_SCREEN=screen,
                               VM_COUNTER=str(Path(directory) / 'count'),
                               VM_CONNECT_FAILS=str(connect_fails), VM_FAIL_TEXT=fail_text)
            return subprocess.run(['bash', str(ROOT / 'scripts/vm-ui-e2e.sh')], cwd=ROOT,
                                  env=environment, text=True, capture_output=True, timeout=20)

    def test_requires_vm_name(self):
        result = self.run_wrapper(vm='')
        self.assertEqual(result.returncode, 2)
        self.assertIn('UXREVIEW_UI_VM', result.stderr)

    def test_preflight_refuses_unusable_guests_before_sync(self):
        cases = {
            'not running': dict(state='stopped'),
            'Could not run commands': dict(exec_exit='255'),
            'No user is logged in': dict(user='root', uid='0'),
            'desktop is locked': dict(locked='1'),
            'Xcode is not selected': dict(xcode='0'),
            'visible screen is 1079x579': dict(screen='1079 579'),
            'Could not read the guest screen': dict(screen='error: no display'),
        }
        for message, overrides in cases.items():
            with self.subTest(message=message):
                result = self.run_wrapper(**overrides)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn('Syncing', result.stdout)

    def test_connect_failures_are_retried_but_other_failures_are_not(self):
        result = self.run_wrapper(connect_fails=2)
        self.assertIn('Syncing', result.stdout, result.stderr)
        self.assertIn('Sync to', result.stderr)  # the fake refuses the sync command (exit 97)
        self.assertEqual(result.returncode, 3)
        result = self.run_wrapper(connect_fails=9)
        self.assertEqual(result.returncode, 3)
        self.assertIn('Could not run commands', result.stderr)
        self.assertNotIn('Syncing', result.stdout)

    def test_idempotent_guest_commands_retry_late_parallels_errors(self):
        # HS2-GR8A2A: PrlJob_GetRetCode can arrive after the command ran; the preflight, screen,
        # sync and read-back commands are repeatable, so they retry it.
        result = self.run_wrapper(connect_fails=2, fail_text='PrlJob_GetRetCode: Invalid argument.')
        self.assertIn('Syncing', result.stdout, result.stderr)
        self.assertEqual(result.returncode, 3)
        result = self.run_wrapper(connect_fails=9, fail_text='PrlJob_GetRetCode: Invalid argument.')
        self.assertIn('Could not run commands', result.stderr)
        self.assertNotIn('Syncing', result.stdout)


if __name__ == '__main__':
    unittest.main()
