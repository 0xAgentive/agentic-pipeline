[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Node = (Get-Command node -ErrorAction Stop).Source
$PythonCommand = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $PythonCommand) { $PythonCommand = Get-Command py -ErrorAction Stop | Select-Object -First 1 }
$Python = $PythonCommand.Source
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-operational-deployment-' + [Guid]::NewGuid().ToString('N'))
$Project = Join-Path $TempRoot 'Проект Ж'
$Registry = Join-Path $TempRoot 'project-registry.json'
$StateRoot = Join-Path $TempRoot 'bridge-state'
$PacketPath = Join-Path $TempRoot 'AGENTIC_ACTION_PACKET_test.json'

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [Parameter(Mandatory = $true)][string]$FailureMessage
  )
  $Output = @(& $FilePath @ArgumentList 2>&1)
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    throw "$FailureMessage ExitCode=$ExitCode Output=$($Output -join [Environment]::NewLine)"
  }
  return [string[]]$Output
}

try {
  New-Item -ItemType Directory -Force -Path $Project | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agents') -Destination (Join-Path $Project '.agents') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\.agy') -Destination (Join-Path $Project '.agy') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Root 'templates\agy-project-base\scripts') -Destination (Join-Path $Project 'scripts') -Recurse -Force

  & git -C $Project init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
  & git -C $Project config user.email 'operational-test@example.invalid'
  & git -C $Project config user.name 'Operational Test'
  [System.IO.File]::WriteAllText((Join-Path $Project 'README.md'), "fixture`n", $Utf8NoBom)
  & git -C $Project add -A
  & git -C $Project commit -m 'baseline' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'fixture commit failed.' }

  # New work item without optional audit_dimensions must succeed under StrictMode.
  $NewWorkItem = Join-Path $Root 'scripts\windows\companion\New-WorkItem.ps1'
  Invoke-Checked -FilePath $Pwsh -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $NewWorkItem,
    '-ProjectRoot', $Project,
    '-PipelineRoot', $Root,
    '-Goal', 'Operational deployment test',
    '-AssuranceMode', 'guarded',
    '-Apply'
  ) -FailureMessage 'New work-item transaction failed.' | Out-Null

  $WorkItemPath = Join-Path $Project '.agy\WORK_ITEM.json'
  if (-not (Test-Path -LiteralPath $WorkItemPath -PathType Leaf)) { throw 'WORK_ITEM.json was not created.' }
  $WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$WorkItem.status -ne 'ready') { throw 'Work item did not enter ready state.' }
  if (-not ($WorkItem.PSObject.Properties.Name -contains 'audit_dimensions')) { throw 'Optional audit_dimensions was not normalized.' }

  # Runtime update must work in runtime-update mode and preserve no product route.
  Remove-Item -LiteralPath $WorkItemPath -Force
  foreach ($Name in @('WORK_ITEM_TRANSACTION.json', 'STAGE_FIREWALL.json', 'PROGRESS_STATE.json', 'NEXT_ACTION.json')) {
    Remove-Item -LiteralPath (Join-Path $Project ('.agy\' + $Name)) -Force -ErrorAction SilentlyContinue
  }
  $Updater = Join-Path $Root 'scripts\windows\Update-AgenticProjectRuntime-v1.2.9.ps1'
  Invoke-Checked -FilePath $Pwsh -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Updater,
    '-ProjectRoot', $Project,
    '-RepoRoot', $Root,
    '-Apply',
    '-AllowDirty',
    '-SkipActiveWorkItemMigration'
  ) -FailureMessage 'Synthetic runtime update failed.' | Out-Null

  $InstallManifest = Get-Content -LiteralPath (Join-Path $Project '.agy\INSTALLATION_MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$InstallManifest.mode -ne 'runtime-update') { throw 'Runtime update manifest mode is not runtime-update.' }
  if ($null -ne $InstallManifest.next_command) { throw 'Runtime update incorrectly opened a product route.' }
  if ([string]$InstallManifest.runtime_version -ne '1.2.9') { throw 'Runtime version mismatch after update.' }

  # JSON Action Packet import must materialize the task in the registered project.
  $CapabilityToken = 'a' * 64
  $RegistryObject = [ordered]@{
    schema_version = '1.2.9'
    ecosystem_version = '1.2.9'
    projects = @([ordered]@{
      project_id = 'operational-test'
      project_root = $Project
      logical_name = 'Operational Test'
      ecosystem_version = '1.2.9'
      capability_token = $CapabilityToken
    })
  }
  [System.IO.File]::WriteAllText($Registry, ($RegistryObject | ConvertTo-Json -Depth 10), $Utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $Project '.agy\ACTION_BRIDGE_CAPABILITY.json'), ([ordered]@{schema_version='1.2.9';ecosystem_version='1.2.9';project_id='operational-test';capability_token=$CapabilityToken}|ConvertTo-Json), $Utf8NoBom)
  $Now = (Get-Date).ToUniversalTime()
  $Packet = [ordered]@{
    schema_version = '1.2.9'
    ecosystem_version = '1.2.9'
    packet_format = 'single_json'
    packet_id = 'operational-' + [Guid]::NewGuid().ToString('N')
    project_id = 'operational-test'
    operation = 'new_work_item'
    route = '/nextphase'
    goal = 'Run operational bridge test'
    assurance_mode = 'guarded'
    owner_approved = $true
    owner_interaction_policy = 'hard_stop_only'
    scope_binding = 'executor_discovery'
    technical_task_markdown = "# Task`nRun operational bridge test."
    owner_summary_ru = "## Что происходит`nПроверка.`n## Что уже сделано`nПодготовлено.`n## Что будет дальше`nИмпорт.`n## Нужно ли что-то от владельца`nНет."
    created_at_utc = $Now.ToString('o')
    expires_at_utc = $Now.AddHours(1).ToString('o')
  }
  [System.IO.File]::WriteAllText($PacketPath, ($Packet | ConvertTo-Json -Depth 20), $Utf8NoBom)
  $Bridge = Join-Path $Root 'scripts\bridge\companion_action_bridge.py'
  Invoke-Checked -FilePath $Python -ArgumentList @(
    $Bridge, 'import',
    '--packet', $PacketPath,
    '--registry', $Registry,
    '--state-root', $StateRoot
  ) -FailureMessage 'Action Bridge import failed.' | Out-Null

  $ActiveTask = Join-Path $Project '.agy\inbox\ACTIVE_ACTION_PACKET\AGENT_TASK.md'
  if (-not (Test-Path -LiteralPath $ActiveTask -PathType Leaf)) { throw 'Action Bridge did not materialize AGENT_TASK.md.' }

  # Node control-plane syntax and manifest writer smoke.
  & $Node --check (Join-Path $Root 'scripts\control-plane\action-packet.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'Node action-packet syntax failed.' }

  Write-Host 'Operational deployment contract passed.'
  exit 0
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
