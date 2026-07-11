[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [ValidateSet("not_started","in_progress","completed","failed","blocked")][string]$ImplementationStatus = "completed",
  [ValidateSet("not_required","missing","partial","complete","invalid")][string]$ArtifactStatus = "not_required",
  [ValidateSet("not_required","pending","passed","failed","blocked")][string]$AuditStatus = "pending",
  [ValidateSet("not_applicable","unvalidated","partially_validated","validated")][string]$ScientificValidationStatus = "not_applicable",
  [string]$CommandResultsFile = "",
  [string]$ArtifactsFile = "",
  [string[]]$ChangedFiles = @(),
  [string[]]$Blockers = @(),
  [string[]]$AcceptedRisks = @(),
  [string[]]$NextAllowedCommands = @("/auditphase"),
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$Accept,
  [switch]$Ship,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Project ".agy"
$ContractPath = Join-Path $AgyRoot "PHASE_CONTRACT.json"
$ResultPath = Join-Path $AgyRoot "PHASE_RESULT.json"
$NodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"

if (!(Test-Path -LiteralPath $ContractPath -PathType Leaf)) { throw "Missing frozen phase contract: $ContractPath" }
$Contract = ([System.IO.File]::ReadAllText($ContractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)

$CommandResults = @()
if (![string]::IsNullOrWhiteSpace($CommandResultsFile)) {
  if (!(Test-Path -LiteralPath $CommandResultsFile -PathType Leaf)) { throw "Command results file not found: $CommandResultsFile" }
  $CommandResults = @([System.IO.File]::ReadAllText($CommandResultsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

$Artifacts = @()
if (![string]::IsNullOrWhiteSpace($ArtifactsFile)) {
  if (!(Test-Path -LiteralPath $ArtifactsFile -PathType Leaf)) { throw "Artifacts file not found: $ArtifactsFile" }
  $Artifacts = @([System.IO.File]::ReadAllText($ArtifactsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

$FailedRequired = @($CommandResults | Where-Object { $_.required -eq $true -and [int]$_.exit_code -ne 0 })
$VerificationStatus = "not_run"
if ($CommandResults.Count -gt 0) {
  $VerificationStatus = if ($FailedRequired.Count -gt 0) { "failed" } else { "passed" }
}

$EffectiveImplementation = $ImplementationStatus
if ($FailedRequired.Count -gt 0 -and $ImplementationStatus -eq "completed") { $EffectiveImplementation = "failed" }

$AcceptanceStatus = "not_evaluated"
if ($Accept) {
  if ($FailedRequired.Count -gt 0 -or $Blockers.Count -gt 0 -or $ArtifactStatus -in @("missing","invalid")) {
    $AcceptanceStatus = "rejected"
  }
  elseif ($AcceptedRisks.Count -gt 0) { $AcceptanceStatus = "accepted_with_debt" }
  else { $AcceptanceStatus = "accepted" }
}

$ShipStatus = "not_evaluated"
if ($Ship) {
  if ($AcceptanceStatus -eq "accepted" -and $VerificationStatus -eq "passed" -and $AuditStatus -eq "passed" -and $Blockers.Count -eq 0) {
    $ShipStatus = "ship"
  }
  else { $ShipStatus = "no_ship" }
}

$Result = [ordered]@{
  schema_version = "1.0.0"
  phase_id = $Contract.phase_id
  contract_hash = $Contract.contract_hash
  implementation_status = $EffectiveImplementation
  verification_status = $VerificationStatus
  artifact_status = $ArtifactStatus
  audit_status = $AuditStatus
  acceptance_status = $AcceptanceStatus
  scientific_validation_status = $ScientificValidationStatus
  ship_status = $ShipStatus
  command_results = [object[]]$CommandResults
  changed_files = [string[]]$ChangedFiles
  artifacts = [object[]]$Artifacts
  blockers = [string[]]$Blockers
  accepted_risks = [string[]]$AcceptedRisks
  next_allowed_commands = [string[]]$NextAllowedCommands
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
}

Write-Host "Phase result preview:"
Write-Host "  Phase: $($Result.phase_id)"
Write-Host "  Implementation: $($Result.implementation_status)"
Write-Host "  Verification: $($Result.verification_status)"
Write-Host "  Acceptance: $($Result.acceptance_status)"
Write-Host "  Ship: $($Result.ship_status)"
Write-Host "  Failed required commands: $($FailedRequired.Count)"

if (!$Apply) {
  Write-Host "DRY RUN. No project files changed."
  exit 0
}

New-Item -ItemType Directory -Force $AgyRoot | Out-Null
[System.IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 30), $Utf8NoBom)

if (!(Test-Path -LiteralPath $NodeCore -PathType Leaf)) { throw "Companion control script not found: $NodeCore" }
& node $NodeCore validate-result --project-root $Project
if ($LASTEXITCODE -ne 0) { throw "Phase result validation failed after write." }
Write-Host "Phase result written: $ResultPath"
exit 0
