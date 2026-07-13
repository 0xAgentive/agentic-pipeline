$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HandshakeScript = Join-Path $ScriptDir "Get-RuntimeHandshake.ps1"
$PipelineRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path

# Create temp project directory for fixtures
$TempDir = Join-Path $env:TEMP "handshake_fixtures_test_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$TempAgy = Join-Path $TempDir ".agy"
$TempWorkflows = Join-Path $TempDir ".agents\workflows"
New-Item -ItemType Directory -Force $TempAgy | Out-Null
New-Item -ItemType Directory -Force $TempWorkflows | Out-Null
[System.IO.File]::WriteAllText((Join-Path $TempWorkflows "landing.md"), "# Landing", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $TempWorkflows "auditphase.md"), "# Auditphase", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $TempDir "README.md"), "# Temp Project", [System.Text.Encoding]::UTF8)

# Initialize git in TempDir
& git -C $TempDir init --quiet
& git -C $TempDir add .
& git -C $TempDir commit -m "initial" --quiet
[System.IO.File]::WriteAllText((Join-Path $TempDir "README.md"), "# Temp Project Dirty", [System.Text.Encoding]::UTF8)

function Run-HandshakeTest {
  param(
    [hashtable]$PhaseStatus,
    [string]$CustomProjectRoot = $TempDir
  )
  
  $PhaseJsonPath = Join-Path $CustomProjectRoot ".agy\PHASE_STATUS.json"
  if ($null -ne $PhaseStatus) {
    [System.IO.File]::WriteAllText($PhaseJsonPath, ($PhaseStatus | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
  }
  
  $OutJson = Join-Path $env:TEMP "handshake_test_out.json"
  if (Test-Path $OutJson) { Remove-Item $OutJson }
  
  $Proc = Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $HandshakeScript, "-ProjectRoot", $CustomProjectRoot, "-PipelineRoot", $PipelineRoot, "-OutFile", $OutJson -PassThru -Wait -NoNewWindow
  
  $ExitCode = $Proc.ExitCode
  $Handshake = $null
  if (Test-Path $OutJson) {
    $Handshake = Get-Content -Raw $OutJson | ConvertFrom-Json
    Remove-Item $OutJson
  }
  
  return [pscustomobject]@{
    ExitCode = $ExitCode
    Handshake = $Handshake
  }
}

Write-Host "Running recovery routing tests on mock temp project..."

# Test 1: Dirty state overrides stale empty commands_allowed_now to /landing
$Res1 = Run-HandshakeTest -PhaseStatus @{
  current_phase = "P8.0c-r3"
  phase_status = "release_candidate_ready"
  next_required_command = $null
  commands_allowed_now = @("")
  stale_state = $true
}

if ($null -eq $Res1.Handshake) {
  Write-Error "Test 1 failed to produce handshake output JSON."
  exit 1
}

if ($Res1.Handshake.next_required_command -ne "/landing" -or $Res1.Handshake.routing_mode -ne "recovery" -or $Res1.Handshake.routing_valid -ne $true) {
  Write-Error "Test 1 expected recovery mode with next_required_command=/landing and routing_valid=true, got mode=$($Res1.Handshake.routing_mode) next=$($Res1.Handshake.next_required_command) valid=$($Res1.Handshake.routing_valid)"
  exit 1
}
Write-Host "  Success: Test 1 derived /landing recovery routing for dirty/stale state."

# Clean up
if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir }

Write-Host "All handshake semantic invariant tests passed successfully!"
exit 0
