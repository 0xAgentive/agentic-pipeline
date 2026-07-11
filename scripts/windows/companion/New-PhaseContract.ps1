[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$PhaseId,
  [Parameter(Mandatory=$true)][string]$Goal,
  [ValidateSet("scratch","research","standard","critical","release")][string]$RiskTrack = "standard",
  [ValidateSet("E0","E1","E2","E3","E4")][string]$EvidenceLevel = "E2",
  [string[]]$NonGoals = @(),
  [string[]]$AllowedPaths = @(),
  [string[]]$ForbiddenPaths = @(),
  [string[]]$RequiredOutputs = @(),
  [string[]]$RequiredChecks = @(),
  [string[]]$AcceptanceCriteria = @(),
  [string[]]$BlockingConditions = @(),
  [string[]]$NonBlockingDebtCategories = @("delivery","observability","cosmetic"),
  [string[]]$NextAllowedCommands = @("/auditphase"),
  [int]$MaxAuditFixCyclesPerSubsystem = 1,
  [int]$MaxTotalRepairsPerPhase = 2,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$Apply,
  [switch]$Replace
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Project ".agy"
$ContractPath = Join-Path $AgyRoot "PHASE_CONTRACT.json"
$LockPath = Join-Path $AgyRoot "PHASE_CONTRACT.lock.json"
$NodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"

if (!(Test-Path -LiteralPath $NodeCore -PathType Leaf)) {
  throw "Companion control script not found: $NodeCore"
}
if (!(Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js is required to canonicalize the phase contract."
}
if ((Test-Path -LiteralPath $ContractPath -PathType Leaf) -and !$Replace) {
  throw "Phase contract already exists. Use -Replace only after explicit review: $ContractPath"
}

$InventoryPath = Join-Path $Project ".agents\COMMAND_INVENTORY.json"
if (!(Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
  $InventoryPath = Join-Path $PipelineRoot "config\command-inventory.json"
}
if (Test-Path -LiteralPath $InventoryPath -PathType Leaf) {
  $InventoryText = [System.IO.File]::ReadAllText($InventoryPath, [System.Text.Encoding]::UTF8)
  $Inventory = $InventoryText | ConvertFrom-Json
  $KnownCommands = @($Inventory.commands | ForEach-Object { $_.command })
  foreach ($Command in $NextAllowedCommands) {
    if ($KnownCommands -notcontains $Command) {
      throw "NextAllowedCommands contains a command absent from runtime inventory: $Command"
    }
  }
}

$Contract = [ordered]@{
  schema_version = "1.0.0"
  contract_version = 1
  phase_id = $PhaseId
  goal = $Goal
  non_goals = [string[]]$NonGoals
  risk_track = $RiskTrack
  evidence_level = $EvidenceLevel
  status = if ($Apply) { "frozen" } else { "draft" }
  allowed_paths = [string[]]$AllowedPaths
  forbidden_paths = [string[]]$ForbiddenPaths
  required_outputs = [string[]]$RequiredOutputs
  required_checks = [string[]]$RequiredChecks
  acceptance_criteria = [string[]]$AcceptanceCriteria
  blocking_conditions = [string[]]$BlockingConditions
  non_blocking_debt_categories = [string[]]$NonBlockingDebtCategories
  repair_budget = [ordered]@{
    max_audit_fix_cycles_per_subsystem = $MaxAuditFixCyclesPerSubsystem
    max_total_repairs_per_phase = $MaxTotalRepairsPerPhase
    on_budget_exhausted = "human_decision_required"
  }
  next_allowed_commands = [string[]]$NextAllowedCommands
  frozen_at_utc = if ($Apply) { (Get-Date).ToUniversalTime().ToString("o") } else { $null }
  started_at_utc = $null
  contract_hash = ("0" * 64)
}

$TempRoot = Join-Path $env:TEMP ("phase_contract_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $TempRoot | Out-Null
try {
  $TempContract = Join-Path $TempRoot "PHASE_CONTRACT.json"
  [System.IO.File]::WriteAllText($TempContract, ($Contract | ConvertTo-Json -Depth 20), $Utf8NoBom)
  $HashOutput = @(& node $NodeCore canonical-hash --file $TempContract 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Contract canonical hash failed: $($HashOutput -join ' ')"
  }
  $Contract.contract_hash = ($HashOutput -join "").Trim().ToLowerInvariant()

  Write-Host "Phase contract preview:"
  Write-Host "  Phase: $PhaseId"
  Write-Host "  Risk track: $RiskTrack"
  Write-Host "  Evidence level: $EvidenceLevel"
  Write-Host "  Contract hash: $($Contract.contract_hash)"
  Write-Host "  Apply: $Apply"

  if (!$Apply) {
    Write-Host "DRY RUN. No project files changed."
    exit 0
  }

  New-Item -ItemType Directory -Force $AgyRoot | Out-Null
  if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
    $BackupRoot = Join-Path $AgyRoot ("phase-contract-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force $BackupRoot | Out-Null
    Copy-Item -LiteralPath $ContractPath -Destination (Join-Path $BackupRoot "PHASE_CONTRACT.json") -Force
    if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
      Copy-Item -LiteralPath $LockPath -Destination (Join-Path $BackupRoot "PHASE_CONTRACT.lock.json") -Force
    }
  }

  [System.IO.File]::WriteAllText($ContractPath, ($Contract | ConvertTo-Json -Depth 20), $Utf8NoBom)
  $Lock = [ordered]@{
    schema_version = "1.0.0"
    phase_id = $PhaseId
    contract_hash = $Contract.contract_hash
    frozen_at_utc = $Contract.frozen_at_utc
  }
  [System.IO.File]::WriteAllText($LockPath, ($Lock | ConvertTo-Json -Depth 10), $Utf8NoBom)

  & node $NodeCore validate-contract --project-root $Project
  if ($LASTEXITCODE -ne 0) { throw "Phase contract validation failed after write." }

  Write-Host "Frozen phase contract written: $ContractPath"
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
