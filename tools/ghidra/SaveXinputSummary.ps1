#requires -Version 7.4
# Select literal Ghidra excerpts, and verify their instruction bytes against the PE file.
[CmdletBinding()]
param(
    [string]$Driver = 'C:\Windows\System32\drivers\xinputhid.sys',
    [string]$Pdb = (Join-Path $PSScriptRoot '..\..\symbols\XINPUTHID.pdb')
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ((Get-FileHash -LiteralPath $Driver).Hash -ne '1E85D1A191F09ED62645658C94F908B733DA5A026ED2B6B662635EBBDDF84588') {
    throw 'These address selections apply only to the investigated driver SHA256.'
}
if ((Get-FileHash -LiteralPath $Pdb).Hash -ne '050B38F56FDB1E11B33CBCF4817C3F470FC2402A45401CB7D79E3E5EB8F3D348') {
    throw 'These selections require the investigated public PDB SHA256.'
}
$pdbVerification = Get-Content -LiteralPath (Join-Path $repo 'artifacts\xinputhid-pdb-verify.log') -Raw
if ($pdbVerification -notmatch 'PDB GUID and age MATCH') { throw 'Missing PDB identity verification.' }
$out = Join-Path $repo 'evidence\static'
New-Item -ItemType Directory -Force $out | Out-Null
$driverBytes = [IO.File]::ReadAllBytes($Driver)
$pe = [BitConverter]::ToInt32($driverBytes, 0x3c)
$sectionCount = [BitConverter]::ToUInt16($driverBytes, $pe + 6)
$optionalSize = [BitConverter]::ToUInt16($driverBytes, $pe + 20)
$imageBase = [BitConverter]::ToUInt64($driverBytes, $pe + 24 + 24)
$sections = for ($n = 0; $n -lt $sectionCount; $n++) {
    $at = $pe + 24 + $optionalSize + 40 * $n
    [pscustomobject]@{
        Rva = [BitConverter]::ToUInt32($driverBytes, $at + 12)
        Size = [BitConverter]::ToUInt32($driverBytes, $at + 16)
        Raw = [BitConverter]::ToUInt32($driverBytes, $at + 20)
    }
}
$selected = @(
    @{ Dir='xinputhid-analysis'; Entry='14000eeec'; Ranges=@(@('14000f140','14000f146'),@('14000f172','14000f17d')); Slices=@(,@('      if (param_1 == 0x8000e388) {','      if (param_1 == 0x8000e3ac) {')) },
    @{ Dir='xinputhid-analysis'; Entry='14000d1d8'; Ranges=@(@('14000d21f','14000d23f'),@('14000d252','14000d2aa'),@('14000d2cb','14000d309'),@('14000d336','14000d377'),@('14000d3be','14000d414'),@('14000d512','14000d52a'),@('14000d5bf','14000d606')); Whole=$true },
    @{ Dir='xinputhid-analysis'; Entry='140004cd0'; Ranges=@(@('140004d04','140004d04'),@('140005535','14000555a'),@('1400058de','1400058e7')); Slices=@(@('LAB_140005535:','    if (*(short *)(lVar11 + 0xb4) != 0) {'),@('    uVar12 = 1;','}')) },
    @{ Dir='xinputhid-followup'; Entry='140009110'; Ranges=@(@('140009235','14000923c'),@('140009348','140009358'),@('1400097d5','14000982b'),@('1400098b0','1400098e7'),@('140009c31','140009c3d')); Slices=@(,@('  uVar2 = ParseAndLoadInputReportExt(param_4,pcVar6,local_c0);','  _Var9 = param_4[0x9c];')) },
    @{ Dir='xinputhid-analysis'; Entry='1400021d8'; Ranges=@(,@('1400022b4','1400022df')); Whole=$true },
    @{ Dir='xinputhid-analysis'; Entry='14000fcb0'; Ranges=@(,@('1400100c2','1400100e2')); Slices=@(,@('              if (p_Var9[0x178] == (_DEVICE_CONTEXT)0x0) {','              (**(code **)(WdfFunctions_01015 + 0x9e0))')) },
    @{ Dir='xinputhid-analysis'; Entry='140006ac4'; Ranges=@(,@('140006e45','140006e53')); Slices=@(,@('        lVar3 = HID_PerformOp(param_1,0,*(WDFMEMORY__ **)(param_1 + 0x50));','        if (-1 < lVar3) {')) },
    @{ Dir='xinputhid-analysis'; Entry='140006010'; Ranges=@(); Slices=@(,@('  lVar9 = *(longlong *)(param_1 + 0x180);','  if (param_1[400] == (_DEVICE_CONTEXT)0x0) {')) },
    @{ Dir='xinputhid-followup'; Entry='140006740'; Ranges=@(@('140006775','140006788'),@('1400067f4','140006801'),@('1400068a9','1400068cb'),@('14000693a','140006962')); Slices=@(@('  pWVar1 = *(WDFMEMORY__ **)(param_1 + 0x180);','  (**(code **)(WdfFunctions_01015 + 0x9e8))(WdfDriverGlobals);'),@('  if (*(longlong *)(param_1 + 0x180) == 0) {','    if (((undefined **)WPP_GLOBAL_Control != &WPP_GLOBAL_Control) &&')) }
)
$text = [Collections.Generic.List[string]]::new()
$text.Add('Literal excerpts from local headless Ghidra 12.1.3; not REA MCP Evidence and not original source.')
$text.Add('Ellipses and excerpt boundaries are editorial. WDF slot names are mapped separately from installed KMDF 1.15 headers.')
$text.Add('Decompiler types and argument counts are uncertain. Instruction bytes below were checked against the source PE.')
$text.Add('Driver SHA256: ' + (Get-FileHash -LiteralPath $Driver).Hash.ToLowerInvariant())
$manifestFiles = @()
$verified = 0
foreach ($selection in $selected) {
    $path = Join-Path $repo ('artifacts\' + $selection.Dir + '\' + $selection.Entry + '.txt')
    $lines = Get-Content -LiteralPath $path
    $marker = [Array]::IndexOf($lines, 'INSTRUCTIONS (analysis bytes, not runtime)')
    if ($marker -lt 0) { throw "Missing instruction section: $path" }
    $manifestFiles += [ordered]@{ path=$path.Substring($repo.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() }
    $text.Add('')
    $text.Add('=== ' + $lines[0] + ' ===')
    $text.Add($lines[1])
    $text.Add('Source export: ' + $manifestFiles[-1].path)
    $decomp = [Array]::FindIndex($lines, [Predicate[string]]{param($line) $line.StartsWith('DECOMPILATION completed=')})
    $text.AddRange([string[]]$lines[2..$decomp])
    if ($selection.Whole) {
        $text.AddRange([string[]]$lines[($decomp+1)..($marker-1)])
    } else {
        foreach ($slice in $selection.Slices) {
            $start = [Array]::IndexOf($lines, $slice[0], $decomp+1)
            $end = [Array]::IndexOf($lines, $slice[1], $start+1)
            if ($start -lt 0 -or $end -lt 0 -or $end -ge $marker) { throw "Missing excerpt boundary: $path / $slice" }
            $text.Add('[... literal pseudocode excerpt ...]')
            $text.AddRange([string[]]$lines[$start..($end-1)])
        }
    }
    foreach ($range in $selection.Ranges) {
        $text.Add('[... selected instruction range ' + $range[0] + '..' + $range[1] + ' ...]')
        $count = 0
        foreach ($line in $lines[($marker+1)..($lines.Length-1)]) {
            if ($line -notmatch '^([0-9a-f]+) ([0-9a-f]+) (.*?) \|') { continue }
            $va = [Convert]::ToUInt64($Matches[1],16)
            if ($va -lt [Convert]::ToUInt64($range[0],16) -or $va -gt [Convert]::ToUInt64($range[1],16)) { continue }
            $hex = $Matches[2]; $instruction = $Matches[3]; $rva = $va - $imageBase
            $section = @($sections | Where-Object { $rva -ge $_.Rva -and $rva -lt $_.Rva + $_.Size })
            if ($section.Count -ne 1) { throw "Ambiguous PE mapping: $line" }
            $offset = $section[0].Raw + $rva - $section[0].Rva
            $bytes = [Convert]::FromHexString($hex)
            for ($j=0; $j -lt $bytes.Length; $j++) {
                if ($driverBytes[$offset+$j] -ne $bytes[$j]) { throw "Source byte mismatch: $line" }
            }
            $text.Add(('{0:x} RVA=0x{1:x} file=0x{2:x} {3} {4}' -f $va,$rva,$offset,$hex,$instruction))
            $verified++; $count++
        }
        if ($count -eq 0) { throw "Empty instruction range: $range" }
    }
}
$header = 'C:\Program Files (x86)\Windows Kits\10\Include\wdf\kmdf\1.15\wdffuncenum.h'
$text.Add('')
$text.Add('=== WDF slot mapping from installed KMDF 1.15 wdffuncenum.h ===')
$slots = @(152,158,185,187,253,263,264,265,269,270,275,281,285,316,317,319,380)
foreach($line in (Get-Content -LiteralPath $header)) {
    if ($line -match '^\s+(Wdf\w+TableIndex) = (\d+),') {
        $index=[int]$Matches[2]
        if($index -in $slots) { $text.Add(('slot +0x{0:x} = index {1}: {2}' -f (8*$index),$index,$Matches[1])) }
    }
}
$excerptPath = Join-Path $out 'xinputhid-10.0.26100.9278-excerpts.txt'
[IO.File]::WriteAllLines($excerptPath,$text,[Text.UTF8Encoding]::new($false))
$manifest = [ordered]@{
    evidence_kind='local-ghidra-static-excerpts'; observed_date='2026-10-25'; runtime_observed=$false
    source=[ordered]@{ path=$Driver; sha256=(Get-FileHash -LiteralPath $Driver).Hash.ToLowerInvariant(); size_bytes=$driverBytes.Length; file_version=(Get-Item -LiteralPath $Driver).VersionInfo.FileVersion; image_base=('0x{0:x}' -f $imageBase) }
    pdb=[ordered]@{ path=[IO.Path]::GetFullPath($Pdb); sha256=(Get-FileHash -LiteralPath $Pdb).Hash.ToLowerInvariant(); guid='f482d0de-64e0-3d63-a8b2-d58e868db1e5'; age=1; identity_verification='artifacts/xinputhid-pdb-verify.log: PE/file GUID and age MATCH' }
    tool=[ordered]@{ ghidra_version='12.1.3'; java='Temurin 25.0.4.1+1'; language='x86:LE:64:default'; compiler_spec='windows'; route='headless CLI; no MCP configuration edits' }
    wdf_header=[ordered]@{ path=$header; sha256=(Get-FileHash -LiteralPath $header).Hash.ToLowerInvariant(); pointer_size=8; mapping_basis='table index multiplied by 8; names not resolved by decompiler' }
    verified_instruction_count=$verified; exports=$manifestFiles
    excerpt=[ordered]@{ path='evidence/static/xinputhid-10.0.26100.9278-excerpts.txt'; sha256=(Get-FileHash -LiteralPath $excerptPath).Hash.ToLowerInvariant() }
    limitations=@('Static control flow only; no IOCTL issued and no ETW captured.', 'Decompiler types/indirect-call argument counts are approximate.', 'Current driver only; no Windows 10 driver comparison.', 'Input byte 3 is observed; its official field name is not established.', 'No packet rate, CPU attribution, or poll-to-rumble causation established.')
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'xinputhid-10.0.26100.9278.json') -Encoding utf8
Write-Output "Saved $excerptPath; verified $verified source instructions."
