"""Exercise x86 benchmark refusal and synthetic state handling without devices."""
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/runtime/Measure-XInputState.ps1"
PS64 = shutil.which("powershell.exe")
PS32 = Path(os.environ.get("WINDIR", "C:/Windows")) / "SysWOW64/WindowsPowerShell/v1.0/powershell.exe"

FAKE = r'''
namespace GameInputStateResearch {
    public static class SyntheticStateTests {
        static uint code;
        static uint Fake(uint slot,out State state) {
            state=new State(); state.Packet=12345; return code;
        }
        static void Check(bool ok) { if(!ok) throw new System.Exception("Synthetic state assertion failed"); }
        static void Bind(uint result) {
            code=result;
            var field=typeof(Benchmark).GetField("getState",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);
            var method=typeof(SyntheticStateTests).GetMethod("Fake",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);
            field.SetValue(null,System.Delegate.CreateDelegate(field.FieldType,method));
        }
        public static void Run() {
            Check(System.Runtime.InteropServices.Marshal.SizeOf(typeof(State))==16);
            Bind(0);
            var success=Benchmark.Run(2,1);
            Check(success.Warmup.Length==4 && success.Samples.Length==8);
            foreach(var row in success.Samples) Check(row.Result==0 && row.Packet==12345 && row.Ticks>=0);
            Bind(1167);
            var disconnected=Benchmark.Run(2,1);
            Check(disconnected.Warmup.Length==4 && disconnected.Samples.Length==8);
            foreach(var row in disconnected.Samples) Check(row.Result==1167 && row.Packet==null);
            Bind(5);
            var failed=Benchmark.Run(2,1);
            Check(failed.Warmup.Length==1 && failed.Samples.Length==0 && failed.Warmup[0].Packet==null);
            bool refused=false;
            try { Benchmark.Run(501,1); } catch(System.ArgumentOutOfRangeException) { refused=true; }
            Check(refused);
        }
    }
}
'''


@unittest.skipUnless(PS64, "Windows PowerShell required")
class XInputStateTests(unittest.TestCase):
    def command(self, executable, command, env=None):
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        return subprocess.run(
            [str(executable), "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def test_compile_only_x64_and_x86_never_loads_xinput(self):
        for executable in (PS64, PS32):
            if not Path(executable).is_file():
                continue
            with self.subTest(executable=str(executable)):
                env = dict(os.environ, STATE_TEST_SCRIPT=str(SCRIPT))
                result = self.command(executable, "& $env:STATE_TEST_SCRIPT -CompileOnly", env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no DLL loaded and no controller state queried", result.stdout)

    def test_success_disconnected_and_unexpected_error_snapshots(self):
        source = re.search(r"Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@", SCRIPT.read_text(), re.S).group(1)
        env = dict(os.environ, STATE_TEST_CSHARP=base64.b64encode((source+FAKE).encode()).decode())
        result = self.command(PS64, '''
$ErrorActionPreference='Stop'
$source=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:STATE_TEST_CSHARP))
Add-Type -TypeDefinition $source
[GameInputStateResearch.SyntheticStateTests]::Run()
Write-Output 'Synthetic state handling passed; no native API calls.'
''', env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Synthetic state handling passed", result.stdout)

    @unittest.skipUnless(PS32.is_file(), "x86 PowerShell required")
    def test_unrecognized_hash_refused_before_dll_load(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            env = dict(os.environ, STATE_TEST_SCRIPT=str(SCRIPT), STATE_TEST_OUTPUT=str(output))
            result = self.command(PS32, '''
function Get-FileHash { [pscustomobject]@{Hash=('0'*64)} }
& $env:STATE_TEST_SCRIPT -Condition synthetic-refusal -OutputPath $env:STATE_TEST_OUTPUT
''', env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires the exact research", result.stderr)
            self.assertFalse(output.exists())

    def test_x64_measurement_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            env = dict(os.environ, STATE_TEST_SCRIPT=str(SCRIPT), STATE_TEST_OUTPUT=str(output))
            result = self.command(PS64, '''
& $env:STATE_TEST_SCRIPT -Condition synthetic-refusal -OutputPath $env:STATE_TEST_OUTPUT
''', env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x86 Windows PowerShell", result.stderr)
            self.assertFalse(output.exists())

    def test_file_identity_rejects_a_separate_identical_copy_and_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            a,b=Path(directory)/"a.bin",Path(directory)/"b.bin"
            a.write_bytes(b"identical synthetic bytes")
            b.write_bytes(a.read_bytes())
            for executable in (PS64,PS32):
                if not Path(executable).is_file():
                    continue
                with self.subTest(executable=str(executable)):
                    env=dict(os.environ,STATE_TEST_SCRIPT=str(SCRIPT),STATE_TEST_A=str(a),STATE_TEST_B=str(b))
                    result=self.command(executable, '''
$ErrorActionPreference='Stop'
& $env:STATE_TEST_SCRIPT -CompileOnly
if (-not [GameInputStateResearch.Benchmark]::SameFile($env:STATE_TEST_A,$env:STATE_TEST_A)) { throw 'Same file rejected' }
if ([GameInputStateResearch.Benchmark]::SameFile($env:STATE_TEST_A,$env:STATE_TEST_B)) { throw 'Different file accepted' }
$refused=$false
try { [void][GameInputStateResearch.Benchmark]::SameFile($env:STATE_TEST_A,($env:STATE_TEST_A+'.missing')) } catch { $refused=$true }
if (-not $refused) { throw 'Missing file was not refused' }
Write-Output 'File identity checks passed'
''',env)
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertIn("File identity checks passed",result.stdout)

    @unittest.skipUnless(PS32.is_file(), "x86 PowerShell required")
    def test_wow64_alias_accepted_but_native_system_dll_rejected(self):
        windows=Path(os.environ.get("WINDIR","C:/Windows"))
        if not all((windows/sub/"XInput1_4.dll").is_file() for sub in ("System32","SysWOW64")):
            self.skipTest("Both architecture-specific system DLLs required for alias test")
        result=self.command(PS32, '''
$ErrorActionPreference='Stop'
& $env:STATE_TEST_SCRIPT -CompileOnly
$x86=Join-Path $env:WINDIR 'SysWOW64\XInput1_4.dll'
$alias=Join-Path $env:WINDIR 'System32\XInput1_4.dll'
$native=Join-Path $env:WINDIR 'Sysnative\XInput1_4.dll'
if (-not [GameInputStateResearch.Benchmark]::SameFile($x86,$alias)) { throw 'WOW64 alias refused' }
if ([GameInputStateResearch.Benchmark]::SameFile($x86,$native)) { throw 'Native x64 DLL accepted as x86 file' }
Write-Output 'WOW64 identity checks passed; no DLL loaded'
''',dict(os.environ,STATE_TEST_SCRIPT=str(SCRIPT)))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("WOW64 identity checks passed",result.stdout)
