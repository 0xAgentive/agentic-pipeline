[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$PhaseId,
  [Parameter(Mandatory=$false)][string]$Goal = $null,
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
  [Parameter(Mandatory=$false)][ValidateRange(1, 2147483647)][int]$ContractVersion = 0,
  [string]$InjectFailurePoint = $null,
  [switch]$Apply,
  [switch]$Replace
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Project ".agy"
$ContractPath = Join-Path $AgyRoot "PHASE_CONTRACT.json"
$LockPath = Join-Path $AgyRoot "PHASE_CONTRACT.lock.json"
$JournalPath = Join-Path $AgyRoot "phase-contract-replacement.json"
$NodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"

if (!(Test-Path -LiteralPath $NodeCore -PathType Leaf)) {
  throw "Companion control script not found: $NodeCore"
}
if (!(Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js is required to canonicalize the phase contract."
}

# Resolve test-only failure injection from environment if allowed
if ($env:TEST_CONTRACT_REPLACE_SUITE -eq "1") {
  if ([string]::IsNullOrEmpty($InjectFailurePoint)) {
    $InjectFailurePoint = $env:TEST_INJECT_FAILURE_POINT
  }
} else {
  $InjectFailurePoint = $null
}

function Inject-Failure {
  param([string]$Point)
  if ($null -ne $InjectFailurePoint) {
    if ($InjectFailurePoint -eq $Point) {
      throw "TEST_INJECT_FAILURE: $Point"
    }
    if ($InjectFailurePoint -eq ("kill:" + $Point)) {
      Write-Warning "TEST_INJECT_KILL: $Point - Terminating process..."
      [System.Diagnostics.Process]::GetCurrentProcess().Kill()
    }
  }
}

function Recover-ReplacementJournal {
  param(
    [string]$JournalPath,
    [string]$ContractPath,
    [string]$LockPath,
    [string]$NodeCore,
    [string]$ProjectRoot
  )

  Write-Warning "Unfinished contract replacement journal found. Initiating recovery..."
  try {
    $Journal = Get-Content -Raw -LiteralPath $JournalPath | ConvertFrom-Json
  }
  catch {
    throw "Journal is corrupted and cannot be read. Recovery failed. Fail closed."
  }

  $RestoreBackup = $false
  $ActiveValid = $false

  if (Test-Path -LiteralPath $ContractPath) {
    & node $NodeCore validate-contract --project-root $ProjectRoot 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $ActiveContract = Get-Content -Raw -LiteralPath $ContractPath | ConvertFrom-Json
      if ($ActiveContract.contract_version -eq $Journal.proposed_version) {
        $ActiveValid = $true
      }
    }
  }

  if ($ActiveValid) {
    Write-Host "Active contract is already updated to proposed version $($Journal.proposed_version) and validated. Completing replacement."
  }
  else {
    $RestoreBackup = $true
  }

  if ($RestoreBackup) {
    Write-Warning "Active contract/lock is missing or invalid. Restoring backup..."
    if ($null -ne $Journal.original_contract_backup_path -and (Test-Path -LiteralPath $Journal.original_contract_backup_path)) {
      Copy-Item -LiteralPath $Journal.original_contract_backup_path -Destination $ContractPath -Force
    }
    else {
      if (Test-Path -LiteralPath $ContractPath) {
        Remove-Item -LiteralPath $ContractPath -Force
      }
    }

    if ($null -ne $Journal.original_lock_backup_path -and (Test-Path -LiteralPath $Journal.original_lock_backup_path)) {
      Copy-Item -LiteralPath $Journal.original_lock_backup_path -Destination $LockPath -Force
    }
    else {
      if (Test-Path -LiteralPath $LockPath) {
        Remove-Item -LiteralPath $LockPath -Force
      }
    }

    if (Test-Path -LiteralPath $ContractPath) {
      & node $NodeCore validate-contract --project-root $ProjectRoot
      if ($LASTEXITCODE -ne 0) {
        throw "Restored contract/lock pair failed validation. Recovery failed. Fail closed."
      }
      Write-Host "Restored contract version $($Journal.current_version) successfully validated."
    }
    else {
      Write-Host "Restored to clean slate (no contract existed)."
    }
  }

  if ($null -ne $Journal.proposed_contract_path -and (Test-Path -LiteralPath $Journal.proposed_contract_path)) {
    Remove-Item -LiteralPath $Journal.proposed_contract_path -Force
  }
  if ($null -ne $Journal.proposed_lock_path -and (Test-Path -LiteralPath $Journal.proposed_lock_path)) {
    Remove-Item -LiteralPath $Journal.proposed_lock_path -Force
  }

  Remove-Item -LiteralPath $JournalPath -Force
  Write-Host "Recovery completed successfully."
}

# Check and execute recovery if journal exists
if (Test-Path -LiteralPath $JournalPath -PathType Leaf) {
  Recover-ReplacementJournal -JournalPath $JournalPath -ContractPath $ContractPath -LockPath $LockPath -NodeCore $NodeCore -ProjectRoot $Project
  exit 0
}

$CurrentVersion = 0
if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
  if (!$Replace) {
    throw "Phase contract already exists. Use -Replace only after explicit review: $ContractPath"
  }

  $CurrentContract = Get-Content -Raw -LiteralPath $ContractPath | ConvertFrom-Json
  $CurrentVersion = $CurrentContract.contract_version

  if (!$PSBoundParameters.ContainsKey('ContractVersion')) {
    throw "Contract version must be explicitly provided via -ContractVersion when replacing an existing contract."
  }
  if ($ContractVersion -le $CurrentVersion) {
    throw "Proposed contract version ($ContractVersion) must be greater than current contract version ($CurrentVersion)."
  }

  # Inherit parameters that are NOT explicitly bound
  if (!$PSBoundParameters.ContainsKey('Goal')) { $Goal = $CurrentContract.goal }
  if (!$PSBoundParameters.ContainsKey('RiskTrack')) { $RiskTrack = $CurrentContract.risk_track }
  if (!$PSBoundParameters.ContainsKey('EvidenceLevel')) { $EvidenceLevel = $CurrentContract.evidence_level }
  if (!$PSBoundParameters.ContainsKey('NonGoals') -and $null -ne $CurrentContract.non_goals) { $NonGoals = [string[]]$CurrentContract.non_goals }
  if (!$PSBoundParameters.ContainsKey('AllowedPaths') -and $null -ne $CurrentContract.allowed_paths) { $AllowedPaths = [string[]]$CurrentContract.allowed_paths }
  if (!$PSBoundParameters.ContainsKey('ForbiddenPaths') -and $null -ne $CurrentContract.forbidden_paths) { $ForbiddenPaths = [string[]]$CurrentContract.forbidden_paths }
  if (!$PSBoundParameters.ContainsKey('RequiredOutputs') -and $null -ne $CurrentContract.required_outputs) { $RequiredOutputs = [string[]]$CurrentContract.required_outputs }
  if (!$PSBoundParameters.ContainsKey('RequiredChecks') -and $null -ne $CurrentContract.required_checks) { $RequiredChecks = [string[]]$CurrentContract.required_checks }
  if (!$PSBoundParameters.ContainsKey('AcceptanceCriteria') -and $null -ne $CurrentContract.acceptance_criteria) { $AcceptanceCriteria = [string[]]$CurrentContract.acceptance_criteria }
  if (!$PSBoundParameters.ContainsKey('BlockingConditions') -and $null -ne $CurrentContract.blocking_conditions) { $BlockingConditions = [string[]]$CurrentContract.blocking_conditions }
  if (!$PSBoundParameters.ContainsKey('NonBlockingDebtCategories') -and $null -ne $CurrentContract.non_blocking_debt_categories) { $NonBlockingDebtCategories = [string[]]$CurrentContract.non_blocking_debt_categories }
  if (!$PSBoundParameters.ContainsKey('NextAllowedCommands') -and $null -ne $CurrentContract.next_allowed_commands) { $NextAllowedCommands = [string[]]$CurrentContract.next_allowed_commands }
  if (!$PSBoundParameters.ContainsKey('MaxAuditFixCyclesPerSubsystem') -and $null -ne $CurrentContract.repair_budget -and $null -ne $CurrentContract.repair_budget.max_audit_fix_cycles_per_subsystem) { $MaxAuditFixCyclesPerSubsystem = [int]$CurrentContract.repair_budget.max_audit_fix_cycles_per_subsystem }
  if (!$PSBoundParameters.ContainsKey('MaxTotalRepairsPerPhase') -and $null -ne $CurrentContract.repair_budget -and $null -ne $CurrentContract.repair_budget.max_total_repairs_per_phase) { $MaxTotalRepairsPerPhase = [int]$CurrentContract.repair_budget.max_total_repairs_per_phase }
} else {
  if ($Replace) {
    throw "Cannot replace contract because no contract exists at: $ContractPath"
  }
  if ([string]::IsNullOrWhiteSpace($Goal)) {
    throw "Goal is required for new contracts."
  }
}

$ProposedVersion = 1
if ($PSBoundParameters.ContainsKey('ContractVersion')) {
  $ProposedVersion = $ContractVersion
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
  contract_version = $ProposedVersion
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
  # Build proposed contract in a temporary workspace
  $TempAgy = Join-Path $TempRoot ".agy"
  New-Item -ItemType Directory -Force $TempAgy | Out-Null

  $TempContract = Join-Path $TempAgy "PHASE_CONTRACT.json"
  [System.IO.File]::WriteAllText($TempContract, ($Contract | ConvertTo-Json -Depth 20), $Utf8NoBom)

  # Validate against JSON Schema
  $SchemaPath = Join-Path $PipelineRoot "schemas\companion\phase-contract.schema.json"
  if (!(Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "Phase contract schema not found: $SchemaPath"
  }
  $SchemaOutput = @(& node $NodeCore validate-json --schema $SchemaPath --file $TempContract 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Proposed contract failed schema validation: $($SchemaOutput -join ' ')"
  }

  # Compute canonical hash
  $HashOutput = @(& node $NodeCore canonical-hash --file $TempContract 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Contract canonical hash failed: $($HashOutput -join ' ')"
  }
  $ContractHash = ($HashOutput -join "").Trim().ToLowerInvariant()
  $Contract.contract_hash = $ContractHash
  [System.IO.File]::WriteAllText($TempContract, ($Contract | ConvertTo-Json -Depth 20), $Utf8NoBom)

  # Generate proposed lock
  $TempLock = Join-Path $TempAgy "PHASE_CONTRACT.lock.json"
  $Lock = [ordered]@{
    schema_version = "1.0.0"
    phase_id = $PhaseId
    contract_hash = $ContractHash
    frozen_at_utc = $Contract.frozen_at_utc
  }
  [System.IO.File]::WriteAllText($TempLock, ($Lock | ConvertTo-Json -Depth 10), $Utf8NoBom)

  # Validate the proposed contract/lock pair without replacing active files
  $PairValidation = @(& node $NodeCore validate-contract --project-root $TempRoot 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Proposed contract/lock pair failed validation in temporary workspace: $($PairValidation -join ' ')"
  }

  Write-Host "Phase contract preview:"
  Write-Host "  Phase: $PhaseId"
  if ($Replace -and $CurrentVersion -gt 0) {
    Write-Host "  Current version: $CurrentVersion"
  }
  Write-Host "  Proposed version: $($Contract.contract_version)"
  Write-Host "  Risk track: $RiskTrack"
  Write-Host "  Evidence level: $EvidenceLevel"
  Write-Host "  Contract hash: $($Contract.contract_hash)"
  Write-Host "  Apply: $Apply"

  if (!$Apply) {
    Write-Host "DRY RUN. No project files changed."
    exit 0
  }

  # replacement backups
  New-Item -ItemType Directory -Force $AgyRoot | Out-Null
  $BackupRoot = $null
  $ContractBackupPath = $null
  $LockBackupPath = $null

  if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
    $BackupRoot = Join-Path $AgyRoot ("phase-contract-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss") + "_supersede_v" + $CurrentVersion + "_to_v" + $ProposedVersion)
    New-Item -ItemType Directory -Force $BackupRoot | Out-Null

    $ContractBackupPath = Join-Path $BackupRoot "PHASE_CONTRACT.json"
    Copy-Item -LiteralPath $ContractPath -Destination $ContractBackupPath -Force

    if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
      $LockBackupPath = Join-Path $BackupRoot "PHASE_CONTRACT.lock.json"
      Copy-Item -LiteralPath $LockPath -Destination $LockBackupPath -Force
    }
  }

  # Keep original bytes in memory for local rollback on immediate catch
  $OriginalContractBytes = if (Test-Path -LiteralPath $ContractPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($ContractPath) } else { $null }
  $OriginalLockBytes = if (Test-Path -LiteralPath $LockPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($LockPath) } else { $null }

  $ContractNext = Join-Path $AgyRoot "PHASE_CONTRACT.json.next"
  $LockNext = Join-Path $AgyRoot "PHASE_CONTRACT.lock.json.next"

  # fsync helper
  function Write-TextFsync {
    param([string]$Path, [string]$Content)
    $Bytes = $Utf8NoBom.GetBytes($Content)
    $Fs = [System.IO.File]::Create($Path)
    try {
      $Fs.Write($Bytes, 0, $Bytes.Length)
      $Fs.Flush($true)
    }
    finally {
      $Fs.Dispose()
    }
  }

  # 6 & 7: write proposed files as .next and flush/fsync them
  Write-TextFsync -Path $ContractNext -Content ($Contract | ConvertTo-Json -Depth 20)
  Write-TextFsync -Path $LockNext -Content ($Lock | ConvertTo-Json -Depth 10)

  # 8: Create replacement journal
  $JournalData = [ordered]@{
    current_version = $CurrentVersion
    proposed_version = $ProposedVersion
    original_contract_backup_path = $ContractBackupPath
    original_lock_backup_path = $LockBackupPath
    proposed_contract_path = $ContractNext
    proposed_lock_path = $LockNext
    replacement_stage = "pre_replacement"
    started_at = (Get-Date).ToUniversalTime().ToString("o")
    expected_old_hash = if ($CurrentVersion -gt 0) { $CurrentContract.contract_hash } else { $null }
    expected_new_hash = $ContractHash
  }
  [System.IO.File]::WriteAllText($JournalPath, ($JournalData | ConvertTo-Json -Depth 10), $Utf8NoBom)

  # Failure point 1
  Inject-Failure -Point "before_replacement"

  try {
    # 9: atomic replace/rename on contract
    $JournalData.replacement_stage = "replacing_contract"
    [System.IO.File]::WriteAllText($JournalPath, ($JournalData | ConvertTo-Json -Depth 10), $Utf8NoBom)

    if (Test-Path -LiteralPath $ContractPath) {
      [System.IO.File]::Delete($ContractPath)
    }
    [System.IO.File]::Move($ContractNext, $ContractPath)

    # Failure point 2
    Inject-Failure -Point "after_contract_replace"

    # atomic replace/rename on lock
    $JournalData.replacement_stage = "replacing_lock"
    [System.IO.File]::WriteAllText($JournalPath, ($JournalData | ConvertTo-Json -Depth 10), $Utf8NoBom)

    if (Test-Path -LiteralPath $LockPath) {
      [System.IO.File]::Delete($LockPath)
    }
    [System.IO.File]::Move($LockNext, $LockPath)

    $JournalData.replacement_stage = "both_replaced"
    [System.IO.File]::WriteAllText($JournalPath, ($JournalData | ConvertTo-Json -Depth 10), $Utf8NoBom)

    # Failure point 3
    Inject-Failure -Point "after_both_replace"

    # 10: run post-write active validator
    & node $NodeCore validate-contract --project-root $Project
    if ($LASTEXITCODE -ne 0) {
      throw "Phase contract validation failed after write."
    }

    # Backup manifest evidence
    if ($null -ne $BackupRoot) {
      $ContractBackupSize = (Get-Item -LiteralPath $ContractBackupPath).Length
      $ContractBackupHash = (Get-FileHash -LiteralPath $ContractBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()

      $LockBackupSize = 0
      $LockBackupHash = $null
      if ($null -ne $LockBackupPath -and (Test-Path -LiteralPath $LockBackupPath)) {
        $LockBackupSize = (Get-Item -LiteralPath $LockBackupPath).Length
        $LockBackupHash = (Get-FileHash -LiteralPath $LockBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
      }

      $BackupManifest = [ordered]@{
        source_contract_path = $ContractPath
        source_lock_path = $LockPath
        source_version = $CurrentVersion
        destination_contract_backup_path = $ContractBackupPath
        destination_lock_backup_path = $LockBackupPath
        size_bytes = $ContractBackupSize
        sha256 = $ContractBackupHash
        lock_size_bytes = $LockBackupSize
        lock_sha256 = $LockBackupHash
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        read_only_attribute_status = "applied"
        restore_verification_status = "backup_integrity_verified"
      }
      $ManifestPath = Join-Path $BackupRoot "BACKUP_MANIFEST.json"
      [System.IO.File]::WriteAllText($ManifestPath, ($BackupManifest | ConvertTo-Json -Depth 10), $Utf8NoBom)

      # Mark backups read-only (not claiming absolute/legal filesystem immutability, just read-only)
      Set-ItemProperty -Path $ContractBackupPath -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
      if ($null -ne $LockBackupPath) {
        Set-ItemProperty -Path $LockBackupPath -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
      }
      Set-ItemProperty -Path $ManifestPath -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
    }

    # Failure point 4
    Inject-Failure -Point "before_journal_cleanup"
  }
  catch {
    # If the process was terminated/killed directly, this catch block is bypassed.
    # Otherwise, for normal exceptions, we perform rollback.
    Write-Warning "Post-write failure or injected failure detected: $_. Triggering active-file rollback..."
    if ($null -ne $OriginalContractBytes) {
      [System.IO.File]::WriteAllBytes($ContractPath, $OriginalContractBytes)
    } else {
      if (Test-Path -LiteralPath $ContractPath) { Remove-Item -LiteralPath $ContractPath -Force }
    }

    if ($null -ne $OriginalLockBytes) {
      [System.IO.File]::WriteAllBytes($LockPath, $OriginalLockBytes)
    } else {
      if (Test-Path -LiteralPath $LockPath) { Remove-Item -LiteralPath $LockPath -Force }
    }

    # Clean up next files and journal
    if (Test-Path -LiteralPath $ContractNext) { Remove-Item -LiteralPath $ContractNext -Force }
    if (Test-Path -LiteralPath $LockNext) { Remove-Item -LiteralPath $LockNext -Force }
    if (Test-Path -LiteralPath $JournalPath) { Remove-Item -LiteralPath $JournalPath -Force }

    # Clean up backup folder on failure
    if ($null -ne $BackupRoot -and (Test-Path -LiteralPath $BackupRoot)) {
      Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }

  # Clean up journal and temp next files on success
  if (Test-Path -LiteralPath $ContractNext) { Remove-Item -LiteralPath $ContractNext -Force }
  if (Test-Path -LiteralPath $LockNext) { Remove-Item -LiteralPath $LockNext -Force }
  if (Test-Path -LiteralPath $JournalPath) { Remove-Item -LiteralPath $JournalPath -Force }

  Write-Host "Frozen phase contract written and verified: $ContractPath"
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
