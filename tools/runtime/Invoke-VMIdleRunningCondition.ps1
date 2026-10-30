[CmdletBinding()]
param(
    [string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputIdleResults',
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
if ([IntPtr]::Size -ne 8) { throw 'Use administrator x64 Windows PowerShell in the prepared guest.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796) { throw 'Prepared guest identity mismatch.' }
$driver=Join-Path $env:WINDIR 'System32\drivers\xinputhid.sys'
if ((Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant() -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f') { throw 'Prepared driver identity mismatch.' }
$recorder=Join-Path $PSScriptRoot 'Measure-VMIdleInput.ps1'
$recorderHash=(Get-FileHash -LiteralPath $recorder).Hash.ToLowerInvariant()
if ($recorderHash -notin @('40d40823aa58312f7aed456885f3e52749ff4b074146598d53322c823bc77bab',
    'd0906226e9ace91d0ae8a79e930892108e5ee51c4f4d727d0963c91b43f34c35')) { throw 'Recorder differs from the stopped-condition source.' }
$inventory=Join-Path $PSScriptRoot 'Save-VMInventory.ps1'
if ((Get-FileHash -LiteralPath $inventory).Hash.ToLowerInvariant() -notin @(
    '59235f028a941a50e4550957c78caeb7614f137ed50e71863b2e8bcbdf8c562c',
    '32b2f9a8b1d8a8483ff28ef099c64e90a2a946d74c01bd4615db17b15abc2702')) { throw 'Inventory helper identity mismatch.' }
$service=Get-Service -Name GameInputSvc
if ($service.Status -ne 'Stopped' -or $service.StartType -ne 'Manual') { throw 'This condition requires the observed Stopped/Manual baseline.' }
if ($ValidateOnly) { Write-Output 'Identity and baseline checked; no service changed or recorder launched.'; return }
$root=Join-Path $ResultsRoot ('running-condition-'+[guid]::NewGuid().ToString('N'))
$measurements=Join-Path $root 'measurements'
[void][IO.Directory]::CreateDirectory($measurements)
function Write-Record([string]$Name,$Value) {
    $path=Join-Path $root $Name
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$path)
}
$record=[ordered]@{schemaVersion=1; baselineState='Stopped'; baselineStartType='Manual'; requestedState='Running'
    startedUtc=[DateTime]::UtcNow.ToString('o'); recorderSha256=$recorderHash
    wrapperSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); qpcFrequency=[Diagnostics.Stopwatch]::Frequency
    startAttempted=$false; runningVerified=$false; stopAttempted=$false; stoppedVerified=$false
    captureFound=$false; error=$null; restorationError=$null; timeLimitSeconds=180}
$child=$null
try {
    # Mark before Start-Service so a partial/failed start still reaches restoration.
    $record.startAttempted=$true
    Start-Service -Name GameInputSvc
    $state=Get-Service -Name GameInputSvc
    if ($state.Status -ne 'Running' -or $state.StartType -ne 'Manual') { throw 'Running/Manual state was not verified.' }
    $record.runningVerified=$true
    $record.runningQpc=[Diagnostics.Stopwatch]::GetTimestamp()
    $record.processesAtStart=@(Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId)
    Write-Record 'running.json' $record
    # Inventory actual loaded GameInput modules outside the timed state window.
    Start-Sleep -Seconds 1
    & $inventory -ResultsRoot $root
    $exe=Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    # This child is intentionally interactive in the operator's existing console.
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$recorder+'"'),'-ResultsRoot',('"'+$measurements+'"'))
    $child=Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru
    $budget=[Diagnostics.Stopwatch]::StartNew()
    while ($budget.Elapsed.TotalSeconds -lt 180) {
        $capture=@(Get-ChildItem -LiteralPath $measurements -Filter capture.json -Recurse -File)
        if ($capture.Count -gt 0) { $record.captureFound=$true; break }
        if ($child.HasExited) { throw ('Recorder exited before publishing a capture: '+$child.ExitCode) }
        Start-Sleep -Milliseconds 250
    }
    if (-not $record.captureFound) { throw 'Capture not published within 180 seconds; restoring the stopped baseline.' }
} catch { $record.error=$_.Exception.Message }
finally {
    if ($record.startAttempted) {
        try {
            $record.stopAttempted=$true
            $record.stopRequestedQpc=[Diagnostics.Stopwatch]::GetTimestamp()
            Stop-Service -Name GameInputSvc
            $state=Get-Service -Name GameInputSvc
            if ($state.Status -ne 'Stopped' -or $state.StartType -ne 'Manual') { throw 'Stopped/Manual baseline was not restored.' }
            $record.stoppedVerified=$true
            $record.stoppedQpc=[Diagnostics.Stopwatch]::GetTimestamp()
        } catch { $record.restorationError=$_.Exception.Message }
    }
    $record.endedUtc=[DateTime]::UtcNow.ToString('o')
    $record.limitations=@('180-second poll limit is not a hard timeout for blocked service/native/file calls or a terminated parent process.',
        'SCM state is verified; exit of every per-user worker is not certified here.',
        'Recorder can still be awaiting its physical-action report after capture publication and service restoration.',
        'Compare the service lifetime QPC bounds with query QPC bounds; a late capture after timeout is not a valid running condition.')
    Write-Record 'restored.json' $record
}
if ($record.error -or $record.restorationError) { throw ($record.error+' '+$record.restorationError) }
Write-Host 'GameInputSvc restored to Stopped/Manual. Finish the recorder action-report prompt if it is still open.'
if ($child -and -not $child.HasExited) { [void]$child.WaitForExit(120000) }
Write-Output "Service-condition records saved to $root"
