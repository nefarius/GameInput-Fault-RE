# Reproduce the xinputhid static investigation

Use Ghidra 12.1.3, the installed JDK, and the public PDB already under `symbols/`.
Run in PowerShell 7.4+ from the repository root. No target driver code is executed.
The analysis requires no REA/MCP configuration changes.

The commands below set environment variables only in this shell and its children.
The stock Ghidra launcher additionally writes `java_home.save` in the user's Ghidra
profile; request execution approval if the environment blocks that write. Settings,
projects, logs and full exports otherwise go under ignored `artifacts/`.

```powershell
$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-25.0.4.101-hotspot'
$env:GHIDRA_HEADLESS_JAVA_OPTIONS = '-Dapplication.settingsdir=D:\RE\GameInput\artifacts\ghidra-settings -Djava.io.tmpdir=D:\RE\GameInput\artifacts'
$headless = 'D:\Tools\ghidra_12.1.3_PUBLIC\support\analyzeHeadless.bat'
New-Item -ItemType Directory -Force artifacts\ghidra-projects | Out-Null
```

For a **fresh project only**, import and analyze:

```powershell
& $headless 'D:\RE\GameInput\artifacts\ghidra-projects' XinputKernel `
  -import 'C:\Windows\System32\drivers\xinputhid.sys' `
  -scriptPath 'D:\RE\GameInput\tools\ghidra' `
  -preScript SetXinputPdb.java 'D:\RE\GameInput\symbols\XINPUTHID.pdb' `
  -postScript ExportXinputEvidence.java 'D:\RE\GameInput\artifacts\xinputhid-analysis' `
  -analysisTimeoutPerFile 300 -max-cpu 2 `
  -log 'D:\RE\GameInput\artifacts\xinputhid-ghidra.log' `
  -scriptlog 'D:\RE\GameInput\artifacts\xinputhid-scripts.log'
```

`SetXinputPdb.java` reads PE/PDB GUID and age before setting the explicit analyzer
file option. It refuses mismatches; no force-load or symbol-server setup is used.
Check the actual logs for success; the process exit code alone does not prove
scripts completed. The original investigation used the explicit PDB option on
import and independently verified its GUID/age in the later read-only run below.

After import, or to reuse the existing project, export the additional paths without
re-analysis or saving project edits:

```powershell
& $headless 'D:\RE\GameInput\artifacts\ghidra-projects' XinputKernel `
  -process xinputhid.sys -noanalysis -readOnly `
  -scriptPath 'D:\RE\GameInput\tools\ghidra' `
  -postScript ExportXinputEvidence.java 'D:\RE\GameInput\artifacts\xinputhid-followup' `
    140009110 140001240 140003504 140006740 140007ae0 14000e9e4 `
  -log 'D:\RE\GameInput\artifacts\xinputhid-followup.log'

& $headless 'D:\RE\GameInput\artifacts\ghidra-projects' XinputKernel `
  -process xinputhid.sys -noanalysis -readOnly `
  -scriptPath 'D:\RE\GameInput\tools\ghidra' `
  -preScript SetXinputPdb.java 'D:\RE\GameInput\symbols\XINPUTHID.pdb' `
  -scriptlog 'D:\RE\GameInput\artifacts\xinputhid-pdb-verify.log' `
  -log 'D:\RE\GameInput\artifacts\xinputhid-pdb-verify-app.log'

& .\tools\ghidra\SaveXinputSummary.ps1
```

The exporter writes function inventories, incoming references, direct callees,
literal pseudocode, and address/byte/instruction listings. Without explicit
addresses it selects relevant function names and literal `0x8000e388` users;
with addresses it exports their containing functions plus literal users. Candidate
selection is not a claim that all indirect edges are resolved.

For another PE or a strictly narrow export, pass `exact` after the output directory,
then preferred VAs: `-postScript ExportXinputEvidence.java <output-dir> exact 180042e98`.
This exports only containing functions for those addresses; it still inventories
functions and occurrences of the literal IOCTL. Despite its historical name,
`SetXinputPdb.java` validates and selects any matching PE/PDB GUID/age pair.

`SaveXinputSummary.ps1` is deliberately scoped to the investigated driver/PDB
hashes and address selections. It retains small excerpts under `evidence/static/`,
checks each selected instruction against original PE bytes, and records hashes.
It uses the installed KMDF 1.15 header for WDF slot names; decompiler argument types
remain uncertain. Keep full exports and project databases out of git.

See [the findings](../../docs/kernel-xinputhid.md) for branch semantics and unresolved
runtime questions. Updating Windows requires a new identity/analysis; do not reuse
these addresses or summary labels for another image.

## Inbox, redist and process-notification validation

The same exporter supports other PE images through `exact`. The focused analysis
is described in [user-mode validation](../../docs/user-mode-validation.md). For fresh
projects, using the shell variables above:

```powershell
& $headless 'D:\RE\GameInput\artifacts\ghidra-projects' InboxValidation `
  -import 'C:\Windows\System32\GameInput.dll' -loader-loadLibraries false `
  -scriptPath 'D:\RE\GameInput\tools\ghidra' `
  -preScript SetXinputPdb.java 'D:\RE\GameInput\symbols\GameInput.pdb' `
  -postScript ExportXinputEvidence.java 'D:\RE\GameInput\artifacts\inbox-analysis' exact 180042e98 `
  -analysisTimeoutPerFile 300 -max-cpu 2 `
  -log 'D:\RE\GameInput\artifacts\inbox-ghidra.log' `
  -scriptlog 'D:\RE\GameInput\artifacts\inbox-scripts.log'

& $headless 'D:\RE\GameInput\artifacts\ghidra-projects' RedistValidation `
  -import 'C:\Windows\System32\GameInputRedist.dll' -loader-loadLibraries false `
  -scriptPath 'D:\RE\GameInput\tools\ghidra' -preScript DisablePdb.java `
  -postScript ExportXinputEvidence.java 'D:\RE\GameInput\artifacts\redist-validation' exact `
    1800519ec 180060468 1800557a0 180064fa8 `
  -analysisTimeoutPerFile 300 -max-cpu 2 `
  -log 'D:\RE\GameInput\artifacts\redist-validation.log'
```

Follow-up exports reopen each saved project read-only. This helper avoids repeating
the common headless arguments:

```powershell
function Export-SavedEvidence($project, $image, $destination, [string[]]$addresses) {
  & $headless 'D:\RE\GameInput\artifacts\ghidra-projects' $project `
    -process $image -noanalysis -readOnly -scriptPath 'D:\RE\GameInput\tools\ghidra' `
    -postScript ExportXinputEvidence.java $destination exact @addresses
}
Export-SavedEvidence InboxValidation GameInput.dll `
  'D:\RE\GameInput\artifacts\inbox-followup' @('1800405e4','18003cea4')
Export-SavedEvidence RedistValidation GameInputRedist.dll `
  'D:\RE\GameInput\artifacts\redist-validation-followup' @('1800602ac','180069e38')
Export-SavedEvidence XinputKernel xinputhid.sys `
  'D:\RE\GameInput\artifacts\xinputhid-process-notify' @('1400104c0','14001035c','14000fcb0')
Export-SavedEvidence XinputKernel xinputhid.sys `
  'D:\RE\GameInput\artifacts\xinputhid-process-cleanup' @('140005c28','14001c03c')
& .\tools\ghidra\SaveValidationEvidence.ps1
```

The summary script pins the investigated image/PDB hashes and checks export
inventories plus every selected instruction against original PE bytes. It writes
three compact excerpt/provenance pairs and does not change the original kernel
evidence pair. `DisablePdb.java` disables the default PDB Universal analyzer for the no-PDB redist import;
it does not change Ghidra's global preferences or MCP configuration.
