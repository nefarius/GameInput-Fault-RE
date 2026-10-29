[CmdletBinding()]
param(
    [string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputResults',
    [ValidateRange(1,90)][int]$SessionMinutes=45,
    [switch]$CompileOnly
)
$ErrorActionPreference='Stop'
$nativeScript=Join-Path $PSScriptRoot 'Measure-XInputState.ps1'
$nativeHashAtStart=(Get-FileHash -LiteralPath $nativeScript).Hash.ToLowerInvariant()
$runnerHashAtStart=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
& $nativeScript -CompileOnly
if ((Get-FileHash -LiteralPath $nativeScript).Hash.ToLowerInvariant() -ne $nativeHashAtStart) { throw 'Native source changed during initialization.' }
if ($CompileOnly) { Write-Output 'Runner parsed; no VM session started.'; return }
if ([IntPtr]::Size -ne 4 -or -not [Environment]::Is64BitOperatingSystem) { throw 'Start the runner in x86 Windows PowerShell on the prepared x64 guest.' }
$driver=Join-Path $env:SystemRoot 'Sysnative\drivers\xinputhid.sys'
$expectedDll=Join-Path $env:SystemRoot 'SysWOW64\XInput1_4.dll'
$driverPin='c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f'
$dllPin='afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d'
function Test-Pins {
    if ((Get-FileHash -LiteralPath $nativeScript).Hash.ToLowerInvariant() -ne $nativeHashAtStart -or
        (Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $runnerHashAtStart) { throw 'Runner source changed; restart in a fresh process.' }
    if ((Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant() -ne $driverPin -or
        (Get-FileHash -LiteralPath $expectedDll).Hash.ToLowerInvariant() -ne $dllPin) { throw 'Research binary identity mismatch.' }
}
Test-Pins
$loadedDll=[GameInputStateResearch.Benchmark]::Load($expectedDll)
if (-not [GameInputStateResearch.Benchmark]::SameFile($loadedDll,$expectedDll) -or
    (Get-FileHash -LiteralPath $loadedDll).Hash.ToLowerInvariant() -ne $dllPin) { throw 'Loaded XInput identity mismatch.' }
[GameInputStateResearch.Benchmark]::Bind()

function Write-Record([string]$Path,$Value) {
    # A completed record is immutable. Publish by rename to avoid partial reads.
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$Path)
}
function Get-Integer($Value,[int]$Default,[int]$Minimum,[int]$Maximum) {
    if ($null -eq $Value) { return $Default }
    $number=0
    if (-not [int]::TryParse([string]$Value,[ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) { throw 'Command integer out of range.' }
    return $number
}
function Get-Inventory {
    Test-Pins
    if (-not [GameInputStateResearch.Benchmark]::SameFile($loadedDll,$expectedDll) -or
        (Get-FileHash -LiteralPath $loadedDll).Hash.ToLowerInvariant() -ne $dllPin) { throw 'Loaded backing identity changed.' }
    $version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return [ordered]@{
        processId=$PID; architecture='x86'; osBuild=$version.CurrentBuild; osUBR=$version.UBR
        driverSha256=$driverPin; loadedXInputPath=$loadedDll; loadedXInputBackingSha256=$dllPin
        loadedXInputSameFileAsExpected=$true
        nativeScriptSha256=$nativeHashAtStart
        runnerSha256=$runnerHashAtStart
        qpcFrequency=[Diagnostics.Stopwatch]::Frequency
        services=@(Get-CimInstance Win32_Service -Filter "Name LIKE 'GameInput%'" | Select-Object Name,State,StartMode,ProcessId)
    }
}
function Read-InputWindow([uint32]$Slot,[int]$Milliseconds) {
    $rows=New-Object 'Collections.Generic.List[object]'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds -and $rows.Count -lt 200) {
        $sample=[GameInputStateResearch.Benchmark]::ReadInput($Slot)
        $rows.Add([pscustomobject]@{elapsedMilliseconds=$clock.Elapsed.TotalMilliseconds; sample=$sample})
        Start-Sleep -Milliseconds 10
    }
    return [pscustomobject]@{elapsedMilliseconds=$clock.Elapsed.TotalMilliseconds; rows=$rows.ToArray()}
}

$sessionId=[guid]::NewGuid().ToString('N')
$directory=Join-Path $ResultsRoot $sessionId
[void][IO.Directory]::CreateDirectory($directory)
$initial=@(0..3 | ForEach-Object { [GameInputStateResearch.Benchmark]::ReadSingle([uint32]$_) })
$ready=[ordered]@{schemaVersion=1; sessionId=$sessionId; startedUtc=[DateTime]::UtcNow.ToString('o'); inventory=(Get-Inventory); initialSlots=$initial; sessionMinutes=$SessionMinutes; maxCommands=64}
Write-Record (Join-Path $directory 'session.ready.json') $ready
Write-Host "VM validation ready. Session $sessionId, PID $PID. Leave this window open."
Write-Host 'The host can request only route, benchmark, input, rumble, observe or stop cases. Physical-action cases prompt here.'
$seen=New-Object 'Collections.Generic.HashSet[string]'
$motorSlots=New-Object 'Collections.Generic.HashSet[uint32]'
$sessionClock=[Diagnostics.Stopwatch]::StartNew()
$endReason='session_timeout'
$stop=$false
$fatal=$null
try {
    while (-not $stop -and $seen.Count -lt 64 -and $sessionClock.Elapsed.TotalMinutes -lt $SessionMinutes) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.command.json' -File | Sort-Object Name)) {
            if ($seen.Count -ge 64 -or $sessionClock.Elapsed.TotalMinutes -ge $SessionMinutes) { break }
            if ($seen.Contains($file.Name)) { continue }
            # Host commands must be atomically published JSON, never executable text.
            try { $command=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($command.sessionId -ne $sessionId) { continue }
            $id=[string]$command.id
            if ($id -notmatch '^[a-z0-9-]{1,48}$') { continue }
            if ($command.kind -notin @('route','benchmark','input','rumble','observe','stop')) { continue }
            [void]$seen.Add($file.Name)
            $record=[ordered]@{
                schemaVersion=1; sessionId=$sessionId; id=$id; kind=$command.kind
                condition=[string]$command.condition; startedUtc=[DateTime]::UtcNow.ToString('o')
                timingEligible=($command.kind -eq 'benchmark'); status='started'; data=[ordered]@{}
            }
            try {
                $record.inventoryBefore=Get-Inventory
                Write-Record (Join-Path $directory ($id+'.started.json')) $record
                $slot=[uint32](Get-Integer $command.slot 0 0 3)
                switch ($command.kind) {
                    'route' {
                        $record.timingEligible=$false
                        $record.data.slot=$slot
                        $record.data.sample=[GameInputStateResearch.Benchmark]::ReadSingle($slot)
                        $record.data.note='Separate debugger observation; elapsed API ticks are contaminated if stopped and are not benchmark data.'
                    }
                    'benchmark' {
                        $cycles=Get-Integer $command.cycles 100 1 100
                        $seconds=Get-Integer $command.seconds 5 1 5
                        $record.data.requestedCycles=$cycles; $record.data.requestedSeconds=$seconds
                        $record.data.measurement=[GameInputStateResearch.Benchmark]::Run($cycles,$seconds)
                    }
                    'observe' {
                        $record.data.slots=@(0..3 | ForEach-Object { [GameInputStateResearch.Benchmark]::ReadInput([uint32]$_) })
                    }
                    'input' {
                        $instructions=@{
                            neutral='Release buttons, triggers and sticks.'
                            'hold-a'='Hold the A/Cross button.'
                            'hold-b'='Hold the B/Circle button.'
                            'hold-up'='Hold D-pad Up.'
                            'left-trigger'='Hold the left trigger fully.'
                            'left-stick'='Hold the left stick fully to the right.'
                            'right-stick'='Hold the right stick fully to the right.'
                        }
                        if (-not $instructions.ContainsKey([string]$command.phase)) { throw 'Unknown physical input phase.' }
                        $record.data.requestedPhase=[string]$command.phase
                        $record.data.requestedAction=$instructions[[string]$command.phase]
                        $answer=Read-Host ($record.data.requestedAction+' Type READY when doing this')
                        $record.data.operatorReadyText=$answer
                        if ($answer -ne 'READY') { throw 'Operator did not report ready; no input window collected.' }
                        $record.data.window=Read-InputWindow $slot (Get-Integer $command.milliseconds 2000 100 2000)
                        $record.data.operatorReport=Read-Host 'What did you actually hold or move? A short description or uncertain'
                    }
                    'rumble' {
                        $left=Get-Integer $command.left 8192 0 16384
                        $right=Get-Integer $command.right 8192 0 16384
                        $answer=Read-Host "Hold the controller to observe 0.5-second vibration (left $left, right $right). Type READY to begin"
                        $record.data.operatorReadyText=$answer
                        if ($answer -ne 'READY') { throw 'Operator did not report ready; no vibration requested.' }
                        $record.data.before=[GameInputStateResearch.Benchmark]::ReadInput($slot)
                        if ($record.data.before.Result -ne 0) { throw 'Selected controller slot is not connected.' }
                        [void]$motorSlots.Add($slot)
                        try {
                            $record.data.requestedLeft=$left; $record.data.requestedRight=$right
                            $record.data.startResult=[GameInputStateResearch.Benchmark]::SetVibration($slot,[uint16]$left,[uint16]$right)
                            $record.data.during=Read-InputWindow $slot 500
                        } finally {
                            $record.data.stopAttempted=$true
                            $record.data.stopResult=[GameInputStateResearch.Benchmark]::SetVibration($slot,0,0)
                            if ($record.data.stopResult -eq 0) { [void]$motorSlots.Remove($slot) }
                        }
                        $record.data.after=Read-InputWindow $slot 500
                        $record.data.operatorObservation=Read-Host 'Did vibration physically start and fully stop? yes, no or uncertain; include which motors if known'
                    }
                    'stop' { $stop=$true; $endReason='host_requested_stop' }
                }
                $record.inventoryAfter=Get-Inventory
                $record.status='completed'
            } catch {
                $record.status='failed'; $record.error=$_.Exception.Message
            }
            $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
            Write-Record (Join-Path $directory ($id+'.result.json')) $record
            Write-Host "Completed $id ($($record.status))."
            if ($stop) { break }
        }
        if (-not $stop) { Start-Sleep -Milliseconds 250 }
    }
    if ($seen.Count -ge 64 -and -not $stop) { $endReason='command_limit' }
} catch {
    $endReason='runner_failure'; $fatal=$_.Exception.Message; throw
} finally {
    $cleanup=@()
    foreach ($slot in $motorSlots) {
        try { $cleanup += [pscustomobject]@{slot=$slot; stopResult=[GameInputStateResearch.Benchmark]::SetVibration($slot,0,0)} }
        catch { $cleanup += [pscustomobject]@{slot=$slot; error=$_.Exception.Message} }
    }
    Write-Record (Join-Path $directory 'session.ended.json') @{sessionId=$sessionId; reason=$endReason; fatalError=$fatal; finishedUtc=[DateTime]::UtcNow.ToString('o'); motorStopAttempts=$cleanup; completedOrFailedCommands=$seen.Count}
}
