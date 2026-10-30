[CmdletBinding()]
param(
    [string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputRawResults',
    [switch]$CompileOnly
)
$ErrorActionPreference='Stop'
# ABI reference: nefarius/DsHidMini setup-v3.27.0, commit
# 3f673849bcbc187a094775536c0583fd687014a2: IPC.c, IPC.h,
# SDK/Nefarius.DsHidMini.IPC/Models/HidStructs.cs and .Commands.cs.
# Opens an EXISTING mapping with FILE_MAP_READ only; no IPC commands/events.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public sealed class DsRawSlot {
    public int Index, Sequence, Attempts;
    public long QpcBefore, QpcAfter;
    public string Status, ReportHex;
}
public sealed class DsRawMapping {
    public string Status;
    public int Win32Error;
    public uint AllocationGranularity;
    public DsRawSlot[] Slots;
}
public static class DsRawInventory {
    [StructLayout(LayoutKind.Sequential)] struct SYSTEM_INFO {
        public ushort Architecture, Reserved;
        public uint PageSize;
        public IntPtr MinimumAddress, MaximumAddress, ProcessorMask;
        public uint ProcessorCount, ProcessorType, AllocationGranularity;
        public ushort ProcessorLevel, ProcessorRevision;
    }
    [DllImport("kernel32.dll")] static extern void GetSystemInfo(out SYSTEM_INFO info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr OpenFileMapping(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr MapViewOfFile(IntPtr handle, uint access, uint high, uint low, UIntPtr size);
    [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr address);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static DsRawMapping Read(string name) {
        SYSTEM_INFO info; GetSystemInfo(out info);
        var result = new DsRawMapping { AllocationGranularity=info.AllocationGranularity };
        IntPtr handle=OpenFileMapping(4, false, name); // FILE_MAP_READ
        if (handle==IntPtr.Zero) {
            result.Status="open-unavailable"; result.Win32Error=Marshal.GetLastWin32Error(); return result;
        }
        IntPtr view=IntPtr.Zero;
        try {
            // Driver's second allocation-granularity region is HID snapshots.
            // Screen only the first 32 slots (60 bytes each), not a device count.
            view=MapViewOfFile(handle, 4, 0, info.AllocationGranularity, new UIntPtr(32*60));
            if (view==IntPtr.Zero) {
                result.Status="view-unavailable"; result.Win32Error=Marshal.GetLastWin32Error(); return result;
            }
            result.Status="mapped-read-only"; result.Slots=new DsRawSlot[32];
            for (int index=1; index<=32; index++) {
                var slot=new DsRawSlot { Index=index, Status="unstable", QpcBefore=Stopwatch.GetTimestamp() };
                result.Slots[index-1]=slot;
                IntPtr address=IntPtr.Add(view,(index-1)*60);
                for (int attempt=1; attempt<=8; attempt++) {
                    slot.Attempts=attempt;
                    int first=Marshal.ReadInt32(address,4);
                    Thread.MemoryBarrier();
                    if ((first & 1)!=0) { Thread.Yield(); continue; }
                    int actualIndex=Marshal.ReadInt32(address,0);
                    byte[] bytes=new byte[49];
                    Marshal.Copy(IntPtr.Add(address,8),bytes,0,bytes.Length);
                    Thread.MemoryBarrier();
                    int second=Marshal.ReadInt32(address,4);
                    if (first!=second) continue;
                    slot.Sequence=first;
                    slot.Status=actualIndex==0 ? "empty" : actualIndex!=index ? "index-mismatch" : "stable";
                    if (slot.Status=="stable") slot.ReportHex=BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();
                    break;
                }
                slot.QpcAfter=Stopwatch.GetTimestamp();
            }
            return result;
        } finally {
            if (view!=IntPtr.Zero) UnmapViewOfFile(view);
            CloseHandle(handle);
        }
    }
}
'@
if ($CompileOnly) { Write-Output 'Compiled; no mapping opened or configuration read.'; return }
if ([IntPtr]::Size -ne 8) { throw 'Use native x64 Windows PowerShell.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796) {
    throw 'This inventory is scoped to the identified Windows 10 VM (19045.5796).'
}
$id='dsraw-inventory-'+[guid]::NewGuid().ToString('N')
$directory=Join-Path $ResultsRoot $id
[void][IO.Directory]::CreateDirectory($directory)
$configPath=Join-Path $env:ProgramData 'DsHidMini\DsHidMini.json'
$config=[ordered]@{ path=$configPath; status='unknown'; sha256=$null; parsed=$null; error=$null }
try {
    # Bound the read even if the file changes size; retain the original bytes.
    $stream=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $buffer=New-Object byte[] (1048576+1)
        $length=0
        while ($length -lt $buffer.Length) {
            $count=$stream.Read($buffer,$length,$buffer.Length-$length)
            if ($count -eq 0) { break }; $length+=$count
        }
        if ($length -gt 1048576) { throw 'Configuration exceeds the 1 MiB inventory limit.' }
        $bytes=New-Object byte[] $length
        [Array]::Copy($buffer,$bytes,$length)
    } finally { $stream.Dispose() }
    $saved=Join-Path $directory 'DsHidMini.json'
    [IO.File]::WriteAllBytes($saved,$bytes)
    $config.sha256=(Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash.ToLowerInvariant()
    $config.status='saved'
    try { $config.parsed=([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff) | ConvertFrom-Json) }
    catch { $config.error='JSON parsing: '+$_.Exception.Message }
} catch { $config.status='unavailable'; $config.error=$_.Exception.Message }
$serviceBefore=@(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)
$snapshots=@([DsRawInventory]::Read('Global\DsHidMiniSharedMemory'))
Start-Sleep -Milliseconds 250
$snapshots+= [DsRawInventory]::Read('Global\DsHidMiniSharedMemory')
$serviceAfter=@(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)
$record=[ordered]@{
    schemaVersion=1; collectedUtc=[DateTime]::UtcNow.ToString('o'); build=$version.CurrentBuild; ubr=$version.UBR
    scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    upstreamCommit='3f673849bcbc187a094775536c0583fd687014a2'
    qpcFrequency=[Diagnostics.Stopwatch]::Frequency; configuration=$config
    serviceBefore=$serviceBefore; serviceAfter=$serviceAfter; snapshots=$snapshots
    limitations=@('Configuration file does not establish effective loaded settings.',
        'ABI is source-pinned; source-to-installed-binary reproducibility is unverified.',
        'Two snapshots of first 32 slots are not a report rate or device count.',
        'Slot identity, freshness and association with the controller need independent verification.',
        'No public XInput call, mapped HID comparison, or queued IOCTL completion is recorded.',
        'IPC bytes are the driver-exposed pre-mapping report, not an independent USB wire capture.')
}
$target=Join-Path $directory 'inventory.json'
[IO.File]::WriteAllText($target+'.tmp',($record | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
[IO.File]::Move($target+'.tmp',$target)
Write-Output "Saved read-only DsHidMini inventory to $target"
