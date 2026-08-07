[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [Parameter(Mandatory = $true)][string]$ActionPacketPath,
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-OptionalProperty {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return $Default }
  return $Property.Value
}

function Get-TextSha256 {
  param([Parameter(Mandatory = $true)][string]$Text)
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant()
  }
  finally {
    $Hasher.Dispose()
  }
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Root '.agy'
$PacketPath = (Resolve-Path -LiteralPath $ActionPacketPath).Path
$Packet = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8 | ConvertFrom-Json

$Operation = [string](Get-OptionalProperty -Object $Packet -Name 'operation' -Default '')
$OwnerApproved = [bool](Get-OptionalProperty -Object $Packet -Name 'owner_approved' -Default $false)
$OwnerPolicy = [string](Get-OptionalProperty -Object $Packet -Name 'owner_interaction_policy' -Default '')
$Route = [string](Get-OptionalProperty -Object $Packet -Name 'route' -Default '')

if ($Operation -ne 'new_work_item') { throw 'Start-WorkItemTransaction accepts only new_work_item packets.' }
if (-not $OwnerApproved) { throw 'Action packet is not owner-approved.' }
if ($OwnerPolicy -ne 'hard_stop_only') { throw 'Unsupported owner interaction policy.' }

$AllowedRoutes = @('/nextphase', '/fixcritical', '/auditphase', '/fastpatch', '/shipcheck')
if ($Route -notin $AllowedRoutes) { throw "Unsupported packet route: $Route" }

$ExistingPath = Join-Path $AgyRoot 'WORK_ITEM.json'
if (Test-Path -LiteralPath $ExistingPath -PathType Leaf) {
  $Existing = Get-Content -LiteralPath $ExistingPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $ExistingStatus = [string](Get-OptionalProperty -Object $Existing -Name 'status' -Default '')
  if ($ExistingStatus -in @('active', 'ready', 'implementation', 'repair', 'audit', 'in_progress')) {
    $ExistingId = [string](Get-OptionalProperty -Object $Existing -Name 'work_item_id' -Default 'unknown')
    throw "An active work item already exists: $ExistingId"
  }
}

$Now = (Get-Date).ToUniversalTime().ToString('o')
$PacketWorkItemId = [string](Get-OptionalProperty -Object $Packet -Name 'work_item_id' -Default '')
$WorkItemId = if ([string]::IsNullOrWhiteSpace($PacketWorkItemId)) {
  'wi-' + [Guid]::NewGuid().ToString('N')
} else {
  $PacketWorkItemId
}

$PacketEpoch = Get-OptionalProperty -Object $Packet -Name 'goal_epoch' -Default 1
$GoalEpoch = [int]$PacketEpoch
$Goal = [string](Get-OptionalProperty -Object $Packet -Name 'goal' -Default '')
if ([string]::IsNullOrWhiteSpace($Goal)) { throw 'Action packet goal is required.' }

$AssuranceMode = [string](Get-OptionalProperty -Object $Packet -Name 'assurance_mode' -Default 'flow')
$StageProfile = [string](Get-OptionalProperty -Object $Packet -Name 'stage_profile' -Default 'general')
$PacketId = [string](Get-OptionalProperty -Object $Packet -Name 'packet_id' -Default '')
[string[]]$Acceptance = @((Get-OptionalProperty -Object $Packet -Name 'acceptance' -Default @()))
[string[]]$NonGoals = @((Get-OptionalProperty -Object $Packet -Name 'non_goals' -Default @()))
[string[]]$RiskHints = @((Get-OptionalProperty -Object $Packet -Name 'risk_hints' -Default @()))
$AuditDimensions = Get-OptionalProperty -Object $Packet -Name 'audit_dimensions' -Default ([pscustomobject]@{})
$GoalHash = Get-TextSha256 -Text $Goal

$WorkItem = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  goal_epoch = $GoalEpoch
  goal = $Goal
  assurance_mode = $AssuranceMode
  status = 'ready'
  owner_approved = $true
  owner_interaction_policy = 'hard_stop_only'
  scope_binding = 'executor_discovery'
  preferred_command = $Route
  project_root = $Root
  branch = $null
  authorization_head = $null
  hard_stop = $false
  external_drift = $false
  flow_restoration_enabled = $true
  created_at_utc = $Now
  updated_at_utc = $Now
  acceptance = $Acceptance
  non_goals = $NonGoals
  risk_hints = $RiskHints
  stage_profile = $StageProfile
  brief_revision = 1
  brief_fingerprint = $GoalHash
  brief_locked_at_utc = $Now
  owner_goal_fingerprint = $GoalHash
  progress_policy = [ordered]@{
    auto_continue_while_progress = $true
    consecutive_no_progress_limit = 2
    same_failure_limit = 2
  }
  audit_dimensions = $AuditDimensions
  action_packet_id = $PacketId
}

$ProtectedPatterns = if ($StageProfile -eq 'protocol_freeze') {
  @('src/backend/analytics/**', 'src/backend/qc/**')
} else {
  @()
}

$Firewall = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  stage_profile = $StageProfile
  status = 'active'
  protected_path_patterns = $ProtectedPatterns
  algorithm_repair_authorized = $false
  algorithm_repair_finding_ids = @()
  analytical_baseline_head = $null
  generated_at_utc = $Now
}

$Progress = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  status = 'active'
  observations_count = 0
  consecutive_no_progress = 0
  same_failure_count = 0
  last_failure_fingerprint = $null
  last_metrics = $null
  last_progress_fingerprint = $null
  last_material_change = $null
  owner_decision_required = $false
  owner_decision_reason = $null
  updated_at_utc = $Now
  history = @()
}

$NextAction = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  route = $Route
  auto_continue = $true
  owner_decision_required = $false
  owner_decision_reason = $null
  technical_task_path = '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
  updated_at_utc = $Now
}

if (-not $Apply) {
  [ordered]@{
    work_item = $WorkItem
    stage_firewall = $Firewall
    progress = $Progress
    next_action = $NextAction
  } | ConvertTo-Json -Depth 40
  exit 0
}

New-Item -ItemType Directory -Force -Path $AgyRoot | Out-Null
$TransactionRoot = Join-Path $AgyRoot ('.transaction-' + [Guid]::NewGuid().ToString('N'))
$HistoryRoot = Join-Path $AgyRoot ('history\work-item-transactions\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $TransactionRoot | Out-Null
$Names = @('WORK_ITEM.json', 'STAGE_FIREWALL.json', 'PROGRESS_STATE.json', 'NEXT_ACTION.json')

try {
  $Payloads = @(
    @('WORK_ITEM.json', $WorkItem),
    @('STAGE_FIREWALL.json', $Firewall),
    @('PROGRESS_STATE.json', $Progress),
    @('NEXT_ACTION.json', $NextAction)
  )

  foreach ($Pair in $Payloads) {
    [System.IO.File]::WriteAllText(
      (Join-Path $TransactionRoot $Pair[0]),
      ($Pair[1] | ConvertTo-Json -Depth 40),
      $Utf8NoBom
    )
  }

  $Files = [ordered]@{}
  foreach ($Name in $Names) {
    $Files[$Name] = [ordered]@{ sha256 = Get-FileSha256 -Path (Join-Path $TransactionRoot $Name) }
  }

  $Receipt = [ordered]@{
    schema_version = '1.1.0'
    status = 'committed'
    transaction_id = 'work-item-' + [Guid]::NewGuid().ToString('N')
    work_item_id = $WorkItemId
    goal_epoch = $GoalEpoch
    owner_goal_sha256 = $GoalHash
    action_packet_sha256 = Get-FileSha256 -Path $PacketPath
    files = $Files
    committed_at_utc = $Now
  }

  [System.IO.File]::WriteAllText(
    (Join-Path $TransactionRoot 'WORK_ITEM_TRANSACTION.json'),
    ($Receipt | ConvertTo-Json -Depth 20),
    $Utf8NoBom
  )

  New-Item -ItemType Directory -Force -Path $HistoryRoot | Out-Null
  foreach ($Name in ($Names + @('WORK_ITEM_TRANSACTION.json'))) {
    $Current = Join-Path $AgyRoot $Name
    if (Test-Path -LiteralPath $Current -PathType Leaf) {
      Copy-Item -LiteralPath $Current -Destination (Join-Path $HistoryRoot $Name) -Force
    }
  }

  foreach ($Name in $Names) {
    Move-Item -LiteralPath (Join-Path $TransactionRoot $Name) -Destination (Join-Path $AgyRoot $Name) -Force
  }
  Move-Item -LiteralPath (Join-Path $TransactionRoot 'WORK_ITEM_TRANSACTION.json') -Destination (Join-Path $AgyRoot 'WORK_ITEM_TRANSACTION.json') -Force

  Write-Host "Work item transaction activated: $WorkItemId. Read-only discovery and exact scope binding are next."
}
finally {
  Remove-Item -LiteralPath $TransactionRoot -Recurse -Force -ErrorAction SilentlyContinue
}
