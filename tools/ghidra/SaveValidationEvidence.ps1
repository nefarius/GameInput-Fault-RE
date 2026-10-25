#requires -Version 7.4
# Retain literal pseudocode and source-byte-checked instruction selections for this build.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sets = @(
    @{ Name='gameinput-inbox-0.2309.26100.9278'; Binary='C:\Windows\System32\GameInput.dll'; Sha='f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6'; Pdb='GameInput.pdb'; PdbGuid='b2f221be-f567-c87a-7830-89f3fe8b3c51'; PdbSha='1452c6e5285e11874ee68e8bda74674e3cecd0d07862247d4bd183bc56c89651'; Files=@(
        @{ Path='inbox-analysis/180042e98'; Ranges=@(@('180042ed2','180042efd'),@('180042f0b','180042f84'),@('180042f8a','180042fbe'),@('180042fec','18004303c')) },
        @{ Path='inbox-followup/1800405e4'; Ranges=@(@('1800405f4','180040630'),@('1800406cb','18004071c')) },
        @{ Path='inbox-followup/18003cea4'; Ranges=@(@('18003ceca','18003ceca'),@('18003cef9','18003cf33')) }
    ) },
    @{ Name='gameinput-redist-3.5.270.0-validation'; Binary='C:\Windows\System32\GameInputRedist.dll'; Sha='6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686'; Files=@(
        @{ Path='redist-validation/1800519ec'; Ranges=@(@('180051a19','180051a6c'),@('180051ae9','180051b50'),@('180051bb2','180051bc9')) },
        @{ Path='redist-validation/1800557a0'; Ranges=@(,@('1800557a4','1800557a9')) },
        @{ Path='redist-validation/180064fa8'; Ranges=@(,@('180064fc1','180065004')) },
        @{ Path='redist-validation-followup/180069e38'; Ranges=@() },
        @{ Path='redist-validation/180060468'; Ranges=@(@('18006050f','18006051d'),@('18006053c','18006058b'),@('1800605eb','180060612')) },
        @{ Path='redist-validation-followup/1800602ac'; Ranges=@(,@('180060351','1800603c8')) }
    ) },
    @{ Name='xinputhid-10.0.26100.9278-process-notify'; Binary='C:\Windows\System32\drivers\xinputhid.sys'; Sha='1e85d1a191f09ed62645658c94f908b733da5a026ed2b6b662635ebbddf84588'; Pdb='XINPUTHID.pdb'; PdbGuid='f482d0de-64e0-3d63-a8b2-d58e868db1e5'; PdbSha='050b38f56fdb1e11b33cbcf4817c3f470fc2402a45401cb7d79e3e5eb8f3d348'; Files=@(
        @{ Path='xinputhid-process-notify/1400104c0'; Ranges=@(@('1400104dd','1400104e0'),@('140010520','140010535'),@('140010573','140010629')) },
        @{ Path='xinputhid-process-notify/14001035c'; Ranges=@(,@('140010443','14001045e')) },
        @{ Path='xinputhid-process-notify/14000fcb0'; NoPseudocode=$true; Ranges=@(,@('1400100c2','1400100e2')) },
        @{ Path='xinputhid-process-cleanup/140005c28'; NoPseudocode=$true; Ranges=@(,@('140005dd6','140005e2b')) },
        @{ Path='xinputhid-process-cleanup/14001c03c'; NoPseudocode=$true; Ranges=@(,@('14001c4f5','14001c501')) }
    ) }
)
foreach ($set in $sets) {
    $hash = (Get-FileHash -LiteralPath $set.Binary).Hash.ToLowerInvariant()
    if ($hash -ne $set.Sha) { throw "Source image changed: $($set.Binary)" }
    if ($set.Pdb -and (Get-FileHash -LiteralPath (Join-Path $repo ('symbols/'+$set.Pdb))).Hash.ToLowerInvariant() -ne $set.PdbSha) {
        throw "PDB image changed: $($set.Pdb)"
    }
    $bytes = [IO.File]::ReadAllBytes($set.Binary)
    $pe = [BitConverter]::ToInt32($bytes,0x3c)
    $sectionCount = [BitConverter]::ToUInt16($bytes,$pe+6)
    $optSize = [BitConverter]::ToUInt16($bytes,$pe+20)
    $base = [BitConverter]::ToUInt64($bytes,$pe+48)
    $sections = for($i=0;$i -lt $sectionCount;$i++) {
        $at=$pe+24+$optSize+40*$i
        @{ Rva=[BitConverter]::ToUInt32($bytes,$at+12); Size=[BitConverter]::ToUInt32($bytes,$at+16); Raw=[BitConverter]::ToUInt32($bytes,$at+20) }
    }
    $text=[Collections.Generic.List[string]]::new()
    $text.Add('Local Ghidra 12.1.3 headless static evidence; literal pseudocode, not original source or runtime observation.')
    $text.Add('Image: '+$set.Binary+' SHA256='+$hash)
    $text.Add('Pseudocode argument/types may be approximate. Selected instruction bytes match the original PE; file offsets and RVA are explicit.')
    if($set.Pdb) { $text.Add('PDB GUID='+$set.PdbGuid+' age=1; GUID/age matched during import.') }
    else { $text.Add('No matching public PDB applied. FUN names are Ghidra labels; class/source names in discussion come from embedded strings.') }
    $exports=@(); $verified=0
    foreach($file in $set.Files) {
        $path=Join-Path $repo ('artifacts/'+$file.Path+'.txt')
        $inventory=Get-Content -LiteralPath (Join-Path (Split-Path $path -Parent) 'inventory.txt') -Raw
        if ($inventory -notmatch [regex]::Escape('Executable SHA256: '+$hash)) { throw "Export image mismatch: $path" }
        $lines=Get-Content -LiteralPath $path
        $marker=[Array]::IndexOf($lines,'INSTRUCTIONS (analysis bytes, not runtime)')
        if($marker -lt 0) { throw "Missing export: $path" }
        $text.Add(''); $text.Add('=== '+$file.Path+' ===')
        $exports += @{ path='artifacts/'+$file.Path+'.txt'; sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() }
        $stop=$marker-1
        if($file.NoPseudocode) { $stop=[Array]::FindIndex($lines,[Predicate[string]]{param($line) $line.StartsWith('DECOMPILATION completed=')}) }
        $text.AddRange([string[]]$lines[0..$stop])
        foreach($range in $file.Ranges) {
            $text.Add('[... selected instructions '+$range[0]+'..'+$range[1]+' ...]')
            $count=0
            foreach($line in $lines[($marker+1)..($lines.Length-1)]) {
                if($line -notmatch '^([0-9a-f]+) ([0-9a-f]+) (.*?) \|') { continue }
                $va=[Convert]::ToUInt64($Matches[1],16)
                if($va -lt [Convert]::ToUInt64($range[0],16) -or $va -gt [Convert]::ToUInt64($range[1],16)) { continue }
                $hex=$Matches[2]; $instruction=$Matches[3]; $rva=$va-$base
                $section=@($sections | Where-Object { $rva -ge $_.Rva -and $rva -lt $_.Rva+$_.Size })
                if($section.Count -ne 1) { throw "Ambiguous source mapping: $line" }
                $offset=$section[0].Raw+$rva-$section[0].Rva
                $expected=[Convert]::FromHexString($hex)
                for($j=0;$j -lt $expected.Length;$j++) { if($bytes[$offset+$j] -ne $expected[$j]) { throw "Source mismatch: $line" } }
                $text.Add(('{0:x} RVA=0x{1:x} file=0x{2:x} {3} {4}' -f $va,$rva,$offset,$hex,$instruction))
                $verified++; $count++
            }
            if($count -eq 0) { throw "Empty instruction range: $range" }
        }
    }
    $dest=Join-Path $repo ('evidence/static/'+$set.Name+'-excerpts.txt')
    [IO.File]::WriteAllLines($dest,$text,[Text.UTF8Encoding]::new($false))
    $pdbInfo=$null
    if($set.Pdb) { $pdbInfo=@{ path='symbols/'+$set.Pdb; guid=$set.PdbGuid; age=1; sha256=(Get-FileHash -LiteralPath (Join-Path $repo ('symbols/'+$set.Pdb))).Hash.ToLowerInvariant() } }
    $manifest=[ordered]@{
        kind='local-ghidra-static'; observed_date='2026-10-25'; runtime_observed=$false
        source=@{ path=$set.Binary; sha256=$hash; size_bytes=$bytes.Length; file_version=(Get-Item -LiteralPath $set.Binary).VersionInfo.FileVersion; preferred_base=('0x{0:x}' -f $base) }
        pdb=$pdbInfo; ghidra='12.1.3'; java='Temurin 25.0.4.1+1'; exports=$exports; source_instructions_verified=$verified
        excerpt=@{ path='evidence/static/'+$set.Name+'-excerpts.txt'; sha256=(Get-FileHash -LiteralPath $dest).Hash.ToLowerInvariant() }
        limitations=@('Static code only; no module loading or IOCTL execution.', 'External import names do not identify runtime implementation or API-set routing.', 'Decompiler types approximate; original instruction bytes verified for retained ranges.', 'No successful poll rate, rumble rate, focus state or CPU causation measured.')
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo ('evidence/static/'+$set.Name+'.json')) -Encoding utf8
    Write-Output "$($set.Name): $verified instructions verified."
}
