"""Run the shipped shell wrapper with controlled Xcode tools, without launching apps."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = r'''
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
if name == 'xcodegen':
    sys.exit(0)
if name == 'xcodebuild':
    print(os.environ['BUILD_LOG'])
    if os.environ['CREATE_RESULT'] == '1':
        Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir()
    sys.exit(int(os.environ['BUILD_EXIT']))
if sys.argv[2] == 'export':
    print('attachment export diagnostic', file=sys.stderr)
    sys.exit(int(os.environ['EXPORT_EXIT']))
sys.stdout.write(os.environ['SUMMARY'])
print('summary export diagnostic', file=sys.stderr)
sys.exit(int(os.environ['SUMMARY_EXIT']))
'''


class UIRunnerTests(unittest.TestCase):
    def run_wrapper(self, *, summary='', build_exit=65, create_result=True,
                    export_exit=0, summary_exit=0, log='error: original build failure'):
        with tempfile.TemporaryDirectory(prefix='uxreview-wrapper-') as directory:
            root = Path(directory)
            tools = root / 'bin'
            tools.mkdir()
            for name in ('xcodegen', 'xcodebuild', 'xcrun'):
                tool = tools / name
                tool.write_text(f'#!{sys.executable}\n' + TOOL)
                tool.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                               TMPDIR=str(root), HOTSHEET_CLI='/usr/bin/true',
                               UXREVIEW_UI_REAL_CAPTURE='0', BUILD_EXIT=str(build_exit),
                               CREATE_RESULT=str(int(create_result)), EXPORT_EXIT=str(export_exit),
                               SUMMARY_EXIT=str(summary_exit), SUMMARY=summary, BUILD_LOG=log)
            result = subprocess.run(['bash', str(ROOT / 'scripts/ui-e2e.sh')],
                                    cwd=ROOT, env=environment, text=True, capture_output=True, timeout=20)
            self.assertNotIn('Traceback', result.stderr)
            self.assertIn('UI test artifacts:', result.stdout)
            return result

    def test_missing_summary_preserves_original_failure(self):
        result = self.run_wrapper(create_result=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn('error: original build failure', result.stderr)
        self.assertIn('summary unavailable', result.stderr)

    def test_invalid_summaries_preserve_failure_and_diagnostics(self):
        for summary in ('', '   ', '{truncated', 'null', '[]', '{"testFailures": null}'):
            with self.subTest(summary=summary):
                result = self.run_wrapper(summary=summary, summary_exit=1)
                self.assertEqual(result.returncode, 65)
                self.assertIn('error: original build failure', result.stderr)
                self.assertIn('summary unavailable', result.stderr)

    def test_valid_summary_keeps_detailed_failures(self):
        summary = json.dumps({'testFailures': [{'testName': 'Capture', 'failureText': 'permission denied'}]})
        result = self.run_wrapper(summary=summary)
        self.assertEqual(result.returncode, 65)
        self.assertIn('Capture: permission denied', result.stderr)
        self.assertIn('error: original build failure', result.stderr)

    def test_unstructured_log_falls_back_to_bounded_tail(self):
        for summary in ('', '{}', '{"testFailures": [null, {}, 1]}'):
            with self.subTest(summary=summary):
                log = '\n'.join(f'build detail {number}' for number in range(30))
                result = self.run_wrapper(summary=summary, log=log)
                self.assertEqual(result.returncode, 65)
                self.assertIn('build detail 29', result.stderr)
                self.assertNotIn('build detail 0\n', result.stderr)

    def test_export_failures_do_not_replace_build_exit_status(self):
        result = self.run_wrapper(export_exit=1, summary_exit=1)
        self.assertEqual(result.returncode, 65)
        self.assertIn('error: original build failure', result.stderr)

    def test_export_failures_fail_an_otherwise_successful_build(self):
        for export_exit, summary_exit in ((1, 0), (0, 1)):
            with self.subTest(export_exit=export_exit, summary_exit=summary_exit):
                result = self.run_wrapper(build_exit=0, export_exit=export_exit,
                                          summary_exit=summary_exit, log='build succeeded')
                self.assertEqual(result.returncode, 1)
                self.assertIn('export diagnostic', result.stderr)

    def test_success_summary_is_unchanged(self):
        summary = json.dumps({'passedTests': 4, 'failedTests': 0, 'skippedTests': 1})
        result = self.run_wrapper(build_exit=0, summary=summary, log='build succeeded')
        self.assertEqual(result.returncode, 0)
        self.assertIn('UI tests: 4 passed, 0 failed, 1 skipped', result.stdout)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
