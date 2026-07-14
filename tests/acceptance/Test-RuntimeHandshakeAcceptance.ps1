[CmdletBinding()]
param(
  [string]$RepoRoot = ".",
  [string]$PowerShellExecutable = "",
  [switch]$UnicodeOnly
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ExpectedWorkflowCompositeHash = "c9036e5d356c5b24845542431613e0287804084d242b40c5d9218fd56ccfece0"

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

function Invoke-GitLines {
  param([string]$Root, [string[]]$Arguments)
  $Result = Invoke-Capture -FilePath "git" -Arguments (@("-C", $Root) + $Arguments)
  if ($Result.Code -ne 0) {
    throw "git failed: $Root $($Arguments -join ' ')"
  }
  return [string[]]@($Result.Text -split "`r?`n" | Where-Object { $_ -ne "" })
}

function Get-Fingerprint {
  param([string]$Root)
  [ordered]@{
    head = ((Invoke-GitLines -Root $Root -Arguments @("rev-parse", "HEAD")) -join "").Trim()
    status = [string[]](Invoke-GitLines -Root $Root -Arguments @("status", "--porcelain=v1", "--untracked-files=all"))
    staged = [string[]](Invoke-GitLines -Root $Root -Arguments @("diff", "--cached", "--name-only"))
    unstaged = [string[]](Invoke-GitLines -Root $Root -Arguments @("diff", "--name-only"))
    untracked = [string[]](Invoke-GitLines -Root $Root -Arguments @("ls-files", "--others", "--exclude-standard"))
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

  $ByName = @{}
  [string[]]$Names = @(
    Get-ChildItem -LiteralPath $WorkflowRoot -File -Filter "*.md" |
      ForEach-Object {
        $Normalized = $_.Name.ToLowerInvariant()
        if ($ByName.ContainsKey($Normalized)) {
          throw "Duplicate normalized workflow filename: $Normalized"
        }
        $ByName[$Normalized] = $_.FullName
        $Normalized
      }
  )

  [System.Array]::Sort($Names, [System.StringComparer]::Ordinal)

  $Builder = New-Object System.Text.StringBuilder
  foreach ($Name in $Names) {
    $Hash = (Get-FileHash -LiteralPath $ByName[$Name] -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$Builder.Append($Name)
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
    [ValidateSet("workflow", "inventory", "malformed", "empty", "duplicate-command", "invalid-command", "workflow-duplicate")][string]$InventoryMode
  )

  $Root = Join-Path $Parent $Name
  New-Item -ItemType Directory -Force (Join-Path $Root ".agy") | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $Root ".agents\workflows") | Out-Null

  Write-Utf8 -Path (Join-Path $Root ".agents\workflows\landing.md") -Text "# Landing`n"
  Write-Utf8 -Path (Join-Path $Root ".agents\workflows\auditphase.md") -Text "# Audit`n"

  if ($InventoryMode -eq "workflow-duplicate") {
    Write-Utf8 -Path (Join-Path $Root ".agents\workflows\Landing.md") -Text "# Duplicate`n"
  }
  elseif ($InventoryMode -eq "inventory") {
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
  elseif ($InventoryMode -eq "empty") {
    Write-Utf8 -Path (Join-Path $Root ".agents\COMMAND_INVENTORY.json") -Text '{ "schema_version": "1.0.0", "commands": [] }'
  }
  elseif ($InventoryMode -eq "duplicate-command") {
    Write-Utf8 -Path (Join-Path $Root ".agents\COMMAND_INVENTORY.json") -Text '{ "schema_version": "1.0.0", "commands": ["/landing", "/landing"] }'
  }
  elseif ($InventoryMode -eq "invalid-command") {
    Write-Utf8 -Path (Join-Path $Root ".agents\COMMAND_INVENTORY.json") -Text '{ "schema_version": "1.0.0", "commands": ["landing"] }'
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
  "current_status": "awaiting_audit",
  "next_required_command": "/landing",
  "commands_allowed_now": ["/landing"]
}
"@

  Write-Utf8 -Path (Join-Path $Root "README.md") -Text "# Fixture`n"

  $Init = Invoke-Capture -FilePath "git" -Arguments @("-C", $Root, "init", "--quiet")
  if ($Init.Code -ne 0) { throw "git init failed: $Root" }
  if ((Invoke-Capture -FilePath "git" -Arguments @("-C", $Root, "config", "user.name", "Acceptance Fixture")).Code -ne 0) { throw "git config failed" }
  if ((Invoke-Capture -FilePath "git" -Arguments @("-C", $Root, "config", "user.email", "fixture@example.invalid")).Code -ne 0) { throw "git config failed" }
  if ((Invoke-Capture -FilePath "git" -Arguments @("-C", $Root, "add", ".")).Code -ne 0) { throw "git add failed" }
  if ((Invoke-Capture -FilePath "git" -Arguments @("-C", $Root, "commit", "-m", "fixture", "--quiet")).Code -ne 0) { throw "fixture commit failed" }

  Write-Utf8 -Path (Join-Path $Root "DIRTY.txt") -Text "dirty`n"
  return $Root
}

$ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
$HandshakeScript = Join-Path $ResolvedRepo "scripts\windows\companion\Get-RuntimeHandshake.ps1"
$CompanionControl = Join-Path $ResolvedRepo "scripts\companion\companion-control.cjs"
$IndependentSchema = Join-Path $ResolvedRepo "tests\acceptance\handshake-schema-contract.cjs"
$HandshakeSchema = Join-Path $ResolvedRepo "schemas\companion\runtime-handshake.schema.json"

foreach ($Required in @($HandshakeScript, $CompanionControl, $IndependentSchema, $HandshakeSchema)) {
  if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
    throw "Required file missing: $Required"
  }
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
  $RunningOnWindows = $env:OS -eq "Windows_NT"
  $UnicodeName = if ($RunningOnWindows) {
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

  if ($null -ne $WorkflowResult.Handshake) {
    Assert-True -Condition ($WorkflowResult.Handshake.schema_version -eq "1.1.0") -Message "Handshake schema_version must be 1.1.0."
    Assert-True -Condition ($WorkflowResult.Handshake.inventory_source -eq "project_workflow_directory_compat") -Message "Workflow inventory_source mismatch."
    Assert-True -Condition ($WorkflowResult.Handshake.inventory_trust -eq "compatibility") -Message "Workflow inventory_trust mismatch."

    $ComputedWorkflowHash = Get-WorkflowCompositeHash -WorkflowRoot (Join-Path $WorkflowFixture ".agents\workflows")
    Assert-True -Condition ($ComputedWorkflowHash -eq $ExpectedWorkflowCompositeHash) -Message "Protected fixture composite hash changed."
    Assert-True -Condition ($WorkflowResult.Handshake.inventory_sha256 -eq $ExpectedWorkflowCompositeHash) -Message "Workflow composite hash mismatch."

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
  }

  $IndependentResult = Invoke-Capture -FilePath "node" -Arguments @(
    $IndependentSchema,
    "validate",
    "--schema", $HandshakeSchema,
    "--file", $WorkflowResult.OutFile
  )
  Assert-True -Condition ($IndependentResult.Code -eq 0) -Message "Independent schema validation failed. Output=$($IndependentResult.Text)"

  $ProductionSchemaResult = Invoke-Capture -FilePath "node" -Arguments @(
    $CompanionControl,
    "validate-handshake",
    "--repo-root", $ResolvedRepo,
    "--file", $WorkflowResult.OutFile
  )
  Assert-True -Condition ($ProductionSchemaResult.Code -eq 0) -Message "Production schema validation failed. Output=$($ProductionSchemaResult.Text)"

  if (!$UnicodeOnly) {
    $InventoryFixture = New-Fixture -Parent $TempRoot -Name ("inventory-" + [Guid]::NewGuid().ToString("N")) -InventoryMode "inventory"
    $InventoryResult = Invoke-Handshake -FixtureRoot $InventoryFixture
    $InventoryPath = Join-Path $InventoryFixture ".agents\COMMAND_INVENTORY.json"
    $ExpectedInventoryHash = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Assert-True -Condition ($InventoryResult.ExitCode -eq 0) -Message "Authoritative inventory handshake must exit 0."
    if ($null -ne $InventoryResult.Handshake) {
      Assert-True -Condition ($InventoryResult.Handshake.inventory_source -eq "project_command_inventory") -Message "Authoritative inventory_source mismatch."
      Assert-True -Condition ($InventoryResult.Handshake.inventory_trust -eq "authoritative") -Message "Authoritative inventory_trust mismatch."
      Assert-True -Condition ($InventoryResult.Handshake.inventory_sha256 -eq $ExpectedInventoryHash) -Message "Authoritative inventory exact-byte hash mismatch."
    }

    foreach ($Mode in @("malformed", "empty", "duplicate-command", "invalid-command")) {
      $InvalidFixture = New-Fixture -Parent $TempRoot -Name ("invalid-" + $Mode + "-" + [Guid]::NewGuid().ToString("N")) -InventoryMode $Mode
      $InvalidResult = Invoke-Handshake -FixtureRoot $InvalidFixture
      Assert-True -Condition ($InvalidResult.ExitCode -ne 0) -Message "Invalid authoritative inventory mode '$Mode' must fail closed."
      if ($null -ne $InvalidResult.Handshake) {
        Assert-True -Condition ($InvalidResult.Handshake.inventory_source -ne "project_workflow_directory_compat") -Message "Invalid authoritative inventory '$Mode' must not fall back."
        Assert-True -Condition ($InvalidResult.Handshake.routing_valid -eq $false) -Message "Invalid authoritative inventory '$Mode' must set routing_valid=false."
      }
    }

    if (!$RunningOnWindows) {
      $DuplicateWorkflowFixture = New-Fixture -Parent $TempRoot -Name ("workflow-duplicate-" + [Guid]::NewGuid().ToString("N")) -InventoryMode "workflow-duplicate"
      $DuplicateWorkflowResult = Invoke-Handshake -FixtureRoot $DuplicateWorkflowFixture
      Assert-True -Condition ($DuplicateWorkflowResult.ExitCode -ne 0) -Message "Duplicate normalized workflow filenames must fail closed."
    }

    $ProductionSchemaSelfTest = Invoke-Capture -FilePath "node" -Arguments @(
      $CompanionControl,
      "test-schema-validator",
      "--repo-root", $ResolvedRepo
    )
    Assert-True -Condition ($ProductionSchemaSelfTest.Code -eq 0) -Message "Production schema validator self-test failed. Output=$($ProductionSchemaSelfTest.Text)"
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
