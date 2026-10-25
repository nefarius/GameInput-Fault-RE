Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ResearchRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:ExpectedModules = @{
    'GameInput.dll' = @{ version='0.2309.26100.9278'; sha256='f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6' }
    'GameInputRedist.dll' = @{ version='3.5.270.0'; sha256='6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686' }
}
$script:ExpectedImages = @{
    'GameInputSvc.exe' = @{ version='0.2309.26100.9278'; sha256='83ba5166dd6397ade67f4b6fddae6be61a694f487ed88ea83ee204f20be6d075' }
    'GameInputRedistService.exe' = @{ version='3.5.270.0'; sha256='1cd8e575f585de38d64b71b5a63a55ba4522d2f47e633091b660b81755db6b3b' }
}
function Initialize-ResearchInterop {
    if ('GameInputResearch.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace GameInputResearch {
 public static class Native {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsWow64Process2(IntPtr handle, out ushort processMachine, out ushort nativeMachine);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr handle, int kind, out uint level, uint size);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
  [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref Privileges state, uint length, IntPtr previous, IntPtr required);
  public static void EnableDebug() {
   IntPtr token;
   if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,"Open debug token"); }
   try {
    Privileges state=new Privileges(); state.Count=1; state.Attributes=2;
    if(!LookupPrivilegeValue(null,"SeDebugPrivilege",out state.Luid)) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,"Lookup debug privilege"); }
    bool okay=AdjustTokenPrivileges(token,false,ref state,0,IntPtr.Zero,IntPtr.Zero);
    int result=Marshal.GetLastWin32Error();
    if(!okay || result!=0) throw new Win32Exception(result,"Enable debug privilege; administrator elevation required");
   } finally { CloseHandle(token); }
  }
  public static string[] Inspect(int pid) {
   var h=OpenProcess(0x1000,false,pid);
   if(h==IntPtr.Zero) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,"OpenProcess query"); }
   try {
    ushort processMachine,nativeMachine;
    if(!IsWow64Process2(h,out processMachine,out nativeMachine)) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,"IsWow64Process2"); }
    uint level;
    if(!GetProcessInformation(h,7,out level,4)) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,"GetProcessInformation protection"); }
    return new[]{processMachine==0 && nativeMachine==0x8664 ? "x64" : "unsupported",level==0xfffffffe ? "NONE" : "PROTECTED-"+level.ToString("x8")};
   } finally { CloseHandle(h); }
  }
 }
}
'@
}
function Test-ResearchAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}
function Enable-ResearchDebugPrivilege {
    if (-not (Test-ResearchAdministrator)) { throw 'Administrator elevation required to enable SeDebugPrivilege.' }
    Initialize-ResearchInterop
    [GameInputResearch.Native]::EnableDebug()
}
function Get-ResearchFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $microsoft = $signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
    $version = $file.VersionInfo
    [pscustomobject]@{
        path=$file.FullName; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        version=('{0}.{1}.{2}.{3}' -f $version.FileMajorPart,$version.FileMinorPart,$version.FileBuildPart,$version.FilePrivatePart)
        signature_status=[string]$signature.Status; microsoft_signed=[bool]$microsoft
        signer=$(if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null })
    }
}
function Get-ResearchTargets {
    Initialize-ResearchInterop
    # Get-Process enumerates ALL matches. Never use Injector --process-name.
    $processes = @(Get-Process -Name GameInputSvc,GameInputRedistService -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        $target = [ordered]@{ pid=$process.Id; image_name=($process.ProcessName+'.exe'); image_path=$null; start_time_utc=$null; architecture=$null; protection=$null; image=$null; modules=@(); eligible=$false; inactive_host=$false; blocked_reasons=@() }
        try {
            $target.image_path = $process.Path
            if ([string]::IsNullOrEmpty($target.image_path)) { throw 'Process path unavailable; elevation may be required.' }
            if ($null -eq $process.StartTime) { throw 'Process creation time unavailable; elevation may be required.' }
            $target.start_time_utc = $process.StartTime.ToUniversalTime().ToString('o')
            $inspection = [GameInputResearch.Native]::Inspect($process.Id)
            $target.architecture = $inspection[0]; $target.protection = $inspection[1]
            if ($target.architecture -ne 'x64') { throw 'Only native x64 targets are supported.' }
            if ($target.protection -ne 'NONE') { throw 'Protected processes are refused.' }
            $system = [Environment]::GetFolderPath('System')
            $redistDir = Join-Path $env:ProgramFiles 'Microsoft GameInput/x64'
            $expectedImage = if ($target.image_name -ieq 'GameInputSvc.exe') { Join-Path $system 'GameInputSvc.exe' } else { Join-Path $redistDir 'GameInputRedistService.exe' }
            if ($target.image_path -ine $expectedImage) { throw 'Process executable path is outside the exact GameInput allowlist.' }
            $target.image = Get-ResearchFileIdentity $target.image_path
            if (-not $target.image.microsoft_signed) { throw 'Process executable lacks a valid Microsoft signature.' }
            $expectedImageIdentity = $script:ExpectedImages[$target.image_name]
            if ($target.image.sha256 -ine $expectedImageIdentity.sha256 -or $target.image.version -ne $expectedImageIdentity.version) { throw 'Process executable hash/version is outside the exact research allowlist.' }
            # Inspect modules actually mapped in this PID, rather than assuming a service DLL path.
            $loaded = @($process.Modules | Where-Object { $script:ExpectedModules.ContainsKey($_.ModuleName) })
            if ($loaded.Count -eq 0) { $target.inactive_host=$true; throw 'Inactive host: no GameInput core DLL loaded; skipped without injection.' }
            foreach ($module in $loaded) {
                $identity = Get-ResearchFileIdentity $module.FileName
                $identity | Add-Member -NotePropertyName base_address -NotePropertyValue ('0x{0:x}' -f $module.BaseAddress.ToInt64())
                $identity | Add-Member -NotePropertyName image_size -NotePropertyValue $module.ModuleMemorySize
                $target.modules += $identity
                $expected = $script:ExpectedModules[$module.ModuleName]
                $allowedPaths = if ($module.ModuleName -ieq 'GameInput.dll') { @((Join-Path $system 'GameInput.dll')) } else { @((Join-Path $system 'GameInputRedist.dll'),(Join-Path $redistDir 'GameInputRedist.dll')) }
                if ($module.FileName -inotIn $allowedPaths -or -not $identity.microsoft_signed -or $identity.sha256 -ine $expected.sha256 -or $identity.version -ne $expected.version) {
                    throw "Loaded $($module.ModuleName) does not match path, Microsoft signature, pinned SHA256 and version."
                }
            }
            $requiredModule = if ($target.image_name -ieq 'GameInputSvc.exe') { 'GameInput.dll' } else { 'GameInputRedist.dll' }
            if (@($loaded | Where-Object ModuleName -IEQ $requiredModule).Count -eq 0) { $target.inactive_host=$true; throw "Inactive host: required loaded $requiredModule is absent; skipped without injection." }
            # Avoid using an inventory result for a PID which exited/recycled during inspection.
            $fresh = Get-Process -Id $process.Id -ErrorAction Stop
            if ($fresh.StartTime.ToUniversalTime().ToString('o') -ne $target.start_time_utc) { throw 'Process identity changed during inventory.' }
            $target.eligible = $true
        } catch { $target.blocked_reasons += $_.Exception.Message }
        [pscustomobject]$target
    }
}
function Get-ResearchInjector {
    $archive = Join-Path $script:ResearchRoot '.deps/Injector-v1.5.0.zip'
    $exe = Join-Path $script:ResearchRoot '.deps/Injector-v1.5.0/x64/Injector.exe'
    if (-not (Test-Path -LiteralPath $archive) -or -not (Test-Path -LiteralPath $exe)) { throw 'Run tools/dependencies/Get-ResearchDependencies.ps1 explicitly before attach.' }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine 'ae8729976ae97cc068813ec67981833f26cf92b5cde0ffe16c01b7b44e346a38') { throw 'Pinned Injector archive hash mismatch.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.GetEntry('x64/Injector.exe')
        if ($null -eq $entry) { throw 'Pinned archive lacks x64/Injector.exe.' }
        $stream = $entry.Open(); $hash = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','') } finally { $stream.Dispose(); $hash.Dispose() }
        if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ine $expected) { throw 'Extracted Injector differs from the authenticated archive.' }
    } finally { $zip.Dispose() }
    return $exe
}
function Invoke-ResearchController {
    param([Parameter(Mandatory)][int]$TargetId,[Parameter(Mandatory)][ValidateSet('start','stop','snapshot','observe','mitigate','verify')][string]$Action)
    $controller = Join-Path $script:ResearchRoot 'tools/build/out/bin/Release/GameInputProbeController.exe'
    if (-not (Test-Path -LiteralPath $controller)) { throw 'Build the native x64 Release probe/controller first with tools/build/build.ps1.' }
    $output = & $controller --pid ([string]$TargetId) --action $Action 2>&1
    $exit = $LASTEXITCODE
    $raw = $output -join "`n"
    if ($exit -ne 0) { throw "Controller $Action failed (exit $exit): $raw" }
    return ($raw | ConvertFrom-Json)
}
Export-ModuleMember -Function Get-ResearchTargets,Test-ResearchAdministrator,Enable-ResearchDebugPrivilege,Get-ResearchInjector,Invoke-ResearchController
