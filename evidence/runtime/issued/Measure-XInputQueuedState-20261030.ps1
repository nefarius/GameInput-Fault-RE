[CmdletBinding()]
param([string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputQueuedResults', [switch]$CompileOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
namespace GameInputQueuedResearch {
    public sealed class RequestRecord {
        public int Index, SubmissionError, CompletionError, CancelError;
        public long SubmittedQpc, ReturnedQpc, CompletionObservedQpc;
        public bool SubmissionReturnedTrue, PendingReturn, Success, CancelRequested, CleanupPending;
        public uint Bytes;
        public string OutputHex;
    }
    public sealed class Cue { public string Phase; public double ElapsedSeconds; }
    public sealed class Capture {
        public long StartQpc, EndQpc, Frequency=Stopwatch.Frequency, CloseTicks;
        public string DevicePath, Error;
        public int OpenError, CloseError;
        public bool Opened, Closed, CleanupPending;
        public RequestRecord[] Requests;
        public Cue[] Cues;
    }
    public interface IQueuedIo {
        IntPtr Open(string path,out int error);
        IntPtr NewEvent(out int error);
        bool Close(IntPtr handle,out int error);
        bool Submit(IntPtr handle,IntPtr input,IntPtr output,IntPtr ov,out int error);
        bool Result(IntPtr handle,IntPtr ov,out uint bytes,out int error);
        bool Cancel(IntPtr handle,IntPtr ov,out int error);
        uint Wait(IntPtr handle,uint milliseconds);
    }
    public static class Reader {
        [StructLayout(LayoutKind.Sequential)] struct Overlapped {
            public UIntPtr Internal, InternalHigh;
            public uint Offset, OffsetHigh;
            public IntPtr Event;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern IntPtr CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern IntPtr CreateEventW(IntPtr sa,bool manual,bool initial,string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool DeviceIoControl(IntPtr handle,uint ioctl,IntPtr input,uint inputLength,IntPtr output,uint outputLength,IntPtr returned,IntPtr overlapped);
        [DllImport("kernel32.dll",SetLastError=true)]
        static extern bool GetOverlappedResult(IntPtr handle,IntPtr overlapped,out uint bytes,bool wait);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CancelIoEx(IntPtr handle,IntPtr overlapped);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        sealed class NativeIo : IQueuedIo {
            public IntPtr Open(string path,out int error) {var h=CreateFileW(path,0xc0000000,3,IntPtr.Zero,3,0x40000080,IntPtr.Zero);error=Marshal.GetLastWin32Error();return h;}
            public IntPtr NewEvent(out int error) {var h=CreateEventW(IntPtr.Zero,true,false,null);error=Marshal.GetLastWin32Error();return h;}
            public bool Close(IntPtr h,out int error) {bool ok=CloseHandle(h);error=ok?0:Marshal.GetLastWin32Error();return ok;}
            public bool Submit(IntPtr h,IntPtr input,IntPtr output,IntPtr ov,out int error) {bool ok=DeviceIoControl(h,0x8000e388,input,4,output,24,IntPtr.Zero,ov);error=ok?0:Marshal.GetLastWin32Error();return ok;}
            public bool Result(IntPtr h,IntPtr ov,out uint bytes,out int error) {bool ok=GetOverlappedResult(h,ov,out bytes,false);error=ok?0:Marshal.GetLastWin32Error();return ok;}
            public bool Cancel(IntPtr h,IntPtr ov,out int error) {bool ok=CancelIoEx(h,ov);error=ok?0:Marshal.GetLastWin32Error();return ok;}
            public uint Wait(IntPtr h,uint ms) {return WaitForSingleObject(h,ms);}
        }
        // Keep unresolved storage/handles allocated until this dedicated process
        // exits; never free or reuse an OVERLAPPED still owned by the kernel.
        static bool unresolved;
        public static string Phase(double seconds) {
            return seconds<20 ? "idle-before" : seconds<25 ? "left-stick" : seconds<35 ? "idle-after" : "ended";
        }
        static void CuePhase(Stopwatch clock,List<Cue> cues) {
            string phase=Phase(clock.Elapsed.TotalSeconds);
            if(cues.Count>0 && cues[cues.Count-1].Phase==phase) return;
            cues.Add(new Cue {Phase=phase,ElapsedSeconds=clock.Elapsed.TotalSeconds});
            Console.WriteLine(phase=="left-stick" ? "MOVE ONLY THE LEFT STICK now." : phase=="ended" ? "DONE. Leave controller untouched." : "RELEASE EVERYTHING; leave controller untouched.");
        }
        public static Capture Measure(string path) {
            return MeasureCore(path,new NativeIo(),35,5);
        }
        // Private dependency seam for synthetic cancellation/lifetime tests.
        static Capture MeasureCore(string path,IQueuedIo io,double seconds,double cancelSeconds) {
            if(unresolved) throw new InvalidOperationException("Prior request unresolved; use a new process.");
            var capture=new Capture {DevicePath=path};
            var rows=new List<RequestRecord>(); var cues=new List<Cue>();
            int openError;
            IntPtr handle=io.Open(path,out openError);
            if(handle==new IntPtr(-1)) {capture.OpenError=openError; return capture;}
            capture.Opened=true;
            Stopwatch clock=Stopwatch.StartNew(); capture.StartQpc=Stopwatch.GetTimestamp();
            try {
                while(clock.Elapsed.TotalSeconds<seconds && rows.Count<1024 && !unresolved) {
                    CuePhase(clock,cues);
                    IntPtr input=IntPtr.Zero, output=IntPtr.Zero, ov=IntPtr.Zero, ev=IntPtr.Zero;
                    bool outstanding=false;
                    var row=new RequestRecord {Index=rows.Count}; rows.Add(row);
                    try {
                        input=Marshal.AllocHGlobal(4); output=Marshal.AllocHGlobal(24);
                        Marshal.Copy(new byte[]{3,1,0,0},0,input,4); // queued mode, byte 3 = 0
                        Marshal.Copy(new byte[24],0,output,24);
                        int eventError;
                        ev=io.NewEvent(out eventError);
                        if(ev==IntPtr.Zero) throw new Win32Exception(eventError);
                        ov=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Overlapped)));
                        Marshal.StructureToPtr(new Overlapped {Event=ev},ov,false);
                        row.SubmittedQpc=Stopwatch.GetTimestamp();
                        int submitError;
                        row.SubmissionReturnedTrue=io.Submit(handle,input,output,ov,out submitError);
                        row.ReturnedQpc=Stopwatch.GetTimestamp();
                        row.SubmissionError=row.SubmissionReturnedTrue?0:submitError;
                        row.PendingReturn=!row.SubmissionReturnedTrue && submitError==997;
                        if(!row.SubmissionReturnedTrue && !row.PendingReturn) {row.CompletionError=submitError; break;}
                        outstanding=true;
                        Stopwatch cancelClock=null;
                        while(true) {
                            uint bytes;
                            int error;
                            bool ok=io.Result(handle,ov,out bytes,out error);
                            if(ok || error!=996) {
                                outstanding=false; row.CompletionObservedQpc=Stopwatch.GetTimestamp();
                                row.Success=ok; row.CompletionError=ok?0:error;
                                if(ok) {
                                    row.Bytes=bytes;
                                    // Never inspect output on pending/error/short replies.
                                    if(bytes==24) {
                                        byte[] result=new byte[24]; Marshal.Copy(output,result,0,24);
                                        row.OutputHex=BitConverter.ToString(result).Replace("-","").ToLowerInvariant();
                                    }
                                }
                                break;
                            }
                            CuePhase(clock,cues);
                            if(clock.Elapsed.TotalSeconds>=seconds && !row.CancelRequested) {
                                row.CancelRequested=true;
                                int cancelError;
                                bool cancelled=io.Cancel(handle,ov,out cancelError);
                                row.CancelError=cancelled?0:cancelError;
                                cancelClock=Stopwatch.StartNew();
                            }
                            if(cancelClock!=null && cancelClock.Elapsed.TotalSeconds>=cancelSeconds) {
                                row.CleanupPending=true; unresolved=true; break;
                            }
                            uint wait=io.Wait(ev,20);
                            if(wait==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error());
                        }
                    } finally {
                        if(outstanding) {
                            // An exception while I/O is active must not free its buffers.
                            // Cancellation is a request, not proof of completion.
                            if(!row.CancelRequested) {
                                row.CancelRequested=true;
                                int cancelError;
                                bool cancelled=io.Cancel(handle,ov,out cancelError);
                                row.CancelError=cancelled?0:cancelError;
                            }
                            unresolved=true; row.CleanupPending=true;
                        } else {
                            if(ov!=IntPtr.Zero) Marshal.FreeHGlobal(ov);
                            if(output!=IntPtr.Zero) Marshal.FreeHGlobal(output);
                            if(input!=IntPtr.Zero) Marshal.FreeHGlobal(input);
                            if(ev!=IntPtr.Zero) {
                                int eventCloseError;
                                if(!io.Close(ev,out eventCloseError)) {
                                    capture.CleanupPending=true;
                                    capture.Error="Owned event close failed: "+eventCloseError;
                                }
                            }
                        }
                    }
                    if(row.CleanupPending || (!row.Success && !row.CancelRequested) || (row.Success && row.Bytes!=24)) break;
                }
            } catch(Exception e) {capture.Error=e.Message;}
            finally {
                capture.EndQpc=Stopwatch.GetTimestamp(); capture.CleanupPending=capture.CleanupPending || unresolved;
                if(!unresolved) {
                    int closeError;
                    long before=Stopwatch.GetTimestamp(); capture.Closed=io.Close(handle,out closeError);
                    capture.CloseError=capture.Closed?0:closeError;
                    if(!capture.Closed) capture.CleanupPending=true;
                    capture.CloseTicks=Stopwatch.GetTimestamp()-before;
                }
                capture.Requests=rows.ToArray(); capture.Cues=cues.ToArray();
            }
            return capture;
        }
    }
}
'@
if ($CompileOnly) { Write-Output 'Compiled; no device opened or request submitted.'; return }
if ([IntPtr]::Size -ne 8) { throw 'Use native x64 Windows PowerShell.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796) { throw 'Requires the identified Windows 10 research VM.' }
$driverHash=(Get-FileHash -LiteralPath "$env:WINDIR\System32\drivers\xinputhid.sys").Hash.ToLowerInvariant()
if ($driverHash -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f') { throw 'Research driver mismatch.' }
$services=@(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)
if ($services.Count -ne 1 -or $services[0].State -ne 'Stopped' -or $services[0].StartMode -ne 'Manual') { throw 'Requires Stopped/Manual service baseline; settings were not changed.' }
$enumerator=Join-Path $PSScriptRoot 'Measure-XInputHandleClose.ps1'
$enumeratorHash=(Get-FileHash -LiteralPath $enumerator).Hash.ToLowerInvariant()
if ($enumeratorHash -notin @('21a15797926b952e4ae84f957edd166619846aa5e2b84605364daa96b198a853','24fb24ed85eee3d9cef72c545e5c5b8aa8f9b85aa5724f2c2f633602a8e149f0')) { throw 'Unknown interface enumerator helper.' }
& $enumerator -CompileOnly | Out-Null
$paths=@([GameInputCloseResearch.Benchmark]::Interfaces())
if ($paths.Count -ne 1 -or -not $paths[0].StartsWith('\\?\HID#VID_045E&PID_02FF&IG_00#',[StringComparison]::OrdinalIgnoreCase)) { throw 'Expected exactly one matching research XInput interface.' }
$directory=Join-Path $ResultsRoot ('queued-state-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
function Save-QueuedRecord([string]$Name,$Value) {
    $path=Join-Path $directory $Name
    [IO.File]::WriteAllText($path+'.tmp',($Value | ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($path+'.tmp',$path)
}
$metadata=[ordered]@{schemaVersion=1; processId=$PID; readyUtc=[DateTime]::UtcNow.ToString('o'); architecture='x64'
    build=$version.CurrentBuild; ubr=$version.UBR; driverSha256=$driverHash; enumeratorSha256=$enumeratorHash
    scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); serviceBefore=$services
    devicePath=$paths[0]; inputHex='03010000'; ioctl='8000e388'; inputLength=4; outputLength=24
    seconds=35; maximumRequests=1024; qpcFrequency=[Diagnostics.Stopwatch]::Frequency
    condition='uncorrected; one owned queued request at a time; GameInputSvc stopped'}
Save-QueuedRecord 'ready.json' $metadata
Write-Host 'Keep WinDbg running without breakpoints. Requested phases: 20s untouched / 5s left stick / 10s untouched.'
Write-Host 'This direct client can add per-process queues on the affected driver. No vibration, service or driver changes.'
if ((Read-Host 'Type READY to begin, or anything else to cancel') -ine 'READY') { Save-QueuedRecord 'cancelled.json' @{reason='operator_cancelled'}; return }
$capture=[GameInputQueuedResearch.Reader]::Measure($paths[0])
Save-QueuedRecord 'capture.json' ([ordered]@{metadata=$metadata; capture=$capture; limitations=@(
    'CompletionObservedQpc is observation time, not exact kernel completion time; up to 20 ms wait/poll granularity.',
    'Maximum 1024 requests; reaching the cap ends recording early. No added resubmission pacing.',
    'Native API/close calls have no hard timeout; the budget is checked between calls.',
    'CancelIoEx targets only this owned request. Unresolved storage/handles stay allocated until dedicated process exit.',
    'At most one request outstanding; this is a test client, not a GameInput service-rate measurement.',
    'Only successful exact 24-byte replies are read. Equal payloads exclude the packet word only during later analysis.',
    'Device identity requires separate loaded-driver/device-stack debugger verification.',
    'Phase cues and operator reports do not prove complete physical input delivery. Raw input is not collected here.')})
$report=Read-Host 'Capture saved. Describe what you actually did in each phase'
Save-QueuedRecord 'operator.json' @{report=$report; utc=[DateTime]::UtcNow.ToString('o')}
Save-QueuedRecord 'after.json' @{serviceAfter=@(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)}
Write-Host "Saved to $directory"
if ($capture.CleanupPending) { Write-Warning 'Owned request/resource cleanup unconfirmed; see capture. Resources may remain until this dedicated process exits.' }
Read-Host 'Leave this process open for the debugger queue count; press Enter only when asked' | Out-Null
