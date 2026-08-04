[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$Goal,
  [ValidateSet('flow','guarded','release')][string]$AssuranceMode = 'flow',
  [ValidateSet('/nextphase','/fastpatch')][string]$PreferredCommand = '/nextphase',
  [ValidateSet('general','protocol_freeze','analytical_validation','empirical_validation')][string]$StageProfile = 'general',
  [string]$WorkItemId = '',
  [string[]]$Acceptance = @(),
  [string[]]$NonGoals = @(),
  [string[]]$RiskHints = @(),
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
function Publish-AtomicFile {
  param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    throw 'Atomic publish source path is empty.'
  }
  if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    throw 'Atomic publish target path is empty.'
  }
  if (!(Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Atomic publish source file is missing: $SourcePath"
  }

  $TargetParent = Split-Path -Parent $TargetPath
  if ([string]::IsNullOrWhiteSpace($TargetParent)) {
    throw "Atomic publish target parent is empty: $TargetPath"
  }
  New-Item -ItemType Directory -Force -Path $TargetParent | Out-Null

  Move-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$StateRoot = Join-Path $Project '.agy'
$OutputPath = Join-Path $StateRoot 'WORK_ITEM.json'
$SchemaPath = Join-Path $Pipeline 'schemas\companion\work-item.schema.json'
$Validator = Join-Path $Pipeline 'scripts\companion\companion-control.cjs'

if ([string]::IsNullOrWhiteSpace($Goal)) { throw 'Goal is required.' }
if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
if (!(Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required.' }
foreach ($Required in @($SchemaPath,$Validator)) {
  if (!(Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file missing: $Required" }
}

$Branch = (@(& git -C $Project branch --show-current 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve project branch.' }
$Head = (@(& git -C $Project rev-parse HEAD 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve project HEAD.' }

$GoalEpoch = 1
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
  try {
    $Previous = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $Previous.goal_epoch) { $GoalEpoch = [int]$Previous.goal_epoch + 1 }
  }
  catch {
    throw "Existing WORK_ITEM.json is invalid: $($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($WorkItemId)) {
  $Slug = ($Goal.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'work-item' }
  if ($Slug.Length -gt 72) { $Slug = $Slug.Substring(0,72).Trim('-') }
  $WorkItemId = "$Slug-$GoalEpoch"
}

function Get-Sha256Text([string]$Text) {
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

$Now = (Get-Date).ToUniversalTime().ToString('o')
$GoalFingerprint = Get-Sha256Text $Goal.Trim()
$RepairLimit = if ($AssuranceMode -eq 'flow') { 2 } else { 3 }
$InitialAuditLimit = if ($AssuranceMode -eq 'flow') { 0 } else { 1 }
$FinalAuditLimit = if ($AssuranceMode -eq 'flow') { 0 } else { 1 }
$Document = [ordered]@{
  schema_version = '1.0.0'
  work_item_id = $WorkItemId
  goal_epoch = $GoalEpoch
  goal = $Goal.Trim()
  assurance_mode = $AssuranceMode
  status = 'ready'
  owner_approved = $true
  owner_interaction_policy = 'hard_stop_only'
  scope_binding = 'executor_discovery'
  preferred_command = $PreferredCommand
  project_root = $Project
  branch = $Branch
  authorization_head = $Head
  hard_stop = $false
  external_drift = $false
  flow_restoration_enabled = $true
  stage_profile = $StageProfile
  brief_revision = 1
  brief_fingerprint = $GoalFingerprint
  brief_locked_at_utc = $Now
  owner_goal_fingerprint = $GoalFingerprint
  convergence_policy = [ordered]@{
    initial_audit_limit = $InitialAuditLimit
    repair_batch_limit = $RepairLimit
    final_audit_limit = $FinalAuditLimit
  }
  created_at_utc = $Now
  updated_at_utc = $Now
  acceptance = [string[]]@($Acceptance | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  non_goals = [string[]]@($NonGoals | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  risk_hints = [string[]]@($RiskHints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("work-item-" + [Guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($Temp, ($Document | ConvertTo-Json -Depth 20), $Utf8NoBom)
try {
  & node $Validator validate-work-item --repo-root $Pipeline --file $Temp
  if ($LASTEXITCODE -ne 0) { throw 'Generated work item failed schema validation.' }
  if (!$Apply) {
    Write-Host 'WORK ITEM DRY RUN PASSED.'
    Write-Host "Work item: $WorkItemId"
    Write-Host "Mode: $AssuranceMode"
  Write-Host "Stage profile: $StageProfile"
    Write-Host 'No file was modified.'
    exit 0
  }
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  $TargetTemp = $OutputPath + '.tmp'
  Copy-Item -LiteralPath $Temp -Destination $TargetTemp -Force
  $HistoryRoot = Join-Path $StateRoot ('history\epoch-' + $GoalEpoch)
  New-Item -ItemType Directory -Force -Path $HistoryRoot | Out-Null
  foreach ($Name in @('EXECUTION_SCOPE.json','EXECUTION_LEASE.json','AUDIT_COVERAGE_MATRIX.json','FINDINGS.json','FINDING_DELTA.json','REPAIR_DELTA.json','REPAIR_BUDGET.json','REVIEWER_ATTESTATION.json','CLOSURE_STATE.json')) {
    $Existing = Join-Path $StateRoot $Name
    if (Test-Path -LiteralPath $Existing -PathType Leaf) { Move-Item -LiteralPath $Existing -Destination (Join-Path $HistoryRoot $Name) -Force }
  }
  Publish-AtomicFile -SourcePath $TargetTemp -TargetPath $OutputPath
  $Budget = [ordered]@{
    schema_version = '1.0.0'
    work_item_id = $WorkItemId
    assurance_mode = $AssuranceMode
    initial_audit_limit = $InitialAuditLimit
    repair_batch_limit = $RepairLimit
    final_audit_limit = $FinalAuditLimit
    initial_audits_used = 0
    repair_batches_used = 0
    final_audits_used = 0
    status = 'available'
    updated_at_utc = $Now
    history = @()
  }
  [System.IO.File]::WriteAllText((Join-Path $StateRoot 'REPAIR_BUDGET.json'), ($Budget | ConvertTo-Json -Depth 20), $Utf8NoBom)
  Write-Host "Work item written: $OutputPath"
  Write-Host "Work item: $WorkItemId"
  Write-Host "Goal epoch: $GoalEpoch"
  Write-Host "Mode: $AssuranceMode"
  Write-Host "Stage profile: $StageProfile"
}
finally {
  Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
