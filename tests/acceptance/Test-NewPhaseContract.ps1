[CmdletBinding()]
param(
  [string]$PipelineRoot = "C:\Users\Администратор\Documents\antigravity\agentic-pipeline"
)

$ErrorActionPreference = "Stop"
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
  Remove-Item -Path (Join-Path $TestProjectRoot ".agy\phase-contract-backups") -Recurse -Force -ErrorAction SilentlyContinue
}

# 1. schema-valid new version-1 contract passes
Run-Test "1. schema-valid new version-1 contract passes" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -Apply
  if ($LASTEXITCODE -ne 0) { throw "Script exited non-zero" }
  
  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.contract_version -ne 1) { throw "Expected version 1, got $($Contract.contract_version)" }
}

# 2. schema-valid replacement version 4 -> 5 passes
Run-Test "2. schema-valid replacement version 4 -> 5 passes" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply
  if ($LASTEXITCODE -ne 0) { throw "Replacement failed" }
  
  $Contract = Get-Content -Raw (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json") | ConvertFrom-Json
  if ($Contract.contract_version -ne 5) { throw "Expected version 5, got $($Contract.contract_version)" }
}

# 3. replacement without explicit new version fails
Run-Test "3. replacement without explicit new version fails" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  
  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -Replace -Apply
  } catch {
    $Failed = $true
  }
  if (!$Failed) { throw "Expected replacement to fail without explicit version" }
}

# 4. replacement with equal version fails
Run-Test "4. replacement with equal version fails" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  
  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Replace -Apply
  } catch {
    $Failed = $true
  }
  if (!$Failed) { throw "Expected replacement to fail with equal version" }
}

# 5. replacement with lower version fails
Run-Test "5. replacement with lower version fails" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  
  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 3 -Replace -Apply
  } catch {
    $Failed = $true
  }
  if (!$Failed) { throw "Expected replacement to fail with lower version" }
}

# 6. invalid risk_track fails even with correct hash and lock
Run-Test "6. invalid risk_track fails even with correct hash and lock" {
  Clear-Contract
  
  $Failed = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "health-adjacent research" -Apply
  } catch {
    $Failed = $true
  }
  if (!$Failed) { throw "Expected script to fail with invalid risk_track" }
  
  # Manually write a contract with invalid risk_track but correct hash and lock
  Clear-Contract
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

# 7. missing required property fails
Run-Test "7. missing required property fails" {
  Clear-Contract
  $BadContract = [ordered]@{
    schema_version = "1.0.0"
    contract_version = 1
    phase_id = "P8.1a"
    goal = "Test missing prop"
    risk_track = "standard"
    evidence_level = "E2"
    # status is missing
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
  if (!$ValFailed) { throw "Expected missing property to fail" }
}

# 8. extra forbidden property fails
Run-Test "8. extra forbidden property fails" {
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
  if (!$ValFailed) { throw "Expected extra forbidden property to fail" }
}

# 9. mismatched contract hash fails
Run-Test "9. mismatched contract hash fails" {
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

# 10. mismatched lock hash fails
Run-Test "10. mismatched lock hash fails" {
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

# 11. dry-run changes no files
Run-Test "11. dry-run changes no files" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2"
  
  if (Test-Path -LiteralPath (Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json")) {
    throw "Contract should not be written during Dry Run!"
  }
}

# 12. failed replacement preserves original contract and lock byte-for-byte
Run-Test "12. failed replacement preserves original contract and lock byte-for-byte" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  
  $OrigContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $OrigLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))
  
  # Trigger post-write validator failure by renaming companion-control.cjs
  $NodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"
  $TempNodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control-temp.cjs"
  Rename-Item -Path $NodeCore -NewName "companion-control-temp.cjs"
  
  $Replaced = $false
  try {
    & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply
  } catch {
    $Replaced = $true
  }
  finally {
    Rename-Item -Path $TempNodeCore -NewName "companion-control.cjs"
  }
  
  if (!$Replaced) { throw "Expected replacement call to throw an error due to validator missing" }
  
  # Now verify original bytes are preserved
  $AfterContractBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.json"))
  $AfterLockBytes = [System.IO.File]::ReadAllBytes((Join-Path $TestProjectRoot ".agy\PHASE_CONTRACT.lock.json"))
  
  if ($OrigContractBytes.Length -ne $AfterContractBytes.Length) { throw "Contract byte length changed after failure" }
  if ($OrigLockBytes.Length -ne $AfterLockBytes.Length) { throw "Lock byte length changed after failure" }
  for ($i = 0; $i -lt $OrigContractBytes.Length; $i++) {
    if ($OrigContractBytes[$i] -ne $AfterContractBytes[$i]) { throw "Contract bytes do not match at index $i" }
  }
  for ($i = 0; $i -lt $OrigLockBytes.Length; $i++) {
    if ($OrigLockBytes[$i] -ne $AfterLockBytes[$i]) { throw "Lock bytes do not match at index $i" }
  }
}

# 13. successful replacement creates an immutable backup
Run-Test "13. successful replacement creates an immutable backup" {
  Clear-Contract
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 4 -Apply
  & $NewContractScript -ProjectRoot $TestProjectRoot -PhaseId "P8.1a" -Goal "Verify stuff" -RiskTrack "standard" -EvidenceLevel "E2" -ContractVersion 5 -Replace -Apply
  
  $BackupDir = Join-Path $TestProjectRoot ".agy\phase-contract-backups"
  if (!(Test-Path -LiteralPath $BackupDir)) { throw "Backup directory not found" }
  
  $Backups = Get-ChildItem -Path $BackupDir -Directory
  if ($Backups.Count -eq 0) { throw "No backups found" }
  
  $BackupFile = Join-Path $Backups[0].FullName "PHASE_CONTRACT.json"
  if (!(Test-Path -LiteralPath $BackupFile)) { throw "Backup contract file not found" }
  
  $FileObj = Get-Item -LiteralPath $BackupFile
  if (($FileObj.Attributes -match "ReadOnly") -ne $true) { throw "Backup file is not read-only/immutable" }
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
