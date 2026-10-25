#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Collector.Common.ps1')
$issues = [Collections.Generic.List[object]]::new()
$files = @{}

function Add-InventoryIssue {
    param([string]$Area, [string]$Message)
    $issues.Add([pscustomobject]@{ Area = $Area; Message = $Message })
}

function Get-CimInventory {
    param([string]$Class, [string]$Filter = '')
    try {
        if ($Filter) { Get-CimInstance -ClassName $Class -Filter $Filter -OperationTimeoutSec 15 -ErrorAction Stop }
        else { Get-CimInstance -ClassName $Class -OperationTimeoutSec 15 -ErrorAction Stop }
    } catch { Add-InventoryIssue $Class $_.Exception.Message }
}

function Add-BinaryIdentity {
    param([string]$Path, [string]$Source)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $expanded = Join-Path $env:SystemRoot $expanded.Substring(12)
    }
    if ($expanded.StartsWith('\??\')) { $expanded = $expanded.Substring(4) }
    if ($expanded -match '^(?i)system32\\') { $expanded = Join-Path $env:SystemRoot $expanded }
    if ($files.ContainsKey($expanded)) {
        $files[$expanded].Sources = @($files[$expanded].Sources) + $Source
        return
    }
    $record = [ordered]@{ Path = $expanded; Sources = @($Source); Exists = $false; SHA256 = $null;
        FileVersion = $null; ProductVersion = $null; SignatureStatus = $null; Signer = $null;
        SignerThumbprint = $null; SignatureNote = 'Authenticode status is not a compatibility or trust allowlist.'; Error = $null }
    try {
        $item = Get-Item -LiteralPath $expanded -ErrorAction Stop
        $record.Exists = $true
        $record.FileVersion = $item.VersionInfo.FileVersion
        $record.ProductVersion = $item.VersionInfo.ProductVersion
        $record.SHA256 = (Get-FileHash -LiteralPath $expanded -Algorithm SHA256).Hash
        $signature = Get-AuthenticodeSignature -LiteralPath $expanded
        $record.SignatureStatus = $signature.Status.ToString()
        if ($signature.SignerCertificate) {
            $record.Signer = $signature.SignerCertificate.Subject
            $record.SignerThumbprint = $signature.SignerCertificate.Thumbprint
        }
    } catch { $record.Error = $_.Exception.Message; Add-InventoryIssue 'BinaryIdentity' "$expanded : $($_.Exception.Message)" }
    $files[$expanded] = [pscustomobject]$record
}

function Get-ServiceImagePath {
    param([string]$CommandLine)
    # Parse a path as data. Never execute service ImagePath or its arguments.
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine)
    if ($expanded -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($expanded -match '^\s*(.+?\.(?:exe|sys|dll))(?=\s|$)') { return $Matches[1] }
    return $expanded
}

$inventory = [ordered]@{
    SchemaVersion = 1; StartedUtc = [DateTime]::UtcNow.ToString('o')
    Elevated = (Test-CollectorAdministrator); PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    ProcessArchitecture = $env:PROCESSOR_ARCHITECTURE
    OS = $null; Services = @(); Processes = @(); ModuleEnumerationFailures = @()
    PnPDevices = @(); PnPDrivers = @(); SystemDrivers = @(); RedistPackages = @()
    Power = [ordered]@{}; Timer = [ordered]@{
        CurrentResolution100ns = $null
        Status = 'Unavailable: no supported built-in read-only CLI for an instantaneous system timer-resolution snapshot.'
        TraceContext = 'WPR Timer/Power keywords and optional Kernel-Power events may expose resolution changes; WPR -profint is the CPU sampling interval, NOT timer resolution.'
    }; Binaries = @(); Issues = @(); FinishedUtc = $null
}

try {
    $os = Get-CimInventory 'Win32_OperatingSystem' | Select-Object -First 1
    $version = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $inventory.OS = [ordered]@{
        Caption = $(if ($os) { $os.Caption } else { $null }); Version = $version.CurrentBuild
        BuildNumber = $version.CurrentBuildNumber; UBR = $version.UBR; DisplayVersion = $version.DisplayVersion
        EditionID = $version.EditionID; InstallationType = $version.InstallationType
        OSArchitecture = $(if ($os) { $os.OSArchitecture } else { $null })
        LastBootUpTime = $(if ($os) { $os.LastBootUpTime.ToUniversalTime().ToString('o') } else { $null })
    }
    foreach ($relative in @('System32\GameInput.dll', 'System32\GameInputRedist.dll',
        'System32\GameInputSvc.exe', 'System32\drivers\xinputhid.sys', 'SysWOW64\GameInput.dll', 'SysWOW64\GameInputRedist.dll')) {
        Add-BinaryIdentity (Join-Path $env:SystemRoot $relative) 'Known Windows location'
    }

    $services = @(Get-CimInventory 'Win32_Service' | Where-Object {
        $_.Name -match 'GameInput' -or $_.PathName -match 'GameInput'
    })
    foreach ($expected in @('GameInputSvc', 'GameInputRedistService')) {
        if (-not @($services | Where-Object { $_.Name -eq $expected }).Count) {
            Add-InventoryIssue 'Services' "$expected was not found (service naming varies by redist version)."
        }
    }
    $inventory.Services = @($services | Select-Object Name, DisplayName, State, Status, StartMode,
        ProcessId, PathName, StartName, ServiceType, ExitCode)
    $sc = Get-SystemTool 'sc.exe'
    foreach ($service in $services) {
        Add-BinaryIdentity (Get-ServiceImagePath $service.PathName) "Service $($service.Name)"
        foreach ($verb in @('qc', 'queryex', 'qfailure', 'qtriggerinfo')) {
            $record = Invoke-CollectorCommand $sc @($verb, $service.Name) 10
            # Service names originate in SCM; sanitize only the output filename.
            $safeName = $service.Name -replace '[^a-zA-Z0-9_.-]', '_'
            Write-CollectorJson (Join-Path $RunDirectory "service-$safeName-$verb.json") $record
        }
    }

    $moduleFailures = [Collections.Generic.List[object]]::new()
    $processRecords = [Collections.Generic.List[object]]::new()
    foreach ($process in Get-Process) {
        try {
            $modules = @($process.Modules | Where-Object { $_.ModuleName -match '^GameInput.*\.(dll|exe)$' })
            if ($modules.Count -gt 0 -or $process.ProcessName -match '^(GameInput.*|WUDFHost)$') {
                $loaded = @($modules | Select-Object ModuleName, FileName, ModuleMemorySize)
                foreach ($module in $modules) { Add-BinaryIdentity $module.FileName "Loaded in PID $($process.Id)" }
                $cpu = $null
                try { $cpu = $process.TotalProcessorTime.TotalSeconds } catch { }
                $processRecords.Add([pscustomobject]@{ Id = $process.Id; Name = $process.ProcessName;
                    SessionId = $process.SessionId; CpuSeconds = $cpu; GameInputModules = $loaded })
            }
        } catch {
            $moduleFailures.Add([pscustomobject]@{ Id = $process.Id; Name = $process.ProcessName; Error = $_.Exception.Message })
        }
    }
    $inventory.Processes = @($processRecords.ToArray())
    $inventory.ModuleEnumerationFailures = @($moduleFailures.ToArray())

    $devices = @(Get-CimInventory 'Win32_PnPEntity' | Where-Object {
        $_.PNPClass -match '^(HIDClass|XboxComposite|XnaComposite)$' -or
        $_.Name -match 'XInput|Xbox|Game.?Controller|DsHidMini|DualShock' -or $_.Service -match 'xinput|dshidmini'
    })
    $inventory.PnPDevices = @($devices | Select-Object Name, Manufacturer, PNPClass, PNPDeviceID,
        Service, Status, ConfigManagerErrorCode, Present, HardwareID, CompatibleID)
    $deviceIds = @{}
    foreach ($device in $devices) { if ($device.PNPDeviceID) { $deviceIds[$device.PNPDeviceID] = $true } }
    $inventory.PnPDrivers = @(Get-CimInventory 'Win32_PnPSignedDriver' | Where-Object {
        ($_.DeviceID -and $deviceIds.ContainsKey($_.DeviceID)) -or $_.DeviceName -match 'XInput|Xbox|DsHidMini|GameInput'
    } | Select-Object DeviceName, DeviceID, DriverVersion, DriverDate, DriverProviderName, InfName, IsSigned, Signer, DriverName)
    $drivers = @(Get-CimInventory 'Win32_SystemDriver' | Where-Object {
        $_.Name -match 'xinput|xusb|dshid|hidclass|hidusb|mshid|wudf|bthps3'
    })
    $inventory.SystemDrivers = @($drivers | Select-Object Name, DisplayName, State, StartMode, PathName)
    foreach ($driver in $drivers) { Add-BinaryIdentity (Get-ServiceImagePath $driver.PathName) "Driver $($driver.Name)" }

    $packages = [Collections.Generic.List[object]]::new()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $package = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($package -and $package.PSObject.Properties['DisplayName'] -and $package.DisplayName -match 'GameInput') {
                $packages.Add(($package | Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, InstallDate))
            }
        }
    }
    $inventory.RedistPackages = @($packages.ToArray())
    # Only known GameInput directories, with bounded depth; no drive-wide search.
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programRoot) { continue }
        $root = Join-Path $programRoot 'Microsoft GameInput'
        if (Test-Path -LiteralPath $root) {
            $directories = @((Get-Item -LiteralPath $root))
            for ($depth = 0; $depth -le 3; $depth++) {
                $next = @()
                foreach ($directory in $directories) {
                    foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File -ErrorAction SilentlyContinue) {
                        if ($file.Name -match '^GameInput.*\.(dll|exe)$') { Add-BinaryIdentity $file.FullName 'Program Files GameInput directory' }
                    }
                    $next += @(Get-ChildItem -LiteralPath $directory.FullName -Directory -ErrorAction SilentlyContinue |
                        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
                }
                $directories = $next
            }
        }
    }
    foreach ($query in @(@('active', '/getactivescheme'), @('settings', '/query'), @('requests', '/requests'))) {
        $inventory.Power[$query[0]] = Invoke-CollectorCommand (Get-SystemTool 'powercfg.exe') @($query[1]) 15
    }
    $inventory.Timer['CpuSamplingIntervalQuery'] = Invoke-CollectorCommand (Get-SystemTool 'wpr.exe') @('-profint') 10
} catch {
    Add-InventoryIssue 'Inventory' $_.Exception.Message
} finally {
    $inventory.Binaries = @($files.Values | Sort-Object Path)
    $inventory.Issues = @($issues.ToArray())
    $inventory.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    Write-CollectorJson (Join-Path $RunDirectory 'inventory.json') $inventory
}
