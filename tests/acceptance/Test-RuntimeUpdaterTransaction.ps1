[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-runtime-transaction-' + [Guid]::NewGuid().ToString('N'))
$BackupRoot = Join-Path $TempRoot 'backups'
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Updater = Join-Path $Root 'scripts\windows\Update-AgenticProjectRuntime-v1.2.15.ps1'
$Utf8 = [Text.UTF8Encoding]::new($false)
$ExpectedEcosystemVersion = [string](Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json).ecosystem_version
$LegacyFindingsArchiveRelative = ".agy/history/legacy-findings/runtime-$ExpectedEcosystemVersion/FINDINGS.json"
$SourceCommitProbe = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
$ExpectedRuntimeSourceCommit = if ($SourceCommitProbe.ExitCode -eq 0 -and $SourceCommitProbe.StdOut.Trim() -match '^[0-9a-fA-F]{40}$') {
  $SourceCommitProbe.StdOut.Trim()
} else {
  [string](Get-Content -LiteralPath (Join-Path $Root 'SOURCE_IDENTITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json).source_commit
}
if ($ExpectedRuntimeSourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Runtime transaction regression cannot resolve an exact source commit.' }
$UpdaterText = Get-Content -LiteralPath $Updater -Raw -Encoding UTF8
if ($UpdaterText -notmatch '(?s)\$null\s+-ne\s+\$OverlayManifest.*?ExpectedSourceCommit is required when installing an extracted release asset') {
  throw 'Runtime updater does not fail closed when a release overlay lacks ExpectedSourceCommit.'
}

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
  Invoke-Required 'git' @('-C',$Project,'config','core.filemode','false') 'git config Windows file-mode semantics' | Out-Null
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

function Write-H10LikeLegacyFindings([string]$Project, [string]$Fault = '') {
  $Definitions = @(
    @('adapter_placeholder','product_blocker','fixed_unverified','initial_audit'),
    @('algorithm_defect','product_blocker','fixed_unverified','initial_audit'),
    @('algorithm_defect','product_blocker','fixed_unverified','initial_audit'),
    @('algorithm_defect','product_blocker','fixed_unverified','initial_audit'),
    @('audit_candidate_unbound','verification_blocker','fixed_unverified','audit_coverage_miss'),
    @('coverage_matrix_incomplete','verification_blocker','open_confirmed','audit_coverage_miss'),
    @('evidence_gap','verification_blocker','deferred','initial_audit'),
    @('external_dependency','verification_blocker','deferred','initial_audit'),
    @('findings_schema_invalid','verification_blocker','fixed_unverified','audit_coverage_miss'),
    @('governance_gap','verification_blocker','deferred','initial_audit'),
    @('lease_authority_defective','verification_blocker','verified_resolved','authority_audit'),
    @('oracle_circularity','product_blocker','fixed_unverified','initial_audit'),
    @('repair_delta_missing','verification_blocker','verified_resolved','authority_audit'),
    @('report_mismatch','product_blocker','fixed_unverified','initial_audit'),
    @('runtime_routing_stale','verification_blocker','verified_resolved','authority_audit'),
    @('stage_firewall_absent','verification_blocker','verified_resolved','authority_audit'),
    @('test_evidence_gap','verification_blocker','fixed_unverified','initial_audit'),
    @('timestamp_not_utc','verification_blocker','verified_resolved','audit_coverage_miss'),
    @('work_item_corruption','verification_blocker','open_confirmed','initial_audit')
  )
  $Findings = New-Object System.Collections.Generic.List[object]
  for ($Index = 0; $Index -lt $Definitions.Count; $Index++) {
    $Number = $Index + 1
    $Definition = $Definitions[$Index]
    $AffectedPaths = @("src/h10-like-$('{0:d2}' -f $Number).txt")
    if ($Number % 3 -ne 1) { $AffectedPaths += "tests/h10-like-$('{0:d2}' -f $Number).test" }
    if ($Number % 3 -eq 0) { $AffectedPaths += "reports/h10-like-$('{0:d2}' -f $Number).md" }
    $Finding = [ordered]@{
      finding_id = 'H10-LIKE-{0:d3}' -f $Number
      title = "Synthetic H10-like legacy finding $Number"
      category = [string]$Definition[0]
      description = "Preserve this exact synthetic legacy description for finding $Number."
      affected_paths = [object[]]$AffectedPaths
      lifecycle_status = [string]$Definition[2]
      materiality = [string]$Definition[1]
      origin = [string]$Definition[3]
      coverage_id = 'H10-COVERAGE-{0:d3}' -f $Number
    }
    if ($Index -eq 0 -and $Fault -eq 'unknown_category') { $Finding['category'] = 'unrecognized_h10_category' }
    if ($Index -eq 0 -and $Fault -eq 'unknown_shape') { $Finding['unexpected_legacy_field'] = 'must fail closed' }
    [void]$Findings.Add($Finding)
  }
  $Head = (Invoke-Required 'git' @('-C',$Project,'rev-parse','HEAD') 'git H10-like fixture head').StdOut.Trim()
  $Document = [ordered]@{
    schema_version = '1.0.0'
    work_item_id = 'execute-h10-like-analytical-validation'
    target_head = $Head
    candidate_manifest_id = 'candidate-manifest-h10-like-legacy'
    findings = [object[]]$Findings.ToArray()
    updated_at_utc = '2026-08-05T13:02:00Z'
  }
  $Path = Join-Path $Project '.agy\FINDINGS.json'
  Write-JsonFile -Path $Path -Value $Document
  return $Path
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
  $TransactionId = 'runtime-1.2.15-' + $Name
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
  $IdentityMismatchProject = New-Fixture 'source identity mismatch'
  $IdentityMismatchBefore = @(Get-TreeSnapshot $IdentityMismatchProject)
  $IdentityMismatch = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$IdentityMismatchProject,'-RepoRoot',$Root,'-ExpectedSourceCommit',('0' * 40),'-AllowDirty','-BackupBaseRoot',$BackupRoot)
  if ($IdentityMismatch.ExitCode -eq 0 -or $IdentityMismatch.StdErr -notmatch 'does not match ExpectedSourceCommit') { throw 'Runtime updater did not reject a mismatched expected source commit.' }
  if (@(Compare-Snapshot -Before $IdentityMismatchBefore -After @(Get-TreeSnapshot $IdentityMismatchProject)).Count -ne 0) { throw 'Source-identity rejection changed the project fixture.' }

  $Project = New-Fixture 'idempotent project юникод'
  Remove-Item -LiteralPath (Join-Path $Project '.agy\PROGRESS_STATE.json') -Force
  Remove-Item -LiteralPath (Join-Path $Project '.agy\NEXT_ACTION.json') -Force
  $ProductBefore = (Get-FileHash -LiteralPath (Join-Path $Project 'src\product.txt') -Algorithm SHA256).Hash
  $Common = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$Project,'-RepoRoot',$Root,'-ExpectedSourceCommit',$ExpectedRuntimeSourceCommit,'-Apply','-AllowDirty','-BackupBaseRoot',$BackupRoot)
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

  $FindingsProject = New-Fixture 'H10-like legacy findings migration'
  $LegacyFindingsPath = Write-H10LikeLegacyFindings -Project $FindingsProject
  [byte[]]$LegacyFindingsBytes = [IO.File]::ReadAllBytes($LegacyFindingsPath)
  $LegacyFindingsDocument = Get-Content -LiteralPath $LegacyFindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
  $LegacyFindingsSha = (Get-FileHash -LiteralPath $LegacyFindingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $FindingsProductBefore = (Get-FileHash -LiteralPath (Join-Path $FindingsProject 'src\product.txt') -Algorithm SHA256).Hash
  $FindingsCommon = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$FindingsProject,'-RepoRoot',$Root,'-ExpectedSourceCommit',$ExpectedRuntimeSourceCommit,'-Apply','-AllowDirty','-SkipActiveWorkItemMigration','-BackupBaseRoot',$BackupRoot)
  $FindingsRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList $FindingsCommon
  if ($FindingsRun.ExitCode -ne 0) { throw "H10-like legacy findings migration failed: stdout=$($FindingsRun.StdOut) stderr=$($FindingsRun.StdErr)" }
  $FindingsArchivePath = Join-Path $FindingsProject $LegacyFindingsArchiveRelative.Replace('/','\')
  if (-not (Test-Path -LiteralPath $FindingsArchivePath -PathType Leaf)) { throw 'Legacy FINDINGS.json byte archive was not created at the versioned path.' }
  if ((Get-FileHash -LiteralPath $FindingsArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $LegacyFindingsSha -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($FindingsArchivePath)) -cne [Convert]::ToBase64String($LegacyFindingsBytes)) { throw 'Legacy FINDINGS.json history archive is not byte-identical to the original.' }
  $MigratedFindingsDocument = Get-Content -LiteralPath $LegacyFindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
  $ExpectedTopProperties = @('schema_version','work_item_id','target_head','findings','updated_at_utc')
  if ((@($MigratedFindingsDocument.PSObject.Properties.Name) -join "`0") -cne ($ExpectedTopProperties -join "`0") -or @($MigratedFindingsDocument.findings).Count -ne 19) { throw 'Migrated finding set does not have the exact canonical top-level shape/count.' }
  $CategoryMap = @{
    adapter_placeholder='delivery'; algorithm_defect='research_validity'; audit_candidate_unbound='reproducibility'; coverage_matrix_incomplete='reproducibility'
    evidence_gap='reproducibility'; external_dependency='delivery'; findings_schema_invalid='data_integrity'; governance_gap='safety'
    lease_authority_defective='safety'; oracle_circularity='research_validity'; repair_delta_missing='observability'; report_mismatch='data_integrity'
    runtime_routing_stale='safety'; stage_firewall_absent='safety'; test_evidence_gap='reproducibility'; timestamp_not_utc='data_integrity'; work_item_corruption='data_integrity'
  }
  $OriginMap = @{ initial_audit='initial_audit'; audit_coverage_miss='audit_coverage_miss'; authority_audit='verification' }
  foreach ($LegacyFinding in @($LegacyFindingsDocument.findings)) {
    $MigratedFinding = @($MigratedFindingsDocument.findings | Where-Object { [string]$_.finding_id -ceq [string]$LegacyFinding.finding_id })
    if ($MigratedFinding.Count -ne 1) { throw "Migrated finding identity was lost or duplicated: $($LegacyFinding.finding_id)" }
    $MigratedFinding = $MigratedFinding[0]
    $ExpectedSeverity = if ([string]$LegacyFinding.materiality -ceq 'product_blocker') { 'blocker' } else { 'high' }
    $ExpectedPhase = if ([string]$LegacyFinding.lifecycle_status -ceq 'deferred') { 'deferred_debt' } else { 'current_phase_blocker' }
    if ([string]$MigratedFinding.category -cne [string]$CategoryMap[[string]$LegacyFinding.category] -or [string]$MigratedFinding.severity -cne $ExpectedSeverity -or [string]$MigratedFinding.phase_classification -cne $ExpectedPhase -or [string]$MigratedFinding.origin -cne [string]$OriginMap[[string]$LegacyFinding.origin]) { throw "Legacy finding mapping mismatch: $($LegacyFinding.finding_id)" }
    if ([string]$MigratedFinding.title -cne [string]$LegacyFinding.title -or [string]$MigratedFinding.lifecycle_status -cne [string]$LegacyFinding.lifecycle_status -or [string]$MigratedFinding.materiality -cne [string]$LegacyFinding.materiality -or [string]$MigratedFinding.coverage_id -cne [string]$LegacyFinding.coverage_id) { throw "Legacy finding canonical fields were not preserved: $($LegacyFinding.finding_id)" }
    if ((@($MigratedFinding.evidence) -join "`0") -cne (@($LegacyFinding.affected_paths) -join "`0") -or [string]$MigratedFinding.notes -notlike "*$([string]$LegacyFinding.description)*" -or [string]$MigratedFinding.notes -notlike "*exact source: $LegacyFindingsArchiveRelative*") { throw "Legacy finding evidence/description provenance was not preserved: $($LegacyFinding.finding_id)" }
    if ($MigratedFinding.auto_repairable -ne $false -or $MigratedFinding.owner_decision_required -ne $false -or $null -ne $MigratedFinding.PSObject.Properties['description'] -or $null -ne $MigratedFinding.PSObject.Properties['affected_paths']) { throw "Migrated finding contains unsafe or legacy fields: $($LegacyFinding.finding_id)" }
  }
  Invoke-Required $Pwsh @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $FindingsProject 'scripts\windows\companion\Test-FindingSet.ps1'),'-ProjectRoot',$FindingsProject) 'canonical migrated finding validation' | Out-Null
  $FindingsRuntimeResult = Get-Content -LiteralPath (Join-Path $FindingsProject '.agy\RUNTIME_UPDATE_RESULT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $FindingsJournal = Get-Content -LiteralPath (Join-Path ([string]$FindingsRuntimeResult.backup_root) 'journal.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
  $FindingsJournalPaths = @($FindingsJournal.paths | ForEach-Object { [string]$_.relative })
  if ($FindingsJournalPaths -cnotcontains '.agy/FINDINGS.json' -or $FindingsJournalPaths -cnotcontains $LegacyFindingsArchiveRelative) { throw 'Runtime journal omitted FINDINGS.json or its exact versioned archive path.' }
  if ((Get-FileHash -LiteralPath (Join-Path $FindingsProject 'src\product.txt') -Algorithm SHA256).Hash -ne $FindingsProductBefore) { throw 'Legacy findings migration changed product source.' }
  $FindingsBeforeSecond = @(Get-TreeSnapshot $FindingsProject)
  Invoke-Required $Pwsh $FindingsCommon 'H10-like findings byte-identical second apply' | Out-Null
  $FindingsSecondDelta = @(Compare-Snapshot $FindingsBeforeSecond (Get-TreeSnapshot $FindingsProject))
  if ($FindingsSecondDelta.Count -gt 0) { throw "Second findings migration run changed bytes/topology: $($FindingsSecondDelta.InputObject -join ', ')" }

  $FindingsFaultProject = New-Fixture 'H10-like findings fault rollback'
  [void](Write-H10LikeLegacyFindings -Project $FindingsFaultProject)
  $FindingsFaultBefore = @(Get-TreeSnapshot $FindingsFaultProject)
  $FindingsFault = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$FindingsFaultProject,'-RepoRoot',$Root,'-ExpectedSourceCommit',$ExpectedRuntimeSourceCommit,'-Apply','-AllowDirty','-SkipActiveWorkItemMigration','-SkipValidation','-BackupBaseRoot',$BackupRoot,'-FaultInjectionAfterMigration')
  if ($FindingsFault.ExitCode -eq 0 -or $FindingsFault.StdErr + $FindingsFault.StdOut -notmatch 'Injected runtime update failure after migration') { throw 'Findings migration fault injection did not reach the post-migration rollback boundary.' }
  $FindingsFaultDelta = @(Compare-Snapshot $FindingsFaultBefore (Get-TreeSnapshot $FindingsFaultProject))
  if ($FindingsFaultDelta.Count -gt 0) { throw "Findings migration rollback was not byte/topology exact: $($FindingsFaultDelta.InputObject -join ', ')" }

  foreach ($FindingsFaultName in @('unknown_category','unknown_shape')) {
    $UnknownFindingsProject = New-Fixture "H10-like findings $FindingsFaultName"
    [void](Write-H10LikeLegacyFindings -Project $UnknownFindingsProject -Fault $FindingsFaultName)
    $UnknownFindingsBefore = @(Get-TreeSnapshot $UnknownFindingsProject)
    $UnknownFindingsRun = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Updater,'-ProjectRoot',$UnknownFindingsProject,'-RepoRoot',$Root,'-ExpectedSourceCommit',$ExpectedRuntimeSourceCommit,'-Apply','-AllowDirty','-SkipActiveWorkItemMigration','-SkipValidation','-BackupBaseRoot',$BackupRoot)
    if ($UnknownFindingsRun.ExitCode -eq 0 -or $UnknownFindingsRun.StdErr + $UnknownFindingsRun.StdOut -notmatch 'Unsupported legacy finding category|unknown finding shape') { throw "Unknown legacy findings input was not rejected fail-closed: $FindingsFaultName" }
    $UnknownFindingsDelta = @(Compare-Snapshot $UnknownFindingsBefore (Get-TreeSnapshot $UnknownFindingsProject))
    if ($UnknownFindingsDelta.Count -gt 0) { throw "Unknown legacy findings rejection changed target bytes/topology ($FindingsFaultName): $($UnknownFindingsDelta.InputObject -join ', ')" }
    if (Test-Path -LiteralPath (Get-ProjectLockPath $UnknownFindingsProject) -PathType Leaf) { throw "Unknown legacy findings rejection left a lock: $FindingsFaultName" }
  }

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

  Write-Host 'Runtime updater transaction, lossless findings migration, resumable recovery, fail-closed legacy adoption, rollback, lock ownership, product preservation and byte-identical second run passed.'
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
