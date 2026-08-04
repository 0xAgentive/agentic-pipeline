[CmdletBinding()]
param(
  [string]$RepoRoot = ".",
  [string]$OutputRoot = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Version = Get-Content -LiteralPath (Join-Path $Root "VERSION.json") -Raw | ConvertFrom-Json
if ([string]($Version.package_version) -ne "1.2.6" -or [string]($Version.runtime_version) -ne "1.2.3") {
  throw "Runtime overlay requires package 1.2.6 / runtime 1.2.3."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $Root ".artifacts\runtime\1.2.3" }
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
$ZipPath = Join-Path $OutputRoot "agentic-project-runtime-1.2.3-overlay.zip"
if ((Test-Path -LiteralPath $ZipPath) -and !$Force) { throw "Output exists. Use -Force: $ZipPath" }

$Files = @(
  "VERSION.json",
  "config\command-inventory.json",
  "scripts\windows\Update-AgenticProjectRuntime-v1.2.3.ps1",
  "scripts\windows\Test-CommandInventory.ps1",
  "scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1",
  "scripts\control-plane\write-installation-manifest.cjs",
  "scripts\control-plane\autonomous-convergence.cjs",
  "tests\acceptance\autonomous-convergence-contract.cjs",
  "templates\agy-project-base\.agents\AGENTS.md",
  "templates\agy-project-base\.agents\COMMAND_INVENTORY.json",
  "templates\agy-project-base\.agents\hooks\guard_preflight.ps1",
  "templates\agy-project-base\.agents\hooks\Test-HookContract.ps1",
  "templates\agy-project-base\.agents\rules\05-runtime-contract.md",
  "templates\agy-project-base\.agents\rules\10-pipeline-rules.md",
  "templates\agy-project-base\.agents\rules\30-product-evidence-contract.md",
  "templates\agy-project-base\.agents\rules\30-verification-gates.md",
  "templates\agy-project-base\.agents\rules\60-v1.2-runtime-truth.md",
  "templates\agy-project-base\.agents\rules\61-autonomous-audit-convergence.md",
  "templates\agy-project-base\.agents\rules\62-protected-reviewer.md",
  "templates\agy-project-base\.agents\rules\63-scientific-stage-firewall.md",
  "templates\agy-project-base\.agents\workflows\planonly.md",
  "templates\agy-project-base\.agents\workflows\nextphase.md",
  "templates\agy-project-base\.agents\workflows\auditphase.md",
  "templates\agy-project-base\.agents\workflows\fixcritical.md",
  "templates\agy-project-base\.agents\skills\audit-coverage-matrix\SKILL.md",
  "templates\agy-project-base\.agents\skills\protected-reviewer\SKILL.md",
  "templates\agy-project-base\.agents\skills\scientific-stage-firewall\SKILL.md",
  "templates\agy-project-base\.agy\CONVERGENCE_POLICY.json",
  "templates\agy-project-base\.agy\STAGE_FIREWALL.json",
  "templates\agy-project-base\scripts\control-plane\autonomous-convergence.cjs",
  "templates\agy-project-base\scripts\windows\companion\New-WorkItem.ps1",
  "templates\agy-project-base\scripts\windows\companion\Set-WorkItemStatus.ps1",
  "templates\agy-project-base\scripts\windows\companion\Write-ExecutionScope.ps1",
  "templates\agy-project-base\scripts\windows\companion\Publish-RunResult.ps1",
  "templates\agy-project-base\scripts\windows\companion\New-ExecutionLease.ps1",
  "templates\agy-project-base\scripts\windows\companion\Test-ExecutionLease.ps1",
  "templates\agy-project-base\scripts\windows\companion\Publish-AuditCoverageMatrix.ps1",
  "templates\agy-project-base\scripts\windows\companion\Test-AuditCoverageMatrix.ps1",
  "templates\agy-project-base\scripts\windows\companion\Register-FindingDelta.ps1",
  "templates\agy-project-base\scripts\windows\companion\Publish-RepairDelta.ps1",
  "templates\agy-project-base\scripts\windows\companion\Register-RepairBatch.ps1",
  "templates\agy-project-base\scripts\windows\companion\New-ProtectedReviewerAttestation.ps1",
  "templates\agy-project-base\scripts\windows\companion\Test-ProtectedReviewerAttestation.ps1",
  "templates\agy-project-base\scripts\windows\companion\New-StageFirewall.ps1",
  "templates\agy-project-base\scripts\windows\companion\Compile-ResultAuthority.ps1",
  "templates\agy-project-base\scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1"
)

$Temp = Join-Path $env:TEMP ("agentic-runtime-overlay-" + [guid]::NewGuid().ToString("N"))
$PackageRoot = Join-Path $Temp "agentic-project-runtime-1.2.3"
New-Item -ItemType Directory -Force $PackageRoot | Out-Null
try {
  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Relative in $Files) {
    $Source = Join-Path $Root $Relative
    if (!(Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Runtime overlay source missing: $Relative" }
    $Destination = Join-Path $PackageRoot $Relative
    New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $Info = Get-Item -LiteralPath $Destination
    [void]$Entries.Add([ordered]@{
      path = ($Relative -replace '\\','/')
      size_bytes = [int64]$Info.Length
      sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
  }
  $Readme = @"
# Agentic Project Runtime 1.2.3 Overlay

Dry run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Update-AgenticProjectRuntime-v1.2.3.ps1 -RepoRoot . -ProjectRoot "C:\path\to\project"
```

Apply after review:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Update-AgenticProjectRuntime-v1.2.3.ps1 -RepoRoot . -ProjectRoot "C:\path\to\project" -Apply
```

The updater changes only its explicit framework-owned allowlist and backs up every replaced file. It does not clean, reset or modify product source.
"@
  [IO.File]::WriteAllText((Join-Path $PackageRoot "README_RU.md"), $Readme, $Utf8NoBom)
  $Manifest = [ordered]@{
    schema_version = "1.0.0"
    package_version = "1.2.6"
    runtime_version = "1.2.3"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    files = [object[]]$Entries.ToArray()
  }
  [IO.File]::WriteAllText((Join-Path $PackageRoot "RUNTIME_OVERLAY_MANIFEST.json"), ($Manifest | ConvertTo-Json -Depth 20), $Utf8NoBom)

  Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
  Write-Host "Runtime overlay built: $ZipPath"
  Write-Host "SHA-256: $((Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}
finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
