[CmdletBinding()]
param(
    [string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputResults',
    [ValidateRange(1,15)][int]$MaximumMinutes=10
)
$ErrorActionPreference='Stop'
if ([IntPtr]::Size -ne 8) { throw 'Use administrator x64 Windows PowerShell in the prepared guest.' }
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$driver=Join-Path $env:WINDIR 'System32\drivers\xinputhid.sys'
if ($version.CurrentBuild -ne '19045' -or $version.UBR -ne 5796 -or
    (Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant() -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f') {
    throw 'Prepared VM identity mismatch; no service changed.'
}
function Get-ServiceRecord {
    Get-CimInstance Win32_Service -Filter "Name='GameInputSvc'" | Select-Object Name,State,StartMode,ProcessId
}
function Write-Record([string]$Path,$Value) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$Path)
}
$original=Get-ServiceRecord
if ($original.State -ne 'Running' -or $original.StartMode -ne 'Manual') { throw 'Expected Running/Manual inbox service; no service changed.' }
$id=[guid]::NewGuid().ToString('N')
$folder=Join-Path $ResultsRoot ('service-recovery-'+$id)
[IO.Directory]::CreateDirectory($folder) | Out-Null
Write-Host 'This stops only GameInputSvc temporarily, then restores its running state.'
Write-Host "Automatic restoration after at most $MaximumMinutes minutes, or earlier on a matching resume request. Startup type is not changed."
Write-Host 'Keep this window open. Forced termination or guest suspension can prevent timely restoration.'
if ((Read-Host 'Type READY to start the agreed VM service recovery test') -ine 'READY') { throw 'Cancelled; no service changed.' }
$record=[ordered]@{schemaVersion=1; sessionId=$id; original=$original; startedUtc=[DateTime]::UtcNow.ToString('o'); scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); stopAttempted=$false; stopError=$null; restoreError=$null; reason=$null}
Write-Record (Join-Path $folder 'original.json') $record
try {
    $record.stopAttempted=$true
    Stop-Service -Name GameInputSvc -ErrorAction Stop
    (Get-Service -Name GameInputSvc).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))
    $record.stopped=Get-ServiceRecord
    $record.stoppedUtc=[DateTime]::UtcNow.ToString('o')
    $record.processesAfterStop=@(Get-Process -Name GameInputSvc -ErrorAction SilentlyContinue | Select-Object Id,ProcessName)
    Write-Record (Join-Path $folder 'stopped.ready.json') $record
    Write-Host 'Service is stopped; leave this window open while measurements run.'
    $deadline=[DateTime]::UtcNow.AddMinutes($MaximumMinutes)
    $request=Join-Path $folder 'resume.request.json'
    $record.reason='timeout'
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $request) {
            try { $message=Get-Content -LiteralPath $request -Raw | ConvertFrom-Json } catch { $message=$null }
            if ($null -ne $message -and $message.sessionId -ceq $id) { $record.reason='matching-resume-request'; break }
        }
        Start-Sleep -Milliseconds 250
    }
} catch { $record.stopError=$_.Exception.Message; $record.reason='error' }
finally {
    $record.restorationStartedUtc=[DateTime]::UtcNow.ToString('o')
    try {
        Start-Service -Name GameInputSvc -ErrorAction Stop
        (Get-Service -Name GameInputSvc).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
        $record.restored=Get-ServiceRecord
        if ($record.restored.State -ne 'Running' -or $record.restored.StartMode -ne $original.StartMode) { throw 'Original service state/configuration not verified.' }
    } catch { $record.restoreError=$_.Exception.Message }
    $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Write-Record (Join-Path $folder 'ended.json') $record
}
if ($null -ne $record.restoreError) { throw ('Restoration failed; inspect GameInputSvc: '+$record.restoreError) }
if ($null -ne $record.stopError) { throw ('Recovery test failed; service restored: '+$record.stopError) }
Write-Output 'GameInputSvc restored to Running; original Manual startup type verified.'
