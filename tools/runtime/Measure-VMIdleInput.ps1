[CmdletBinding(DefaultParameterSetName='Capture')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Compile')][switch]$CompileOnly,
    [Parameter(ParameterSetName='Capture')][string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputResults'
)
$ErrorActionPreference='Stop'
function Get-IdleInputPhase([double]$Seconds) {
    if ($Seconds -lt 0) { throw 'Elapsed time must be nonnegative.' }
    if ($Seconds -lt 20) { return 'idle-before' }
    if ($Seconds -lt 25) { return 'left-stick' }
    if ($Seconds -lt 35) { return 'idle-after' }
    return 'ended'
}
$native=Join-Path $PSScriptRoot 'Measure-XInputState.ps1'
& $native -CompileOnly
if ($CompileOnly) { Write-Output 'Idle recorder compiled; no DLL loaded or controller queried.'; return }
if ([IntPtr]::Size -ne 4) { throw 'Use x86 Windows PowerShell in the prepared guest.' }
$nativeHash=(Get-FileHash -LiteralPath $native).Hash.ToLowerInvariant()
if ($nativeHash -notin @('a7dee09f72eddcb6590ec5ddf7a360ecee51687b9eb73669cff100683b6d1083',
    '1cc7a16f6468016d3d03c5614af7c045f27fe1285cabbaa5c7d9c44cc37d098a')) { throw 'Unrecognized native helper source.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796) { throw 'This recording requires the prepared Windows 10 guest.' }
$driver=Join-Path $env:WINDIR 'Sysnative\drivers\xinputhid.sys'
$dll=Join-Path $env:WINDIR 'SysWOW64\XInput1_4.dll'
$driverHash=(Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant()
$dllHash=(Get-FileHash -LiteralPath $dll).Hash.ToLowerInvariant()
if ($driverHash -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f' -or
    $dllHash -ne 'afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d') { throw 'Research backing-file identity mismatch.' }
$loaded=[GameInputStateResearch.Benchmark]::Load($dll)
if (-not [GameInputStateResearch.Benchmark]::SameFile($loaded,$dll) -or
    (Get-FileHash -LiteralPath $loaded).Hash.ToLowerInvariant() -ne $dllHash) { throw 'Loaded XInput backing-file identity mismatch.' }
[GameInputStateResearch.Benchmark]::Bind()
function Get-ServiceInventory {
    return @(Get-CimInstance Win32_Service -Filter "Name LIKE 'GameInput%'" | Select-Object Name,State,StartMode,ProcessId)
}
function Write-ImmutableRecord([string]$Path,$Value) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$Path)
}
$id=[guid]::NewGuid().ToString('N')
$directory=Join-Path $ResultsRoot ('idle-input-'+$id)
[void][IO.Directory]::CreateDirectory($directory)
$services=Get-ServiceInventory
$metadata=[ordered]@{schemaVersion=1; id=$id; readyUtc=[DateTime]::UtcNow.ToString('o'); processId=$PID; architecture='x86'; osBuild=$version.CurrentBuild; ubr=$version.UBR
    driverSha256=$driverHash; loadedXInputPath=$loaded; loadedBackingSha256=$dllHash; nativeScriptSha256=$nativeHash
    scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); servicesBefore=$services
    qpcFrequency=[Diagnostics.Stopwatch]::Frequency; seconds=35; maximumSamples=3500; slot=0
    purpose='Public XInput state variation screening; not raw HID, queued IOCTL completion timing, or full input fidelity'}
Write-ImmutableRecord (Join-Path $directory 'ready.json') $metadata
$services | Format-Table -AutoSize | Out-Host
Write-Host 'Keep the debugger running with no breakpoints. Baseline service and controller settings are preserved.'
Write-Host 'After READY: 20 seconds untouched, 5 seconds moving ONLY the left stick, then 10 seconds untouched.'
Write-Host 'Phase labels describe requested actions. The final report records what you actually did.'
if ((Read-Host 'Type READY to start, or anything else to cancel') -ine 'READY') {
    Write-ImmutableRecord (Join-Path $directory 'cancelled.json') @{reason='operator_cancelled_before_queries'}
    return
}
$rows=New-Object 'Collections.Generic.List[object]'
$cues=New-Object 'Collections.Generic.List[object]'
$clock=[Diagnostics.Stopwatch]::StartNew()
$phase=''; $failure=$null
try {
    while ($rows.Count -lt 3500 -and $clock.Elapsed.TotalSeconds -lt 35) {
        $current=Get-IdleInputPhase $clock.Elapsed.TotalSeconds
        if ($current -eq 'ended') { break }
        if ($current -ne $phase) {
            $phase=$current
            $cues.Add([pscustomobject]@{phase=$phase; elapsedSeconds=$clock.Elapsed.TotalSeconds})
            if ($phase -eq 'left-stick') { Write-Host 'MOVE ONLY THE LEFT STICK now.' }
            else { Write-Host 'RELEASE EVERYTHING; leave the controller untouched.' }
        }
        $before=[Diagnostics.Stopwatch]::GetTimestamp()
        $sample=[GameInputStateResearch.Benchmark]::ReadInput(0)
        $after=[Diagnostics.Stopwatch]::GetTimestamp()
        $rows.Add([pscustomobject]@{phase=$phase; elapsedSeconds=$clock.Elapsed.TotalSeconds; queryStartQpc=$before; queryEndQpc=$after; sample=$sample})
        Start-Sleep -Milliseconds 10
    }
} catch { $failure=$_.Exception.Message }
finally {
    $clock.Stop()
    $record=[ordered]@{metadata=$metadata; endedUtc=[DateTime]::UtcNow.ToString('o'); elapsedSeconds=$clock.Elapsed.TotalSeconds
        sampleCount=$rows.Count; cues=$cues.ToArray(); rows=$rows.ToArray(); error=$failure
        limitations=@('Only public XInput slot 0 snapshots; raw HID, PS/battery and queued completion lifetimes are not collected.',
            'Polling adds observer activity; nominal 10 ms sleeps and phase-console output do not guarantee sampling frequency.',
            'Bounds checked between native calls; a blocked API call is not subject to a hard timeout.',
            'Phase labels/cues do not prove physical movement; operator report is separate.',
            'Contains private process/module paths. Keep raw records ignored.')}
    Write-ImmutableRecord (Join-Path $directory 'capture.json') $record
}
Write-Host 'DONE. Release the stick. Capture saved before requesting your action report.'
$report=Read-Host 'What did you physically do in each phase? Mention accidental trigger/button input or missed cues'
Write-ImmutableRecord (Join-Path $directory 'operator.json') @{report=$report; collectedUtc=[DateTime]::UtcNow.ToString('o')}
Write-ImmutableRecord (Join-Path $directory 'after.json') @{servicesAfter=(Get-ServiceInventory)}
Write-Output "Saved idle input screening to $directory"
if ($failure) { throw $failure }
