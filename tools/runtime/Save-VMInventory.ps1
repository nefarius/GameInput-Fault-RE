[CmdletBinding()]
param([string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputResults')
$ErrorActionPreference='Stop'
if ([IntPtr]::Size -ne 8) { throw 'Run in native x64 Windows PowerShell.' }
# Read-only inventory. Raw device identifiers and paths remain in private results.
function Get-FileRecord([string]$Path) {
    try {
        $file=Get-Item -LiteralPath $Path -ErrorAction Stop
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        $pe=[BitConverter]::ToInt32($bytes,0x3c)
        [ordered]@{path=$file.FullName; sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            fileVersion=$file.VersionInfo.FileVersion; productVersion=$file.VersionInfo.ProductVersion
            peTimestamp=('{0:x8}' -f [BitConverter]::ToUInt32($bytes,$pe+8))
            imageSize=[BitConverter]::ToUInt32($bytes,$pe+24+56)
            checksum=[BitConverter]::ToUInt32($bytes,$pe+24+64); error=$null}
    } catch { [ordered]@{path=$Path; error=$_.Exception.Message} }
}
$files=@('System32\drivers\xinputhid.sys','System32\drivers\Wdf01000.sys',
    'System32\drivers\mshidumdf.sys','System32\GameInputInbox.dll',
    'System32\GameInputSvc.exe','SysWOW64\XInput1_4.dll') |
    ForEach-Object { Get-FileRecord (Join-Path $env:WINDIR $_) }
$modules=@(foreach ($process in @(Get-Process -Name GameInputSvc,WUDFHost -ErrorAction SilentlyContinue)) {
    try {
        $matching=@($process.Modules | Where-Object { $_.ModuleName -match 'GameInput|DsHidMini|XInput' })
        [ordered]@{processId=$process.Id; processName=$process.ProcessName; error=$null
            modules=@($matching | ForEach-Object { Get-FileRecord $_.FileName })}
    } catch { [ordered]@{processId=$process.Id; processName=$process.ProcessName; error=$_.Exception.Message} }
})
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$record=[ordered]@{
    schemaVersion=1; collectedUtc=[DateTime]::UtcNow.ToString('o'); architecture='x64'
    build=$version.CurrentBuild; ubr=$version.UBR; files=@($files); processes=$modules
    devices=@(Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'PLAYSTATION|DualShock|DsHidMini|XINPUT' -or $_.Service -match 'dshidmini|xinputhid' } | Select-Object Name,Service,Status,ConfigManagerErrorCode,DeviceID)
    signedDrivers=@(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'PLAYSTATION|DsHidMini|XINPUT' -or $_.DriverProviderName -match 'Nefarius' } | Select-Object DeviceName,DeviceID,DriverVersion,DriverDate,DriverProviderName,InfName,IsSigned)
    services=@(Get-CimInstance Win32_Service -Filter "Name LIKE 'GameInput%'" | Select-Object Name,State,StartMode,ProcessId)
}
$path=Join-Path $ResultsRoot ('inventory-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')+'.json')
$temporary=$path+'.tmp'
[IO.File]::WriteAllText($temporary,($record | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
[IO.File]::Move($temporary,$path)
Write-Output "Saved read-only inventory to $path"
