# LEGACY_SHAPE_SAFE_PROGRESS_GUARD_MIGRATION
[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$Now = (Get-Date).ToUniversalTime().ToString('o')

if (-not (Test-Path -LiteralPath $Agy -PathType Container)) {
  throw "Agentic runtime state directory is missing: $Agy"
}

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $null
  }

  return ($Text | ConvertFrom-Json)
}

function Get-PropertyValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$DefaultValue = $null
  )

  if ($null -eq $Object) {
    return $DefaultValue
  }

  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      return $Object[$Name]
    }
    return $DefaultValue
  }

  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) {
    return $DefaultValue
  }

  return $Property.Value
}

function Set-PropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$Value
  )

  if ($Object -is [System.Collections.IDictionary]) {
    [void]($Object[$Name] = $Value)
    return
  }

  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    return
  }

  [void]($Property.Value = $Value)
}

function Remove-PropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      [void]$Object.Remove($Name)
    }
    return
  }

  if ($null -ne $Object.PSObject.Properties[$Name]) {
    [void]$Object.PSObject.Properties.Remove($Name)
  }
}

function Test-MutableJsonObject {
  param([AllowNull()][object]$Object)

  if ($null -eq $Object) {
    return $false
  }

  return (
    $Object -is [System.Collections.IDictionary] -or
    $Object -is [System.Management.Automation.PSCustomObject]
  )
}

$WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
$WorkItem = Read-JsonObject -Path $WorkItemPath
$WorkItemIdValue = Get-PropertyValue -Object $WorkItem -Name 'work_item_id'
$WorkItemId = if ($null -eq $WorkItemIdValue) { $null } else { [string]$WorkItemIdValue }

$LegacyNames = @(
  'CONVERGENCE_BUDGET.json',
  'REPAIR_BUDGET.json',
  'repair-ledger.ndjson'
)
$Legacy = @(
  $LegacyNames |
    ForEach-Object { Join-Path $Agy $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)

$FindingsMalformed = $false
$OpenProduct = 0
$OpenVerification = 0
$FindingsPath = Join-Path $Agy 'FINDINGS.json'

if (Test-Path -LiteralPath $FindingsPath -PathType Leaf) {
  try {
    $Payload = Read-JsonObject -Path $FindingsPath
    $FindingsValue = Get-PropertyValue -Object $Payload -Name 'findings' -DefaultValue @()
    $Findings = if ($null -eq $FindingsValue) { @() } else { @($FindingsValue) }

    foreach ($Finding in $Findings) {
      if ($null -eq $Finding) {
        $FindingsMalformed = $true
        continue
      }

      $FindingId = [string](Get-PropertyValue -Object $Finding -Name 'finding_id' -DefaultValue '')
      $Materiality = [string](Get-PropertyValue -Object $Finding -Name 'materiality' -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($FindingId) -or [string]::IsNullOrWhiteSpace($Materiality)) {
        $FindingsMalformed = $true
        continue
      }

      $Lifecycle = Get-PropertyValue -Object $Finding -Name 'lifecycle_status'
      if ($null -eq $Lifecycle) {
        $Lifecycle = Get-PropertyValue -Object $Finding -Name 'status' -DefaultValue ''
      }
      $State = [string]$Lifecycle
      $Closed = $State -in @(
        'verified_resolved',
        'resolved',
        'deferred',
        'accepted_risk',
        'superseded',
        'false_positive'
      )

      if (-not $Closed -and $Materiality -eq 'product_blocker') {
        $OpenProduct++
      }
      if (-not $Closed -and $Materiality -in @('verification_blocker', 'release_blocker')) {
        $OpenVerification++
      }
    }
  }
  catch {
    $FindingsMalformed = $true
  }
}

$WorkItemStatus = [string](Get-PropertyValue -Object $WorkItem -Name 'status' -DefaultValue '')
$PreferredCommand = [string](Get-PropertyValue -Object $WorkItem -Name 'preferred_command' -DefaultValue '')
$ActiveStates = @('active', 'implementation', 'repair', 'audit', 'ready', 'in_progress')

if ($FindingsMalformed) {
  $Route = '/auditphase'
}
elseif ($OpenProduct -gt 0) {
  $Route = '/fixcritical'
}
elseif ($OpenVerification -gt 0) {
  $Route = '/auditphase'
}
elseif ($null -ne $WorkItem -and $WorkItemStatus -in $ActiveStates) {
  $Route = if ([string]::IsNullOrWhiteSpace($PreferredCommand)) { '/nextphase' } else { $PreferredCommand }
}
else {
  $Route = $null
}

$LegacyFileNames = @($Legacy | ForEach-Object { [System.IO.Path]::GetFileName($_) })
$Progress = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  status = if ($Route) { 'progressing' } else { 'idle' }
  observations_count = 0
  consecutive_no_progress = 0
  same_failure_count = 0
  last_failure_fingerprint = $null
  last_metrics = $null
  last_progress_fingerprint = $null
  last_material_change = 'migrated_from_numeric_repair_budget'
  owner_decision_required = $false
  owner_decision_reason = $null
  updated_at_utc = $Now
  history = @(
    [ordered]@{
      at_utc = $Now
      event = 'owner_autonomy_migration'
      legacy_budget_files = $LegacyFileNames
      route = $Route
      findings_malformed = $FindingsMalformed
    }
  )
}

$TaskRelative = '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
$Next = [ordered]@{
  schema_version = '1.1.0'
  work_item_id = $WorkItemId
  route = $Route
  auto_continue = [bool]$Route
  owner_decision_required = $false
  owner_decision_reason = $null
  technical_task_path = if (Test-Path -LiteralPath (Join-Path $Root $TaskRelative) -PathType Leaf) { $TaskRelative } else { $null }
  updated_at_utc = $Now
}

if ($null -ne $WorkItem) {
  foreach ($Name in @('convergence_policy', 'repair_budget', 'repair_batches_used', 'repair_batch_limit')) {
    Remove-PropertyValue -Object $WorkItem -Name $Name
  }
  Set-PropertyValue -Object $WorkItem -Name 'progress_policy' -Value ([ordered]@{
    auto_continue_while_progress = $true
    consecutive_no_progress_limit = 2
    same_failure_limit = 2
  })
  Set-PropertyValue -Object $WorkItem -Name 'updated_at_utc' -Value $Now
}

$HandshakePath = Join-Path $Agy 'RUNTIME_HANDSHAKE.json'
$Handshake = Read-JsonObject -Path $HandshakePath
if ($null -ne $Handshake) {
  Set-PropertyValue -Object $Handshake -Name 'installed' -Value ([ordered]@{
    package_version = '1.2.19'
    runtime_version = '1.2.19'
    companion_version = '1.2.19'
  })
  Set-PropertyValue -Object $Handshake -Name 'progress_guard' -Value ([ordered]@{
    numeric_repair_budget = $false
    auto_continue_while_progress = $true
    consecutive_no_progress_limit = 2
    same_failure_limit = 2
  })

  $Routing = Get-PropertyValue -Object $Handshake -Name 'routing'
  if (-not (Test-MutableJsonObject -Object $Routing)) {
    $Routing = [pscustomobject]@{}
    Set-PropertyValue -Object $Handshake -Name 'routing' -Value $Routing
  }

  Set-PropertyValue -Object $Routing -Name 'next_required_command' -Value $Route
  Set-PropertyValue -Object $Routing -Name 'resolved_commands_allowed_now' -Value $(if ($Route) { @($Route) } else { @() })
  Set-PropertyValue -Object $Routing -Name 'product_execution_allowed' -Value ($Route -in @('/nextphase', '/fixcritical', '/fastpatch'))
  Set-PropertyValue -Object $Routing -Name 'release_execution_allowed' -Value ($Route -eq '/shipcheck')
  Set-PropertyValue -Object $Handshake -Name 'generated_at_utc' -Value $Now
}

$Result = [ordered]@{
  schema_version = '1.1.0'
  status = 'PASS'
  project_root = $Root
  work_item_id = $WorkItemId
  legacy_budget_files = $LegacyFileNames
  next_route = $Route
  numerical_repair_budget_enabled = $false
  findings_malformed = $FindingsMalformed
  open_product_blockers = $OpenProduct
  open_verification_blockers = $OpenVerification
  generated_at_utc = $Now
}

if (-not $Apply) {
  [ordered]@{
    progress = $Progress
    next_action = $Next
    result = $Result
  } | ConvertTo-Json -Depth 30
  exit 0
}

$HistoryRoot = Join-Path $Agy ('history\legacy-repair-budget\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if ($Legacy.Count -gt 0) {
  New-Item -ItemType Directory -Force -Path $HistoryRoot | Out-Null
}
foreach ($Path in $Legacy) {
  Move-Item -LiteralPath $Path -Destination (Join-Path $HistoryRoot ([System.IO.Path]::GetFileName($Path))) -Force
}

if ($null -ne $WorkItem) {
  [System.IO.File]::WriteAllText($WorkItemPath, ($WorkItem | ConvertTo-Json -Depth 40), $Utf8)
}
[System.IO.File]::WriteAllText((Join-Path $Agy 'PROGRESS_STATE.json'), ($Progress | ConvertTo-Json -Depth 30), $Utf8)
[System.IO.File]::WriteAllText((Join-Path $Agy 'NEXT_ACTION.json'), ($Next | ConvertTo-Json -Depth 20), $Utf8)
if ($null -ne $Handshake) {
  [System.IO.File]::WriteAllText($HandshakePath, ($Handshake | ConvertTo-Json -Depth 40), $Utf8)
}
[System.IO.File]::WriteAllText((Join-Path $Agy 'OWNER_AUTONOMY_MIGRATION_RESULT.json'), ($Result | ConvertTo-Json -Depth 20), $Utf8)

Write-Host 'Active work item migrated to progress-based continuation. Legacy and partial runtime-state shapes are supported.'
exit 0
