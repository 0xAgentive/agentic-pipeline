[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutFile = "",
  [switch]$WriteToProject
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-JsonFile {
  param([string]$Path)

  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{
      Present = $false
      Valid = $false
      Value = $null
      Error = $null
    }
  }

  try {
    $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($Text)) {
      return [pscustomobject]@{
        Present = $true
        Valid = $false
        Value = $null
        Error = "File is empty."
      }
    }

    return [pscustomobject]@{
      Present = $true
      Valid = $true
      Value = ($Text | ConvertFrom-Json)
      Error = $null
    }
  }
  catch {
    return [pscustomobject]@{
      Present = $true
      Valid = $false
      Value = $null
      Error = $_.Exception.Message
    }
  }
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList
  )

  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $Output = @(& $FilePath @ArgumentList 2>&1)
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }

  return [pscustomobject]@{
    Code = [int]$Code
    Lines = [object[]]$Output
    Text = ([object[]]$Output -join "`n")
  }
}

function Get-Sha256 {
  param([string]$Path)

  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-RootCommand {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return [regex]::IsMatch($Value, '^/[^\s]+$')
}

function Get-WorkflowInventory {
  param([string]$WorkflowRoot)

  $Errors = New-Object System.Collections.Generic.List[string]
  $Commands = New-Object System.Collections.Generic.List[string]
  $ByName = @{}

  [string[]]$Names = @(
    Get-ChildItem -LiteralPath $WorkflowRoot -File -Filter "*.md" |
      ForEach-Object {
        $Normalized = $_.Name.ToLowerInvariant()
        if ($ByName.ContainsKey($Normalized)) {
          [void]$Errors.Add("Duplicate normalized workflow filename: $Normalized")
        }
        else {
          $ByName[$Normalized] = $_.FullName
        }
        $Normalized
      }
  )

  if ($Names.Count -eq 0) {
    [void]$Errors.Add("Workflow directory contains no root-level *.md command files.")
  }

  [System.Array]::Sort($Names, [System.StringComparer]::Ordinal)
  $UniqueNames = [string[]]@($Names | Select-Object -Unique)

  $Builder = New-Object System.Text.StringBuilder
  foreach ($Name in $UniqueNames) {
    if (!$ByName.ContainsKey($Name)) {
      continue
    }

    $Command = "/" + [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if (!(Test-RootCommand -Value $Command)) {
      [void]$Errors.Add("Invalid workflow command derived from filename: $Name")
      continue
    }

    [void]$Commands.Add($Command)

    $FileHash = (
      Get-FileHash -LiteralPath $ByName[$Name] -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    [void]$Builder.Append($Name)
    [void]$Builder.Append("`t")
    [void]$Builder.Append($FileHash)
    [void]$Builder.Append("`n")
  }

  $CompositeHash = $null
  if ($Errors.Count -eq 0) {
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Builder.ToString())
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $CompositeHash = (
        [System.BitConverter]::ToString($Sha.ComputeHash($Bytes))
      ).Replace("-", "").ToLowerInvariant()
    }
    finally {
      $Sha.Dispose()
    }
  }

  return [pscustomobject]@{
    Commands = [string[]]$Commands.ToArray()
    Hash = $CompositeHash
    Errors = [string[]]$Errors.ToArray()
  }
}

function Get-InventoryFileCommands {
  param([string]$Path)

  $Errors = New-Object System.Collections.Generic.List[string]
  $Commands = New-Object System.Collections.Generic.List[string]
  $Seen = @{}

  $Read = Read-JsonFile -Path $Path
  if (!$Read.Valid) {
    [void]$Errors.Add("Project command inventory is not valid JSON: $($Read.Error)")
    return [pscustomobject]@{
      Commands = @()
      Errors = [string[]]$Errors.ToArray()
    }
  }

  $Inventory = $Read.Value
  if ($null -eq $Inventory.commands) {
    [void]$Errors.Add("Project command inventory has no commands field.")
  }
  else {
    foreach ($Item in @($Inventory.commands)) {
      $Command = $null

      if ($Item -is [string]) {
        $Command = [string]$Item
      }
      elseif ($null -ne $Item -and $null -ne $Item.command) {
        $Command = [string]$Item.command
      }

      if (!(Test-RootCommand -Value $Command)) {
        [void]$Errors.Add("Project command inventory contains an invalid command entry.")
        continue
      }

      if ($Seen.ContainsKey($Command)) {
        [void]$Errors.Add("Project command inventory contains duplicate command: $Command")
        continue
      }

      $Seen[$Command] = $true
      [void]$Commands.Add($Command)
    }
  }

  if ($Commands.Count -eq 0) {
    [void]$Errors.Add("Project command inventory contains no valid commands.")
  }

  return [pscustomobject]@{
    Commands = [string[]]$Commands.ToArray()
    Errors = [string[]]$Errors.ToArray()
  }
}

function Test-PhaseResultStructure {
  param(
    [string]$ResultPath,
    [string]$PipelineRoot
  )

  if (!(Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
    return $false
  }

  $Validator = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"
  $Schema = Join-Path $PipelineRoot "schemas\companion\phase-result.schema.json"

  if (!(Test-Path -LiteralPath $Validator -PathType Leaf) -or
      !(Test-Path -LiteralPath $Schema -PathType Leaf)) {
    return $false
  }

  $Result = Invoke-NativeCapture `
    -FilePath "node" `
    -ArgumentList @(
      $Validator,
      "validate-json",
      "--schema", $Schema,
      "--file", $ResultPath
    )

  return ($Result.Code -eq 0)
}

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$StateRoot = Join-Path $Project ".agy"
$ArtifactRoot = Join-Path $Project ".artifacts"
$WorkflowRoot = Join-Path $Project ".agents\workflows"

if (!(Test-Path -LiteralPath $Project -PathType Container)) {
  throw "Project root not found: $ProjectRoot"
}

$GitRoot = $null
$GitState = $null
$GitHead = $null

if (Get-Command git -ErrorAction SilentlyContinue) {
  # Avoid decoding a non-ASCII absolute path from Git stdout under Windows
  # PowerShell 5.1. --show-cdup returns an ASCII relative path.
  $GitRootResult = Invoke-NativeCapture `
    -FilePath "git" `
    -ArgumentList @("-C", $Project, "rev-parse", "--show-cdup")

  if ($GitRootResult.Code -eq 0) {
    $GitCdup = $GitRootResult.Text.Trim()
    $GitRootCandidate = if ([string]::IsNullOrWhiteSpace($GitCdup)) {
      $Project
    }
    else {
      [System.IO.Path]::GetFullPath((Join-Path $Project $GitCdup))
    }

    $GitRoot = (Resolve-Path -LiteralPath $GitRootCandidate).Path
  }

  if ($GitRoot) {
    $HeadResult = Invoke-NativeCapture `
      -FilePath "git" `
      -ArgumentList @("-C", $Project, "rev-parse", "HEAD")
    if ($HeadResult.Code -eq 0) {
      $GitHead = $HeadResult.Text.Trim()
    }

    $StatusResult = Invoke-NativeCapture `
      -FilePath "git" `
      -ArgumentList @("-C", $Project, "status", "--porcelain=v1", "--untracked-files=all")

    if ($StatusResult.Code -eq 0) {
      $GitState = if ($StatusResult.Lines.Count -eq 0) { "clean" } else { "dirty" }
    }
  }
}

$VersionPath = Join-Path $Pipeline "VERSION.json"
$VersionRead = Read-JsonFile -Path $VersionPath
$PipelineVersion = if ($VersionRead.Valid) { $VersionRead.Value } else { $null }
$PackageVersion = if ($PipelineVersion) { [string]$PipelineVersion.package_version } else { $null }
$RuntimeVersion = if ($PipelineVersion) { [string]$PipelineVersion.runtime_version } else { $null }

$InventoryErrors = New-Object System.Collections.Generic.List[string]
$ProjectInventoryPath = Join-Path $Project ".agents\COMMAND_INVENTORY.json"
$LowerInventoryPath = Join-Path $Project ".agents\command-inventory.json"

if (!(Test-Path -LiteralPath $ProjectInventoryPath -PathType Leaf) -and
    (Test-Path -LiteralPath $LowerInventoryPath -PathType Leaf)) {
  $ProjectInventoryPath = $LowerInventoryPath
}

$InventorySource = "missing"
$InventoryTrust = "none"
$InventoryPath = $null
$InventoryHash = $null
$InventoryCommands = @()

if (Test-Path -LiteralPath $ProjectInventoryPath -PathType Leaf) {
  $InventorySource = "project_command_inventory"
  $InventoryTrust = "authoritative"
  $InventoryPath = $ProjectInventoryPath
  $InventoryHash = Get-Sha256 -Path $ProjectInventoryPath

  $InventoryResult = Get-InventoryFileCommands -Path $ProjectInventoryPath
  $InventoryCommands = [string[]]$InventoryResult.Commands

  foreach ($ErrorText in @($InventoryResult.Errors)) {
    [void]$InventoryErrors.Add([string]$ErrorText)
  }
}
elseif (Test-Path -LiteralPath $WorkflowRoot -PathType Container) {
  $InventorySource = "project_workflow_directory_compat"
  $InventoryTrust = "compatibility"
  $InventoryPath = $WorkflowRoot

  $WorkflowResult = Get-WorkflowInventory -WorkflowRoot $WorkflowRoot
  $InventoryCommands = [string[]]$WorkflowResult.Commands
  $InventoryHash = $WorkflowResult.Hash

  foreach ($ErrorText in @($WorkflowResult.Errors)) {
    [void]$InventoryErrors.Add([string]$ErrorText)
  }
}
else {
  [void]$InventoryErrors.Add("No project-local command inventory or workflow directory was found.")
}

if ($InventoryErrors.Count -gt 0) {
  $InventorySource = "missing"
  $InventoryTrust = "none"
  $InventoryCommands = @()
}

$CentralInventoryCommands = @()
$CentralInventoryPath = Join-Path $Pipeline "config\command-inventory.json"
$CentralRead = Read-JsonFile -Path $CentralInventoryPath
if ($CentralRead.Valid -and $null -ne $CentralRead.Value.commands) {
  foreach ($Item in @($CentralRead.Value.commands)) {
    if ($null -ne $Item.command) {
      $CentralInventoryCommands += [string]$Item.command
    }
  }
}

$InstallationManifestPath = Join-Path $StateRoot "INSTALLATION_MANIFEST.json"
$InstallationRead = Read-JsonFile -Path $InstallationManifestPath
$InstallationManifestHash = if ($InstallationRead.Present) {
  Get-Sha256 -Path $InstallationManifestPath
}
else {
  $null
}

$InstalledPackageVersion = "unknown"
$InstalledRuntimeVersion = "unknown"
$InstalledSourceCommit = "unknown"

if ($InstallationRead.Valid) {
  if (![string]::IsNullOrWhiteSpace([string]$InstallationRead.Value.package_version)) {
    $InstalledPackageVersion = [string]$InstallationRead.Value.package_version
  }
  if (![string]::IsNullOrWhiteSpace([string]$InstallationRead.Value.runtime_version)) {
    $InstalledRuntimeVersion = [string]$InstallationRead.Value.runtime_version
  }
  if (![string]::IsNullOrWhiteSpace([string]$InstallationRead.Value.source_commit)) {
    $InstalledSourceCommit = [string]$InstallationRead.Value.source_commit
  }
}

$PhasePath = Join-Path $StateRoot "PHASE_STATUS.json"
$PhaseRead = Read-JsonFile -Path $PhasePath
$Phase = if ($PhaseRead.Valid) { $PhaseRead.Value } else { $null }

$ContractPath = Join-Path $StateRoot "PHASE_CONTRACT.json"
$ContractRead = Read-JsonFile -Path $ContractPath
$Contract = if ($ContractRead.Valid) { $ContractRead.Value } else { $null }

$ResultPath = Join-Path $StateRoot "PHASE_RESULT.json"
$ResultRead = Read-JsonFile -Path $ResultPath
$Result = if ($ResultRead.Valid) { $ResultRead.Value } else { $null }
$PhaseResultPresent = [bool]$ResultRead.Present
$PhaseResultStructurallyValid = [bool](
  $ResultRead.Valid -and
  (Test-PhaseResultStructure -ResultPath $ResultPath -PipelineRoot $Pipeline)
)
$PhaseResultContractHashValid = [bool](
  $PhaseResultStructurallyValid -and
  $null -ne $Contract -and
  ![string]::IsNullOrWhiteSpace([string]$Contract.contract_hash) -and
  ([string]$Contract.contract_hash -eq [string]$Result.contract_hash)
)

$FinalVerificationPath = Join-Path $Project "FINAL_VERIFICATION.json"
$FinalVerificationRead = Read-JsonFile -Path $FinalVerificationPath
$FinalVerification = if ($FinalVerificationRead.Valid) {
  $FinalVerificationRead.Value
}
else {
  $null
}

$FindingsIndexPath = Join-Path $StateRoot "FINDINGS_INDEX.json"
$FindingsRead = Read-JsonFile -Path $FindingsIndexPath
$FindingsIndex = if ($FindingsRead.Valid) { $FindingsRead.Value } else { $null }

$OpenConfirmedCurrentPhaseBlockers = 0
$RepairRequiredCurrentPhaseFindings = 0
$VerificationRequiredCurrentPhaseFindings = 0
$FixedUnverifiedCurrentPhaseFindings = 0
$VerifiedResolvedFindings = 0
$DeferredProductFindings = 0
$DeferredInfrastructureFindings = 0
$AcceptedRisks = 0

if ($FindingsIndex -and $FindingsIndex.findings) {
  foreach ($Finding in @($FindingsIndex.findings)) {
    $Classification = [string]$Finding.phase_classification
    $LifecycleStatus = [string]$Finding.lifecycle_status
    $Category = [string]$Finding.category

    if ($LifecycleStatus -eq "verified_resolved" -or $Classification -eq "resolved") {
      $VerifiedResolvedFindings++
    }
    elseif ($LifecycleStatus -eq "accepted_risk" -or $LifecycleStatus -eq "deferred") {
      $AcceptedRisks++
    }
    elseif ($Classification -eq "current_phase_blocker") {
      if ($LifecycleStatus -eq "open_confirmed" -or $LifecycleStatus -eq "repair_required") {
        $OpenConfirmedCurrentPhaseBlockers++
        $RepairRequiredCurrentPhaseFindings++
      }
      elseif ($LifecycleStatus -eq "fixed_unverified") {
        $FixedUnverifiedCurrentPhaseFindings++
        $VerificationRequiredCurrentPhaseFindings++
      }
    }
    elseif ($Classification -eq "next_phase_requirement" -or $Classification -eq "deferred") {
      if ($Category -eq "delivery" -or
          $Category -eq "infrastructure" -or
          [string]$Finding.title -like "*migration*") {
        $DeferredInfrastructureFindings++
      }
      else {
        $DeferredProductFindings++
      }
    }
  }
}

$RequiredCommandFailure = $false
if ($PhaseResultStructurallyValid) {
  foreach ($CommandResult in @($Result.command_results)) {
    if ($CommandResult.required -eq $true -and [int]$CommandResult.exit_code -ne 0) {
      $RequiredCommandFailure = $true
    }
  }
}

$AuditResultPresent = $PhaseResultPresent
$AuditResultStructurallyValid = $PhaseResultStructurallyValid
$AuditAuthoritative = [bool](
  $PhaseResultStructurallyValid -and
  $PhaseResultContractHashValid -and
  [string]$Result.audit_status -eq "passed"
)

$AuditEvidenceComplete = [bool](
  $PhaseResultStructurallyValid -and
  !$RequiredCommandFailure -and
  ([string]$Result.artifact_status -eq "complete" -or
   [string]$Result.artifact_status -eq "not_required")
)

$ClaimsEvidenceConsistent = [bool]$PhaseResultStructurallyValid
if ($PhaseResultStructurallyValid) {
  if ($RequiredCommandFailure -and [string]$Result.verification_status -eq "passed") {
    $ClaimsEvidenceConsistent = $false
  }
  if (@($Result.blockers).Count -gt 0 -and
      ([string]$Result.acceptance_status -eq "accepted" -or
       [string]$Result.acceptance_status -eq "accepted_with_debt")) {
    $ClaimsEvidenceConsistent = $false
  }
  if ([string]$Result.ship_status -eq "ship" -and
      [string]$Result.acceptance_status -ne "accepted" -and
      [string]$Result.acceptance_status -ne "accepted_with_debt") {
    $ClaimsEvidenceConsistent = $false
  }
}

$CurrentStatus = if ($Phase) {
  if ($null -ne $Phase.current_status) { [string]$Phase.current_status }
  elseif ($null -ne $Phase.phase_status) { [string]$Phase.phase_status }
  elseif ($null -ne $Phase.status) { [string]$Phase.status }
  elseif ($null -ne $Phase.project_status) { [string]$Phase.project_status }
  else { $null }
}
else {
  $null
}

$Facts = [ordered]@{
  project_inventory = [ordered]@{
    source = $InventorySource
    trust = $InventoryTrust
    inventory_path = $InventoryPath
    inventory_sha256 = $InventoryHash
    commands = [string[]]$InventoryCommands
  }
  installation_facts = [ordered]@{
    installation_manifest_path = if ($InstallationRead.Present) {
      $InstallationManifestPath
    }
    else {
      $null
    }
    installation_manifest_sha256 = $InstallationManifestHash
    installed_project_package_version = $InstalledPackageVersion
    installed_project_runtime_version = $InstalledRuntimeVersion
    installed_project_source_commit = $InstalledSourceCommit
  }
  central_inventory_advisory = [ordered]@{
    commands = [string[]]$CentralInventoryCommands
    package_version = if ($PackageVersion) { $PackageVersion } else { "unknown" }
    runtime_version = if ($RuntimeVersion) { $RuntimeVersion } else { "unknown" }
  }
  git_facts = [ordered]@{
    git_state = $GitState
    head_commit = $GitHead
    git_root = $GitRoot
  }
  state_facts = [ordered]@{
    current_phase = if ($Phase) { $Phase.current_phase } else { $null }
    current_status = $CurrentStatus
    implementation_status = if ($Phase) { $Phase.implementation_status } else { $null }
    verification_status = if ($Phase) { $Phase.verification_status } else { $null }
    artifact_status = if ($Phase) { $Phase.artifact_status } else { $null }
    audit_status = if ($Phase) { $Phase.audit_status } else { $null }
    acceptance_status = if ($Phase) { $Phase.acceptance_status } else { $null }
    scientific_validation_status = if ($Phase) { $Phase.scientific_validation_status } else { $null }
    ship_status = if ($Phase) { $Phase.ship_status } else { $null }
    next_required_command = if ($Phase) { $Phase.next_required_command } else { $null }
    commands_allowed_now = if ($Phase) { $Phase.commands_allowed_now } else { @() }
    stale_state = if ($Phase) { $Phase.stale_state } else { $false }
    evidence_state = if ($Phase) { $Phase.evidence_state } else { $null }
    command_inventory_sha256 = if ($Phase) { $Phase.command_inventory_sha256 } else { $null }
    state_handoff_required = if ($Phase -and $Phase.state_handoff_required -eq $true) { $true } else { $false }
    landing_completed = if ($Phase -and $Phase.landing_completed -eq $true) { $true } else { $false }
    recovery_required = if ($Phase -and $Phase.recovery_required -eq $true) { $true } else { $false }
  }
  phase_contract_facts = [ordered]@{
    contract_hash = if ($Contract) { $Contract.contract_hash } else { $null }
    contract_status = if ($Contract) { $Contract.status } else { $null }
  }
  phase_result_facts = [ordered]@{
    present = $PhaseResultPresent
    structurally_valid = $PhaseResultStructurallyValid
    contract_hash_valid = $PhaseResultContractHashValid
    valid = $PhaseResultStructurallyValid
    missing = !$PhaseResultPresent
    contract_hash = if ($Result) { $Result.contract_hash } else { $null }
    release_source_commit = if ($Result) { $Result.release_source_commit } else { $null }
    source_commit = if ($Result) { $Result.source_commit } else { $null }
    command_inventory_sha256 = if ($Result) { $Result.command_inventory_sha256 } else { $null }
  }
  acceptance_facts = [ordered]@{
    acceptance_status = if ($Result) {
      $Result.acceptance_status
    }
    elseif ($FinalVerification) {
      $FinalVerification.acceptance_status
    }
    else {
      $null
    }
    audit_status = if ($Result) {
      $Result.audit_status
    }
    elseif ($Phase) {
      $Phase.audit_status
    }
    else {
      $null
    }
    verification_status = if ($Result) { $Result.verification_status } else { $null }
    artifact_status = if ($Result) { $Result.artifact_status } elseif ($Phase) { $Phase.artifact_status } else { $null }
    ship_status = if ($Result) { $Result.ship_status } else { $null }
    open_confirmed_current_phase_blockers = $OpenConfirmedCurrentPhaseBlockers
    repair_required_current_phase_findings = $RepairRequiredCurrentPhaseFindings
    verification_required_current_phase_findings = $VerificationRequiredCurrentPhaseFindings
    fixed_unverified_current_phase_findings = $FixedUnverifiedCurrentPhaseFindings
    verified_resolved_findings = $VerifiedResolvedFindings
    deferred_product_findings = $DeferredProductFindings
    deferred_infrastructure_findings = $DeferredInfrastructureFindings
    accepted_risks = $AcceptedRisks
  }
  audit_facts = [ordered]@{
    audit_result_present = $AuditResultPresent
    audit_result_structurally_valid = $AuditResultStructurallyValid
    audit_authoritative = $AuditAuthoritative
    audit_evidence_complete = $AuditEvidenceComplete
    claims_evidence_consistent = $ClaimsEvidenceConsistent
  }
  repair_facts = [ordered]@{
    repair_budget_known = if ($Contract -and $null -ne $Contract.repair_budget) { $true } else { $false }
    repair_budget_exhausted = if ($Phase -and $Phase.repair_budget_exhausted -eq $true) { $true } else { $false }
    user_continue_repair_authorized = if ($Phase -and $Phase.user_continue_repair_authorized -eq $true) { $true } else { $false }
    registered_repair_cycle_count = if ($Phase -and $null -ne $Phase.registered_repair_cycle_count) {
      [int]$Phase.registered_repair_cycle_count
    }
    else {
      0
    }
  }
  requested_command = $null
  routing_policy = [ordered]@{
    explicit_compatibility_matrix = @{}
  }
}

$ResolverScript = Join-Path $Pipeline "scripts\control-plane\resolve-runtime-route.cjs"
if (!(Test-Path -LiteralPath $ResolverScript -PathType Leaf)) {
  throw "Authoritative route resolver script not found: $ResolverScript"
}

$TempFactsPath = Join-Path $env:TEMP ("handshake-facts-" + [Guid]::NewGuid().ToString("N") + ".json")
[System.IO.File]::WriteAllText(
  $TempFactsPath,
  ($Facts | ConvertTo-Json -Depth 20),
  $Utf8NoBom
)

try {
  $ResolverResult = Invoke-NativeCapture `
    -FilePath "node" `
    -ArgumentList @($ResolverScript, "--facts-file", $TempFactsPath)

  if ($ResolverResult.Code -ne 0) {
    throw "Route resolver execution failed: $($ResolverResult.Text)"
  }

  $Decision = $ResolverResult.Text | ConvertFrom-Json
}
finally {
  Remove-Item -LiteralPath $TempFactsPath -Force -ErrorAction SilentlyContinue
}

$ExtraErrors = New-Object System.Collections.Generic.List[string]
$NormProject = $Project.Replace("\", "/").TrimEnd("/").ToLowerInvariant()
$NormGit = if ($GitRoot) {
  $GitRoot.Replace("\", "/").TrimEnd("/").ToLowerInvariant()
}
else {
  $null
}
$NormState = $StateRoot.Replace("\", "/").TrimEnd("/").ToLowerInvariant()

if ($NormState -ne "$NormProject/.agy") {
  [void]$ExtraErrors.Add("state_root does not point to the .agy directory of project_root: $StateRoot vs $Project")
}
if ($null -eq $NormGit) {
  [void]$ExtraErrors.Add("git_root is null or project is not inside a Git repository.")
}
elseif ($NormProject -ne $NormGit) {
  [void]$ExtraErrors.Add("project_root and git_root do not point to the same active project: $Project vs $GitRoot")
}
foreach ($InventoryError in @($InventoryErrors.ToArray())) {
  [void]$ExtraErrors.Add([string]$InventoryError)
}

$AllErrors = @()
if ($Decision.routing_errors) {
  $AllErrors += @($Decision.routing_errors)
}
if ($ExtraErrors.Count -gt 0) {
  $AllErrors += @($ExtraErrors.ToArray())
}
$AllErrors = [string[]]@($AllErrors | Select-Object -Unique)

$FinalRoutingValid = [bool](
  $Decision.routing_valid -and
  $ExtraErrors.Count -eq 0
)

$StaleReasonsList = @()
foreach ($Reason in @($Decision.stale_reasons)) {
  $StaleReasonsList += [ordered]@{
    code = [string]$Reason.code
    evidence = [string]$Reason.evidence
    severity = [string]$Reason.severity
  }
}

if ($WriteToProject) {
  $OutFile = Join-Path $StateRoot "RUNTIME_HANDSHAKE.json"
}
elseif ([string]::IsNullOrWhiteSpace($OutFile)) {
  $OutFile = Join-Path $env:TEMP ("runtime-handshake-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
}

$Handshake = [ordered]@{
  schema_version = "1.1.0"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pipeline_package_version = $PackageVersion
  runtime_version = $RuntimeVersion
  project_root = $Project
  workspace_root = $Project
  git_root = $GitRoot
  git_head = $GitHead
  state_root = $StateRoot
  artifact_root = $ArtifactRoot
  command_inventory_path = $InventoryPath
  command_inventory_sha256 = $InventoryHash
  available_commands = [string[]]@($Decision.available_commands)
  current_phase = if ($Phase) { [string]$Phase.current_phase } else { $null }
  current_status = [string]$Decision.current_status
  next_required_command = if ($Decision.next_required_command) {
    [string]$Decision.next_required_command
  }
  else {
    $null
  }
  commands_allowed_now = [string[]]@($Decision.commands_allowed_now)
  routing_valid = $FinalRoutingValid
  routing_errors = [string[]]$AllErrors
  git_state = $GitState
  routing_mode = [string]$Decision.routing_mode
  inventory_source = [string]$Decision.inventory_source
  inventory_trust = [string]$Decision.inventory_trust
  inventory_path = $InventoryPath
  inventory_sha256 = $InventoryHash
  inventory_command_count = [int]$Decision.inventory_command_count
  installation_manifest_path = if ($InstallationRead.Present) {
    $InstallationManifestPath
  }
  else {
    $null
  }
  installation_manifest_sha256 = $InstallationManifestHash
  installed_project_package_version = [string]$Decision.installed_project_package_version
  installed_project_runtime_version = [string]$Decision.installed_project_runtime_version
  installed_project_source_commit = [string]$Decision.installed_project_source_commit
  available_pipeline_package_version = [string]$Decision.available_pipeline_package_version
  available_pipeline_runtime_version = [string]$Decision.available_pipeline_runtime_version
  runtime_compatibility = [string]$Decision.runtime_compatibility
  state_declared_next_required_command = if ($Decision.state_declared_next_required_command) {
    [string]$Decision.state_declared_next_required_command
  }
  else {
    $null
  }
  state_declared_commands_allowed_now = [string[]]@($Decision.state_declared_commands_allowed_now)
  resolved_commands_allowed_now = [string[]]@($Decision.resolved_commands_allowed_now)
  stale_state = [bool]$Decision.stale_state
  stale_reasons = $StaleReasonsList
  routing_decision = [string]$Decision.routing_decision
  routing_reason_codes = [string[]]@($Decision.routing_reason_codes)
  phase_result_present = [bool]$Decision.phase_result_present
  phase_result_structurally_valid = [bool]$Decision.phase_result_structurally_valid
  phase_result_contract_hash_valid = [bool]$Decision.phase_result_contract_hash_valid
  audit_result_present = [bool]$Decision.audit_result_present
  audit_result_structurally_valid = [bool]$Decision.audit_result_structurally_valid
  audit_authoritative = [bool]$Decision.audit_authoritative
  audit_evidence_complete = [bool]$Decision.audit_evidence_complete
  claims_evidence_consistent = [bool]$Decision.claims_evidence_consistent
}

$Parent = Split-Path -Parent $OutFile
if ($Parent) {
  New-Item -ItemType Directory -Force $Parent | Out-Null
}
[System.IO.File]::WriteAllText(
  $OutFile,
  ($Handshake | ConvertTo-Json -Depth 30),
  $Utf8NoBom
)

$CompanionControl = Join-Path $Pipeline "scripts\companion\companion-control.cjs"
$SchemaValidation = Invoke-NativeCapture `
  -FilePath "node" `
  -ArgumentList @(
    $CompanionControl,
    "validate-handshake",
    "--repo-root", $Pipeline,
    "--file", $OutFile
  )

if ($SchemaValidation.Code -ne 0) {
  Write-Host $SchemaValidation.Text
  exit 1
}

Write-Host "Runtime handshake written: $OutFile"
Write-Host "Routing mode: $($Decision.routing_mode)"
Write-Host "Inventory source: $($Decision.inventory_source)"
Write-Host "Inventory trust: $($Decision.inventory_trust)"
Write-Host "Available commands: $(@($Decision.available_commands).Count)"
Write-Host "Current status: $($Decision.current_status)"
Write-Host "Next required command: $($Decision.next_required_command)"
Write-Host "Routing valid: $FinalRoutingValid"

if ($AllErrors.Count -gt 0) {
  $AllErrors | ForEach-Object { Write-Host "- $_" }
  exit 1
}

exit 0
