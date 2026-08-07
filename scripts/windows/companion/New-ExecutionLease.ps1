[CmdletBinding()]
param(
  [string]$ProjectRoot = ".",
  [ValidateSet("general","protocol_freeze","analytical_validation","empirical_validation")]
  [string]$StageProfile = "general",
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root ".agy"
$WorkItemPath = Join-Path $Agy "WORK_ITEM.json"
$ScopePath = Join-Path $Agy "EXECUTION_SCOPE.json"
$LeasePath = Join-Path $Agy "EXECUTION_LEASE.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($Path in @($WorkItemPath,$ScopePath)) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required authority missing: $Path" }
}
$WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw | ConvertFrom-Json
$Scope = Get-Content -LiteralPath $ScopePath -Raw | ConvertFrom-Json
if ($WorkItem.owner_approved -ne $true) { throw "WORK_ITEM is not owner-approved." }
if ($Scope.status -ne "exact") { throw "EXECUTION_SCOPE must be exact before a lease can be issued." }
if ([string]$WorkItem.work_item_id -ne [string]$Scope.work_item_id) { throw "WORK_ITEM and EXECUTION_SCOPE identify different work items." }

function Invoke-Git([string[]]$Arguments) {
  $Output = @(& git -C $Root @Arguments 2>&1)
  $Code = $LASTEXITCODE
  if ($Code -ne 0) { throw "git $($Arguments -join ' ') failed: $($Output -join [Environment]::NewLine)" }
  return ($Output -join "`n").Trim()
}
function Get-Sha256Text([string]$Text) {
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Hash = [System.Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hash.ComputeHash($Bytes))).ToLowerInvariant() }
  finally { $Hash.Dispose() }
}

$GitRoot = (Invoke-Git @("rev-parse","--show-toplevel"))
$Branch = (Invoke-Git @("rev-parse","--abbrev-ref","HEAD"))
$Head = (Invoke-Git @("rev-parse","HEAD"))
$ScopeRaw = Get-Content -LiteralPath $ScopePath -Raw
$GoalHash = Get-Sha256Text ([string]$WorkItem.goal)
$ScopeHash = Get-Sha256Text $ScopeRaw
$LeaseId = "lease-" + ([guid]::NewGuid().ToString("N"))
$Now = (Get-Date).ToUniversalTime().ToString("o")
$Allowed = @($Scope.allowed_paths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($Allowed.Count -eq 0) { throw "EXECUTION_SCOPE.allowed_paths is empty." }

$Lease = [ordered]@{
  schema_version = "1.0.0"
  lease_id = $LeaseId
  status = "active"
  work_item_id = [string]$WorkItem.work_item_id
  goal_epoch = [int]$WorkItem.goal_epoch
  assurance_mode = [string]$WorkItem.assurance_mode
  project_root = $Root
  worktree_root = $GitRoot
  branch = $Branch
  baseline_head = $Head
  owner_goal_sha256 = $GoalHash
  execution_scope_sha256 = $ScopeHash
  allowed_paths = $Allowed
  allowed_command_patterns = @($Scope.allowed_command_patterns | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  forbidden_domains = @($Scope.forbidden_domains | ForEach-Object { [string]$_ })
  stage_profile = $StageProfile
  first_write_started = $false
  first_write_started_at_utc = $null
  issued_at_utc = $Now
  invalidated_at_utc = $null
  invalidation_reasons = @()
}

if ($Apply) {
  New-Item -ItemType Directory -Force $Agy | Out-Null
  $Temp = $LeasePath + ".tmp"
  [System.IO.File]::WriteAllText($Temp, ($Lease | ConvertTo-Json -Depth 20), $Utf8NoBom)
  Move-Item -LiteralPath $Temp -Destination $LeasePath -Force
  Write-Host "Execution lease issued: $LeasePath"
} else {
  $Lease | ConvertTo-Json -Depth 20
  Write-Host "Dry-run only. Add -Apply to write EXECUTION_LEASE.json."
}
