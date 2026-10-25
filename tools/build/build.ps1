[CmdletBinding()]
param(
    [ValidateSet('Debug','Release','RelWithDebInfo')][string]$Configuration = 'Release',
    [switch]$PolicyOnly,
    [switch]$ConfigureOnly
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Installed vswhere is required; no toolchain will be downloaded.' }
$vs = & $vswhere -latest -products Microsoft.VisualStudio.Product.Professional Microsoft.VisualStudio.Product.Enterprise Microsoft.VisualStudio.Product.Community Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Installed Visual Studio C++ x64 toolchain required.' }
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ctest = Join-Path (Split-Path $cmake) 'ctest.exe'
$cl = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe') | Sort-Object FullName -Descending | Select-Object -First 1
if (-not (Test-Path -LiteralPath $cmake) -or -not $cl) { throw 'Installed CMake and x64 cl.exe required.' }
Write-Host "Using $cmake"
Write-Host "Installed compiler $($cl.FullName)"
$out = Join-Path $PSScriptRoot 'out'
if ($PolicyOnly) { $out = Join-Path $PSScriptRoot 'out-policy' }
$probe = if ($PolicyOnly) { 'OFF' } else { 'ON' }
& $cmake -S $root -B $out -G 'Visual Studio 18 2026' -A x64 "-DCMAKE_GENERATOR_INSTANCE=$vs" "-DGAMEINPUT_BUILD_PROBE=$probe" -DBUILD_TESTING=ON
if ($LASTEXITCODE) { throw "Configure failed ($LASTEXITCODE)." }
if ($ConfigureOnly) { return }
& $cmake --build $out --config $Configuration --parallel
if ($LASTEXITCODE) { throw "Build failed ($LASTEXITCODE)." }
& $ctest --test-dir $out -C $Configuration --output-on-failure
if ($LASTEXITCODE) { throw "Tests failed ($LASTEXITCODE)." }
