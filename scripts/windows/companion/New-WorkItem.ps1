[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [Parameter(Mandatory = $true)][string]$Goal,
  [ValidateSet('flow', 'guarded', 'release')][string]$AssuranceMode = 'flow',
  [ValidateSet('/nextphase', '/fastpatch')][string]$PreferredCommand = '/nextphase',
  [ValidateSet('general', 'protocol_freeze', 'analytical_validation', 'empirical_validation')][string]$StageProfile = 'general',
  [string]$WorkItemId = '',
  [string[]]$Acceptance = @(),
  [string[]]$NonGoals = @(),
  [string[]]$RiskHints = @(),
  [hashtable]$AuditDimensions = @{},
  [string]$PipelineRoot = '',
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Root '.agy'
$TransactionScript = Join-Path $Root 'scripts\windows\companion\Start-WorkItemTransaction.ps1'

if (-not (Test-Path -LiteralPath $TransactionScript -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($PipelineRoot)) {
  $ResolvedPipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
  $TransactionScript = Join-Path $ResolvedPipeline 'scripts\windows\companion\Start-WorkItemTransaction.ps1'
}

if (-not (Test-Path -LiteralPath $TransactionScript -PathType Leaf)) {
  throw "Atomic work-item transaction is missing in both the project and Pipeline root: $TransactionScript"
}
if ([string]::IsNullOrWhiteSpace($Goal)) { throw 'Goal is required.' }

$Epoch = 1
$ExistingPath = Join-Path $AgyRoot 'WORK_ITEM.json'
if (Test-Path -LiteralPath $ExistingPath -PathType Leaf) {
  try {
    $Previous = Get-Content -LiteralPath $ExistingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $EpochProperty = $Previous.PSObject.Properties['goal_epoch']
    if ($null -ne $EpochProperty -and $null -ne $EpochProperty.Value) {
      $Epoch = [int]$EpochProperty.Value + 1
    }
  }
  catch {
    throw "Existing WORK_ITEM.json is invalid: $($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($WorkItemId)) {
  $Slug = ($Goal.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'work-item' }
  if ($Slug.Length -gt 72) { $Slug = $Slug.Substring(0, 72).Trim('-') }
  $WorkItemId = "$Slug-$Epoch"
}

$Packet = [ordered]@{
  schema_version = '1.0.0'
  packet_id = 'local-' + [Guid]::NewGuid().ToString('N')
  ecosystem_version = '1.2.26'
  packet_format = 'single_json'
  operation = 'new_work_item'
  route = $PreferredCommand
  project_id = Split-Path -Leaf $Root
  project_root_hint = $Root
  work_item_id = $WorkItemId
  goal_epoch = $Epoch
  goal = $Goal.Trim()
  assurance_mode = $AssuranceMode
  stage_profile = $StageProfile
  owner_approved = $true
  owner_interaction_policy = 'hard_stop_only'
  scope_binding = 'executor_discovery'
  technical_task_file = 'AGENT_TASK.md'
  owner_summary_file = 'OWNER_SUMMARY_RU.md'
  created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  acceptance = [string[]]@($Acceptance | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  non_goals = [string[]]@($NonGoals | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  risk_hints = [string[]]@($RiskHints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  audit_dimensions = $AuditDimensions
}

$PacketPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-work-item-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
  [System.IO.File]::WriteAllText($PacketPath, ($Packet | ConvertTo-Json -Depth 30), $Utf8NoBom)
  $InvocationArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $TransactionScript,
    '-ProjectRoot', $Root,
    '-ActionPacketPath', $PacketPath
  )
  if ($Apply) { $InvocationArguments += '-Apply' }

  & (Get-Command pwsh -ErrorAction Stop).Source @InvocationArguments
  if ($LASTEXITCODE -ne 0) { throw 'Atomic work-item transaction failed.' }

  if ($Apply) {
    Write-Host "Work item activated with progress-based continuation: $WorkItemId"
    Write-Host "Goal epoch: $Epoch"
    Write-Host "Preferred initial route: $PreferredCommand"
  }
}
finally {
  Remove-Item -LiteralPath $PacketPath -Force -ErrorAction SilentlyContinue
}
