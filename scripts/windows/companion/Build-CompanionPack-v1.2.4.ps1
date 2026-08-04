[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutputRoot = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root ".artifacts\companion\1.2.4"
}
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
$ZipPath = Join-Path $OutputRoot "agentic_pipeline_companion_pack1.2.4.zip"
$SidecarPath = $ZipPath + ".sha256"
if ((Test-Path -LiteralPath $ZipPath) -and !$Force) { throw "Output already exists. Use -Force: $ZipPath" }

$ProjectInstructions = "docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.4.md"
$KnowledgeFiles = @(
  "docs\companion\00_AGENTIC_PIPELINE_INDEX_v1.2.4.md",
  "docs\companion\01_CONTEXT_SPLIT_POLICY.md",
  "docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.4.md",
  "docs\companion\03_PRODUCT_EVIDENCE_CONTROL_PLANE.md",
  "docs\companion\04_PROJECT_AUDIT_AND_RECOVERY.md",
  "docs\companion\05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md",
  "docs\companion\06_RUNTIME_TRUTH_REVIEW_POLICY.md",
  "docs\companion\07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md",
  "docs\companion\08_PHASE_CONTRACT_AND_REPAIR_BUDGET.md",
  "docs\companion\09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md",
  "docs\companion\10_STATUS_AND_FINDING_LIFECYCLE.md",
  "docs\companion\11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md",
  "docs\companion\12_GOLDEN_EVALS.md",
  "docs\companion\13_LOCAL_CONTROL_TOOLS.md",
  "docs\companion\14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md",
  "docs\companion\15_OWNER_OUTPUT_PRESENTATION.md"
)
$SupportFiles = @(
  "docs\companion\VERSION.json",
  "docs\companion\README.md",
  "docs\companion\README_INSTALL_RU_v1.2.4.md",
  "docs\companion\COMPANION_CHANGELOG.md"
)

$TempRoot = Join-Path $env:TEMP ("companion_pack_" + [guid]::NewGuid().ToString("N"))
$PackRoot = Join-Path $TempRoot "agentic_pipeline_companion_pack1.2.4"
$KnowledgeRoot = Join-Path $PackRoot "knowledge"
New-Item -ItemType Directory -Force $KnowledgeRoot | Out-Null

try {
  $ManifestEntries = New-Object System.Collections.Generic.List[object]

  function Copy-PackFile {
    param([string]$Relative,[string]$DestinationRelative)
    $Source = Join-Path $Root $Relative
    if (!(Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required companion file missing: $Source" }
    $Destination = Join-Path $PackRoot $DestinationRelative
    New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $Info = Get-Item -LiteralPath $Destination
    [void]$ManifestEntries.Add([ordered]@{
      path = ($DestinationRelative -replace '\\','/')
      size_bytes = [int64]$Info.Length
      sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
  }

  Copy-PackFile -Relative $ProjectInstructions -DestinationRelative "01_PROJECT_INSTRUCTIONS_v1.2.4.md"
  foreach ($Relative in $KnowledgeFiles) {
    Copy-PackFile -Relative $Relative -DestinationRelative ("knowledge\" + (Split-Path -Leaf $Relative))
  }
  foreach ($Relative in $SupportFiles) {
    Copy-PackFile -Relative $Relative -DestinationRelative (Split-Path -Leaf $Relative)
  }

  $Manifest = [ordered]@{
    schema_version = "1.0.0"
    companion_version = "1.2.4"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    project_instructions = "01_PROJECT_INSTRUCTIONS_v1.2.4.md"
    knowledge_directory = "knowledge"
    files = [object[]]$ManifestEntries.ToArray()
  }
  [System.IO.File]::WriteAllText((Join-Path $PackRoot "PACK_MANIFEST.json"), ($Manifest | ConvertTo-Json -Depth 10), $Utf8NoBom)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
  [System.IO.Compression.ZipFile]::CreateFromDirectory($PackRoot, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
  $ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  [System.IO.File]::WriteAllText($SidecarPath, ($ZipHash + "  " + (Split-Path -Leaf $ZipPath) + "`n"), $Utf8NoBom)
  Write-Host "Companion pack built: $ZipPath"
  Write-Host "SHA-256: $ZipHash"
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
