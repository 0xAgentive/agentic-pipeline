[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [switch]$PreserveFailedFixture
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$EcosystemVersion = '1.2.16'
$ActionPacketSchemaVersion = '1.2.9'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Python = (Get-Command python -ErrorAction Stop | Select-Object -First 1).Source
$Node = (Get-Command node -ErrorAction Stop | Select-Object -First 1).Source
$Pwsh = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
$Git = (Get-Command git -ErrorAction Stop | Select-Object -First 1).Source
$Bridge = Join-Path $Root 'scripts\bridge\companion_action_bridge.py'
$TemplateRoot = Join-Path $Root 'templates\agy-project-base'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Assertions = 0

foreach ($Required in @(
  $Bridge,
  (Join-Path $TemplateRoot '.agents\hooks\agentic_runtime_hook.cjs'),
  (Join-Path $TemplateRoot 'scripts\windows\companion\Activate-ActionPacket.ps1'),
  (Join-Path $TemplateRoot 'scripts\windows\companion\Start-WorkItemTransaction.ps1')
)) {
  if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required Action Bridge test input is missing: $Required" }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
  param([Parameter(Mandatory = $true)][string]$Text)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Write-Utf8Text {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  Write-Utf8Text -Path $Path -Text (($Value | ConvertTo-Json -Depth 100) + "`n")
}

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [string]$WorkingDirectory = '',
    [AllowNull()][string]$InputText = $null,
    [int]$TimeoutSeconds = 30
  )

  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $FilePath
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.RedirectStandardInput = $null -ne $InputText
  $StartInfo.StandardOutputEncoding = $Utf8NoBom
  $StartInfo.StandardErrorEncoding = $Utf8NoBom
  if ($null -ne $InputText) { $StartInfo.StandardInputEncoding = $Utf8NoBom }
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $StartInfo.WorkingDirectory = $WorkingDirectory }
  $StartInfo.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
  foreach ($Argument in $ArgumentList) { [void]$StartInfo.ArgumentList.Add($Argument) }

  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw 'Unable to start hermetic child process.' }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) {
      $Process.StandardInput.Write($InputText)
      $Process.StandardInput.Close()
    }
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
      $Process.Kill($true)
      throw "Hermetic child process timed out after $TimeoutSeconds seconds."
    }
    $Process.WaitForExit()
    return [pscustomobject]@{
      exit_code = $Process.ExitCode
      stdout = $StdoutTask.GetAwaiter().GetResult()
      stderr = $StderrTask.GetAwaiter().GetResult()
    }
  }
  finally {
    $Process.Dispose()
  }
}

function Get-CheckoutSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string[]]$InputPaths
  )
  $Records = [Collections.Generic.List[string]]::new()
  $Files = [Collections.Generic.List[IO.FileInfo]]::new()
  foreach ($InputPath in $InputPaths) {
    if (Test-Path -LiteralPath $InputPath -PathType Leaf) { [void]$Files.Add((Get-Item -LiteralPath $InputPath)) }
    elseif (Test-Path -LiteralPath $InputPath -PathType Container) {
      foreach ($File in Get-ChildItem -LiteralPath $InputPath -File -Recurse -Force) { [void]$Files.Add($File) }
    }
    else { throw "Audited source input is missing: $InputPath" }
  }
  foreach ($File in $Files | Sort-Object FullName -Unique) {
    $Relative = [IO.Path]::GetRelativePath($CheckoutRoot, $File.FullName).Replace('\', '/')
    [void]$Records.Add(('{0}|{1}|{2}' -f $Relative, [long]$File.Length, (Get-Sha256 -Path $File.FullName)))
  }
  return $Records -join "`n"
}

function Initialize-HermeticProject {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [Parameter(Mandatory = $true)][string]$CapabilityToken
  )

  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
  Copy-Item -LiteralPath (Join-Path $TemplateRoot '.agents') -Destination (Join-Path $ProjectRoot '.agents') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $TemplateRoot '.agy') -Destination (Join-Path $ProjectRoot '.agy') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $TemplateRoot 'scripts') -Destination (Join-Path $ProjectRoot 'scripts') -Recurse -Force
  Write-Utf8Text -Path (Join-Path $ProjectRoot 'README.md') -Text "hermetic Action Bridge fixture`n"

  foreach ($GitArgs in @(
    @('-C', $ProjectRoot, 'init', '--initial-branch=main'),
    @('-C', $ProjectRoot, 'config', 'user.email', 'action-bridge@example.invalid'),
    @('-C', $ProjectRoot, 'config', 'user.name', 'Action Bridge Acceptance'),
    @('-C', $ProjectRoot, 'add', '-f', 'README.md'),
    @('-C', $ProjectRoot, 'commit', '-m', 'fixture baseline')
  )) {
    $GitResult = Invoke-CapturedProcess -FilePath $Git -ArgumentList $GitArgs -WorkingDirectory $ProjectRoot
    if ($GitResult.exit_code -ne 0) { throw 'Hermetic Git fixture initialization failed.' }
  }

  Write-JsonFile -Path (Join-Path $ProjectRoot '.agy\INSTALLATION_MANIFEST.json') -Value ([ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    package_version = $EcosystemVersion
    runtime_version = $EcosystemVersion
    version = $EcosystemVersion
  })
  Write-JsonFile -Path (Join-Path $ProjectRoot '.agy\ACTION_BRIDGE_CAPABILITY.json') -Value ([ordered]@{
    schema_version = $ActionPacketSchemaVersion
    ecosystem_version = $EcosystemVersion
    project_id = $ProjectId
    capability_token = $CapabilityToken
  })
}

function New-ExternalPacket {
  param(
    [Parameter(Mandatory = $true)][string]$PacketId,
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [string]$Operation = 'new_work_item',
    [string]$Route = '/nextphase',
    [string]$SchemaVersion = $ActionPacketSchemaVersion,
    [string]$PacketEcosystemVersion = $EcosystemVersion,
    [string]$Goal = 'Hermetic Action Bridge owner goal',
    [AllowNull()][string]$WorkItemId = $null,
    [AllowNull()][Nullable[int]]$GoalEpoch = $null,
    [datetime]$CreatedAt = (Get-Date).ToUniversalTime(),
    [datetime]$ExpiresAt = (Get-Date).ToUniversalTime().AddHours(1)
  )

  $Packet = [ordered]@{
    schema_version = $SchemaVersion
    ecosystem_version = $PacketEcosystemVersion
    packet_format = 'single_json'
    packet_id = $PacketId
    project_id = $ProjectId
    operation = $Operation
    route = $Route
    goal = $Goal
    assurance_mode = 'guarded'
    owner_approved = $true
    owner_interaction_policy = 'hard_stop_only'
    scope_binding = 'executor_discovery'
    technical_task_markdown = "# Hermetic task`nСтрока с LF и пробелами в конце.  `nПродолжить безопасно."
    owner_summary_ru = "## Что происходит`nГерметичная проверка.`n## Что уже сделано`nПодготовлен fixture.`n## Что будет дальше`nИмпорт и активация.`n## Нужно ли что-то от владельца`nНет."
    created_at_utc = $CreatedAt.ToString('o')
    expires_at_utc = $ExpiresAt.ToString('o')
  }
  if (-not [string]::IsNullOrWhiteSpace($WorkItemId)) { $Packet['work_item_id'] = $WorkItemId }
  if ($null -ne $GoalEpoch) { $Packet['goal_epoch'] = [int]$GoalEpoch }
  if ($Operation -eq 'continue_work_item' -and -not [string]::IsNullOrWhiteSpace($WorkItemId)) {
    $Packet['owner_goal_sha256'] = Get-TextSha256 -Text $Goal
  }
  return $Packet
}

function Assert-SecretAbsentFromText {
  param(
    [AllowNull()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Label
  )
  Assert-True -Condition (-not ([string]$Text).Contains($CapabilityToken)) -Message "Capability leaked through $Label."
}

function Invoke-BridgeScan {
  param([Parameter(Mandatory = $true)][int]$ExpectedExitCode)
  $Result = Invoke-CapturedProcess -FilePath $Python -ArgumentList @(
    '-B', $Bridge, 'scan', '--inbox', $ExternalInbox, '--registry', $RegistryPath, '--state-root', $StateRoot
  )
  Assert-True -Condition ($Result.exit_code -eq $ExpectedExitCode) -Message "Action Bridge scan returned $($Result.exit_code), expected $ExpectedExitCode."
  Assert-SecretAbsentFromText -Text $Result.stdout -Label 'bridge stdout'
  Assert-SecretAbsentFromText -Text $Result.stderr -Label 'bridge stderr'
  return $Result
}

function Invoke-Hook {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)
  $Hook = Join-Path $ProjectRoot '.agents\hooks\agentic_runtime_hook.cjs'
  $Payload = [ordered]@{ workspacePaths = @($ProjectRoot); conversationId = 'hermetic-action-bridge' } | ConvertTo-Json -Compress
  $Result = Invoke-CapturedProcess -FilePath $Node -ArgumentList @($Hook, 'preinvocation') -WorkingDirectory $ProjectRoot -InputText $Payload
  Assert-True -Condition ($Result.exit_code -eq 0) -Message 'PreInvocation hook process failed.'
  Assert-SecretAbsentFromText -Text $Result.stdout -Label 'hook stdout'
  Assert-SecretAbsentFromText -Text $Result.stderr -Label 'hook stderr'
  return ($Result.stdout | ConvertFrom-Json)
}

function Get-ControlFileState {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)
  $AgyRoot = Join-Path $ProjectRoot '.agy'
  $Records = foreach ($Name in @('WORK_ITEM.json', 'STAGE_FIREWALL.json', 'PROGRESS_STATE.json', 'NEXT_ACTION.json', 'WORK_ITEM_TRANSACTION.json')) {
    $Path = Join-Path $AgyRoot $Name
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      [ordered]@{ name = $Name; exists = $true; size_bytes = [long](Get-Item -LiteralPath $Path).Length; sha256 = Get-Sha256 -Path $Path }
    }
    else { [ordered]@{ name = $Name; exists = $false; size_bytes = 0; sha256 = $null } }
  }
  return (ConvertTo-Json -InputObject @($Records) -Depth 10 -Compress)
}

function Invoke-RejectedPacket {
  param(
    [Parameter(Mandatory = $true)][object]$Packet,
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string]$ExpectedErrorPattern,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
  )
  $ReceiptPath = Join-Path $ProjectRoot '.agy\ACTION_PACKET_RECEIPT.json'
  $ActiveManifestPath = Join-Path $ProjectRoot '.agy\inbox\ACTIVE_ACTION_PACKET\MANIFEST.json'
  $ReceiptBefore = Get-Sha256 -Path $ReceiptPath
  $ActiveBefore = Get-Sha256 -Path $ActiveManifestPath
  $ExternalPath = Join-Path $ExternalInbox $FileName
  Write-JsonFile -Path $ExternalPath -Value $Packet
  $null = Invoke-BridgeScan -ExpectedExitCode 1
  Assert-True -Condition ((Get-Sha256 -Path $ReceiptPath) -ceq $ReceiptBefore) -Message "Rejected packet changed the project receipt: $FileName"
  Assert-True -Condition ((Get-Sha256 -Path $ActiveManifestPath) -ceq $ActiveBefore) -Message "Rejected packet changed the active packet: $FileName"
  $ErrorPath = Join-Path (Join-Path $StateRoot 'failed') ($FileName + '.error.txt')
  Assert-True -Condition (Test-Path -LiteralPath $ErrorPath -PathType Leaf) -Message "Rejected packet error evidence is missing: $FileName"
  $ErrorText = Get-Content -LiteralPath $ErrorPath -Raw -Encoding UTF8
  Assert-True -Condition ($ErrorText -match $ExpectedErrorPattern) -Message "Rejected packet reason mismatch: $FileName"
  Assert-SecretAbsentFromText -Text $ErrorText -Label "rejection error $FileName"
}

function Assert-CapabilityContainment {
  param([Parameter(Mandatory = $true)][string[]]$AllowedPaths)
  $Allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($Path in $AllowedPaths) { [void]$Allowed.Add([IO.Path]::GetFullPath($Path)) }
  foreach ($ScanRoot in @($ExternalInbox, $StateRoot, (Join-Path $Project '.agy'), (Join-Path $RollbackProject '.agy'))) {
    if (-not (Test-Path -LiteralPath $ScanRoot -PathType Container)) { continue }
    foreach ($File in Get-ChildItem -LiteralPath $ScanRoot -File -Recurse -Force) {
      if ($Allowed.Contains([IO.Path]::GetFullPath($File.FullName))) { continue }
      $Text = [IO.File]::ReadAllText($File.FullName, [Text.Encoding]::UTF8)
      Assert-True -Condition (-not $Text.Contains($CapabilityToken)) -Message "Capability escaped its local allowlist: $($File.FullName)"
    }
  }
}

$AuditedSourceInputs = @(
  $Bridge,
  $TemplateRoot,
  (Join-Path $Root 'scripts\windows\companion\Activate-ActionPacket.ps1'),
  (Join-Path $Root 'scripts\windows\companion\Start-WorkItemTransaction.ps1'),
  $PSCommandPath
)
$CheckoutBefore = Get-CheckoutSnapshot -CheckoutRoot $Root -InputPaths $AuditedSourceInputs
$PathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$PathSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($PathSeparators) + [IO.Path]::DirectorySeparatorChar
$TempRoot = [IO.Path]::GetFullPath((Join-Path $TempBase ('action-bridge-e2e-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TempRoot.StartsWith($TempBase, $PathComparison)) { throw 'Unsafe Action Bridge temporary root.' }

$Project = Join-Path $TempRoot 'Проект Action Bridge'
$RollbackProject = Join-Path $TempRoot 'Проект Rollback'
$ExternalInbox = Join-Path $TempRoot 'external-inbox'
$StateRoot = Join-Path $TempRoot 'bridge-state'
$RegistryPath = Join-Path $TempRoot 'project-registry.json'
$ProjectId = 'bridge-e2e-main'
$RollbackProjectId = 'bridge-e2e-rollback'
$CapabilityBytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Fill($CapabilityBytes)
$CapabilityToken = ([Convert]::ToHexString($CapabilityBytes)).ToLowerInvariant()
$Completed = $false

try {
  New-Item -ItemType Directory -Force -Path $ExternalInbox | Out-Null
  Initialize-HermeticProject -ProjectRoot $Project -ProjectId $ProjectId -CapabilityToken $CapabilityToken
  Initialize-HermeticProject -ProjectRoot $RollbackProject -ProjectId $RollbackProjectId -CapabilityToken $CapabilityToken
  Write-JsonFile -Path $RegistryPath -Value ([ordered]@{
    schema_version = $ActionPacketSchemaVersion
    ecosystem_version = $EcosystemVersion
    projects = @(
      [ordered]@{ project_id = $ProjectId; project_root = $Project; logical_name = 'Hermetic main'; ecosystem_version = $EcosystemVersion; capability_token = $CapabilityToken },
      [ordered]@{ project_id = $RollbackProjectId; project_root = $RollbackProject; logical_name = 'Hermetic rollback'; ecosystem_version = $EcosystemVersion; capability_token = $CapabilityToken }
    )
  })

  $NewPacketId = 'new-' + [Guid]::NewGuid().ToString('N')
  $NewPacket = New-ExternalPacket -PacketId $NewPacketId -ProjectId $ProjectId
  Assert-True -Condition (-not $NewPacket.Contains('work_item_id') -and -not $NewPacket.Contains('goal_epoch')) -Message 'new_work_item fixture unexpectedly contains optional identity.'
  Assert-True -Condition (-not $NewPacket.Contains('capability_token')) -Message 'External new_work_item contains a capability.'
  $NewExternalName = "AGENTIC_ACTION_PACKET_$NewPacketId.json"
  Write-JsonFile -Path (Join-Path $ExternalInbox $NewExternalName) -Value $NewPacket
  $null = Invoke-BridgeScan -ExpectedExitCode 0

  $ReceiptPath = Join-Path $Project '.agy\ACTION_PACKET_RECEIPT.json'
  $Receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True -Condition ([string]$Receipt.status -eq 'imported' -and [string]$Receipt.packet_id -eq $NewPacketId) -Message 'Token-free new_work_item was not imported.'
  $ProcessedNew = Join-Path (Join-Path $StateRoot 'processed') $NewExternalName
  Assert-True -Condition (Test-Path -LiteralPath $ProcessedNew -PathType Leaf) -Message 'Processed external new_work_item is missing.'
  Assert-SecretAbsentFromText -Text (Get-Content -LiteralPath $ProcessedNew -Raw -Encoding UTF8) -Label 'processed external packet'

  $ActiveRoot = Join-Path $Project '.agy\inbox\ACTIVE_ACTION_PACKET'
  $InternalPacket = Get-Content -LiteralPath (Join-Path $ActiveRoot 'ACTION_PACKET.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $TaskBytesText = [IO.File]::ReadAllText((Join-Path $ActiveRoot 'AGENT_TASK.md'), [Text.Encoding]::UTF8)
  Assert-True -Condition ([string]$InternalPacket.capability_token -ceq $CapabilityToken) -Message 'Local capability was not injected into the internal packet.'
  Assert-True -Condition ([string]$InternalPacket.technical_task_markdown -ceq $TaskBytesText) -Message 'Internal task bytes and packet text disagree.'
  Assert-True -Condition (-not $TaskBytesText.Contains("`r")) -Message 'Internal task materialization is not deterministic LF.'

  $HookOutput = Invoke-Hook -ProjectRoot $Project
  $HookOutputJson = ConvertTo-Json -InputObject $HookOutput -Depth 20 -Compress
  Assert-True -Condition (@($HookOutput.injectSteps).Count -eq 1) -Message "new_work_item hook injection did not occur exactly once: $HookOutputJson"
  $Receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True -Condition ([string]$Receipt.status -eq 'injected') -Message 'new_work_item receipt did not reach injected.'
  $WorkItem = Get-Content -LiteralPath (Join-Path $Project '.agy\WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True -Condition ([string]$WorkItem.work_item_id -match '^wi-[0-9a-f]{32}$' -and [int]$WorkItem.goal_epoch -eq 1) -Message 'new_work_item optional identity was not generated safely.'
  $SecondHookOutput = Invoke-Hook -ProjectRoot $Project
  Assert-True -Condition (@($SecondHookOutput.injectSteps).Count -eq 0) -Message 'new_work_item was injected more than once.'

  $ContinuePacketId = 'continue-' + [Guid]::NewGuid().ToString('N')
  $ContinuePacket = New-ExternalPacket -PacketId $ContinuePacketId -ProjectId $ProjectId -Operation 'continue_work_item' -Route '/fixcritical' -Goal ([string]$WorkItem.goal) -WorkItemId ([string]$WorkItem.work_item_id) -GoalEpoch ([int]$WorkItem.goal_epoch)
  $ContinueExternalName = "AGENTIC_ACTION_PACKET_$ContinuePacketId.json"
  Write-JsonFile -Path (Join-Path $ExternalInbox $ContinueExternalName) -Value $ContinuePacket
  $null = Invoke-BridgeScan -ExpectedExitCode 0
  $ContinueHookOutput = Invoke-Hook -ProjectRoot $Project
  Assert-True -Condition (@($ContinueHookOutput.injectSteps).Count -eq 1) -Message 'Exact-identity continuation was not injected.'
  $Receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True -Condition ([string]$Receipt.status -eq 'injected' -and [string]$Receipt.packet_id -eq $ContinuePacketId) -Message 'Continuation receipt identity/status mismatch.'
  $NextAction = Get-Content -LiteralPath (Join-Path $Project '.agy\NEXT_ACTION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True -Condition ([string]$NextAction.work_item_id -eq [string]$WorkItem.work_item_id -and [string]$NextAction.route -eq '/fixcritical') -Message 'Continuation did not preserve exact work-item identity and route.'
  $ContinueSecondHook = Invoke-Hook -ProjectRoot $Project
  Assert-True -Condition (@($ContinueSecondHook.injectSteps).Count -eq 0) -Message 'Continuation was injected more than once.'

  $ProcessedContinue = Join-Path (Join-Path $StateRoot 'processed') $ContinueExternalName
  Copy-Item -LiteralPath $ProcessedContinue -Destination (Join-Path $ExternalInbox $ContinueExternalName)
  $ReceiptBeforeReplay = Get-Sha256 -Path $ReceiptPath
  $null = Invoke-BridgeScan -ExpectedExitCode 1
  $ReplayErrorPath = Join-Path (Join-Path $StateRoot 'failed') ($ContinueExternalName + '.error.txt')
  Assert-True -Condition ((Get-Content -LiteralPath $ReplayErrorPath -Raw -Encoding UTF8) -match 'replay rejected') -Message 'Replay rejection evidence is missing.'
  Assert-True -Condition ((Get-Sha256 -Path $ReceiptPath) -ceq $ReceiptBeforeReplay) -Message 'Replay rejection changed the project receipt.'
  $null = Invoke-BridgeScan -ExpectedExitCode 0

  $Now = (Get-Date).ToUniversalTime()
  $ExpiredId = 'expired-' + [Guid]::NewGuid().ToString('N')
  Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $ExpiredId -ProjectId $ProjectId -CreatedAt $Now.AddHours(-2) -ExpiresAt $Now.AddHours(-1)) -FileName "AGENTIC_ACTION_PACKET_$ExpiredId.json" -ExpectedErrorPattern 'expired|time window' -ProjectRoot $Project

  $WrongProjectId = 'wrong-project-' + [Guid]::NewGuid().ToString('N')
  Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $WrongProjectId -ProjectId 'not-registered') -FileName "AGENTIC_ACTION_PACKET_$WrongProjectId.json" -ExpectedErrorPattern 'Unknown project_id' -ProjectRoot $Project

  $WrongSchemaId = 'wrong-schema-' + [Guid]::NewGuid().ToString('N')
  Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $WrongSchemaId -ProjectId $ProjectId -SchemaVersion '0.0.0') -FileName "AGENTIC_ACTION_PACKET_$WrongSchemaId.json" -ExpectedErrorPattern 'Unsupported ecosystem' -ProjectRoot $Project

  $UnsafeId = '../unsafe-packet'
  Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $UnsafeId -ProjectId $ProjectId) -FileName 'AGENTIC_ACTION_PACKET_unsafe-id.json' -ExpectedErrorPattern 'Packet ID is empty or unsafe' -ProjectRoot $Project

  $WrongIdentityId = 'wrong-identity-' + [Guid]::NewGuid().ToString('N')
  Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $WrongIdentityId -ProjectId $ProjectId -Operation 'continue_work_item' -Goal ([string]$WorkItem.goal) -WorkItemId 'wi-not-current' -GoalEpoch ([int]$WorkItem.goal_epoch)) -FileName "AGENTIC_ACTION_PACKET_$WrongIdentityId.json" -ExpectedErrorPattern 'identity is stale' -ProjectRoot $Project

  $ManifestPath = Join-Path $Project '.agy\INSTALLATION_MANIFEST.json'
  $ManifestOriginal = [IO.File]::ReadAllBytes($ManifestPath)
  try {
    Write-JsonFile -Path $ManifestPath -Value ([ordered]@{ schema_version = '1.0.0'; ecosystem_version = '0.0.0'; package_version = '0.0.0'; runtime_version = '0.0.0'; version = '0.0.0' })
    $StaleRuntimeId = 'stale-runtime-' + [Guid]::NewGuid().ToString('N')
    Invoke-RejectedPacket -Packet (New-ExternalPacket -PacketId $StaleRuntimeId -ProjectId $ProjectId) -FileName "AGENTIC_ACTION_PACKET_$StaleRuntimeId.json" -ExpectedErrorPattern 'runtime version is stale' -ProjectRoot $Project
  }
  finally {
    [IO.File]::WriteAllBytes($ManifestPath, $ManifestOriginal)
  }

  $RollbackPacketId = 'rollback-' + [Guid]::NewGuid().ToString('N')
  $RollbackPacket = New-ExternalPacket -PacketId $RollbackPacketId -ProjectId $RollbackProjectId
  $RollbackExternalName = "AGENTIC_ACTION_PACKET_$RollbackPacketId.json"
  Write-JsonFile -Path (Join-Path $ExternalInbox $RollbackExternalName) -Value $RollbackPacket
  $null = Invoke-BridgeScan -ExpectedExitCode 0
  $RollbackAgy = Join-Path $RollbackProject '.agy'
  $RollbackReceiptPath = Join-Path $RollbackAgy 'ACTION_PACKET_RECEIPT.json'
  $RollbackReceiptBefore = Get-Sha256 -Path $RollbackReceiptPath
  $RollbackControlBefore = Get-ControlFileState -ProjectRoot $RollbackProject
  $RollbackResultPath = Join-Path $RollbackAgy 'ACTION_PACKET_ACTIVATION_RESULT.json'
  Assert-True -Condition (-not (Test-Path -LiteralPath $RollbackResultPath)) -Message 'Rollback fixture unexpectedly has a pre-existing activation result.'
  $FaultResult = Invoke-CapturedProcess -FilePath $Pwsh -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $RollbackProject 'scripts\windows\companion\Activate-ActionPacket.ps1'),
    '-ProjectRoot', $RollbackProject,
    '-PacketDirectory', (Join-Path $RollbackAgy 'inbox\ACTIVE_ACTION_PACKET'),
    '-Apply', '-FaultInjectionAfterPublishes', '2'
  ) -WorkingDirectory $RollbackProject
  Assert-True -Condition ($FaultResult.exit_code -ne 0) -Message 'Activation fault injection unexpectedly succeeded.'
  Assert-True -Condition (($FaultResult.stdout + $FaultResult.stderr) -match 'SIMULATED_WORK_ITEM_TRANSACTION_FAILURE_AFTER_2') -Message 'Activation fault marker was not observed.'
  Assert-SecretAbsentFromText -Text $FaultResult.stdout -Label 'fault-injection stdout'
  Assert-SecretAbsentFromText -Text $FaultResult.stderr -Label 'fault-injection stderr'
  Assert-True -Condition ((Get-ControlFileState -ProjectRoot $RollbackProject) -ceq $RollbackControlBefore) -Message 'Five-file work-item activation did not roll back exactly.'
  Assert-True -Condition ((Get-Sha256 -Path $RollbackReceiptPath) -ceq $RollbackReceiptBefore) -Message 'Failed activation changed the imported receipt.'
  Assert-True -Condition (-not (Test-Path -LiteralPath $RollbackResultPath)) -Message 'Failed activation left a partial activation result.'
  Assert-True -Condition (@(Get-ChildItem -LiteralPath $RollbackAgy -Directory -Filter '.transaction-*' -Force).Count -eq 0) -Message 'Failed activation left a transaction staging directory.'

  Assert-CapabilityContainment -AllowedPaths @(
    $RegistryPath,
    (Join-Path $Project '.agy\ACTION_BRIDGE_CAPABILITY.json'),
    (Join-Path $Project '.agy\inbox\ACTIVE_ACTION_PACKET\ACTION_PACKET.json'),
    (Join-Path $RollbackProject '.agy\ACTION_BRIDGE_CAPABILITY.json'),
    (Join-Path $RollbackProject '.agy\inbox\ACTIVE_ACTION_PACKET\ACTION_PACKET.json')
  )

  $CheckoutAfter = Get-CheckoutSnapshot -CheckoutRoot $Root -InputPaths $AuditedSourceInputs
  Assert-True -Condition ($CheckoutAfter -ceq $CheckoutBefore) -Message 'Action Bridge acceptance changed the source checkout.'
  $Completed = $true
  Write-Host "Action Bridge end-to-end acceptance passed. Assertions=$Assertions; live_writes=0; source_checkout_changed=false"
}
finally {
  if ($PreserveFailedFixture -and -not $Completed) {
    Write-Warning "Preserved failed Action Bridge fixture: $TempRoot"
  }
  elseif (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $ResolvedTemp = (Resolve-Path -LiteralPath $TempRoot).Path
    if (-not $ResolvedTemp.StartsWith($TempBase, $PathComparison)) { throw 'Unsafe Action Bridge test cleanup target.' }
    Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
  }
}
