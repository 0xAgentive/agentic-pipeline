[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$KitRoot = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Failures = New-Object System.Collections.Generic.List[object]
$Warnings = New-Object System.Collections.Generic.List[object]
$Passes = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [string]$Details = '',
    [ValidateSet('critical', 'advisory')][string]$Severity = 'critical'
  )

  $Item = [pscustomobject]@{ id = $Id; severity = $Severity; details = $Details }
  if ($Passed) {
    [void]$Passes.Add($Item)
  }
  elseif ($Severity -eq 'advisory') {
    [void]$Warnings.Add($Item)
  }
  else {
    [void]$Failures.Add($Item)
  }
}

function Read-TextFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $Path = Join-Path $Root $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing: $RelativePath" }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return (Read-TextFile -RelativePath $RelativePath) | ConvertFrom-Json
}

function Resolve-FirstExistingRelative {
  param([Parameter(Mandatory = $true)][string[]]$Candidates)
  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath (Join-Path $Root $Candidate) -PathType Leaf) { return $Candidate }
  }
  return $null
}

try {
  $Version = Read-JsonFile -RelativePath 'VERSION.json'
  $Ecosystem = Read-JsonFile -RelativePath 'ECOSYSTEM_VERSION.json'
  $VersionOk = (
    [string]$Version.package_version -eq '1.2.8' -and
    [string]$Version.runtime_version -eq '1.2.8' -and
    [string]$Version.playbook_version -eq '1.2.8' -and
    [string]$Version.companion_version -eq '1.2.8' -and
    [string]$Ecosystem.ecosystem_version -eq '1.2.8'
  )
  foreach ($ComponentName in @('pipeline', 'runtime', 'playbook', 'companion', 'action_bridge', 'context_handoff')) {
    $Property = $Ecosystem.components.PSObject.Properties[$ComponentName]
    $VersionOk = $VersionOk -and $null -ne $Property -and [string]$Property.Value -eq '1.2.8'
  }
  Add-CheckResult -Id 'KF-014' -Passed $VersionOk -Details 'Unified ecosystem version'
}
catch {
  Add-CheckResult -Id 'KF-014' -Passed $false -Details $_.Exception.Message
}

try {
  $OwnerFiles = @(
    'docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.8.md',
    'docs\companion\SYSTEM_PROMPT_GPT56_COMPANION_v1.2.8.md',
    'docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.8.md',
    'docs\companion\08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md',
    'docs\companion\14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md',
    'docs\companion\15_OWNER_OUTPUT_PRESENTATION.md'
  )
  $OwnerFiles = @($OwnerFiles | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf })
  if ($OwnerFiles.Count -eq 0) {
    Add-CheckResult -Id 'KF-012' -Passed $true -Details 'Companion owner files are not part of this component package.' -Severity 'advisory'
  }
  else {
  $ForbiddenPatterns = @(
    'repair_batch_limit',
    'repair_batches_used',
    'initial_audits_used',
    'final_audits_used',
    'HARD_STOP_REPAIR_BUDGET',
    '(?i)repair\s+batch\s+\d+\s*/\s*\d+',
    '(?i)audit\s+budget',
    '(?i)authorize\s+(?:an?\s+)?(?:extra|additional|another)\s+repair'
  )
  $Hits = New-Object System.Collections.Generic.List[string]
  foreach ($RelativePath in $OwnerFiles) {
    $Text = Read-TextFile -RelativePath $RelativePath
    foreach ($Pattern in $ForbiddenPatterns) {
      if ($Text -match $Pattern) { [void]$Hits.Add("$RelativePath :: $Pattern") }
    }
  }
  Add-CheckResult -Id 'KF-012' -Passed ($Hits.Count -eq 0) -Details ($Hits.ToArray() -join '; ')
  }
}
catch {
  Add-CheckResult -Id 'KF-012' -Passed $false -Details $_.Exception.Message
}

try {
  $InstructionsPath = Resolve-FirstExistingRelative -Candidates @('docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.8.md')
  if (-not $InstructionsPath) {
    Add-CheckResult -Id 'KF-028' -Passed $true -Details 'Companion instructions are not part of this component package.' -Severity 'advisory'
    $PlainLanguageOk = $null
  }
  else {
  $Instructions = Read-TextFile -RelativePath $InstructionsPath
  $PlainLanguageOk = $true
  foreach ($Section in @('Что происходит', 'Что уже сделано', 'Что будет дальше', 'Нужно ли что-то от владельца')) {
    $PlainLanguageOk = $PlainLanguageOk -and $Instructions.Contains($Section)
  }
  Add-CheckResult -Id 'KF-028' -Passed $PlainLanguageOk -Details 'Plain-language owner sections'
  }
}
catch {
  Add-CheckResult -Id 'KF-028' -Passed $false -Details $_.Exception.Message
}

try {
  $ManifestWriter = Read-TextFile -RelativePath 'scripts\control-plane\write-installation-manifest.cjs'
  $ModeOk = $ManifestWriter.Contains("'runtime-update'") -and $ManifestWriter.Contains('defaultNextCommand = null')
  Add-CheckResult -Id 'KF-005' -Passed $ModeOk -Details 'runtime-update mode and null route'
}
catch {
  Add-CheckResult -Id 'KF-005' -Passed $false -Details $_.Exception.Message
}

try {
  $NewWorkItemPath = Resolve-FirstExistingRelative -Candidates @('scripts\windows\companion\New-WorkItem.ps1','templates\agy-project-base\scripts\windows\companion\New-WorkItem.ps1')
  $TransactionPath = Resolve-FirstExistingRelative -Candidates @('scripts\windows\companion\Start-WorkItemTransaction.ps1','templates\agy-project-base\scripts\windows\companion\Start-WorkItemTransaction.ps1')
  if (-not $NewWorkItemPath -or -not $TransactionPath) { throw 'Work-item transaction scripts are missing.' }
  $NewWorkItem = Read-TextFile -RelativePath $NewWorkItemPath
  $Transaction = Read-TextFile -RelativePath $TransactionPath
  $FlowOk = (
    $NewWorkItem.Contains('$PipelineRoot') -and
    $NewWorkItem.Contains("operation = 'new_work_item'") -and
    $NewWorkItem.Contains('route = $PreferredCommand') -and
    $NewWorkItem.Contains('audit_dimensions = $AuditDimensions') -and
    $Transaction.Contains('Get-OptionalProperty') -and
    $Transaction.Contains("-Name 'audit_dimensions'")
  )
  Add-CheckResult -Id 'KF-031' -Passed $FlowOk -Details 'Flow-restoration compatibility and optional packet fields'
}
catch {
  Add-CheckResult -Id 'KF-031' -Passed $false -Details $_.Exception.Message
}

try {
  $ProfilePaths = @(
    'templates\agy-project-base\.agy\PHASE_STATUS.json',
    'templates\state-profiles\new-project\PHASE_STATUS.json',
    'templates\state-profiles\adopt-existing\PHASE_STATUS.json'
  )
  $ProfilePaths = @($ProfilePaths | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf })
  $BadProfiles = New-Object System.Collections.Generic.List[string]
  foreach ($RelativePath in $ProfilePaths) {
    $Profile = Read-JsonFile -RelativePath $RelativePath
    if ([string]$Profile.framework_version -ne '1.2.8') { [void]$BadProfiles.Add($RelativePath) }
  }
  Add-CheckResult -Id 'KF-034' -Passed ($BadProfiles.Count -eq 0) -Details ($BadProfiles.ToArray() -join '; ')
}
catch {
  Add-CheckResult -Id 'KF-034' -Passed $false -Details $_.Exception.Message
}

try {
  $ManifestPublisherPath = Resolve-FirstExistingRelative -Candidates @('scripts\windows\companion\Publish-CandidateManifest.ps1','templates\agy-project-base\scripts\windows\companion\Publish-CandidateManifest.ps1')
  if (-not $ManifestPublisherPath) { throw 'Publish-CandidateManifest.ps1 is missing.' }
  $ManifestPublisher = Read-TextFile -RelativePath $ManifestPublisherPath
  $UnsafeGenericList = $ManifestPublisher -match '@\(\s*\$(Candidate|Ambient|Control)\s*\)'
  Add-CheckResult -Id 'KF-033' -Passed (-not $UnsafeGenericList) -Details 'Generic List conversion uses ToArray'
}
catch {
  Add-CheckResult -Id 'KF-033' -Passed $false -Details $_.Exception.Message
}

try {
  $LeakTerms = @('H' + '10', 'Athlete' + ' Cardio Lab')
  $LeakHits = New-Object System.Collections.Generic.List[string]
  $ProductionScripts = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Recurse -File -Include '*.ps1', '*.cjs', '*.sh' |
    Where-Object {
      $_.Name -notmatch '^(Test|Validate)-' -and
      $_.FullName -notmatch '[\\/]archive[\\/]'
    }
  foreach ($File in $ProductionScripts) {
    $Text = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
    foreach ($Term in $LeakTerms) {
      if ($Text.IndexOf($Term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        [void]$LeakHits.Add($File.FullName)
      }
    }
  }
  Add-CheckResult -Id 'KF-035' -Passed ($LeakHits.Count -eq 0) -Details ($LeakHits.ToArray() -join '; ') -Severity 'advisory'
}
catch {
  Add-CheckResult -Id 'KF-035' -Passed $false -Details $_.Exception.Message -Severity 'advisory'
}

try {
  $Acceptance = Read-TextFile -RelativePath 'tests\acceptance\autonomous-convergence-contract.cjs'
  $HasPlaceholder = (
    $Acceptance -match '(?m)^\s*assert\s+true\s*$' -or
    $Acceptance -match '(?m)^\s*pass\s*$' -or
    $Acceptance -match 'except\s+ImportError\s*:\s*pass'
  )
  Add-CheckResult -Id 'KF-019' -Passed (-not $HasPlaceholder) -Details 'No obvious placeholder acceptance tests'
}
catch {
  Add-CheckResult -Id 'KF-019' -Passed $false -Details $_.Exception.Message
}

try {
  $Playbook = Read-JsonFile -RelativePath 'tests\regression\KNOWN_FAILURE_PLAYBOOK_v1.2.8.json'
  $CaseCount = @($Playbook.cases).Count
  Add-CheckResult -Id 'KF-030' -Passed ($CaseCount -ge 48) -Details "Known cases: $CaseCount" -Severity 'advisory'
}
catch {
  Add-CheckResult -Id 'KF-030' -Passed $false -Details $_.Exception.Message -Severity 'advisory'
}

try {
  $Node = (Get-Command node -ErrorAction Stop).Source
  & $Node (Join-Path $Root 'tests\regression\known-failure-regression.cjs') $Root
  $NodeExitCode = $LASTEXITCODE
  Add-CheckResult -Id 'KF-030-NODE' -Passed ($NodeExitCode -eq 0) -Details "Portable regression exit=$NodeExitCode" -Severity 'advisory'
}
catch {
  Add-CheckResult -Id 'KF-030-NODE' -Passed $false -Details $_.Exception.Message -Severity 'advisory'
}


try {
  $SchemaRoot = Join-Path $Root 'schemas\companion'
  if (-not (Test-Path -LiteralPath $SchemaRoot -PathType Container)) {
    Add-CheckResult -Id 'KF-046' -Passed $true -Details 'Schemas are not part of this reduced component package.' -Severity 'advisory'
  }
  else {
    function Test-SchemaRevisionSupport {
      param([Parameter(Mandatory = $true)][object]$Schema,[Parameter(Mandatory = $true)][string]$Version)
      $VersionNode = $Schema.properties.schema_version
      if ($null -ne $VersionNode.PSObject.Properties['const']) { return [string]$VersionNode.const -eq $Version }
      if ($null -ne $VersionNode.PSObject.Properties['enum']) { return @($VersionNode.enum) -contains $Version }
      return $false
    }
    $WorkItemSchema = Read-JsonFile -RelativePath 'schemas\companion\work-item.schema.json'
    $ScopeSchema = Read-JsonFile -RelativePath 'schemas\companion\execution-scope.schema.json'
    $LeaseSchema = Read-JsonFile -RelativePath 'schemas\companion\execution-lease.schema.json'
    $FirewallSchema = Read-JsonFile -RelativePath 'schemas\companion\stage-firewall.schema.json'
    $NextSchema = Read-JsonFile -RelativePath 'schemas\companion\next-action.schema.json'
    $ManifestStatusSchema = Read-JsonFile -RelativePath 'schemas\companion\candidate-manifest-status.schema.json'
    $SchemaParityOk = (
      (Test-SchemaRevisionSupport -Schema $WorkItemSchema -Version '1.1.0') -and
      (Test-SchemaRevisionSupport -Schema $ScopeSchema -Version '1.1.0') -and
      (Test-SchemaRevisionSupport -Schema $LeaseSchema -Version '1.1.0') -and
      (Test-SchemaRevisionSupport -Schema $FirewallSchema -Version '1.1.0') -and
      (Test-SchemaRevisionSupport -Schema $NextSchema -Version '1.1.0') -and
      (Test-SchemaRevisionSupport -Schema $ManifestStatusSchema -Version '1.1.0') -and
      ($WorkItemSchema.properties.PSObject.Properties.Name -contains 'action_packet_id') -and
      ($ScopeSchema.properties.PSObject.Properties.Name -contains 'route') -and
      ($LeaseSchema.properties.PSObject.Properties.Name -contains 'route') -and
      ($ManifestStatusSchema.properties.PSObject.Properties.Name -contains 'candidate_file_count')
    )
    Add-CheckResult -Id 'KF-046' -Passed $SchemaParityOk -Details 'Control-plane writer/schema revision parity'
  }
}
catch {
  Add-CheckResult -Id 'KF-046' -Passed $false -Details $_.Exception.Message
}



try {
  $DistributionPolicyText = Read-TextFile -RelativePath 'scripts\windows\Test-DistributionIntegrity.ps1'
  $CompanionPolicyText = Read-TextFile -RelativePath 'scripts\windows\companion\Test-CompanionPack-v1.2.8.ps1'
  $WhitespacePolicyOk = (
    $DistributionPolicyText.Contains("'-WorkingTreeWhitespacePolicy', 'advisory'") -and
    $CompanionPolicyText.Contains("ValidateSet('strict', 'advisory', 'skip')") -and
    $CompanionPolicyText.Contains(':(exclude,glob)**/*.md') -and
    $CompanionPolicyText.Contains('Documentation-only whitespace issues are advisory in operational mode')
  )
  Add-CheckResult -Id 'KF-040' -Passed $WhitespacePolicyOk -Details 'Operational/advisory gate separation'
  Add-CheckResult -Id 'KF-048' -Passed $WhitespacePolicyOk -Details 'Documentation-only whitespace cannot block operational deployment'
}
catch {
  Add-CheckResult -Id 'KF-040' -Passed $false -Details $_.Exception.Message
  Add-CheckResult -Id 'KF-048' -Passed $false -Details $_.Exception.Message
}

try {
  $MigrationText = Read-TextFile -RelativePath 'scripts\windows\companion\Migrate-ActiveWorkItemToProgressGuard.ps1'
  $DistributionText = Read-TextFile -RelativePath 'scripts\windows\Test-DistributionIntegrity.ps1'
  $CompatibilityTest = Join-Path $Root 'tests\acceptance\Test-ProgressGuardMigrationCompatibility.ps1'
  $MigrationCompatibilityOk = (
    $MigrationText.Contains('LEGACY_SHAPE_SAFE_PROGRESS_GUARD_MIGRATION') -and
    (Test-Path -LiteralPath $CompatibilityTest -PathType Leaf) -and
    $DistributionText.Contains('progress-guard migration compatibility')
  )
  Add-CheckResult -Id 'KF-047' -Passed $MigrationCompatibilityOk -Details 'Legacy runtime-state migration compatibility'
}
catch {
  Add-CheckResult -Id 'KF-047' -Passed $false -Details $_.Exception.Message
}

[object[]]$FailureArray = $Failures.ToArray()
[object[]]$WarningArray = $Warnings.ToArray()
[object[]]$PassArray = $Passes.ToArray()

$Report = [ordered]@{
  schema_version = '1.2.8'
  status = if ($FailureArray.Count -eq 0) { 'PASS' } else { 'FAIL' }
  passes = $PassArray
  warnings = $WarningArray
  failures = $FailureArray
  generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
}

$Report | ConvertTo-Json -Depth 12 | Write-Host
if ($WarningArray.Count -gt 0) {
  Write-Host "Known-failure advisory warnings: $($WarningArray.Count)"
}
if ($FailureArray.Count -gt 0) { exit 1 }
Write-Host 'Known-failure regression playbook passed.'
exit 0
