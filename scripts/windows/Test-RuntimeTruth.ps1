param(
  [string]$RepoRoot = ".",
  [switch]$StrictHotPath
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) { [void]$Errors.Add($Message) }
function Add-Warning([string]$Message) { [void]$Warnings.Add($Message) }
function Read-Text([string]$RelPath) {
  $path = Join-Path $Root $RelPath
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}
function Hash([string]$RelPath) {
  $path = Join-Path $Root $RelPath
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
}


$canonicalPlaybook = Read-Text "docs\AGENTIC_PIPELINE_PLAYBOOK.md"
$versionedPlaybook = Read-Text "docs\maintainers\AGENTIC_PIPELINE_PLAYBOOK_v1.2.0.md"
if (!$canonicalPlaybook -or ($canonicalPlaybook -notmatch 'Version:\s*`?1\.2\.0`?' -and $canonicalPlaybook -notmatch 'Playbook v1\.2\.0')) {
  Add-Error "Canonical playbook is not v1.2.0"
}
if (!$versionedPlaybook -or ($versionedPlaybook -notmatch 'Version:\s*`?1\.2\.0`?' -and $versionedPlaybook -notmatch 'Playbook v1\.2\.0')) {
  Add-Error "Versioned v1.2.0 playbook is missing or invalid"
}
if ((Hash "docs\AGENTIC_PIPELINE_PLAYBOOK.md") -ne (Hash "docs\maintainers\AGENTIC_PIPELINE_PLAYBOOK_v1.2.0.md")) {
  Add-Error "Canonical playbook does not match versioned v1.2.0 playbook"
}

$templateAgents = Read-Text "templates\agy-project-base\.agents\AGENTS.md"
if (!$templateAgents -or $templateAgents -notmatch 'Framework Runtime Version:\s*`?1\.2\.0`?') {
  Add-Error "Template .agents/AGENTS.md lacks v1.2.0 runtime marker"
}

$rootGate = "scripts\Test-FastPatchAllowed.ps1"
$templateGate = "templates\agy-project-base\scripts\Test-FastPatchAllowed.ps1"
$workflow = "templates\agy-project-base\.agents\workflows\fastpatch.md"

foreach ($rel in @($rootGate, $templateGate, $workflow)) {
  if (!(Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) {
    Add-Error "Missing runtime file: $rel"
  }
}

foreach ($rel in @($rootGate, $templateGate)) {
  $text = Read-Text $rel
  if ($text) {
    if ($text -notmatch '\[switch\]\s*\$RequireChanges') { Add-Error "$rel lacks RequireChanges" }
    if ($text -notmatch 'ls-files.+--others.+--exclude-standard') { Add-Error "$rel lacks untracked-file detection" }
    foreach ($name in @("MaxChangedFiles","MaxAddedLines","MaxDeletedLines")) {
      if ($text -notmatch [regex]::Escape($name)) { Add-Error "$rel lacks $name" }
    }
  }
}

if ((Hash $rootGate) -ne (Hash $templateGate)) {
  Add-Error "Root and template fastpatch scripts differ"
}

$workflowText = Read-Text $workflow
if ($workflowText -and $workflowText -notmatch '-RequireChanges') {
  Add-Error "fastpatch workflow does not require the post-edit -RequireChanges gate"
}

$legacy = Read-Text "scripts\windows\Apply-AgenticPipeline-v1.1.1.ps1"
if ($legacy) {
  if ($legacy -match 'Fastpatch gate passes trivially|\$testFastText\s*=\s*@|Conservative default for H10') {
    Add-Error "Legacy installer still contains stale embedded fastpatch payload"
  }
  if ($legacy -notmatch 'deprecated|intentionally blocked') {
    Add-Warning "Legacy installer is not explicitly marked deprecated/blocked"
  }
}

$phasePath = Join-Path $Root "templates\agy-project-base\.agy\PHASE_STATUS.json"
try {
  $phase = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json
  foreach ($field in @("schema_version","project_name","current_phase","next_required_command","phase_lock","batch_allowed")) {
    if (!($phase.PSObject.Properties.Name -contains $field)) { Add-Error "PHASE_STATUS missing field: $field" }
  }
  if ($phase.schema_version -ne "1.2.0") { Add-Error "PHASE_STATUS schema_version must be 1.2.0" }
} catch {
  Add-Error "Invalid template PHASE_STATUS.json: $($_.Exception.Message)"
}

foreach ($rel in @(
  "templates\agy-project-base\.agy\PRODUCT_CONTRACT.json",
  "templates\agy-project-base\.agy\REQUIREMENTS_DELTA.md",
  "templates\agy-project-base\.agy\evidence.ndjson",
  "templates\agy-project-base\.agy\ARTIFACT_INDEX.ndjson"
)) {
  if (!(Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) { Add-Error "Missing evidence baseline: $rel" }
}

$productPath = Join-Path $Root "templates\agy-project-base\.agy\PRODUCT_CONTRACT.json"
try {
  $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
  foreach ($field in @("product_goal","mandatory_gates","shipcheck_blockers")) {
    if (!($product.PSObject.Properties.Name -contains $field)) { Add-Error "PRODUCT_CONTRACT missing field: $field" }
  }
  if ($product.product_goal -eq "UNCONFIGURED" -and @($product.shipcheck_blockers) -notcontains "product_contract_not_configured") {
    Add-Error "Unconfigured PRODUCT_CONTRACT must block shipcheck"
  }
} catch {
  Add-Error "Invalid PRODUCT_CONTRACT.json: $($_.Exception.Message)"
}

$hooksPath = Join-Path $Root "templates\agy-project-base\.agents\hooks.json"
try {
  $hooks = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
  if (@($hooks.hooks).Count -eq 0) {
    $claims = Get-ChildItem -LiteralPath $Root -Recurse -File -Include "*.md" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch "\\docs\\archive\\|\\.git\\|\\.pipeline_patch_backup\\" } |
      Where-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $text -match '(?im)^\s*(?:[-*]\s*)?(?:the\s+)?hooks\s+(?:are|remain)\s+active\b|active\s+hooks\s+(?:are\s+)?(?:enabled|configured|enforcing)\b'
      }
    if (@($claims).Count -gt 0) { Add-Error "hooks.json is empty but docs claim active hooks: $(@($claims.FullName) -join ', ')" }
  }
} catch {
  Add-Error "Invalid hooks.json: $($_.Exception.Message)"
}

$hotPath = @("specdoc","planonly","auditphase","probephase","nextphase","fastpatch","securityaudit","visualqa","reportqa","artifactaudit","shipcheck")
$stubs = @()
foreach ($name in $hotPath) {
  $rel = "templates\agy-project-base\.agents\workflows\$name.md"
  $text = Read-Text $rel
  if (!$text) {
    $stubs += "$name(missing)"
  } elseif ($text -match '(?m)^\s*Follow the playbook contract in docs/AGENTIC_PIPELINE_PLAYBOOK\.md\.\s*$') {
    $stubs += $name
  }
}
if ($stubs.Count -gt 0) {
  if ($StrictHotPath) { Add-Error "Hot-path workflow stubs: $($stubs -join ', ')" }
  else { Add-Warning "Hot-path workflow stubs: $($stubs -join ', ')" }
}

foreach ($rel in @(
  "docs\companion\06_RUNTIME_TRUTH_REVIEW_POLICY.md",
  "docs\companion\SYSTEM_PROMPT_GPT55_COMPANION_v1.2.1.md",
  "docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.1.md"
)) {
  if (!(Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) { Add-Error "Missing companion runtime-truth file: $rel" }
}

$prompt = Read-Text "docs\companion\SYSTEM_PROMPT_GPT55_COMPANION_v1.2.1.md"
if ($prompt -and $prompt -notmatch 'Runtime Truth Classification') { Add-Error "Companion system prompt lacks Runtime Truth Classification" }
$task = Read-Text "docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.1.md"
if ($task -and $task -notmatch 'Runtime Truth Block') { Add-Error "Agent Task Pack contract lacks Runtime Truth Block" }

if ($Warnings.Count -gt 0) {
  Write-Host "Runtime truth warnings:"
  $Warnings | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
}

if ($Errors.Count -gt 0) {
  Write-Host "Runtime truth validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Runtime truth validation passed."
exit 0
