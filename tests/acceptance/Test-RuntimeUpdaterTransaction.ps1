[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-runtime-transaction-' + [Guid]::NewGuid().ToString('N'))
$BackupRoot = Join-Path $TempRoot 'backups'
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Updater = Join-Path $Root 'scripts\windows\Update-AgenticProjectRuntime-v1.2.9.ps1'
$Utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-Required([string]$FilePath, [string[]]$Arguments, [string]$Description) {
  $Result = Invoke-AgenticNativeProcess -FilePath $FilePath -ArgumentList $Arguments
  Assert-AgenticNativeSuccess -Result $Result -Description $Description
  return $Result
}

function New-Fixture([string]$Name) {
  $Project = Join-Path $TempRoot $Name
  New-Item -ItemType Directory -Force -Path $Project | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agents') -Destination (Join-Path $Project '.agents') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agy') -Destination (Join-Path $Project '.agy') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\scripts') -Destination (Join-Path $Project 'scripts') -Recurse -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $Project 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $Project 'src\product.txt'), "protected product bytes`n", $Utf8)
  Invoke-Required 'git' @('-C',$Project,'init','--quiet','--initial-branch=main') 'git init' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'config','user.email','runtime-regression@example.invalid') 'git config email' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'config','user.name','Runtime Regression') 'git config name' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'add','--all') 'git add' | Out-Null
  Invoke-Required 'git' @('-C',$Project,'commit','--quiet','-m','fixture baseline') 'git commit' | Out-Null
  return $Project
}

function Get-TreeSnapshot([string]$Project) {
  $Rows = New-Object System.Collections.Generic.List[string]
  foreach ($Directory in Get-ChildItem -LiteralPath $Project -Recurse -Force -Directory | Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }) {
    $Relative = $Directory.FullName.Substring($Project.Length).TrimStart('\').Replace('\','/')
    [void]$Rows.Add("D`0$Relative")
  }
  foreach ($File in Get-ChildItem -LiteralPath $Project -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $Relative = $File.FullName.Substring($Project.Length).TrimStart('\').Replace('\','/')
    [void]$Rows.Add("F`0$Relative`0$($File.Length)`0$((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant())")
  }
  return @($Rows.ToArray() | Sort-Object)
}

function Compare-Snapshot([string[]]$Before, [string[]]$After) {
  return @(Compare-Object -ReferenceObject $Before -DifferenceObject $After)
}

function Get-TextSha256([string]$Text) {
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Write-JsonFile([string]$Path, [object]$Value) {
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), $Utf8)
}

function Get-ProjectLockPath([string]$Project) {
  $LockRoot = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) '.locks'
  New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null
  $Resolved = (Resolve-Path -LiteralPath $Project).Path
  return Join-Path $LockRoot ((Get-TextSha256 $Resolved).Substring(0, 24) + '.lock')
}

function New-LegacyAuthorityFixture([string]$Name, [string]$Fault = '') {
  $Project = New-Fixture $Name
  $Agy = Join-Path $Project '.agy'
  $WorkItemId = 'synthetic-active-work-item'
  $LeaseId = 'synthetic-active-lease'
  $Goal = 'Preserve this exact synthetic owner goal.'
  $Head = (Invoke-Required 'git' @('-C',$Project,'rev-parse','HEAD') 'git fixture head').StdOut.Trim()
  $Branch = (Invoke-Required 'git' @('-C',$Project,'branch','--show-current') 'git fixture branch').StdOut.Trim()
  Write-JsonFile (Join-Path $Agy 'WORK_ITEM.json') ([ordered]@{ schema_version='1.0.0'; work_item_id=$WorkItemId; goal_epoch=3; goal=$Goal; owner_approved=$true; status='ready'; preferred_command='/nextphase'; repair_batch_limit=9 })
  $Scope = [ordered]@{ schema_version='1.0.0'; work_item_id=$WorkItemId; allowed_paths=@('src/**'); forbidden_domains=@('release') }
  if ($Fault -eq 'stale_scope_root') { $Scope['project_root'] = 'C:\stale\other-project' }
  Write-JsonFile (Join-Path $Agy 'EXECUTION_SCOPE.json') $Scope
  $ScopeHash = (Get-FileHash -LiteralPath (Join-Path $Agy 'EXECUTION_SCOPE.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  $Lease = [ordered]@{
    schema_version='1.0.0'; work_item_id=$WorkItemId; goal_epoch=3; lease_id=$LeaseId; status='active'
    project_root=$Project; worktree_root=$Project; branch=$Branch; baseline_head=$Head
    first_write_started=$true; first_write_started_at_utc='2026-08-08T00:00:00Z'
    owner_goal_sha256=(Get-TextSha256 $Goal); execution_scope_sha256=$ScopeHash
    allowed_paths=@('src/**'); route='/nextphase'
  }
  if ($Fault -eq 'stale_lease_root') { $Lease.project_root = 'C:\stale\other-project' }
  if ($Fault -eq 'stale_branch') { $Lease.branch = 'stale-owner-branch' }
  if ($Fault -eq 'stale_head') { $Lease.baseline_head = ('0' * 40) }
  if ($Fault -eq 'stale_goal_hash') { $Lease.owner_goal_sha256 = ('1' * 64) }
  if ($Fault -eq 'stale_scope_hash') { $Lease.execution_scope_sha256 = ('2' * 64) }
  Write-JsonFile (Join-Path $Agy 'EXECUTION_LEASE.json') $Lease
  Write-JsonFile (Join-Path $Agy 'STAGE_FIREWALL.json') ([ordered]@{ schema_version='1.0.0'; work_item_id=$WorkItemId; active_sub_scope='algorithm_repair'; protected_path_patterns=@('src/algorithm/**'); bound_findings=@('finding-synthetic') })
  if ($Fault -eq 'aborted_transactions') {
    Write-JsonFile (Join-Path $Agy 'WORK_ITEM_TRANSACTION.json') ([ordered]@{ schema_version='1.0.0'; status='aborted'; transaction_id='owner-aborted-work'; work_item_id='different-work-item'; goal_epoch=2 })
    Write-JsonFile (Join-Path $Agy 'EXECUTION_AUTHORITY_TRANSACTION.json') ([ordered]@{ schema_version='1.0.0'; status='aborted'; transaction_id='owner-aborted-authority'; work_item_id='different-work-item'; goal_epoch=2; lease_id='different-lease' })
  }
  return $Project
}

function New-StaleTransaction([string]$Project, [string]$Name, [string]$Phase, [object[]]$Paths, [object[]]$Directories) {
  $ProjectSlug = ([IO.Path]::GetFileName($Project) -replace '[^A-Za-z0-9._-]', '_')
  $TransactionId = 'runtime-1.2.9-' + $Name
  $StaleBackupRoot = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) (Join-Path $ProjectSlug $TransactionId)
  $JournalPath = Join-Path $StaleBackupRoot 'journal.json'
  New-Item -ItemType Directory -Force -Path $StaleBackupRoot | Out-Null
  Write-JsonFile $JournalPath ([ordered]@{ schema_version='1.1.0'; transaction_id=$TransactionId; phase=$Phase; project_root=(Resolve-Path -LiteralPath $Project).Path; paths=$Paths; directories=$Directories })
  $LockPath = Get-ProjectLockPath $Project
  Write-JsonFile $LockPath ([ordered]@{ schema_version='1.0.0'; phase='planning'; project_root=(Resolve-Path -LiteralPath $Project).Path; transaction_id=$TransactionId; backup_root=$StaleBackupRoot; journal_path=$JournalPath; created_at_utc='2026-08-08T00:00:00Z' })
  return [pscustomobject]@{ backup_root=$StaleBackupRoot; journal_path=$JournalPath; lock_path=$LockPath }
}

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  $Project = New-Fixture 'idempotent project юникод'
  Remove-Item -LiteralPath (Join-Path $Project '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $Project '.agy\NEXT_ACTION.json') -Force
  $ProductBefore = (Get-FileHash -LiteralPath (Join-Path $Project 'src\product.txt') -Algorithm SHA256).Hash
  $Common = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$Project,'-RepoRoot',$Root,'-Apply','-AllowDirty','-BackupBaseRoot',$BackupRoot)
  Invoke-Required $Pwsh $Common 'runtime updater first apply' | Out-Null
  foreach ($Required in @('.agy\PROGRESS_STATE.json','.agy\NEXT_ACTION.json','.agy\OWNER_AUTONOMY_MIGRATION_RESULT.json','.agy\INSTALLATION_MANIFEST.json','.agy\RUNTIME_UPDATE_RESULT.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Project $Required) -PathType Leaf)) { throw "Runtime updater omitted required state: $Required" }
  }
  if ((Get-FileHash -LiteralPath (Join-Path $Project 'src\product.txt') -Algorithm SHA256).Hash -ne $ProductBefore) { throw 'Runtime updater changed product source.' }
  $BeforeSecond = @(Get-TreeSnapshot $Project)
  Invoke-Required $Pwsh $Common 'runtime updater verification-only second apply' | Out-Null
  $AfterSecond = @(Get-TreeSnapshot $Project)
  $SecondDelta = @(Compare-Snapshot $BeforeSecond $AfterSecond)
  if ($SecondDelta.Count -gt 0) { throw "Second identical updater run changed bytes: $($SecondDelta.InputObject -join ', ')" }

  $FaultProject = New-Fixture 'rollback project'
  Remove-Item -LiteralPath (Join-Path $FaultProject '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $FaultProject '.agy\NEXT_ACTION.json') -Force
  [IO.File]::AppendAllText((Join-Path $FaultProject '.agents\AGENTS.md'), "fault probe`n", $Utf8)
  $BeforeFault = @(Get-TreeSnapshot $FaultProject)
  $Fault = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$FaultProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot,'-FaultInjectionAfterWrites','2')
  if ($Fault.ExitCode -eq 0 -or $Fault.StdErr + $Fault.StdOut -notmatch 'Injected runtime update failure') { throw 'Fault injection did not fail at the requested write boundary.' }
  $AfterFault = @(Get-TreeSnapshot $FaultProject)
  $FaultDelta = @(Compare-Snapshot $BeforeFault $AfterFault)
  if ($FaultDelta.Count -gt 0) { throw "Transactional rollback was not byte-exact: $($FaultDelta.InputObject -join ', ')" }

  $MigrationFaultProject = New-Fixture 'post-migration rollback project'
  Remove-Item -LiteralPath (Join-Path $MigrationFaultProject '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $MigrationFaultProject '.agy\NEXT_ACTION.json') -Force
  $BeforeMigrationFault = @(Get-TreeSnapshot $MigrationFaultProject)
  $MigrationFault = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$MigrationFaultProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot,'-FaultInjectionAfterMigration')
  if ($MigrationFault.ExitCode -eq 0 -or $MigrationFault.StdErr + $MigrationFault.StdOut -notmatch 'Injected runtime update failure after migration') { throw 'Post-migration fault injection did not reach the requested boundary.' }
  $MigrationFaultDelta = @(Compare-Snapshot $BeforeMigrationFault (Get-TreeSnapshot $MigrationFaultProject))
  if ($MigrationFaultDelta.Count -gt 0) { throw "Post-migration rollback was not byte-exact: $($MigrationFaultDelta.InputObject -join ', ')" }

  $LockProject = New-Fixture 'active lock contention project'
  $LockPath = Get-ProjectLockPath $LockProject
  $ActiveLock = [IO.File]::Open($LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $LockFault = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$LockProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot)
    if ($LockFault.ExitCode -eq 0 -or $LockFault.StdErr + $LockFault.StdOut -notmatch 'Another runtime transaction is active') { throw 'An actively held runtime lock was not rejected.' }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { throw 'Failed lock contender removed the actively held lock.' }
  }
  finally { $ActiveLock.Dispose() }
  Remove-Item -LiteralPath $LockPath -Force

  $EmptyLockProject = New-Fixture 'empty stale pre-mutation lock project'
  $EmptyLockBefore = @(Get-TreeSnapshot $EmptyLockProject)
  $EmptyLockPath = Get-ProjectLockPath $EmptyLockProject
  $EmptyLockStream = [IO.File]::Open($EmptyLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $EmptyLockStream.Dispose()
  $EmptyLockRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$EmptyLockProject,'-RepoRoot',$Root,'-BackupBaseRoot',$BackupRoot)
  if ($EmptyLockRun.ExitCode -ne 0 -or $EmptyLockRun.StdErr + $EmptyLockRun.StdOut -notmatch 'empty stale pre-mutation runtime lock') { throw "Empty stale pre-mutation lock recovery failed: $($EmptyLockRun.StdErr)" }
  if (Test-Path -LiteralPath $EmptyLockPath -PathType Leaf) { throw 'Empty stale pre-mutation lock was not cleaned.' }
  if (@(Compare-Snapshot $EmptyLockBefore (Get-TreeSnapshot $EmptyLockProject)).Count -gt 0) { throw 'Empty stale pre-mutation lock recovery changed the project.' }

  $CommittedProject = New-Fixture 'stale committed lock project'
  $CommittedBefore = @(Get-TreeSnapshot $CommittedProject)
  $CommittedState = New-StaleTransaction -Project $CommittedProject -Name 'stale-committed' -Phase 'committed' -Paths @() -Directories @()
  $CommittedRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$CommittedProject,'-RepoRoot',$Root,'-BackupBaseRoot',$BackupRoot)
  if ($CommittedRun.ExitCode -ne 0) { throw "Stale committed lock cleanup failed: $($CommittedRun.StdErr)" }
  if (Test-Path -LiteralPath $CommittedState.lock_path -PathType Leaf) { throw 'Stale committed lock was not cleaned.' }
  if (@(Compare-Snapshot $CommittedBefore (Get-TreeSnapshot $CommittedProject)).Count -gt 0) { throw 'Stale committed lock cleanup changed the project.' }

  $BackedUpProject = New-Fixture 'interrupted backed-up project'
  $BackedUpBefore = @(Get-TreeSnapshot $BackedUpProject)
  $BackedTarget = Join-Path $BackedUpProject '.agents\AGENTS.md'
  $BackedHash = (Get-FileHash -LiteralPath $BackedTarget -Algorithm SHA256).Hash.ToLowerInvariant()
  $BackedState = New-StaleTransaction -Project $BackedUpProject -Name 'stale-backed-up' -Phase 'backed_up' -Paths @([pscustomobject]@{ relative='.agents/AGENTS.md'; existed=$true; sha256=$BackedHash }) -Directories @([pscustomobject]@{ relative='.agents'; existed=$true })
  $BackedCopy = Join-Path $BackedState.backup_root 'files\.agents\AGENTS.md'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BackedCopy) | Out-Null
  Copy-Item -LiteralPath $BackedTarget -Destination $BackedCopy -Force
  $BackedRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$BackedUpProject,'-RepoRoot',$Root,'-BackupBaseRoot',$BackupRoot)
  if ($BackedRun.ExitCode -ne 0) { throw "Interrupted backed-up recovery failed: $($BackedRun.StdErr)" }
  if (@(Compare-Snapshot $BackedUpBefore (Get-TreeSnapshot $BackedUpProject)).Count -gt 0) { throw 'Interrupted backed-up recovery was not byte/topology exact.' }
  if ([string](Get-Content -LiteralPath $BackedState.journal_path -Raw -Encoding UTF8 | ConvertFrom-Json).phase -ne 'rolled_back') { throw 'Interrupted backed-up journal was not marked rolled_back.' }

  $MidWriteProject = New-Fixture 'interrupted mid-write project'
  Remove-Item -LiteralPath (Join-Path $MidWriteProject 'scripts\github') -Recurse -Force
  Invoke-Required 'git' @('-C',$MidWriteProject,'add','--all') 'git stage absent-directory baseline' | Out-Null
  Invoke-Required 'git' @('-C',$MidWriteProject,'commit','--quiet','-m','baseline without github runtime directory') 'git commit absent-directory baseline' | Out-Null
  $MidWriteBefore = @(Get-TreeSnapshot $MidWriteProject)
  $ExistingTarget = Join-Path $MidWriteProject '.agents\AGENTS.md'
  $ExistingHash = (Get-FileHash -LiteralPath $ExistingTarget -Algorithm SHA256).Hash.ToLowerInvariant()
  $MidWriteState = New-StaleTransaction -Project $MidWriteProject -Name 'stale-mid-write' -Phase 'backed_up' -Paths @(
    [pscustomobject]@{ relative='.agents/AGENTS.md'; existed=$true; sha256=$ExistingHash },
    [pscustomobject]@{ relative='scripts/github/Sync-GitHub.ps1'; existed=$false; sha256=$null }
  ) -Directories @(
    [pscustomobject]@{ relative='.agents'; existed=$true },
    [pscustomobject]@{ relative='scripts'; existed=$true },
    [pscustomobject]@{ relative='scripts/github'; existed=$false }
  )
  $ExistingBackup = Join-Path $MidWriteState.backup_root 'files\.agents\AGENTS.md'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ExistingBackup) | Out-Null
  Copy-Item -LiteralPath $ExistingTarget -Destination $ExistingBackup -Force
  [IO.File]::AppendAllText($ExistingTarget, "interrupted mutation`n", $Utf8)
  New-Item -ItemType Directory -Force -Path (Join-Path $MidWriteProject 'scripts\github') | Out-Null
  [IO.File]::WriteAllText((Join-Path $MidWriteProject 'scripts\github\Sync-GitHub.ps1'), 'interrupted new file', $Utf8)
  $MidWriteRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$MidWriteProject,'-RepoRoot',$Root,'-AllowDirty','-BackupBaseRoot',$BackupRoot)
  if ($MidWriteRun.ExitCode -ne 0) { throw "Interrupted mid-write recovery failed: $($MidWriteRun.StdErr)" }
  $MidWriteDelta = @(Compare-Snapshot $MidWriteBefore (Get-TreeSnapshot $MidWriteProject))
  if ($MidWriteDelta.Count -gt 0) { throw "Interrupted mid-write recovery was not byte/topology exact: $($MidWriteDelta.InputObject -join ', '). stdout=$($MidWriteRun.StdOut) stderr=$($MidWriteRun.StdErr)" }
  if ([string](Get-Content -LiteralPath $MidWriteState.journal_path -Raw -Encoding UTF8 | ConvertFrom-Json).phase -ne 'rolled_back') { throw 'Interrupted mid-write journal was not marked rolled_back.' }

  $LegacyProject = New-LegacyAuthorityFixture 'valid missing-transaction legacy authority'
  $LegacyProduct = (Get-FileHash -LiteralPath (Join-Path $LegacyProject 'src\product.txt') -Algorithm SHA256).Hash
  $LegacyLeaseBefore = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\EXECUTION_LEASE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $LegacyRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$LegacyProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot)
  if ($LegacyRun.ExitCode -ne 0) { throw "Truthful missing-transaction legacy adoption failed: $($LegacyRun.StdErr)" }
  $LegacyWorkTx = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\WORK_ITEM_TRANSACTION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $LegacyAuthorityTx = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\EXECUTION_AUTHORITY_TRANSACTION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $LegacyLeaseAfter = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\EXECUTION_LEASE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $LegacyScopeAfter = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\EXECUTION_SCOPE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $LegacyFirewallAfter = Get-Content -LiteralPath (Join-Path $LegacyProject '.agy\STAGE_FIREWALL.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($LegacyWorkTx.status -ne 'committed' -or $LegacyAuthorityTx.status -ne 'committed' -or $LegacyScopeAfter.status -ne 'exact' -or $LegacyFirewallAfter.status -ne 'active') { throw 'Truthful legacy adoption did not create canonical committed authority.' }
  if ($LegacyLeaseAfter.first_write_started -ne $true -or [string]$LegacyLeaseAfter.first_write_started_at_utc -ne [string]$LegacyLeaseBefore.first_write_started_at_utc -or [string]$LegacyLeaseAfter.baseline_head -ne [string]$LegacyLeaseBefore.baseline_head) { throw 'Truthful legacy adoption changed active-write/baseline identity.' }
  if ((Get-FileHash -LiteralPath (Join-Path $LegacyProject 'src\product.txt') -Algorithm SHA256).Hash -ne $LegacyProduct) { throw 'Truthful legacy adoption changed product source.' }

  foreach ($FaultName in @('aborted_transactions','stale_scope_root','stale_lease_root','stale_branch','stale_head','stale_goal_hash','stale_scope_hash')) {
    $AdversarialProject = New-LegacyAuthorityFixture ("adversarial legacy $FaultName") $FaultName
    $AdversarialBefore = @(Get-TreeSnapshot $AdversarialProject)
    $AdversarialRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$AdversarialProject,'-RepoRoot',$Root,'-Apply','-AllowDirty','-SkipValidation','-BackupBaseRoot',$BackupRoot)
    if ($AdversarialRun.ExitCode -eq 0) { throw "Contradictory legacy authority was accepted: $FaultName" }
    $AdversarialDelta = @(Compare-Snapshot $AdversarialBefore (Get-TreeSnapshot $AdversarialProject))
    if ($AdversarialDelta.Count -gt 0) { throw "Contradictory legacy authority changed target bytes/topology before rejection ($FaultName): $($AdversarialDelta.InputObject -join ', ')" }
    if (Test-Path -LiteralPath (Get-ProjectLockPath $AdversarialProject) -PathType Leaf) { throw "Contradictory legacy rejection left a lock: $FaultName" }
  }

  Write-Host 'Runtime updater transaction, resumable recovery, fail-closed legacy adoption, rollback, lock ownership, product preservation and byte-identical second run passed.'
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
