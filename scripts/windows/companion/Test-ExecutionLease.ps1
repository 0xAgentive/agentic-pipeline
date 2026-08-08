[CmdletBinding()]
param(
  [string]$ProjectRoot = ".",
  [switch]$BeforeWrite,
  [switch]$MarkWriteStarted
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root ".agy"
. (Join-Path $PSScriptRoot '..\common\NativeProcess.ps1')
$WorkItemPath = Join-Path $Agy "WORK_ITEM.json"
$ScopePath = Join-Path $Agy "EXECUTION_SCOPE.json"
$LeasePath = Join-Path $Agy "EXECUTION_LEASE.json"
$FirewallPath = Join-Path $Agy "STAGE_FIREWALL.json"
$WorkTransactionPath = Join-Path $Agy "WORK_ITEM_TRANSACTION.json"
$AuthorityTransactionPath = Join-Path $Agy "EXECUTION_AUTHORITY_TRANSACTION.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($Path in @($WorkItemPath,$ScopePath,$LeasePath,$FirewallPath,$WorkTransactionPath,$AuthorityTransactionPath)) { if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Execution lease authority missing: $Path" } }
$WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw | ConvertFrom-Json
$ScopeRaw = Get-Content -LiteralPath $ScopePath -Raw
$Scope = $ScopeRaw | ConvertFrom-Json
$Lease = Get-Content -LiteralPath $LeasePath -Raw | ConvertFrom-Json
$Firewall = Get-Content -LiteralPath $FirewallPath -Raw | ConvertFrom-Json
$WorkTransaction = Get-Content -LiteralPath $WorkTransactionPath -Raw | ConvertFrom-Json
$AuthorityTransaction = Get-Content -LiteralPath $AuthorityTransactionPath -Raw | ConvertFrom-Json
function Invoke-Git([string[]]$Arguments) { $Result=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList (@('-C',$Root)+$Arguments);Assert-AgenticNativeSuccess -Result $Result -Description 'git';return $Result.StdOut.Trim() }
function HashText([string]$Text) { $B=[Text.Encoding]::UTF8.GetBytes($Text);$H=[Security.Cryptography.SHA256]::Create();try{return ([Convert]::ToHexString($H.ComputeHash($B))).ToLowerInvariant()}finally{$H.Dispose()} }
$Errors = New-Object System.Collections.Generic.List[string]
if ($Lease.status -ne "active") { $Errors.Add("EXECUTION_LEASE_NOT_ACTIVE") }
if ($Scope.status -ne "exact") { $Errors.Add("EXECUTION_SCOPE_NOT_EXACT") }
if ($Firewall.status -ne "active" -or [string]$Firewall.work_item_id -ne [string]$WorkItem.work_item_id) { $Errors.Add("STAGE_FIREWALL_NOT_ACTIVE") }
if ($WorkTransaction.status -ne "committed" -or [string]$WorkTransaction.work_item_id -ne [string]$WorkItem.work_item_id) { $Errors.Add("WORK_ITEM_TRANSACTION_NOT_COMMITTED") }
if ($AuthorityTransaction.status -ne "committed" -or [string]$AuthorityTransaction.work_item_id -ne [string]$WorkItem.work_item_id -or [string]$AuthorityTransaction.lease_id -ne [string]$Lease.lease_id) { $Errors.Add("EXECUTION_AUTHORITY_TRANSACTION_NOT_COMMITTED") }
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
