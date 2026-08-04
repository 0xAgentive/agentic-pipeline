[CmdletBinding()]
param(
  [string]$ProjectRoot = ".",
  [switch]$BeforeWrite,
  [switch]$MarkWriteStarted
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root ".agy"
$WorkItemPath = Join-Path $Agy "WORK_ITEM.json"
$ScopePath = Join-Path $Agy "EXECUTION_SCOPE.json"
$LeasePath = Join-Path $Agy "EXECUTION_LEASE.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($Path in @($WorkItemPath,$ScopePath,$LeasePath)) { if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Execution lease authority missing: $Path" } }
$WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw | ConvertFrom-Json
$ScopeRaw = Get-Content -LiteralPath $ScopePath -Raw
$Scope = $ScopeRaw | ConvertFrom-Json
$Lease = Get-Content -LiteralPath $LeasePath -Raw | ConvertFrom-Json
function Invoke-Git([string[]]$Arguments) { $O=@(& git -C $Root @Arguments 2>&1); if($LASTEXITCODE-ne 0){throw "git failed: $($O -join ' ')"}; return ($O -join "`n").Trim() }
function HashText([string]$Text) { $B=[Text.Encoding]::UTF8.GetBytes($Text);$H=[Security.Cryptography.SHA256]::Create();try{return ([Convert]::ToHexString($H.ComputeHash($B))).ToLowerInvariant()}finally{$H.Dispose()} }
$Errors = New-Object System.Collections.Generic.List[string]
if ($Lease.status -ne "active") { $Errors.Add("EXECUTION_LEASE_NOT_ACTIVE") }
if ([string]$WorkItem.work_item_id -ne [string]$Scope.work_item_id -or [string]$WorkItem.work_item_id -ne [string]$Lease.work_item_id) { $Errors.Add("WORK_ITEM_ID_MISMATCH") }
if ([int]$WorkItem.goal_epoch -ne [int]$Lease.goal_epoch) { $Errors.Add("GOAL_EPOCH_MISMATCH") }
if ((HashText ([string]$WorkItem.goal)) -ne [string]$Lease.owner_goal_sha256) { $Errors.Add("OWNER_GOAL_FINGERPRINT_MISMATCH") }
if ((HashText $ScopeRaw) -ne [string]$Lease.execution_scope_sha256) { $Errors.Add("EXECUTION_SCOPE_FINGERPRINT_MISMATCH") }
$GitRoot=Invoke-Git @("rev-parse","--show-toplevel");$Branch=Invoke-Git @("rev-parse","--abbrev-ref","HEAD");$Head=Invoke-Git @("rev-parse","HEAD")
if ([IO.Path]::GetFullPath($GitRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath([string]$Lease.worktree_root).TrimEnd('\')) { $Errors.Add("WORKTREE_ROOT_MISMATCH") }
if ($Branch -ne [string]$Lease.branch) { $Errors.Add("BRANCH_MISMATCH") }
if ($BeforeWrite -and $Lease.first_write_started -ne $true -and $Head -ne [string]$Lease.baseline_head) { $Errors.Add("BASELINE_HEAD_MISMATCH") }
if (@($Lease.allowed_paths).Count -eq 0) { $Errors.Add("LEASE_ALLOWED_PATHS_EMPTY") }
if ($Errors.Count -gt 0) { Write-Host "Execution lease invalid:"; $Errors | ForEach-Object { Write-Host "- $_" }; exit 1 }
if ($MarkWriteStarted -and $Lease.first_write_started -ne $true) {
  $Lease.first_write_started = $true
  $Lease.first_write_started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  $Temp=$LeasePath+".tmp";[IO.File]::WriteAllText($Temp,($Lease|ConvertTo-Json -Depth 20),$Utf8NoBom);Move-Item $Temp $LeasePath -Force
}
Write-Host "Execution lease valid: $($Lease.lease_id)"
exit 0
