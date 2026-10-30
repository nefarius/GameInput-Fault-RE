[CmdletBinding()]
param([string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputRawResults', [switch]$CompileOnly)
$ErrorActionPreference='Stop'
# A parent PowerShell 7 process can supply a module path that omits the
# Windows PowerShell utility module. Resolve the native built-in explicitly.
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
function Get-PairService {
    return @(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)
}
function Assert-PairServiceBaseline([object[]]$Services) {
    if ($Services.Count -ne 1 -or $Services[0].State -ne 'Stopped' -or $Services[0].StartMode -ne 'Manual') {
        $observed=ConvertTo-Json -InputObject @($Services) -Compress -Depth 4
        throw "Requires the Stopped/Manual service baseline; settings were not changed. Observed: $observed"
    }
}
function Test-StableIpcBracket($Before,$After) {
    return ($null -ne $Before -and $null -ne $After -and
        $Before.Status -eq 'stable' -and $After.Status -eq 'stable' -and
        $Before.Index -eq $After.Index -and $Before.Sequence -eq $After.Sequence -and
        $Before.ReportHex -eq $After.ReportHex)
}
function Write-PairRecord([string]$Path,$Record) {
    [IO.File]::WriteAllText($Path+'.tmp',($Record | ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($Path+'.tmp',$Path)
}
$rawHelper=Join-Path $PSScriptRoot 'Save-DsHidMiniInputInventory.ps1'
$nativeHelper=Join-Path $PSScriptRoot 'Measure-XInputState.ps1'
# Pin helper bytes before compiling their code. LF and CRLF source forms only.
$rawHash=(Get-FileHash -LiteralPath $rawHelper -Algorithm SHA256).Hash.ToLowerInvariant()
$nativeHash=(Get-FileHash -LiteralPath $nativeHelper -Algorithm SHA256).Hash.ToLowerInvariant()
if ($rawHash -notin @('bdd7ad10864f1922ccc9112c3082eda85f939698764c2ba110f69e1b1f98df26','829f32029495d4a7a8e95bac35fd2d99ab2abd05e50f070a69bf53edc603609a')) { throw 'Unrecognized raw helper source.' }
if ($nativeHash -notin @('a7dee09f72eddcb6590ec5ddf7a360ecee51687b9eb73669cff100683b6d1083','1cc7a16f6468016d3d03c5614af7c045f27fe1285cabbaa5c7d9c44cc37d098a')) { throw 'Unrecognized XInput helper source.' }
& $rawHelper -CompileOnly | Out-Null
& $nativeHelper -CompileOnly | Out-Null
if ($CompileOnly) { Write-Output 'Compiled; no mapping opened, DLL loaded or controller queried.'; return }
if ([IntPtr]::Size -ne 4) { throw 'Use x86 Windows PowerShell in the prepared guest.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796) { throw 'Wrong research VM build.' }
$driverHash=(Get-FileHash -LiteralPath "$env:WINDIR\Sysnative\drivers\xinputhid.sys").Hash.ToLowerInvariant()
$dsHash=(Get-FileHash -LiteralPath "$env:WINDIR\Sysnative\drivers\UMDF\dshidmini.dll").Hash.ToLowerInvariant()
$dll="$env:WINDIR\SysWOW64\XInput1_4.dll"
$dllHash=(Get-FileHash -LiteralPath $dll).Hash.ToLowerInvariant()
if ($driverHash -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f' -or
    $dsHash -ne '84c22c152fccc8d0e17595e0f3a1125312b2c4d1a45cd814c74b635a505e077a' -or
    $dllHash -ne 'afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d') { throw 'Research backing-file identity mismatch.' }
# PowerShell 5.1 unwraps a one-item function result to PSCustomObject, whose
# Count is null. Materialize an array at the call site, including singleton/zero.
$services=@(Get-PairService)
Assert-PairServiceBaseline $services
$initial=[DsRawInventory]::Read('Global\DsHidMiniSharedMemory')
if ($initial.Status -ne 'mapped-read-only' -or $initial.Slots[0].Status -ne 'stable' -or
    @($initial.Slots | Where-Object { $_.Status -ne 'empty' -and $_.Index -ne 1 }).Count -ne 0) {
    throw 'Expected only slot 1 populated in the first 32 IPC slots; review inventory.'
}
$slotProperties=@(foreach ($device in @(Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -eq 'PLAYSTATION(R)3 Controller' })) {
    try {
        $property=Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName '{3FECF510-CC94-4FBE-8839-738201F84D59} 6'
        [pscustomobject]@{deviceId=$device.InstanceId; status=$property.Type; slot=$property.Data; error=$null}
    } catch { [pscustomobject]@{deviceId=$device.InstanceId; slot=$null; error=$_.Exception.Message} }
})
$loaded=[GameInputStateResearch.Benchmark]::Load($dll)
if (-not [GameInputStateResearch.Benchmark]::SameFile($loaded,$dll) -or
    (Get-FileHash -LiteralPath $loaded).Hash.ToLowerInvariant() -ne $dllHash) { throw 'Loaded XInput identity mismatch.' }
[GameInputStateResearch.Benchmark]::Bind()
$directory=Join-Path $ResultsRoot ('dsraw-pair-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$configPath=Join-Path $env:ProgramData 'DsHidMini\DsHidMini.json'
$metadata=[ordered]@{
    schemaVersion=1; readyUtc=[DateTime]::UtcNow.ToString('o'); architecture='x86'; build=$version.CurrentBuild; ubr=$version.UBR
    rawScriptSha256=$rawHash; nativeScriptSha256=$nativeHash; scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
    driverSha256=$driverHash; dsHidMiniBackingSha256=$dsHash; loadedXInputPath=$loaded; xinputBackingSha256=$dllHash
    configBeforeSha256=(Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()
    serviceBefore=$services; slotProperties=$slotProperties; ipcSlot=1; publicXInputSlot=0
    qpcFrequency=[Diagnostics.Stopwatch]::Frequency; seconds=35; maximumSamples=3500; initialIpc=$initial
}
Write-PairRecord (Join-Path $directory 'ready.json') $metadata
Write-Host 'Keep WinDbg running without breakpoints. Service and controller settings are preserved.'
Write-Host 'After READY: 20 seconds untouched, 5 seconds moving ONLY the left stick, then 10 seconds untouched.'
if ((Read-Host 'Type READY to begin, or anything else to cancel') -ine 'READY') {
    Write-PairRecord (Join-Path $directory 'cancelled.json') @{reason='operator_cancelled'}; return
}
$rows=New-Object 'Collections.Generic.List[object]'
$cues=New-Object 'Collections.Generic.List[object]'
$clock=[Diagnostics.Stopwatch]::StartNew(); $phase=''; $failure=$null
try {
    while ($rows.Count -lt 3500 -and $clock.Elapsed.TotalSeconds -lt 35) {
        $elapsed=$clock.Elapsed.TotalSeconds
        $next=if ($elapsed -lt 20) { 'idle-before' } elseif ($elapsed -lt 25) { 'left-stick' } else { 'idle-after' }
        if ($next -ne $phase) {
            $phase=$next; $cues.Add([pscustomobject]@{phase=$phase; elapsedSeconds=$clock.Elapsed.TotalSeconds})
            if ($phase -eq 'left-stick') { Write-Host 'MOVE ONLY THE LEFT STICK now.' }
            else { Write-Host 'RELEASE EVERYTHING; leave the controller untouched.' }
        }
        $before=[DsRawInventory]::Read('Global\DsHidMiniSharedMemory')
        $queryStart=[Diagnostics.Stopwatch]::GetTimestamp()
        $sample=[GameInputStateResearch.Benchmark]::ReadInput(0)
        $queryEnd=[Diagnostics.Stopwatch]::GetTimestamp()
        $after=[DsRawInventory]::Read('Global\DsHidMiniSharedMemory')
        $a=$null; $b=$null
        if ($before.Status -eq 'mapped-read-only') { $a=$before.Slots[0] }
        if ($after.Status -eq 'mapped-read-only') { $b=$after.Slots[0] }
        $rows.Add([pscustomobject]@{phase=$phase; elapsedSeconds=$elapsed; queryStartQpc=$queryStart; queryEndQpc=$queryEnd
            rawBefore=$a; rawAfter=$b; rawBeforeStatus=$before.Status; rawBeforeError=$before.Win32Error
            rawAfterStatus=$after.Status; rawAfterError=$after.Win32Error; sample=$sample
            stableIpcBracket=(Test-StableIpcBracket $a $b)})
        Start-Sleep -Milliseconds 10
    }
} catch { $failure=$_.Exception.Message }
finally {
    $clock.Stop()
    Write-PairRecord (Join-Path $directory 'capture.json') ([ordered]@{metadata=$metadata; endedUtc=[DateTime]::UtcNow.ToString('o')
        elapsedSeconds=$clock.Elapsed.TotalSeconds; sampleCount=$rows.Count; rows=$rows.ToArray(); cues=$cues.ToArray(); error=$failure
        limitations=@('IPC slot 1 and XInput slot 0 association requires independent verification; slot properties are retained.',
            'An unchanged IPC sequence across a query does not prove the returned XInput state came from that report.',
            'Pre-mapping IPC snapshots and public XInput are collected; actual mapped HID and queued IOCTL completions are not.',
            'Snapshots can miss intermediate reports. IPC sequence increments are not queued completion counts.',
            'Repeated mapping and public queries add observer work; nominal 10 ms sleep is not a timing guarantee.',
            'Time/sample bounds checked between native calls; blocked native calls have no hard timeout.',
            'Phase cues are requested actions, not proof of physical input. Configuration is not effective-memory evidence.')})
}
Write-Host 'DONE. Capture saved. Leave the controller untouched.'
$report=Read-Host 'Describe your actual actions in each phase and any missed cues or accidental input'
Write-PairRecord (Join-Path $directory 'operator.json') @{report=$report; collectedUtc=[DateTime]::UtcNow.ToString('o')}
$configAfter=$null; $configError=$null
try { $configAfter=(Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant() } catch { $configError=$_.Exception.Message }
Write-PairRecord (Join-Path $directory 'after.json') @{serviceAfter=(Get-PairService); configAfterSha256=$configAfter; configError=$configError}
Write-Output "Saved raw/public input screening to $directory"
if ($failure) { throw $failure }
