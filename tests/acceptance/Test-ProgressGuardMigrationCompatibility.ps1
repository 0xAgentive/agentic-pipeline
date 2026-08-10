[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$Migration = Join-Path $Root 'scripts\windows\companion\Migrate-ActiveWorkItemToProgressGuard.ps1'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-progress-migration-' + [Guid]::NewGuid().ToString('N'))

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), $Utf8)
}

function Invoke-Migration {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)

  $CommandOutput = @(& $HostExe -NoProfile -ExecutionPolicy Bypass -File $Migration -ProjectRoot $ProjectRoot -Apply 2>&1)
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    throw "Migration failed. ExitCode=$ExitCode Output=$($CommandOutput -join [Environment]::NewLine)"
  }
}

$Cases = @(
  [ordered]@{ name = 'no-handshake'; handshake = $null },
  [ordered]@{ name = 'missing-installed'; handshake = [ordered]@{ schema_version = '1.1.0'; routing = [ordered]@{} } },
  [ordered]@{ name = 'missing-routing'; handshake = [ordered]@{ schema_version = '1.1.0' } },
  [ordered]@{ name = 'null-routing'; handshake = [ordered]@{ schema_version = '1.1.0'; routing = $null } }
)

try {
  if (-not (Test-Path -LiteralPath $Migration -PathType Leaf)) {
    throw "Migration script is missing: $Migration"
  }

  foreach ($CaseItem in $Cases) {
    $Project = Join-Path $TempRoot ('Проект-' + $CaseItem.name)
    $Agy = Join-Path $Project '.agy'
    New-Item -ItemType Directory -Force -Path $Agy | Out-Null

    Write-JsonFile -Path (Join-Path $Agy 'WORK_ITEM.json') -Value ([ordered]@{
      schema_version = '1.1.0'
      work_item_id = 'legacy-work-item'
      status = 'active'
      repair_budget = [ordered]@{ limit = 3; used = 3 }
      repair_batches_used = 3
      repair_batch_limit = 3
    })
    Write-JsonFile -Path (Join-Path $Agy 'FINDINGS.json') -Value ([ordered]@{
      schema_version = '1.1.0'
      findings = @(
        [ordered]@{
          finding_id = 'LEGACY-001'
          materiality = 'product_blocker'
          lifecycle_status = 'open_confirmed'
        }
      )
    })
    Write-JsonFile -Path (Join-Path $Agy 'REPAIR_BUDGET.json') -Value ([ordered]@{ limit = 3; used = 3 })

    if ($null -ne $CaseItem.handshake) {
      Write-JsonFile -Path (Join-Path $Agy 'RUNTIME_HANDSHAKE.json') -Value $CaseItem.handshake
    }

    Invoke-Migration -ProjectRoot $Project

    $UpdatedWorkItem = Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($UpdatedWorkItem.PSObject.Properties.Name -contains 'progress_policy')) {
      throw "Case $($CaseItem.name): progress_policy was not added."
    }
    if (-not ($UpdatedWorkItem.PSObject.Properties.Name -contains 'updated_at_utc')) {
      throw "Case $($CaseItem.name): updated_at_utc was not added."
    }
    foreach ($LegacyProperty in @('repair_budget', 'repair_batches_used', 'repair_batch_limit')) {
      if ($UpdatedWorkItem.PSObject.Properties.Name -contains $LegacyProperty) {
        throw "Case $($CaseItem.name): legacy property remains: $LegacyProperty"
      }
    }

    foreach ($RequiredFile in @('PROGRESS_STATE.json', 'NEXT_ACTION.json', 'OWNER_AUTONOMY_MIGRATION_RESULT.json')) {
      if (-not (Test-Path -LiteralPath (Join-Path $Agy $RequiredFile) -PathType Leaf)) {
        throw "Case $($CaseItem.name): missing output $RequiredFile"
      }
    }

    $MigrationResult = Get-Content -LiteralPath (Join-Path $Agy 'OWNER_AUTONOMY_MIGRATION_RESULT.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$MigrationResult.status -ne 'PASS' -or [string]$MigrationResult.next_route -ne '/fixcritical') {
      throw "Case $($CaseItem.name): migration result is not PASS/fixcritical."
    }

    if (Test-Path -LiteralPath (Join-Path $Agy 'REPAIR_BUDGET.json') -PathType Leaf) {
      throw "Case $($CaseItem.name): legacy budget file was not archived."
    }
    $ArchivedBudget = @(Get-ChildItem -LiteralPath (Join-Path $Agy 'history') -Recurse -File -Filter 'REPAIR_BUDGET.json' -ErrorAction SilentlyContinue)
    if ($ArchivedBudget.Count -ne 1) {
      throw "Case $($CaseItem.name): expected exactly one archived budget file."
    }

    $HandshakePath = Join-Path $Agy 'RUNTIME_HANDSHAKE.json'
    if ($null -eq $CaseItem.handshake) {
      if (Test-Path -LiteralPath $HandshakePath -PathType Leaf) {
        throw "Case $($CaseItem.name): migration created a handshake that did not exist."
      }
    }
    else {
      $UpdatedHandshake = Get-Content -LiteralPath $HandshakePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not ($UpdatedHandshake.PSObject.Properties.Name -contains 'installed')) {
        throw "Case $($CaseItem.name): installed was not added."
      }
      if ([string]$UpdatedHandshake.installed.runtime_version -ne '1.2.18') {
        throw "Case $($CaseItem.name): installed runtime version mismatch."
      }
      if (-not ($UpdatedHandshake.PSObject.Properties.Name -contains 'routing')) {
        throw "Case $($CaseItem.name): routing was not added."
      }
      if ([string]$UpdatedHandshake.routing.next_required_command -ne '/fixcritical') {
        throw "Case $($CaseItem.name): route was not repaired."
      }
      if (-not ($UpdatedHandshake.PSObject.Properties.Name -contains 'generated_at_utc')) {
        throw "Case $($CaseItem.name): generated_at_utc was not added."
      }
    }
  }

  Write-Host "Progress-guard migration compatibility passed. Cases: $($Cases.Count)"
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
