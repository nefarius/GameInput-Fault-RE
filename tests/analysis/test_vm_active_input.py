"""Guard the bounded VM input phase without querying a real controller."""
import hashlib
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime/Measure-VMActiveInput.ps1'
PS = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'SysWOW64/WindowsPowerShell/v1.0/powershell.exe'

@unittest.skipUnless(PS.exists(), 'x86 Windows PowerShell required')
class VMActiveInputTests(unittest.TestCase):
    def run_script(self, *args):
        return subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass',
                               '-File', str(SCRIPT), *args], capture_output=True,
                              text=True, timeout=20,
                              env=dict(os.environ, PSMODULEPATH=str(PS.parent / 'Modules')))

    def test_compile_only_pins_native_source_and_does_not_query_controller(self):
        digest = hashlib.sha256((SCRIPT.parent / 'Measure-XInputState.ps1').read_bytes()).hexdigest()
        self.assertIn(digest, SCRIPT.read_text())
        result = self.run_script('-CompileOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no XInput DLL loaded or controller queried', result.stdout)

    def test_excessive_duration_refused_before_capture(self):
        result = self.run_script('-Seconds', '31', '-CompileOnly')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ParameterArgumentValidationError', result.stderr)
        self.assertNotIn('Compiled;', result.stdout)

if __name__ == '__main__':
    unittest.main()
