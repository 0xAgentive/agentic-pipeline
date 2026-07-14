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
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  return ($Text | ConvertFrom-Json)
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

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$StateRoot = Join-Path $Project ".agy"
$ArtifactRoot = Join-Path $Project ".artifacts"
$WorkflowRoot = Join-Path $Project ".agents\workflows"

if (!(Test-Path -LiteralPath $Project -PathType Container)) {
  throw "Project root not found: $ProjectRoot"
}

$GitRoot = $null
$GitState = $null
$HeadCommit = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
  $GitRootResult = Invoke-NativeCapture -FilePath "git" -ArgumentList @("-C", $Project, "rev-parse", "--show-toplevel")
  if ($GitRootResult.Code -eq 0) { $GitRoot = $GitRootResult.Text.Trim() }
  if ($GitRoot) {
    $HeadResult = Invoke-NativeCapture -FilePath "git" -ArgumentList @("-C", $Project, "rev-parse", "HEAD")
    if ($HeadResult.Code -eq 0) { $HeadCommit = $HeadResult.Text.Trim() }

    $StatusResult = Invoke-NativeCapture -FilePath "git" -ArgumentList @("-C", $Project, "status", "--porcelain=v1", "--untracked-files=all")
    if ($StatusResult.Code -eq 0) {
      $GitState = if ($StatusResult.Lines.Count -eq 0) { "clean" } else { "dirty" }
    }
  }
}

$PackageVersion = $null
$RuntimeVersion = $null
$PipelineVersionPath = Join-Path $PipelineRoot "VERSION.json"
$PipelineVersion = Read-JsonFile -Path $PipelineVersionPath
if ($PipelineVersion) {
  $PackageVersion = $PipelineVersion.package_version
  $RuntimeVersion = $PipelineVersion.runtime_version
}

# 1. Project-Local Inventory Discovery
$ProjectInventoryPath = Join-Path $Project ".agents\COMMAND_INVENTORY.json"
if (!(Test-Path -LiteralPath $ProjectInventoryPath -PathType Leaf)) {
  $Candidate = Join-Path $Project ".agents\command-inventory.json"
  if (Test-Path -LiteralPath $Candidate -PathType Leaf) { $ProjectInventoryPath = $Candidate }
}

$ProjectInventoryCommands = @()
$ProjectInventoryHash = $null
$InventorySource = "missing"

if (Test-Path -LiteralPath $ProjectInventoryPath -PathType Leaf) {
  $InventoryJson = Read-JsonFile -Path $ProjectInventoryPath
  if ($InventoryJson -and $InventoryJson.commands) {
    foreach ($Item in @($InventoryJson.commands)) {
      if ($Item.command) { $ProjectInventoryCommands += [string]$Item.command }
      elseif (typeof $Item -eq "string") { $ProjectInventoryCommands += [string]$Item }
    }
    $ProjectInventoryHash = (Get-FileHash -LiteralPath $ProjectInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $InventorySource = "project_local"
  }
}
elseif (Test-Path -LiteralPath $WorkflowRoot -PathType Container) {
  $WorkflowFiles = Get-ChildItem -LiteralPath $WorkflowRoot -File -Filter "*.md" | Sort-Object Name
  if ($WorkflowFiles.Count -gt 0) {
    foreach ($File in $WorkflowFiles) {
      $ProjectInventoryCommands += "/" + [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    }
    $InventorySource = "project_local"
    $ProjectInventoryPath = $WorkflowRoot
  }
}

# 2. Central Inventory Advisory
$CentralInventoryPath = Join-Path $PipelineRoot "config\command-inventory.json"
$CentralInventoryCommands = @()
if (Test-Path -LiteralPath $CentralInventoryPath -PathType Leaf) {
  $CentralJson = Read-JsonFile -Path $CentralInventoryPath
  if ($CentralJson -and $CentralJson.commands) {
    foreach ($Item in @($CentralJson.commands)) {
      if ($Item.command) { $CentralInventoryCommands += [string]$Item.command }
    }
  }
}

# 3. Read State / Result / Contract Facts
$PhasePath = Join-Path $StateRoot "PHASE_STATUS.json"
$Phase = Read-JsonFile -Path $PhasePath

$ContractPath = Join-Path $StateRoot "PHASE_CONTRACT.json"
$Contract = Read-JsonFile -Path $ContractPath

$ResultPath = Join-Path $StateRoot "PHASE_RESULT.json"
$Result = Read-JsonFile -Path $ResultPath

$FinalVerificationPath = Join-Path $Project "FINAL_VERIFICATION.json"
$FinalVerification = Read-JsonFile -Path $FinalVerificationPath

# Read Findings Index
$FindingsIndexPath = Join-Path $StateRoot "FINDINGS_INDEX.json"
$FindingsIndex = Read-JsonFile -Path $FindingsIndexPath

$OpenConfirmedCurrentPhaseBlockers = 0
$RepairRequiredCurrentPhaseFindings = 0
$VerificationRequiredCurrentPhaseFindings = 0
$FixedUnverifiedCurrentPhaseFindings = 0
$VerifiedResolvedFindings = 0
$DeferredProductFindings = 0
$DeferredInfrastructureFindings = 0
$AcceptedRisks = 0

if ($FindingsIndex -and $FindingsIndex.findings) {
  foreach ($Finding in $FindingsIndex.findings) {
    $Classification = $Finding.phase_classification
    $Status = $Finding.lifecycle_status
    $Category = $Finding.category

    if ($Status -eq "verified_resolved" -or $Classification -eq "resolved") {
      $VerifiedResolvedFindings++
    }
    elseif ($Status -eq "accepted_risk" -or $Status -eq "deferred") {
      $AcceptedRisks++
    }
    elseif ($Classification -eq "current_phase_blocker") {
      if ($Status -eq "open_confirmed" -or $Status -eq "repair_required") {
        $OpenConfirmedCurrentPhaseBlockers++
        $RepairRequiredCurrentPhaseFindings++
      }
      elseif ($Status -eq "fixed_unverified") {
        $FixedUnverifiedCurrentPhaseFindings++
        $VerificationRequiredCurrentPhaseFindings++
      }
    }
    elseif ($Classification -eq "next_phase_requirement" -or $Classification -eq "deferred") {
      if ($Category -eq "delivery" -or $Category -eq "infrastructure" -or $Finding.title -like "*migration*") {
        $DeferredInfrastructureFindings++
      }
      else {
        $DeferredProductFindings++
      }
    }
  }
}

# Construct Facts Object
$Facts = [ordered]@{
  project_inventory = [ordered]@{
    source = $InventorySource
    inventory_path = $ProjectInventoryPath
    inventory_sha256 = $ProjectInventoryHash
    commands = $ProjectInventoryCommands
    runtime_version = if ($Phase -and $Phase.runtime_version) { $Phase.runtime_version } else { $null }
  }
  central_inventory_advisory = [ordered]@{
    commands = $CentralInventoryCommands
    runtime_version = $RuntimeVersion
  }
  git_facts = [ordered]@{
    git_state = $GitState
    head_commit = $HeadCommit
    git_root = $GitRoot
  }
  state_facts = [ordered]@{
    current_phase = if ($Phase) { $Phase.current_phase } else { $null }
    current_status = if ($Phase) {
      if ($null -ne $Phase.current_status) { $Phase.current_status }
      elseif ($null -ne $Phase.phase_status) { $Phase.phase_status }
      elseif ($null -ne $Phase.status) { $Phase.status }
      elseif ($null -ne $Phase.project_status) { $Phase.project_status }
      else { $null }
    } else { $null }
    implementation_status = if ($Phase) { $Phase.implementation_status } else { $null }
    verification_status = if ($Phase) { $Phase.verification_status } else { $null }
    artifact_status = if ($Phase) { $Phase.artifact_status } else { $null }
    audit_status = if ($Phase) { $Phase.audit_status } else { $null }
    acceptance_status = if ($Phase) { $Phase.acceptance_status } else { $null }
    scientific_validation_status = if ($Phase) { $Phase.scientific_validation_status } else { $null }
    ship_status = if ($Phase) { $Phase.ship_status } else { $null }
    next_required_command = if ($Phase) { $Phase.next_required_command } else { $null }
    commands_allowed_now = if ($Phase) { $Phase.commands_allowed_now } else { $null }
    stale_state = if ($Phase) { $Phase.stale_state } else { $null }
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
    valid = if ($Result) { $true } else { $false }
    missing = if ($Result) { $false } else { $true }
    contract_hash = if ($Result) { $Result.contract_hash } else { $null }
    release_source_commit = if ($Result) { $Result.release_source_commit } else { $null }
    source_commit = if ($Result) { $Result.source_commit } else { $null }
    command_inventory_sha256 = if ($Result) { $Result.command_inventory_sha256 } else { $null }
  }
  acceptance_facts = [ordered]@{
    acceptance_status = if ($Result) { $Result.acceptance_status } elseif ($FinalVerification) { $FinalVerification.acceptance_status } else { $null }
    audit_status = if ($Result) { $Result.audit_status } elseif ($Phase) { $Phase.audit_status } else { $null }
    verification_status = if ($Result) { $Result.verification_status } else { $null }
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
    audit_result_present = if ($Result) { $true } else { $false }
    audit_result_schema_valid = if ($Result) { $true } else { $false }
    audit_authoritative = if ($Result -and $Result.audit_authoritative -ne $false) { $true } else { $false }
    audit_evidence_complete = if ($Result -and $Result.audit_evidence_complete -ne $false) { $true } else { $false }
    claims_evidence_consistent = if ($Result -and $Result.claims_evidence_consistent -eq $false) { $false } else { $true }
  }
  repair_facts = [ordered]@{
    repair_budget_known = if ($Contract -and $null -ne $Contract.repair_budget) { $true } else { $false }
    repair_budget_exhausted = if ($Phase -and $Phase.repair_budget_exhausted -eq $true) { $true } else { $false }
    user_continue_repair_authorized = if ($Phase -and $Phase.user_continue_repair_authorized -eq $true) { $true } else { $false }
    registered_repair_cycle_count = if ($Phase -and $null -ne $Phase.registered_repair_cycle_count) { $Phase.registered_repair_cycle_count } else { 1 }
  }
  requested_command = $null
  routing_policy = [ordered]@{
    allow_triage = $false
    allow_1x_compatibility = $true
  }
}

# 4. Invoke resolve-runtime-route.cjs
$ResolverScript = Join-Path $PipelineRoot "scripts\control-plane\resolve-runtime-route.cjs"
if (!(Test-Path -LiteralPath $ResolverScript -PathType Leaf)) {
  throw "Authoritative route resolver script not found: $ResolverScript"
}

$TempFactsPath = Join-Path $env:TEMP ("handshake_facts_" + [Guid]::NewGuid().ToString() + ".json")
[System.IO.File]::WriteAllText($TempFactsPath, ($Facts | ConvertTo-Json -Depth 10), $Utf8NoBom)

try {
  $ResolverResult = Invoke-NativeCapture -FilePath "node" -ArgumentList @($ResolverScript, "--facts-file", $TempFactsPath)
  if ($ResolverResult.Code -ne 0) {
    throw "Route resolver execution failed: $($ResolverResult.Text)"
  }
  $Decision = $ResolverResult.Text | ConvertFrom-Json
}
finally {
  if (Test-Path -LiteralPath $TempFactsPath) { Remove-Item -LiteralPath $TempFactsPath -Force }
}

# 5. Check Root Mismatch Invariants
$ExtraErrors = New-Object System.Collections.Generic.List[string]
$NormProject = $Project.Replace("\", "/").TrimEnd("/").ToLowerInvariant()
$NormGit = if ($GitRoot) { $GitRoot.Replace("\", "/").TrimEnd("/").ToLowerInvariant() } else { $null }
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

$AllErrors = @()
if ($Decision.routing_errors) { $AllErrors += @($Decision.routing_errors) }
if ($ExtraErrors.Count -gt 0) { $AllErrors += @($ExtraErrors.ToArray()) }

$FinalRoutingValid = [bool]($Decision.routing_valid -and ($ExtraErrors.Count -eq 0))

# Format Stale Reasons
$StaleReasonsList = @()
if ($Decision.stale_reasons) {
  foreach ($SR in $Decision.stale_reasons) {
    $StaleReasonsList += [ordered]@{
      code = [string]$SR.code
      evidence = [string]$SR.evidence
      severity = [string]$SR.severity
    }
  }
}

if ($WriteToProject) {
  $OutFile = Join-Path $StateRoot "RUNTIME_HANDSHAKE.json"
}
elseif ([string]::IsNullOrWhiteSpace($OutFile)) {
  $OutFile = Join-Path $env:TEMP ("runtime_handshake_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
}

$Handshake = [ordered]@{
  schema_version = "1.0.0"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pipeline_package_version = $PackageVersion
  runtime_version = $RuntimeVersion
  project_root = $Project
  workspace_root = $Project
  git_root = $GitRoot
  state_root = $StateRoot
  artifact_root = $ArtifactRoot
  command_inventory_path = $ProjectInventoryPath
  command_inventory_sha256 = $ProjectInventoryHash
  available_commands = [string[]]@($Decision.available_commands)
  current_phase = if ($Phase) { $Phase.current_phase } else { $null }
  current_status = [string]$Decision.current_status
  next_required_command = if ($Decision.next_required_command) { [string]$Decision.next_required_command } else { $null }
  commands_allowed_now = [string[]]@($Decision.commands_allowed_now)
  routing_valid = $FinalRoutingValid
  routing_errors = [string[]]$AllErrors
  git_state = $GitState
  routing_mode = [string]$Decision.routing_mode
  inventory_source = [string]$Decision.inventory_source
  inventory_path = $ProjectInventoryPath
  inventory_sha256 = $ProjectInventoryHash
  installed_project_runtime_version = [string]$Decision.installed_project_runtime_version
  available_pipeline_runtime_version = [string]$Decision.available_pipeline_runtime_version
  runtime_compatibility = [string]$Decision.runtime_compatibility
  state_declared_next_required_command = if ($Decision.state_declared_next_required_command) { [string]$Decision.state_declared_next_required_command } else { $null }
  state_declared_commands_allowed_now = [string[]]@($Decision.state_declared_commands_allowed_now)
  resolved_commands_allowed_now = [string[]]@($Decision.resolved_commands_allowed_now)
  stale_state = [bool]$Decision.stale_state
  stale_reasons = $StaleReasonsList
}

$Parent = Split-Path -Parent $OutFile
if ($Parent) { New-Item -ItemType Directory -Force $Parent | Out-Null }
[System.IO.File]::WriteAllText($OutFile, ($Handshake | ConvertTo-Json -Depth 20), $Utf8NoBom)

Write-Host "Runtime handshake written: $OutFile"
Write-Host "Routing mode: $($Decision.routing_mode)"
Write-Host "Inventory source: $($Decision.inventory_source)"
Write-Host "Available commands: $(@($Decision.available_commands).Count)"
Write-Host "Current status: $($Decision.current_status)"
Write-Host "Next required command: $($Decision.next_required_command)"
Write-Host "Routing valid: $FinalRoutingValid"
if ($AllErrors.Count -gt 0) {
  $AllErrors | ForEach-Object { Write-Host "- $_" }
  exit 1
}
exit 0
