"""Verify that benchmark setup/refusal paths never enter a device experiment."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell.exe")
SCRIPT = ROOT / "tools/runtime/Measure-XInputHandleClose.ps1"


@unittest.skipUnless(POWERSHELL, "Windows PowerShell 5.1 required")
class HandleCloseGuards(unittest.TestCase):
    def invoke(self, *args, env=None):
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(SCRIPT), *args],
            capture_output=True, text=True, timeout=30, env=env,
        )

    def test_compile_only_needs_no_windows_device_or_output(self):
        result = self.invoke("-CompileOnly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no interfaces enumerated or device handles opened", result.stdout)

    def test_unknown_driver_refused_without_output_or_device_open(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "result.json"
            environment = dict(os.environ, CLOSE_TEST_SCRIPT=str(SCRIPT), CLOSE_TEST_OUTPUT=str(output))
            command = '''
function Get-FileHash { [pscustomobject]@{ Hash=('0' * 64) } }
& $env:CLOSE_TEST_SCRIPT -DevicePath not-a-device -Condition synthetic-refusal -OutputPath $env:CLOSE_TEST_OUTPUT
'''
            result = subprocess.run(
                [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
                 base64.b64encode(command.encode("utf-16le")).decode("ascii")],
                capture_output=True, text=True, timeout=30, env=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            # EncodedCommand can wrap stderr in CLIXML; the message remains literal.
            self.assertIn("restricted to the inspected Windows 10", result.stderr)
            self.assertFalse(output.exists())

    def test_unbounded_sample_request_refused_by_parameter_validation(self):
        result = self.invoke(
            "-DevicePath", "not-a-device", "-Condition", "synthetic-refusal",
            "-OutputPath", "unused.json", "-Samples", "501",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Samples", result.stderr)
        self.assertIn("500", result.stderr)
