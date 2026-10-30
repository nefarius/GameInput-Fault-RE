"""Exercise queued reader completion/cancellation using synthetic I/O only."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/runtime/Measure-XInputQueuedState.ps1'
PS = shutil.which('powershell.exe')
FAKE = r'''
namespace GameInputQueuedResearch {
    public sealed class FakeIo : IQueuedIo {
        public string Mode;
        public int Closes, Cancels, Results, Submits;
        bool cancelled;
        System.IntPtr output;
        public System.IntPtr Open(string path,out int error) {error=0;return new System.IntPtr(123);}
        public System.IntPtr NewEvent(out int error) {error=0;return new System.IntPtr(456);}
        public bool Close(System.IntPtr h,out int error) {Closes++;error=(Mode=="close-error" && h==new System.IntPtr(123))?5:0;return error==0;}
        public bool Submit(System.IntPtr h,System.IntPtr input,System.IntPtr target,System.IntPtr ov,out int error) {
            Submits++;output=target;
            byte[] bytes=new byte[4];System.Runtime.InteropServices.Marshal.Copy(input,bytes,0,4);
            if(bytes[0]!=3 || bytes[1]!=1 || bytes[2]!=0 || bytes[3]!=0) throw new System.Exception("Wrong input bytes");
            error=Mode=="error"?5:Mode=="immediate"?0:997;
            return Mode=="immediate";
        }
        public bool Result(System.IntPtr h,System.IntPtr ov,out uint bytes,out int error) {
            Results++;bytes=0;
            if(Mode=="cancel" || Mode=="unresolved" || Mode=="wait-error") {
                error=cancelled && Mode=="cancel"?995:996;return false;
            }
            bytes=Mode=="short"?2u:24u;error=0;
            byte[] payload=new byte[24];for(int i=0;i<24;i++)payload[i]=(byte)(i+1);
            System.Runtime.InteropServices.Marshal.Copy(payload,0,output,24);return true;
        }
        public bool Cancel(System.IntPtr h,System.IntPtr ov,out int error) {
            Cancels++;cancelled=true;error=Mode=="unresolved"?1168:0;return error==0;
        }
        public uint Wait(System.IntPtr h,uint ms) {
            if(Mode=="wait-error") throw new System.Exception("Synthetic wait failure");
            System.Threading.Thread.Sleep(1);return 258;
        }
    }
}
'''


@unittest.skipUnless(PS, 'Windows PowerShell required')
class QueuedStateTests(unittest.TestCase):
    def run_ps(self, code, mode=''):
        return subprocess.run(
            [PS, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
             base64.b64encode(code.encode('utf-16le')).decode()],
            env=dict(os.environ, QUEUED_SCRIPT=str(SCRIPT), QUEUED_FAKE=FAKE, QUEUED_MODE=mode),
            capture_output=True, text=True, timeout=30)

    def fake(self, mode, priming=False):
        result = self.run_ps('$priming=$' + str(priming).lower() + '\n' + '''
function Add-Type { param($TypeDefinition) Microsoft.PowerShell.Utility\Add-Type -TypeDefinition ($TypeDefinition+$env:QUEUED_FAKE) }
. $env:QUEUED_SCRIPT -CompileOnly | Out-Null
$fake=New-Object GameInputQueuedResearch.FakeIo
$fake.Mode=$env:QUEUED_MODE
$methodName=if ($priming) { 'MeasureBounded' } else { 'MeasureCore' }
$method=[GameInputQueuedResearch.Reader].GetMethod($methodName,[Reflection.BindingFlags]'NonPublic,Static')
$invokeArgs=@('synthetic-only',$fake.psobject.BaseObject,[double]0.03,[double]0.03)
if ($priming) { $invokeArgs+=1; $invokeArgs+=$false }
$capture=$method.Invoke($null,$invokeArgs)
[pscustomobject]@{capture=$capture;closes=$fake.Closes;cancels=$fake.Cancels;results=$fake.Results} | ConvertTo-Json -Depth 12 -Compress
''', mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_compile_only(self):
        result = self.run_ps('& $env:QUEUED_SCRIPT -CompileOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no device opened or request submitted', result.stdout)

    def test_unknown_vm_is_refused_before_output_or_device_open(self):
        with tempfile.TemporaryDirectory() as directory:
            code = '''
function Get-ItemProperty { [pscustomobject]@{CurrentBuild='0'; UBR=0} }
& $env:QUEUED_SCRIPT -ResultsRoot $env:QUEUED_OUTPUT
'''
            encoded = base64.b64encode(code.encode('utf-16le')).decode()
            output = Path(directory) / 'must-not-exist'
            result = subprocess.run([PS, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
                                    env=dict(os.environ, QUEUED_SCRIPT=str(SCRIPT), QUEUED_OUTPUT=str(output)),
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Requires the identified Windows 10 research VM', result.stderr)
            self.assertFalse(output.exists())

    def test_immediate_and_pending_success_read_exact_reply(self):
        for mode in ('immediate', 'success'):
            with self.subTest(mode=mode):
                value = self.fake(mode)
                capture = value['capture']
                self.assertTrue(capture['Closed'])
                self.assertFalse(capture['CleanupPending'])
                self.assertGreater(len(capture['Requests']), 0)
                self.assertLessEqual(len(capture['Requests']), 1024)
                for row in capture['Requests']:
                    self.assertEqual(row['OutputHex'], bytes(range(1, 25)).hex())
                    self.assertEqual(row['PendingReturn'], mode == 'success')
                    self.assertGreaterEqual(row['CompletionObservedQpc'], row['SubmittedQpc'])

    def test_submission_error_never_reads_or_reaps_output(self):
        value = self.fake('error')
        self.assertEqual(value['results'], 0)
        row = value['capture']['Requests'][0]
        self.assertEqual(row['SubmissionError'], 5)
        self.assertIsNone(row['OutputHex'])
        self.assertTrue(value['capture']['Closed'])

    def test_short_success_stops_without_reading_output(self):
        value = self.fake('short')
        self.assertEqual(len(value['capture']['Requests']), 1)
        self.assertEqual(value['capture']['Requests'][0]['Bytes'], 2)
        self.assertIsNone(value['capture']['Requests'][0]['OutputHex'])

    def test_pending_cancel_is_reaped_before_closing(self):
        value = self.fake('cancel')
        row = value['capture']['Requests'][0]
        self.assertTrue(row['CancelRequested'])
        self.assertEqual(row['CompletionError'], 995)
        self.assertIsNone(row['OutputHex'])
        self.assertTrue(value['capture']['Closed'])
        self.assertFalse(value['capture']['CleanupPending'])
        self.assertEqual(value['closes'], 2)

    def test_unconfirmed_cancel_retains_handles_and_marks_cleanup_pending(self):
        value = self.fake('unresolved')
        self.assertTrue(value['capture']['CleanupPending'])
        self.assertFalse(value['capture']['Closed'])
        self.assertEqual(value['closes'], 0)
        self.assertGreaterEqual(value['cancels'], 1)
        self.assertIsNone(value['capture']['Requests'][0]['OutputHex'])

    def test_exception_with_active_request_keeps_resources(self):
        value = self.fake('wait-error')
        self.assertEqual(value['capture']['Error'], 'Synthetic wait failure')
        self.assertTrue(value['capture']['CleanupPending'])
        self.assertEqual(value['closes'], 0)
        self.assertGreaterEqual(value['cancels'], 1)
        self.assertTrue(value['capture']['Requests'][0]['CancelRequested'])

    def test_failed_device_close_is_not_reported_as_clean(self):
        value = self.fake('close-error')
        self.assertFalse(value['capture']['Closed'])
        self.assertEqual(value['capture']['CloseError'], 5)
        self.assertTrue(value['capture']['CleanupPending'])

    def test_priming_submits_only_one_request_without_measurement_cues(self):
        value = self.fake('success', priming=True)
        self.assertEqual(len(value['capture']['Requests']), 1)
        self.assertEqual(value['capture']['Cues'], [])
        self.assertTrue(value['capture']['Closed'])
        self.assertFalse(value['capture']['CleanupPending'])


if __name__ == '__main__':
    unittest.main()
