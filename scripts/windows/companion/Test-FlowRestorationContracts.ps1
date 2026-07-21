[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$Node = (Get-Command node -ErrorAction Stop).Source
$Git = (Get-Command git -ErrorAction Stop).Source

function Write-JsonNoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][object]$Value
  )

  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), $Utf8NoBom)
}

function Invoke-ChildScript {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string[]]$Arguments = @(),
    [string]$FailureMessage = "Child script failed."
  )

  $Output = @(& $HostExe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
  $Code = $LASTEXITCODE
  if ($Code -ne 0) {
    throw "$FailureMessage ExitCode=$Code Output=$($Output -join [Environment]::NewLine)"
  }
  return [string[]]$Output
}

function Assert-Equal {
  param(
    [Parameter(Mandatory=$true)][AllowNull()]$Actual,
    [Parameter(Mandatory=$true)][AllowNull()]$Expected,
    [Parameter(Mandatory=$true)][string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected=$Expected Actual=$Actual"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory=$true)][object[]]$Collection,
    [Parameter(Mandatory=$true)]$Value,
    [Parameter(Mandatory=$true)][string]$Message
  )

  if (@($Collection) -notcontains $Value) {
    throw "$Message Missing=$Value"
  }
}

function Read-Handshake {
  param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$RequestedCommand = ""
  )

  $Generator = Join-Path $Root "scripts\windows\companion\Get-RuntimeHandshake.ps1"
  $Arguments = @(
    "-ProjectRoot", $ProjectRoot,
    "-PipelineRoot", $Root,
    "-OutFile", $OutputPath
  )
  if (![string]::IsNullOrWhiteSpace($RequestedCommand)) {
    $Arguments += @("-RequestedCommand", $RequestedCommand)
  }
  Invoke-ChildScript -Path $Generator -Arguments $Arguments -FailureMessage "Handshake generation failed." | Out-Null
  return Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

& $Node (Join-Path $Root "scripts\companion\companion-control.cjs") test-flow-restoration --repo-root $Root
if ($LASTEXITCODE -ne 0) { throw "Flow restoration Node tests failed." }

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("flow-restoration-contracts-" + [Guid]::NewGuid().ToString("N"))
$Project = Join-Path $TempRoot "Project With Unicode Ж"
New-Item -ItemType Directory -Force -Path $Project | Out-Null

try {
  & $Git -C $Project init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed." }
  & $Git -C $Project config user.email "flow-restoration@example.invalid"
  & $Git -C $Project config user.name "Flow Restoration Test"
  [System.IO.File]::WriteAllText((Join-Path $Project "README.md"), "fixture`n", $Utf8NoBom)
  & $Git -C $Project add README.md
  & $Git -C $Project commit -m "fixture baseline" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "fixture commit failed." }

  $AgentsRoot = Join-Path $Project ".agents"
  $AgyRoot = Join-Path $Project ".agy"
  New-Item -ItemType Directory -Force -Path $AgentsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $AgyRoot | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root "templates\agy-project-base\.agents\COMMAND_INVENTORY.json") -Destination (Join-Path $AgentsRoot "COMMAND_INVENTORY.json") -Force
  Copy-Item -LiteralPath (Join-Path $Root "templates\agy-project-base\.agy\FLOW_POLICY.json") -Destination (Join-Path $AgyRoot "FLOW_POLICY.json") -Force

  $Version = Get-Content -LiteralPath (Join-Path $Root "VERSION.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  $Head = (@(& $Git -C $Project rev-parse HEAD 2>&1) -join "`n").Trim()
  Write-JsonNoBom -Path (Join-Path $AgyRoot "INSTALLATION_MANIFEST.json") -Value ([ordered]@{
    schema_version = "1.0.0"
    package_version = [string]$Version.package_version
    runtime_version = [string]$Version.runtime_version
    source_commit = $Head
  })
  Write-JsonNoBom -Path (Join-Path $AgyRoot "PHASE_STATUS.json") -Value ([ordered]@{
    schema_version = "1.0.0"
    current_phase = "legacy-completed"
    current_status = "release_candidate_ready"
    implementation_status = "completed"
    verification_status = "passed"
    artifact_status = "complete"
    audit_status = "passed"
    acceptance_status = "accepted"
    scientific_validation_status = "unvalidated"
    ship_status = "ship"
    next_required_command = $null
    commands_allowed_now = @()
    stale_state = $false
    evidence_state = "current"
  })

  $NewWorkItem = Join-Path $Root "scripts\windows\companion\New-WorkItem.ps1"
  Invoke-ChildScript -Path $NewWorkItem -Arguments @(
    "-ProjectRoot", $Project,
    "-PipelineRoot", $Root,
    "-Goal", "Implement the next owner-approved product change",
    "-AssuranceMode", "guarded",
    "-Apply"
  ) -FailureMessage "New work item creation failed." | Out-Null

  $ShadowHandshakePath = Join-Path $TempRoot "shadow-handshake.json"
  $Shadow = Read-Handshake -ProjectRoot $Project -OutputPath $ShadowHandshakePath
  Assert-Equal -Actual $Shadow.routing_decision -Expected "shadow_route" -Message "Shadow policy must report a candidate route."
  Assert-Equal -Actual $Shadow.next_required_command -Expected $null -Message "Shadow policy must not authorize an executable route."
  Assert-Equal -Actual $Shadow.product_execution_allowed -Expected $false -Message "Shadow policy must not authorize product writes."
  Assert-Equal -Actual $Shadow.shadow_candidate_command -Expected "/nextphase" -Message "Shadow candidate route mismatch."

  $PolicyPath = Join-Path $AgyRoot "FLOW_POLICY.json"
  $Policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Policy.enforcement_mode = "enforcing"
  Write-JsonNoBom -Path $PolicyPath -Value $Policy

  $EnforcingHandshakePath = Join-Path $TempRoot "enforcing-handshake.json"
  $Enforcing = Read-Handshake -ProjectRoot $Project -OutputPath $EnforcingHandshakePath
  Assert-Equal -Actual $Enforcing.next_required_command -Expected "/nextphase" -Message "New owner work item must reopen /nextphase."
  Assert-Equal -Actual $Enforcing.routing_valid -Expected $true -Message "Enforcing product route must be valid."
  Assert-Equal -Actual $Enforcing.release_actions_allowed -Expected $false -Message "Release actions must remain closed."

  $ScopeWriter = Join-Path $Root "scripts\windows\companion\Write-ExecutionScope.ps1"
  $WorkItem = Get-Content -LiteralPath (Join-Path $AgyRoot "WORK_ITEM.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  Invoke-ChildScript -Path $ScopeWriter -Arguments @(
    "-ProjectRoot", $Project,
    "-PipelineRoot", $Root,
    "-WorkItemId", [string]$WorkItem.work_item_id,
    "-AllowedPath", "README.md"
  ) -FailureMessage "Execution scope writer failed." | Out-Null

  $RunResultInput = Join-Path $TempRoot "RUN_RESULT_INPUT.json"
  $RunResultWriter = Join-Path $Root "scripts\windows\companion\Publish-RunResult.ps1"

  function Publish-TestRunResult {
    param(
      [string]$ImplementationStatus,
      [string]$VerificationStatus,
      [string]$AuditStatus,
      [string]$AcceptanceStatus,
      [object[]]$ProductBlockers = @(),
      [object[]]$VerificationBlockers = @(),
      [object[]]$ServiceWarnings = @()
    )

    $CurrentHead = (@(& $Git -C $Project rev-parse HEAD 2>&1) -join "`n").Trim()
    Write-JsonNoBom -Path $RunResultInput -Value ([ordered]@{
      schema_version = "1.0.0"
      work_item_id = [string]$WorkItem.work_item_id
      assurance_mode = "guarded"
      branch = "main"
      head = $CurrentHead
      git_state = "dirty"
      implementation_status = $ImplementationStatus
      verification_status = $VerificationStatus
      audit_status = $AuditStatus
      acceptance_status = $AcceptanceStatus
      product_blockers = [object[]]$ProductBlockers
      verification_blockers = [object[]]$VerificationBlockers
      release_blockers = @()
      service_warnings = [object[]]$ServiceWarnings
      changed_files = @("README.md")
      tests = @()
      evidence_artifacts = @("RUN_RESULT.json", "AUDIT_RESULT.json")
      product_artifacts = @()
      next_workflow = $null
      no_progress = $false
      hard_stop = $false
      generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    })
    Invoke-ChildScript -Path $RunResultWriter -Arguments @(
      "-ProjectRoot", $Project,
      "-PipelineRoot", $Root,
      "-InputFile", $RunResultInput
    ) -FailureMessage "Run result publication failed." | Out-Null
  }

  Publish-TestRunResult `
    -ImplementationStatus "in_progress" `
    -VerificationStatus "not_run" `
    -AuditStatus "pending" `
    -AcceptanceStatus "not_evaluated" `
    -ServiceWarnings @([ordered]@{ code = "STALE_TEST_COUNT"; message = "A stale prose count was superseded."; category = "observability"; auto_repairable = $true })
  $WarningRoute = Read-Handshake -ProjectRoot $Project -OutputPath (Join-Path $TempRoot "warning-route.json")
  Assert-Equal -Actual $WarningRoute.next_required_command -Expected "/nextphase" -Message "Service warning must not block product flow."
  Assert-Equal -Actual $WarningRoute.owner_interaction_required -Expected $false -Message "Service warning must not require the owner."

  Publish-TestRunResult `
    -ImplementationStatus "in_progress" `
    -VerificationStatus "failed" `
    -AuditStatus "pending" `
    -AcceptanceStatus "blocked" `
    -ProductBlockers @([ordered]@{ code = "RAW_ECG_PARITY"; message = "Requested raw ECG member is absent."; category = "data_integrity"; auto_repairable = $true })
  $RepairRoute = Read-Handshake -ProjectRoot $Project -OutputPath (Join-Path $TempRoot "repair-route.json")
  Assert-Equal -Actual $RepairRoute.next_required_command -Expected "/fixcritical" -Message "Product blocker must route to /fixcritical."

  Publish-TestRunResult `
    -ImplementationStatus "completed" `
    -VerificationStatus "partial" `
    -AuditStatus "pending" `
    -AcceptanceStatus "blocked" `
    -VerificationBlockers @([ordered]@{ code = "PACKAGED_FLOW_UNPROVEN"; message = "Packaged flow requires verification."; category = "delivery"; auto_repairable = $true })
  $AuditRoute = Read-Handshake -ProjectRoot $Project -OutputPath (Join-Path $TempRoot "audit-route.json")
  Assert-Equal -Actual $AuditRoute.next_required_command -Expected "/auditphase" -Message "Verification blocker must route to /auditphase."

  Publish-TestRunResult `
    -ImplementationStatus "completed" `
    -VerificationStatus "passed" `
    -AuditStatus "passed" `
    -AcceptanceStatus "accepted"
  $CompleteRoute = Read-Handshake -ProjectRoot $Project -OutputPath (Join-Path $TempRoot "complete-route.json")
  Assert-Equal -Actual $CompleteRoute.routing_decision -Expected "work_item_completed" -Message "Accepted guarded work item must complete without closing the project."
  Assert-Equal -Actual $CompleteRoute.next_required_command -Expected $null -Message "Completed work item must have no next command."

  $WorkItemStatus = Join-Path $Root "scripts\windows\companion\Set-WorkItemStatus.ps1"
  Invoke-ChildScript -Path $WorkItemStatus -Arguments @(
    "-ProjectRoot", $Project,
    "-PipelineRoot", $Root,
    "-Status", "completed"
  ) -FailureMessage "Work item completion writer failed." | Out-Null

  Invoke-ChildScript -Path $NewWorkItem -Arguments @(
    "-ProjectRoot", $Project,
    "-PipelineRoot", $Root,
    "-Goal", "Start a second owner-approved goal after the prior SHIP decision",
    "-AssuranceMode", "flow",
    "-Apply"
  ) -FailureMessage "Second work item creation failed." | Out-Null
  Remove-Item -LiteralPath (Join-Path $AgyRoot "RUN_RESULT.json") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $AgyRoot "EXECUTION_SCOPE.json") -Force -ErrorAction SilentlyContinue

  $SecondGoal = Read-Handshake -ProjectRoot $Project -OutputPath (Join-Path $TempRoot "second-goal-route.json")
  Assert-Equal -Actual $SecondGoal.next_required_command -Expected "/nextphase" -Message "New owner goal must reopen /nextphase after a prior terminal work item."
  Assert-Equal -Actual $SecondGoal.routing_decision -Expected "route" -Message "New owner goal route must be executable in enforcing mode."

  Write-Host "Flow Restoration PowerShell contract tests passed."
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
