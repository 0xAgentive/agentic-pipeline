[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutFile = "",
  [string]$RequestedCommand = "",
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

function Get-AgenticWritableTempRoot {
  $Candidates = New-Object System.Collections.Generic.List[string]

  foreach ($Value in @(
    $env:AGENTIC_PIPELINE_TEMP,
    $env:TEMP,
    $env:TMP,
    $env:TMPDIR
  )) {
    if (![string]::IsNullOrWhiteSpace([string]$Value)) {
      [void]$Candidates.Add([string]$Value)
    }
  }

  $IsWindowsPlatform = (
    [System.Environment]::OSVersion.Platform -eq
    [System.PlatformID]::Win32NT
  )

  $UserProfile = [System.Environment]::GetFolderPath(
    [System.Environment+SpecialFolder]::UserProfile
  )

  if ($IsWindowsPlatform) {
    $LocalApplicationData = [System.Environment]::GetFolderPath(
      [System.Environment+SpecialFolder]::LocalApplicationData
    )
    if (![string]::IsNullOrWhiteSpace($LocalApplicationData)) {
      [void]$Candidates.Add(
        [System.IO.Path]::Combine($LocalApplicationData, "Temp")
      )
    }
    if (![string]::IsNullOrWhiteSpace($UserProfile)) {
      [void]$Candidates.Add(
        [System.IO.Path]::Combine(
          $UserProfile,
          "AppData",
          "Local",
          "Temp"
        )
      )
    }
  }
  else {
    foreach ($Value in @(
      $env:XDG_RUNTIME_DIR,
      $env:XDG_CACHE_HOME
    )) {
      if (![string]::IsNullOrWhiteSpace([string]$Value)) {
        [void]$Candidates.Add([string]$Value)
      }
    }
    if (![string]::IsNullOrWhiteSpace($UserProfile)) {
      [void]$Candidates.Add(
        [System.IO.Path]::Combine($UserProfile, ".cache")
      )
    }
    [void]$Candidates.Add("/tmp")
  }

  try {
    [void]$Candidates.Add([System.IO.Path]::GetTempPath())
  }
  catch {
    # The platform resolver is advisory. Every candidate is verified below.
  }

  foreach ($Candidate in @($Candidates | Select-Object -Unique)) {
    $ProbePath = $null
    try {
      $ExpandedCandidate = [System.Environment]::ExpandEnvironmentVariables(
        [string]$Candidate
      )
      if (![System.IO.Path]::IsPathRooted($ExpandedCandidate)) {
        continue
      }

      $BaseRoot = [System.IO.Path]::GetFullPath($ExpandedCandidate)
      $TempRoot = [System.IO.Path]::Combine(
        $BaseRoot,
        "agentic-pipeline",
        "runtime-handshake"
      )
      [System.IO.Directory]::CreateDirectory($TempRoot) | Out-Null

      $ProbePath = [System.IO.Path]::Combine(
        $TempRoot,
        ".write-probe-" + [Guid]::NewGuid().ToString("N") + ".tmp"
      )
      [System.IO.File]::WriteAllText($ProbePath, "", $Utf8NoBom)
      [System.IO.File]::Delete($ProbePath)
      return $TempRoot
    }
    catch {
      if ($ProbePath) {
        Remove-Item -LiteralPath $ProbePath -Force -ErrorAction SilentlyContinue
      }
    }
  }

  throw (
    "No writable temporary directory is available for Agentic Pipeline. " +
    "Set AGENTIC_PIPELINE_TEMP to an absolute writable directory."
  )
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

function Test-JsonAgainstSchema {
  param(
    [string]$DocumentPath,
    [string]$SchemaPath,
    [string]$PipelineRoot
  )

  if (!(Test-Path -LiteralPath $DocumentPath -PathType Leaf) -or
      !(Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    return $false
  }

  $Validator = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"
  if (!(Test-Path -LiteralPath $Validator -PathType Leaf)) {
    return $false
  }

  $Result = Invoke-NativeCapture `
    -FilePath "node" `
    -ArgumentList @(
      $Validator,
      "validate-json",
      "--schema", $SchemaPath,
      "--file", $DocumentPath
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
$GitBranch = $null

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

    $BranchResult = Invoke-NativeCapture `
      -FilePath "git" `
      -ArgumentList @("-C", $Project, "branch", "--show-current")
    if ($BranchResult.Code -eq 0) {
      $GitBranch = $BranchResult.Text.Trim()
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
$ContractSchemaPath = Join-Path $Pipeline "schemas\companion\phase-contract.schema.json"
$PhaseContractStructurallyValid = [bool](
  $ContractRead.Valid -and
  (Test-JsonAgainstSchema -DocumentPath $ContractPath -SchemaPath $ContractSchemaPath -PipelineRoot $Pipeline)
)

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

$WorkItemPath = Join-Path $StateRoot "WORK_ITEM.json"
$WorkItemRead = Read-JsonFile -Path $WorkItemPath
$WorkItem = if ($WorkItemRead.Valid) { $WorkItemRead.Value } else { $null }
$WorkItemSchemaPath = Join-Path $Pipeline "schemas\companion\work-item.schema.json"
$WorkItemStructurallyValid = [bool](
  $WorkItemRead.Valid -and
  (Test-JsonAgainstSchema -DocumentPath $WorkItemPath -SchemaPath $WorkItemSchemaPath -PipelineRoot $Pipeline)
)

$ExecutionScopePath = Join-Path $StateRoot "EXECUTION_SCOPE.json"
$ExecutionScopeRead = Read-JsonFile -Path $ExecutionScopePath
$ExecutionScope = if ($ExecutionScopeRead.Valid) { $ExecutionScopeRead.Value } else { $null }
$ExecutionScopeSchemaPath = Join-Path $Pipeline "schemas\companion\execution-scope.schema.json"
$ExecutionScopeStructurallyValid = [bool](
  !$ExecutionScopeRead.Present -or
  ($ExecutionScopeRead.Valid -and
   (Test-JsonAgainstSchema -DocumentPath $ExecutionScopePath -SchemaPath $ExecutionScopeSchemaPath -PipelineRoot $Pipeline))
)

$RunResultPath = Join-Path $StateRoot "RUN_RESULT.json"
$RunResultRead = Read-JsonFile -Path $RunResultPath
$RunResult = if ($RunResultRead.Valid) { $RunResultRead.Value } else { $null }
$RunResultSchemaPath = Join-Path $Pipeline "schemas\companion\run-result.schema.json"
$RunResultStructurallyValid = [bool](
  $RunResultRead.Valid -and
  (Test-JsonAgainstSchema -DocumentPath $RunResultPath -SchemaPath $RunResultSchemaPath -PipelineRoot $Pipeline)
)

$FlowPolicyPath = Join-Path $StateRoot "FLOW_POLICY.json"
$FlowPolicyRead = Read-JsonFile -Path $FlowPolicyPath
$FlowPolicy = if ($FlowPolicyRead.Valid) { $FlowPolicyRead.Value } else { $null }
$FlowPolicySchemaPath = Join-Path $Pipeline "schemas\companion\flow-policy.schema.json"
$FlowPolicyStructurallyValid = [bool](
  $FlowPolicyRead.Valid -and
  (Test-JsonAgainstSchema -DocumentPath $FlowPolicyPath -SchemaPath $FlowPolicySchemaPath -PipelineRoot $Pipeline)
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
$ProductBlockers = 0
$VerificationBlockers = 0
$ReleaseBlockers = 0
$ServiceWarnings = 0

if ($FindingsIndex -and $FindingsIndex.findings) {
  foreach ($Finding in @($FindingsIndex.findings)) {
    $Classification = [string]$Finding.phase_classification
    $LifecycleStatus = [string]$Finding.lifecycle_status
    $Category = [string]$Finding.category
    $Materiality = [string]$Finding.materiality

    if ($LifecycleStatus -eq "open_confirmed" -or
        $LifecycleStatus -eq "repair_required" -or
        $LifecycleStatus -eq "fixed_unverified") {
      if ($Materiality -eq "product_blocker") {
        $ProductBlockers++
      }
      elseif ($Materiality -eq "verification_blocker") {
        $VerificationBlockers++
      }
      elseif ($Materiality -eq "release_blocker") {
        $ReleaseBlockers++
      }
      elseif ($Materiality -eq "service_warning") {
        $ServiceWarnings++
      }
      elseif ($LifecycleStatus -eq "fixed_unverified") {
        $VerificationBlockers++
      }
      elseif ($Category -eq "safety" -or
              $Category -eq "security_privacy" -or
              $Category -eq "data_integrity" -or
              $Category -eq "research_validity") {
        $ProductBlockers++
      }
      elseif ($Category -eq "reproducibility" -or $Category -eq "delivery") {
        $VerificationBlockers++
      }
      else {
        $ServiceWarnings++
      }
    }

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

if ($RunResultStructurallyValid) {
  $ProductBlockers = @($RunResult.product_blockers).Count
  $VerificationBlockers = @($RunResult.verification_blockers).Count
  $ReleaseBlockers = @($RunResult.release_blockers).Count
  $ServiceWarnings = @($RunResult.service_warnings).Count
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
    branch_name = $GitBranch
    git_root = $GitRoot
    source_changed_since_result = if ($Phase -and $Phase.source_changed_since_result -eq $true) { $true } else { $false }
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
    present = [bool]$ContractRead.Present
    structurally_valid = $PhaseContractStructurallyValid
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
    product_blockers = $ProductBlockers
    verification_blockers = $VerificationBlockers
    release_blockers = $ReleaseBlockers
    service_warnings = $ServiceWarnings
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
    hard_stop = if ($RunResult -and $RunResult.hard_stop -eq $true) { $true } else { $false }
    no_progress = if ($RunResult -and $RunResult.no_progress -eq $true) { $true } else { $false }
    same_failure_count = if ($Phase -and $null -ne $Phase.same_failure_count) { [int]$Phase.same_failure_count } else { 0 }
    progress_observed = if ($Phase -and $Phase.progress_observed -eq $false) { $false } else { $true }
  }
  work_item_facts = [ordered]@{
    present = [bool]$WorkItemRead.Present
    structurally_valid = $WorkItemStructurallyValid
    work_item_id = if ($WorkItem) { $WorkItem.work_item_id } else { $null }
    goal_epoch = if ($WorkItem) { $WorkItem.goal_epoch } else { $null }
    status = if ($WorkItem) { $WorkItem.status } else { $null }
    owner_approved = if ($WorkItem -and $WorkItem.owner_approved -eq $true) { $true } else { $false }
    assurance_mode = if ($WorkItem) { $WorkItem.assurance_mode } else { $null }
    preferred_command = if ($WorkItem) { $WorkItem.preferred_command } else { $null }
    project_root = if ($WorkItem) { $WorkItem.project_root } else { $null }
    branch = if ($WorkItem) { $WorkItem.branch } else { $null }
    authorization_head = if ($WorkItem) { $WorkItem.authorization_head } else { $null }
    scope_status = if ($ExecutionScope) { $ExecutionScope.status } else { "unresolved" }
    external_drift = if ($ExecutionScope -and $ExecutionScope.external_drift -eq $true) { $true } else { $false }
    hard_stop = if ($WorkItem -and $WorkItem.hard_stop -eq $true) { $true } else { $false }
    flow_restoration_enabled = if ($FlowPolicyStructurallyValid -and $FlowPolicy.enabled -eq $true) { $true } else { $false }
  }
  run_result_facts = [ordered]@{
    present = [bool]$RunResultRead.Present
    structurally_valid = $RunResultStructurallyValid
    work_item_id = if ($RunResult) { $RunResult.work_item_id } else { $null }
    implementation_status = if ($RunResult) { $RunResult.implementation_status } else { $null }
    verification_status = if ($RunResult) { $RunResult.verification_status } else { $null }
    audit_status = if ($RunResult) { $RunResult.audit_status } else { $null }
    acceptance_status = if ($RunResult) { $RunResult.acceptance_status } else { $null }
    product_blockers = if ($RunResult) { @($RunResult.product_blockers).Count } else { 0 }
    verification_blockers = if ($RunResult) { @($RunResult.verification_blockers).Count } else { 0 }
    release_blockers = if ($RunResult) { @($RunResult.release_blockers).Count } else { 0 }
    service_warnings = if ($RunResult) { @($RunResult.service_warnings).Count } else { 0 }
    no_progress = if ($RunResult -and $RunResult.no_progress -eq $true) { $true } else { $false }
    hard_stop = if ($RunResult -and $RunResult.hard_stop -eq $true) { $true } else { $false }
  }
  execution_scope_facts = [ordered]@{
    status = if ($ExecutionScope) { $ExecutionScope.status } else { "unresolved" }
    structurally_valid = $ExecutionScopeStructurallyValid
    work_item_id = if ($ExecutionScope) { $ExecutionScope.work_item_id } else { $null }
    project_root = if ($ExecutionScope) { $ExecutionScope.project_root } else { $null }
    git_head = if ($ExecutionScope) { $ExecutionScope.git_head } else { $null }
    external_drift = if ($ExecutionScope -and $ExecutionScope.external_drift -eq $true) { $true } else { $false }
  }
  flow_policy = [ordered]@{
    enabled = if ($FlowPolicyStructurallyValid -and $FlowPolicy.enabled -eq $true) { $true } else { $false }
    enforcement_mode = if ($FlowPolicyStructurallyValid) { $FlowPolicy.enforcement_mode } else { "enforcing" }
    default_assurance_mode = if ($FlowPolicyStructurallyValid) { $FlowPolicy.default_assurance_mode } else { "flow" }
    same_failure_limit = if ($FlowPolicyStructurallyValid) { [int]$FlowPolicy.same_failure_limit } else { 3 }
    allow_degraded_product_execution = if ($FlowPolicyStructurallyValid -and $FlowPolicy.allow_degraded_product_execution -eq $true) { $true } else { $false }
  }
  requested_command = if ([string]::IsNullOrWhiteSpace($RequestedCommand)) { $null } else { $RequestedCommand }
  routing_policy = [ordered]@{
    explicit_compatibility_matrix = [ordered]@{}
  }
}

if ($FlowPolicyStructurallyValid -and $FlowPolicy.compatible_installed_runtime_versions) {
  foreach ($CompatibleVersion in @($FlowPolicy.compatible_installed_runtime_versions)) {
    if (![string]::IsNullOrWhiteSpace([string]$CompatibleVersion) -and $RuntimeVersion) {
      $Facts.routing_policy.explicit_compatibility_matrix[[string]$CompatibleVersion] = [string]$RuntimeVersion
    }
  }
}

$ResolverScript = Join-Path $Pipeline "scripts\control-plane\resolve-runtime-route.cjs"
if (!(Test-Path -LiteralPath $ResolverScript -PathType Leaf)) {
  throw "Authoritative route resolver script not found: $ResolverScript"
}

$RuntimeTempRoot = Get-AgenticWritableTempRoot
$TempFactsPath = [System.IO.Path]::Combine(
  $RuntimeTempRoot,
  "handshake-facts-" + [Guid]::NewGuid().ToString("N") + ".json"
)
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
  $OutFile = [System.IO.Path]::Combine(
    $RuntimeTempRoot,
    (
      "runtime-handshake-" +
      (Get-Date -Format "yyyyMMdd-HHmmss") +
      "-" +
      [Guid]::NewGuid().ToString("N") +
      ".json"
    )
  )
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
  flow_restoration_enabled = [bool]$Decision.flow_restoration_enabled
  enforcement_mode = [string]$Decision.enforcement_mode
  work_item_present = [bool]$Decision.work_item_present
  work_item_structurally_valid = [bool]$Decision.work_item_structurally_valid
  work_item_id = if ($Decision.work_item_id) { [string]$Decision.work_item_id } else { $null }
  goal_epoch = if ($null -ne $Decision.goal_epoch) { [int]$Decision.goal_epoch } else { $null }
  work_item_status = if ($Decision.work_item_status) { [string]$Decision.work_item_status } else { $null }
  assurance_mode = if ($Decision.assurance_mode) { [string]$Decision.assurance_mode } else { $null }
  execution_scope_status = [string]$Decision.execution_scope_status
  product_execution_allowed = [bool]$Decision.product_execution_allowed
  release_actions_allowed = [bool]$Decision.release_actions_allowed
  governance_health = [string]$Decision.governance_health
  owner_interaction_required = [bool]$Decision.owner_interaction_required
  product_blocker_count = [int]$Decision.product_blocker_count
  verification_blocker_count = [int]$Decision.verification_blocker_count
  release_blocker_count = [int]$Decision.release_blocker_count
  service_warning_count = [int]$Decision.service_warning_count
  run_result_present = [bool]$Decision.run_result_present
  run_result_structurally_valid = [bool]$Decision.run_result_structurally_valid
  shadow_candidate_command = if ($Decision.shadow_candidate_command) { [string]$Decision.shadow_candidate_command } else { $null }
  shadow_candidate_commands_allowed = [string[]]@($Decision.shadow_candidate_commands_allowed)
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
Write-Host "Work item: $($Decision.work_item_id)"
Write-Host "Assurance mode: $($Decision.assurance_mode)"
Write-Host "Governance health: $($Decision.governance_health)"

if ($AllErrors.Count -gt 0) {
  $AllErrors | ForEach-Object { Write-Host "- $_" }
  exit 1
}

exit 0
