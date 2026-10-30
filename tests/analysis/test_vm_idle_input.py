"""Guard the idle recorder and its physical-action phase boundaries."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime/Measure-VMIdleInput.ps1'
POWERSHELL = shutil.which('powershell.exe')


@unittest.skipUnless(POWERSHELL, 'Windows PowerShell required')
class IdleInputTests(unittest.TestCase):
    def run_ps(self, code, **environment):
        return subprocess.run(
            [POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-EncodedCommand', base64.b64encode(code.encode('utf-16le')).decode()],
            env=dict(os.environ, IDLE_SCRIPT=str(SCRIPT), **environment),
            capture_output=True, text=True, timeout=30)

    def test_compile_only_does_not_load_or_query(self):
        result = self.run_ps('& $env:IDLE_SCRIPT -CompileOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no DLL loaded or controller queried', result.stdout)

    def test_phase_boundaries_and_terminal_time(self):
        result = self.run_ps('''
. $env:IDLE_SCRIPT -CompileOnly | Out-Null
@(0,19.999,20,24.999,25,34.999,35,100) |
    ForEach-Object { Get-IdleInputPhase $_ } | ConvertTo-Json -Compress
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            'idle-before', 'idle-before', 'left-stick', 'left-stick',
            'idle-after', 'idle-after', 'ended', 'ended'])

    def test_wrong_architecture_refused_before_capture(self):
        if 'SysWOW64' in POWERSHELL:
            self.skipTest('requires native x64 PowerShell')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'must-not-exist'
            result = self.run_ps('& $env:IDLE_SCRIPT -ResultsRoot $env:IDLE_OUTPUT',
                                 IDLE_OUTPUT=str(output))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Use x86 Windows PowerShell', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
