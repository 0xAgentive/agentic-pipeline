[CmdletBinding()]
param(
  [string]$RepoRoot = ".",
  [string]$PowerShellExecutable = "",
  [switch]$UnicodeOnly
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8 {
  param([string]$Path, [string]$Text)
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force $Parent | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Invoke-Capture {
  param([string]$FilePath, [string[]]$Arguments)
  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $Output = @(& $FilePath @Arguments 2>&1)
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }
  [pscustomobject]@{
    Code = [int]$Code
    Text = ([object[]]$Output -join "`n")
  }
}

function Get-Fingerprint {
  param([string]$Root)
  [ordered]@{
    head = (& git -C $Root rev-parse HEAD).Trim()
    status = [string[]]@(& git -C $Root status --porcelain=v1 --untracked-files=all)
    staged = [string[]]@(& git -C $Root diff --cached --name-only)
    unstaged = [string[]]@(& git -C $Root diff --name-only)
    untracked = [string[]]@(& git -C $Root ls-files --others --exclude-standard)
  }
}

function Test-FingerprintEqual {
  param([object]$Before, [object]$After)
  return (
    $Before.head -eq $After.head -and
    (($Before.status -join "`n") -eq ($After.status -join "`n")) -and
    (($Before.staged -join "`n") -eq ($After.staged -join "`n")) -and
    (($Before.unstaged -join "`n") -eq ($After.unstaged -join "`n")) -and
    (($Before.untracked -join "`n") -eq ($After.untracked -join "`n"))
  )
}

function Get-WorkflowCompositeHash {
  param([string]$WorkflowRoot)
  $Files = @(
    Get-ChildItem -LiteralPath $WorkflowRoot -File -Filter "*.md" |
      ForEach-Object {
        [pscustomobject]@{
          Normalized = $_.Name.ToLowerInvariant()
          FullName = $_.FullName
        }
      }
  )
  [System.Array]::Sort($Files, [System.Collections.Generic.Comparer[object]]::Create({
    param($A, $B)
    return [System.StringComparer]::Ordinal.Compare($A.Normalized, $B.Normalized)
  }))
  $Builder = New-Object System.Text.StringBuilder
  foreach ($File in $Files) {
    $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$Builder.Append($File.Normalized)
    [void]$Builder.Append("`t")
    [void]$Builder.Append($Hash)
    [void]$Builder.Append("`n")
  }
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Builder.ToString())
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $Sha.Dispose()
  }
}

function New-Fixture {
  param(
    [string]$Parent,
    [string]$Name,
    [ValidateSet("workflow", "inventory", "malformed")][string]$InventoryMode
  )

  $Root = Join-Path $Parent $Name
  New-Item -ItemType Directory -Force (Join-Path $Root ".agy") | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $Root ".agents\workflows") | Out-Null

  Write-Utf8 -Path (Join-Path $Root ".agents\workflows\landing.md") -Text "# Landing`n"
  Write-Utf8 -Path (Join-Path $Root ".agents\workflows\auditphase.md") -Text "# Audit`n"

  if ($InventoryMode -eq "inventory") {
    Write-Utf8 -Path (Join-Path $Root ".agents\COMMAND_INVENTORY.json") -Text @"
{
  "schema_version": "1.0.0",
  "commands": [
    { "command": "/landing" },
    { "command": "/auditphase" }
  ]
}
"@
  }
  elseif ($InventoryMode -eq "malformed") {
    Write-Utf8 -Path (Join-Path $Root ".agents\COMMAND_INVENTORY.json") -Text "{ invalid-json"
  }

  Write-Utf8 -Path (Join-Path $Root ".agy\INSTALLATION_MANIFEST.json") -Text @"
{
  "schema_version": "1.0.0",
  "package_version": "1.2.4",
  "runtime_version": "1.2.1",
  "playbook_version": "1.2.0",
  "companion_version": "1.2.2",
  "source_commit": "fixture",
  "source_repo": "agentic-pipeline",
  "mode": "adopt",
  "state_profile": "adopt-existing",
  "installed_at_utc": "2026-07-14T00:00:00Z"
}
"@

  Write-Utf8 -Path (Join-Path $Root ".agy\PHASE_STATUS.json") -Text @"
{
  "schema_version": "1.0.0",
  "current_phase": "P1",
  "current_status": "release_candidate_ready",
  "next_required_command": "/shipcheck",
  "commands_allowed_now": ["/shipcheck"]
}
"@

  Write-Utf8 -Path (Join-Path $Root "README.md") -Text "# Fixture`n"

  & git -C $Root init --quiet
  if ($LASTEXITCODE -ne 0) { throw "git init failed: $Root" }
  & git -C $Root config user.name "Acceptance Fixture"
  & git -C $Root config user.email "fixture@example.invalid"
  & git -C $Root add .
  & git -C $Root commit -m "fixture" --quiet
  if ($LASTEXITCODE -ne 0) { throw "fixture commit failed: $Root" }

  Write-Utf8 -Path (Join-Path $Root "DIRTY.txt") -Text "dirty`n"
  return $Root
}

$ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
$HandshakeScript = Join-Path $ResolvedRepo "scripts\windows\companion\Get-RuntimeHandshake.ps1"
$CompanionControl = Join-Path $ResolvedRepo "scripts\companion\companion-control.cjs"

if (!(Test-Path -LiteralPath $HandshakeScript -PathType Leaf)) {
  throw "Handshake script missing: $HandshakeScript"
}
if (!(Test-Path -LiteralPath $CompanionControl -PathType Leaf)) {
  throw "Companion control missing: $CompanionControl"
}

if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
  $PowerShellExecutable = if ($PSVersionTable.PSEdition -eq "Core") {
    (Get-Command pwsh -ErrorAction Stop).Source
  } else {
    (Get-Command powershell -ErrorAction Stop).Source
  }
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-acceptance-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $TempRoot | Out-Null
$Failures = New-Object System.Collections.Generic.List[string]
$Passed = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (!$Condition) { [void]$Failures.Add($Message) }
  else { $script:Passed++ }
}

function Invoke-Handshake {
  param([string]$FixtureRoot)
  $OutFile = Join-Path $TempRoot ("handshake-" + [Guid]::NewGuid().ToString("N") + ".json")
  $Result = Invoke-Capture -FilePath $PowerShellExecutable -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $HandshakeScript,
    "-ProjectRoot", $FixtureRoot,
    "-PipelineRoot", $ResolvedRepo,
    "-OutFile", $OutFile
  )
  $Json = $null
  if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
    try {
      $Json = [System.IO.File]::ReadAllText($OutFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {}
  }
  [pscustomobject]@{
    ExitCode = $Result.Code
    Text = $Result.Text
    OutFile = $OutFile
    Handshake = $Json
  }
}

try {
  $UnicodeName = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    "Проверка-маршрута-" + [Guid]::NewGuid().ToString("N")
  } else {
    "unicode-проект-" + [Guid]::NewGuid().ToString("N")
  }

  $WorkflowFixture = New-Fixture -Parent $TempRoot -Name $UnicodeName -InventoryMode "workflow"
  $Before = Get-Fingerprint -Root $WorkflowFixture
  $WorkflowResult = Invoke-Handshake -FixtureRoot $WorkflowFixture
  $After = Get-Fingerprint -Root $WorkflowFixture

  Assert-True -Condition ($WorkflowResult.ExitCode -eq 0) -Message "Workflow compatibility handshake must exit 0. Output=$($WorkflowResult.Text)"
  Assert-True -Condition ($null -ne $WorkflowResult.Handshake) -Message "Workflow compatibility handshake JSON missing."
  Assert-True -Condition ($WorkflowResult.Handshake.schema_version -eq "1.1.0") -Message "Handshake schema_version must be 1.1.0."
  Assert-True -Condition ($WorkflowResult.Handshake.inventory_source -eq "project_workflow_directory_compat") -Message "Workflow inventory_source mismatch."
  Assert-True -Condition ($WorkflowResult.Handshake.inventory_trust -eq "compatibility") -Message "Workflow inventory_trust mismatch."

  $ExpectedWorkflowHash = Get-WorkflowCompositeHash -WorkflowRoot (Join-Path $WorkflowFixture ".agents\workflows")
  Assert-True -Condition ($WorkflowResult.Handshake.inventory_sha256 -eq $ExpectedWorkflowHash) -Message "Workflow composite hash mismatch."
  Assert-True -Condition (Test-FingerprintEqual -Before $Before -After $After) -Message "Handshake mutated the external product fixture."
  Assert-True -Condition (
    [System.StringComparer]::OrdinalIgnoreCase.Equals(
      [System.IO.Path]::GetFullPath([string]$WorkflowResult.Handshake.project_root),
      [System.IO.Path]::GetFullPath([string]$WorkflowResult.Handshake.git_root)
    )
  ) -Message "Non-ASCII project_root/git_root mismatch."

  Assert-True -Condition ($WorkflowResult.Handshake.installed_project_package_version -eq "1.2.4") -Message "Installed package identity mismatch."
  Assert-True -Condition ($WorkflowResult.Handshake.installed_project_runtime_version -eq "1.2.1") -Message "Installed runtime identity mismatch."
  Assert-True -Condition ($WorkflowResult.Handshake.runtime_compatibility -eq "compatible") -Message "Runtime compatibility should be compatible."

  $SchemaResult = Invoke-Capture -FilePath "node" -Arguments @(
    $CompanionControl,
    "validate-handshake",
    "--repo-root", $ResolvedRepo,
    "--file", $WorkflowResult.OutFile
  )
  Assert-True -Condition ($SchemaResult.Code -eq 0) -Message "Generated handshake must pass schema validation. Output=$($SchemaResult.Text)"

  if (!$UnicodeOnly) {
    $InventoryFixture = New-Fixture -Parent $TempRoot -Name ("inventory-" + [Guid]::NewGuid().ToString("N")) -InventoryMode "inventory"
    $InventoryResult = Invoke-Handshake -FixtureRoot $InventoryFixture
    $InventoryPath = Join-Path $InventoryFixture ".agents\COMMAND_INVENTORY.json"
    $ExpectedInventoryHash = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Assert-True -Condition ($InventoryResult.ExitCode -eq 0) -Message "Authoritative inventory handshake must exit 0."
    Assert-True -Condition ($InventoryResult.Handshake.inventory_source -eq "project_command_inventory") -Message "Authoritative inventory_source mismatch."
    Assert-True -Condition ($InventoryResult.Handshake.inventory_trust -eq "authoritative") -Message "Authoritative inventory_trust mismatch."
    Assert-True -Condition ($InventoryResult.Handshake.inventory_sha256 -eq $ExpectedInventoryHash) -Message "Authoritative inventory exact-byte hash mismatch."

    $MalformedFixture = New-Fixture -Parent $TempRoot -Name ("malformed-" + [Guid]::NewGuid().ToString("N")) -InventoryMode "malformed"
    $MalformedResult = Invoke-Handshake -FixtureRoot $MalformedFixture
    Assert-True -Condition ($MalformedResult.ExitCode -ne 0) -Message "Malformed authoritative inventory must fail closed."
    if ($null -ne $MalformedResult.Handshake) {
      Assert-True -Condition ($MalformedResult.Handshake.inventory_source -ne "project_workflow_directory_compat") -Message "Malformed authoritative inventory must not fall back to workflows."
      Assert-True -Condition ($MalformedResult.Handshake.routing_valid -eq $false) -Message "Malformed authoritative inventory must set routing_valid=false."
    }

    $SchemaSelfTest = Invoke-Capture -FilePath "node" -Arguments @(
      $CompanionControl,
      "test-schema-validator",
      "--repo-root", $ResolvedRepo
    )
    Assert-True -Condition ($SchemaSelfTest.Code -eq 0) -Message "Schema validator self-test failed. Output=$($SchemaSelfTest.Text)"
  }
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures.Count -gt 0) {
  Write-Host "Runtime handshake acceptance failed: $($Failures.Count)" -ForegroundColor Red
  $Failures.ToArray() | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Runtime handshake acceptance passed. Assertions: $Passed" -ForegroundColor Green
exit 0