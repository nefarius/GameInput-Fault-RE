# One-time recovery for the two recorded pre-PIN failures of 2026-10-25.
# No process, DLL, or export arguments are accepted. This is not public Eject.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$log=Join-Path $root 'artifacts/runtime/failed-start-cleanup.jsonl'
function Record($value) { $value | ConvertTo-Json -Depth 12 -Compress | Add-Content -LiteralPath $log -Encoding utf8 }
try {
    Import-Module (Join-Path $PSScriptRoot 'GameInput.Research.psm1') -Force
    Enable-ResearchDebugPrivilege
    $controller=Join-Path $root 'tools/build/out/bin/Release/GameInputProbeController.exe'
    $probe=Join-Path $root 'tools/build/out/bin/Release/GameInputProbe.dll'
    if ((Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash -ine '3e56b6b9a16cd71148baaadd2a5eff5f4bf0b768aa42df1bbf3e5b70fab9e990') { throw 'Cleanup applies only to the recorded failed-start DLL hash; local DLL changed.' }
    $prior=Join-Path $root 'captures/probe-20261025T132731462Z-32d24001ab9049b0aff7ba2207466456/research.jsonl'
    $records=@(Get-Content -LiteralPath $prior | ForEach-Object { $_ | ConvertFrom-Json })
    $injector=Get-ResearchInjector
    foreach($id in @(7188,6128)) {
        $inventory=@($records | Where-Object { $_.kind -eq 'inventory' -and $_.target.pid -eq $id })
        $failure=@($records | Where-Object { $_.kind -eq 'blocked' -and $_.target.pid -eq $id -and [string]$_.details -like '*Controller start failed*error_code*5*' })
        if($inventory.Count -ne 1 -or $failure.Count -ne 1) { throw "Recorded pre-PIN startup failure is not proven for $id." }
        $target=Get-Process -Id $id -ErrorAction Stop
        $recordedStart=([DateTime]$inventory[0].target.start_time_utc).ToUniversalTime()
        if($target.StartTime.ToUniversalTime() -ne $recordedStart -or $target.Path -ine $inventory[0].target.image_path) { throw "Recorded process identity changed for $id." }
        $raw=& $controller --pid ([string]$id) --action failed_start_status
        $exit=$LASTEXITCODE;Record @{pid=$id;kind='fixed_stop_proof';exit_code=$exit;output=($raw -join "`n")}
        if($exit -ne 0) { throw "Failed-start stop proof refused for $id." }
        $proof=($raw -join "`n") | ConvertFrom-Json
        if(-not $proof.stopped -or -not $proof.never_started -or $proof.unload_safe -ne 1) { throw "Unload safety not confirmed for known failed start $id." }
        # Recheck creation time immediately before the separate generic loader.
        if((Get-Process -Id $id).StartTime.ToUniversalTime() -ne $recordedStart) { throw 'PID changed before failed-start cleanup.' }
        $output=& $injector --process-id ([string]$id) --eject $probe 2>&1
        $exit=$LASTEXITCODE;Record @{pid=$id;kind='known_failed_start_eject';exit_code=$exit;output=($output -join "`n")}
        if($exit -ne 0) { throw "Known failed-start cleanup failed for $id." }
    }
    Record @{kind='complete';success=$true;timestamp_utc=[DateTime]::UtcNow.ToString('o')}
    exit 0
} catch { Record @{kind='blocked';success=$false;error=$_.Exception.Message;timestamp_utc=[DateTime]::UtcNow.ToString('o')}; exit 1 }
