[CmdletBinding()]
param(
  [string]$PipelineRoot = "C:\Users\Администратор\Documents\antigravity\agentic-pipeline"
)

$ErrorActionPreference = "Stop"

# Set env var to allow failure injection
$env:TEST_CONTRACT_REPLACE_SUITE = "1"

$TestProjectRoot = Join-Path $env:TEMP ("contract_test_project_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $TestProjectRoot | Out-Null
New-Item -ItemType Directory -Force (Join-Path $TestProjectRoot ".agy") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $TestProjectRoot ".agents") | Out-Null

# Write a minimal COMMAND_INVENTORY.json under .agents
$MinInventory = @{
  commands = @(
    @{ command = "/auditphase" }
  )
}
[System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agents\COMMAND_INVENTORY.json"), ($MinInventory | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

$NewContractScript = Join-Path $PipelineRoot "scripts\windows\companion\New-PhaseContract.ps1"
$TestContractScript = Join-Path $PipelineRoot "scripts\windows\companion\Test-PhaseContract.ps1"

$Results = [ordered]@{}

function Run-Test {
  param(
    [string]$Name,
    [scriptblock]$Block
  )
  Write-Host "Running Test: $Name..."
  try {
    & $Block
    $Results[$Name] = @{ Status = "PASS"; Error = $null }
    Write-Host "  PASS" -ForegroundColor Green
  }
  catch {
    $Results[$Name] = @{ Status = "FAIL"; Error = $_.Exception.Message }
    Write-Host "  FAIL: $_" -ForegroundColor Red
  }
}

function Clear-Contract {
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") -Force -ErrorAction SilentlyContinue
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json") -Force -ErrorAction SilentlyContinue
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\phase-contract-replacement.json") -Force -ErrorAction SilentlyContinue
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json.next") -Force -ErrorAction SilentlyContinue
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json.next") -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\phase-contract-backups")) {
    # Remove read-only attributes first so we can clean them up
    Get-ChildItem -Path (Join-Path $TestProjectRoot ".agy\phase-contract-backups") -Recurse -File | ForEach-Object {
      Set-ItemProperty -Path $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    }
    Remove-Item -Path (Join-Path $TestProjectRoot ".agy\phase-contract-backups") -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Helper to verify bytes match exactly
function Assert-BytesEqual {
  param([byte[]]$a, [byte[]]$b)
  if ($null -eq $a -or $null -eq $b) {
    if ($a -ne $b) { throw "Byte arrays are not equal (one is null)" }
    return
  }
  if ($a.Length -ne $b.Length) { throw "Byte arrays lengths differ: $($a.Length) vs $($b.Length)" }
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($a[$i] -ne $b[$i]) { throw "Byte mismatch at index $i" }
  }
}

# 1. schema-valid new v1 contract
Run-Test "1. schema-valid new v1 contract" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -Apply
  if ($LASTEXITCODE -ne 0) { throw "Script exited non-zero" }

  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.contract_version -ne 1) { throw "Expected version 1, got $($Contract.contract_version)" }
}

# 2. schema-valid replacement v4 -> v5
Run-Test "2. schema-valid replacement v4 -> v5" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply
  if ($LASTEXITCODE -ne 0) { throw "Replacement failed" }

  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.contract_version -ne 5) { throw "Expected version 5, got $($Contract.contract_version)" }
}

# 3. replacement version rules
Run-Test "3. replacement version rules" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $FailedEqual = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -ContractVersion 4 -Replace -Apply
  } catch {
    $FailedEqual = $true
  }
  if (!$FailedEqual) { throw "Expected equal version replacement to fail" }

  $FailedLower = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -ContractVersion 3 -Replace -Apply
  } catch {
    $FailedLower = $true
  }
  if (!$FailedLower) { throw "Expected lower version replacement to fail" }
}

# 4. invalid risk_track with correct hash and lock
Run-Test "4. invalid risk_track with correct hash and lock" {
  Clear-Contract
  # Manually write contract with invalid risk_track and correct hash
  $BadContract = [ordered]@{
    schema_version = "1.0.0"
    contract_version = 1
    phase_id = "P8.1a"
    goal = "Test bad risk track"
    non_goals = @()
    risk_track = "health-adjacent research"
    evidence_level = "E2"
    status = "frozen"
    allowed_paths = @()
    forbidden_paths = @()
    required_outputs = @()
    required_checks = @()
    acceptance_criteria = @()
    blocking_conditions = @()
    non_blocking_debt_categories = @("delivery","observability","cosmetic")
    repair_budget = @{
      max_audit_fix_cycles_per_subsystem = 1
      max_total_repairs_per_phase = 2
      on_budget_exhausted = "human_decision_required"
    }
    next_allowed_commands = @("/auditphase")
    frozen_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    started_at_utc = $null
    contract_hash = ("0" * 64)
  }

  $TempFile = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($TempFile, ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
  $HashOutput = @(& node (Join-Path $PipelineRoot "scripts\companion\companion-control.cjs") canonical-hash --file $TempFile 2>&1)
  $ActualHash = ($HashOutput -join "").Trim().ToLowerInvariant()
  Remove-Item $TempFile -Force

  $BadContract.contract_hash = $ActualHash
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"), ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

  $Lock = @{
    schema_version = "1.0.0"
    phase_id = "P8.1a"
    contract_hash = $ActualHash
    frozen_at_utc = $BadContract.frozen_at_utc
  }
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"), ($Lock | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

  $ValFailed = $false
  & $TestContractScript -ProjectRoot $TestProjectRoot -PipelineRoot $PipelineRoot
  if ($LASTEXITCODE -ne 0) { $ValFailed = $true }
  if (!$ValFailed) { throw "Expected validate-contract to fail on bad risk_track" }
}

# 5. missing required property
Run-Test "5. missing required property" {
  Clear-Contract
  $BadContract = [ordered]@{
    schema_version = "1.0.0"
    contract_version = 1
    phase_id = "P8.1a"
    goal = "Test missing prop"
    risk_track = "standard"
    evidence_level = "E2"
    # status missing
    allowed_paths = @()
    forbidden_paths = @()
    required_outputs = @()
    required_checks = @()
    acceptance_criteria = @()
    blocking_conditions = @()
    non_blocking_debt_categories = @("delivery","observability","cosmetic")
    repair_budget = @{
      max_audit_fix_cycles_per_subsystem = 1
      max_total_repairs_per_phase = 2
      on_budget_exhausted = "human_decision_required"
    }
    next_allowed_commands = @("/auditphase")
    frozen_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    contract_hash = ("0" * 64)
  }

  $TempFile = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($TempFile, ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
  $HashOutput = @(& node (Join-Path $PipelineRoot "scripts\companion\companion-control.cjs") canonical-hash --file $TempFile 2>&1)
  $ActualHash = ($HashOutput -join "").Trim().ToLowerInvariant()
  Remove-Item $TempFile -Force

  $BadContract.contract_hash = $ActualHash
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"), ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

  $Lock = @{
    schema_version = "1.0.0"
    phase_id = "P8.1a"
    contract_hash = $ActualHash
    frozen_at_utc = $BadContract.frozen_at_utc
  }
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"), ($Lock | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

  $ValFailed = $false
  & $TestContractScript -ProjectRoot $TestProjectRoot -PipelineRoot $PipelineRoot
  if ($LASTEXITCODE -ne 0) { $ValFailed = $true }
  if (!$ValFailed) { throw "Expected validation to fail with missing property" }
}

# 6. forbidden extra property
Run-Test "6. forbidden extra property" {
  Clear-Contract
  $BadContract = [ordered]@{
    schema_version = "1.0.0"
    contract_version = 1
    phase_id = "P8.1a"
    goal = "Test extra prop"
    risk_track = "standard"
    evidence_level = "E2"
    status = "frozen"
    extra_forbidden_property = "forbidden"
    allowed_paths = @()
    forbidden_paths = @()
    required_outputs = @()
    required_checks = @()
    acceptance_criteria = @()
    blocking_conditions = @()
    non_blocking_debt_categories = @("delivery","observability","cosmetic")
    repair_budget = @{
      max_audit_fix_cycles_per_subsystem = 1
      max_total_repairs_per_phase = 2
      on_budget_exhausted = "human_decision_required"
    }
    next_allowed_commands = @("/auditphase")
    frozen_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    contract_hash = ("0" * 64)
  }

  $TempFile = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($TempFile, ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
  $HashOutput = @(& node (Join-Path $PipelineRoot "scripts\companion\companion-control.cjs") canonical-hash --file $TempFile 2>&1)
  $ActualHash = ($HashOutput -join "").Trim().ToLowerInvariant()
  Remove-Item $TempFile -Force

  $BadContract.contract_hash = $ActualHash
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"), ($BadContract | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

  $Lock = @{
    schema_version = "1.0.0"
    phase_id = "P8.1a"
    contract_hash = $ActualHash
    frozen_at_utc = $BadContract.frozen_at_utc
  }
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"), ($Lock | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

  $ValFailed = $false
  & $TestContractScript -ProjectRoot $TestProjectRoot -PipelineRoot $PipelineRoot
  if ($LASTEXITCODE -ne 0) { $ValFailed = $true }
  if (!$ValFailed) { throw "Expected validation to fail with extra property" }
}

# 7. contract-hash mismatch
Run-Test "7. contract-hash mismatch" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -Apply

  $Text = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json")
  $Obj = $Text | ConvertFrom-Json
  $Obj.contract_hash = "a" * 64
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"), ($Obj | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)

  $ValFailed = $false
  & $TestContractScript -ProjectRoot $TestProjectRoot -PipelineRoot $PipelineRoot
  if ($LASTEXITCODE -ne 0) { $ValFailed = $true }
  if (!$ValFailed) { throw "Expected mismatched contract hash to fail" }
}

# 8. lock-hash mismatch
Run-Test "8. lock-hash mismatch" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -Apply

  $Text = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json")
  $Obj = $Text | ConvertFrom-Json
  $Obj.contract_hash = "b" * 64
  [System.IO.File]::WriteAllText((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"), ($Obj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

  $ValFailed = $false
  & $TestContractScript -ProjectRoot $TestProjectRoot -PipelineRoot $PipelineRoot
  if ($LASTEXITCODE -ne 0) { $ValFailed = $true }
  if (!$ValFailed) { throw "Expected mismatched lock hash to fail" }
}

# 9. dry-run no-write
Run-Test "9. dry-run no-write" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2"

  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json")) {
    throw "Contract should not be written during Dry Run!"
  }
}

# 10. pre-replacement injected failure
Run-Test "10. pre-replacement injected failure" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply -InjectFailurePoint "before_replacement"
  } catch {
    $Failed = $true
  }

  if (!$Failed) { throw "Expected script to fail at before_replacement hook" }

  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 11. failure after contract replacement
Run-Test "11. failure after contract replacement" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply -InjectFailurePoint "after_contract_replace"
  } catch {
    $Failed = $true
  }

  if (!$Failed) { throw "Expected script to fail at after_contract_replace hook" }

  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 12. failure after both replacements
Run-Test "12. failure after both replacements" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply -InjectFailurePoint "after_both_replace"
  } catch {
    $Failed = $true
  }

  if (!$Failed) { throw "Expected script to fail at after_both_replace hook" }

  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 13. post-write validator failure
Run-Test "13. post-write validator failure" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply -InjectFailurePoint "before_journal_cleanup"
  } catch {
    $Failed = $true
  }

  if (!$Failed) { throw "Expected script to fail at before_journal_cleanup hook" }

  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 14. journal recovery after interrupted child process
Run-Test "14. journal recovery after interrupted child process" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  # Run replacement in a child process that crashes/fails at after_contract_replace
  $env:TEST_CONTRACT_REPLACE_SUITE = "1"
  $ProcArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $NewContractScript,
                "-ProjectRoot", $TestProjectRoot, "-PhaseId", "P8.1a", "-Goal", "Verify stuff",
                "-RiskTrack", "standard", "-EvidenceLevel", "E2", "-ContractVersion", "5",
                "-Replace", "-Apply", "-InjectFailurePoint", "kill:after_contract_replace")

  # Execute in background and wait
  $Proc = Start-Process pwsh -ArgumentList $ProcArgs -NoNewWindow -PassThru -Wait

  # The child process has exited, leaving the directory in a partially replaced state:
  # PHASE_CONTRACT.json is replaced with proposed version 5, but PHASE_CONTRACT.lock.json is still old,
  # and the replacement journal phase-contract-replacement.json is still present!

  # Run New-PhaseContract.ps1 again to trigger recovery!
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2"
  if ($LASTEXITCODE -ne 0) { throw "Recovery invocation failed" }

  # Check that recovery restored the valid prior pair v4
  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 15. exact-byte rollback
Run-Test "15. exact-byte rollback" {
  # This is already fully validated in Tests 10, 11, 12, 13, 14.
  # We will execute another rollback test to verify exact bytes match.
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply -InjectFailurePoint "after_both_replace"
  } catch {}

  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))

  Assert-BytesEqual $OrigContractBytes $AfterContractBytes
  Assert-BytesEqual $OrigLockBytes $AfterLockBytes
}

# 16. no stale .next or journal
Run-Test "16. no stale .next or journal" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  # Verify no journal or .next files remain after successful run
  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\phase-contract-replacement.json")) { throw "Stale journal exists" }
  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json.next")) { throw "Stale contract.next exists" }
  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json.next")) { throw "Stale lock.next exists" }
}

# 17. backup manifest/hash correctness
Run-Test "17. backup manifest/hash correctness" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  # Replace
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply

  $BackupDir = Join-Path $TestProjectRoot ".agy\phase-contract-backups"
  $Backups = Get-ChildItem -Path $BackupDir -Directory
  if ($Backups.Count -eq 0) { throw "No backups folder" }

  $ManifestPath = Join-Path $Backups[0].FullName "BACKUP_MANIFEST.json"
  if (!(Test-Path -LiteralPath $ManifestPath)) { throw "Manifest missing" }

  $Manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
  if ($Manifest.source_version -ne 4) { throw "Expected source version 4, got $($Manifest.source_version)" }
  if ($Manifest.restore_verification_status -ne "backup_integrity_verified") { throw "Expected backup_integrity_verified" }
}

# 18. new contract without Goal fails
Run-Test "18. new contract without Goal fails" {
  Clear-Contract
  $Failed = $false
  try {
    # Run without Goal
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Apply
  } catch {
    $Failed = $true
  }
  if (!$Failed) { throw "Expected new contract to fail without Goal" }
}

# 19. replacement without Goal inherits
Run-Test "19. replacement without Goal inherits" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Original Goal Text" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  # Replace without specifying Goal
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -ContractVersion 5 -Replace -Apply
  if ($LASTEXITCODE -ne 0) { throw "Replacement failed" }

  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.goal -ne "Original Goal Text") { throw "Expected inherited goal 'Original Goal Text', got '$($Contract.goal)'" }
}

# 20. replacement with explicit Goal overrides
Run-Test "20. replacement with explicit Goal overrides" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Original Goal Text" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply

  # Replace specifying override Goal
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Overridden Goal Text" -ContractVersion 5 -Replace -Apply
  if ($LASTEXITCODE -ne 0) { throw "Replacement failed" }

  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.goal -ne "Overridden Goal Text") { throw "Expected overridden goal 'Overridden Goal Text', got '$($Contract.goal)'" }
}

# Clean up
Remove-Item -Path $TestProjectRoot -Recurse -Force -ErrorAction SilentlyContinue

# Write test summary and output result JSON
$PassCount = 0
$FailCount = 0
$ResultsArray = @()
foreach ($Key in $Results.Keys) {
  if ($Results[$Key].Status -eq "PASS") { $PassCount++ } else { $FailCount++ }
  $ResultsArray += [ordered]@{
    TestName = $Key
    Status = $Results[$Key].Status
    Error = $Results[$Key].Error
  }
}

$TestSummary = "PASS: $PassCount, FAIL: $FailCount"
Write-Host $TestSummary

# Save JSON results to temporary file for parent runner
$Output = [ordered]@{
  Summary = $TestSummary
  PassCount = $PassCount
  FailCount = $FailCount
  Tests = $ResultsArray
}
$Output | ConvertTo-Json -Depth 10
if ($FailCount -gt 0) {
  exit 1
}
exit 0
