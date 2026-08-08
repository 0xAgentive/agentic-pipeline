[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [switch]$PreserveFailedFixture
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$Utf8 = [Text.UTF8Encoding]::new($false)
$Assertions = 0
$Completed = $false

function Assert-True {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

function Write-Utf8Text {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Write-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
  Write-Utf8Text -Path $Path -Text ($Value | ConvertTo-Json -Depth 30)
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileState {
  param([Parameter(Mandatory = $true)][string[]]$Paths)
  $Records = foreach ($Path in $Paths) {
    $Item = Get-Item -LiteralPath $Path
    '{0}|{1}|{2}|{3}' -f $Path, [long]$Item.Length, (Get-Sha256 -Path $Path), $Item.LastWriteTimeUtc.Ticks
  }
  return $Records -join "`n"
}

function Get-TreeContentSnapshot {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return '<absent>' }
  $Records = [Collections.Generic.List[string]]::new()
  foreach ($Directory in Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force | Sort-Object FullName) {
    [void]$Records.Add(('D|{0}' -f [IO.Path]::GetRelativePath($Path, $Directory.FullName).Replace('\', '/')))
  }
  foreach ($File in Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName) {
    $Relative = [IO.Path]::GetRelativePath($Path, $File.FullName).Replace('\', '/')
    [void]$Records.Add(('F|{0}|{1}|{2}' -f $Relative, [long]$File.Length, (Get-Sha256 -Path $File.FullName)))
  }
  return $Records -join "`n"
}

function Get-BackupArtifactCount {
  param([Parameter(Mandatory = $true)][string]$Path)
  return @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '(?i)(backup|\.bak$|\.tmp$|^\.transaction-)'
  }).Count
}

function Initialize-ProjectFixture {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Force -Path (Join-Path $Path '.agy'), (Join-Path $Path '.agents') | Out-Null
  Write-JsonFile -Path (Join-Path $Path '.agy\INSTALLATION_MANIFEST.json') -Value ([ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = '1.2.10'
    package_version = '1.2.10'
    runtime_version = '1.2.10'
  })
}

function New-InstallerInvocationFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Arguments
  )
  Write-JsonFile -Path $Path -Value $Arguments
}

function Invoke-HermeticInstaller {
  param(
    [Parameter(Mandatory = $true)][string]$InvocationFile,
    [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
    [string]$Installer = ''
  )
  if ([string]::IsNullOrWhiteSpace($Installer)) { $Installer = $script:InstallerPath }
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $HostExe
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = $Utf8
  $StartInfo.StandardErrorEncoding = $Utf8
  foreach ($Argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HarnessPath, '-Installer', $Installer, '-InvocationFile', $InvocationFile)) {
    [void]$StartInfo.ArgumentList.Add($Argument)
  }
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw 'Unable to start hermetic Action Bridge installer process.' }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(30000)) {
      $Process.Kill($true)
      throw 'Hermetic Action Bridge installer timed out.'
    }
    $Process.WaitForExit()
    $Result = [pscustomobject]@{ exit_code = $Process.ExitCode; stdout = $StdoutTask.GetAwaiter().GetResult(); stderr = $StderrTask.GetAwaiter().GetResult() }
  }
  finally { $Process.Dispose() }
  Assert-True -Condition ($Result.exit_code -eq $ExpectedExitCode) -Message "Installer exit code $($Result.exit_code), expected $ExpectedExitCode. stderr=$($Result.stderr)"
  return $Result
}

$InstallerSource = Join-Path $Root 'scripts\bridge\Install-CompanionActionBridge.ps1'
$BridgeSource = Join-Path $Root 'scripts\bridge\companion_action_bridge.py'
foreach ($Required in @($InstallerSource, $BridgeSource)) {
  if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required installer test input is missing: $Required" }
}
$SourceBefore = @($InstallerSource, $BridgeSource) | ForEach-Object { "$_|$(Get-Sha256 -Path $_)" }
$TempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TempRoot = [IO.Path]::GetFullPath((Join-Path $TempPrefix ('action-bridge-installer-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TempRoot.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Action Bridge installer fixture path.' }
$PackageRoot = Join-Path $TempRoot 'package'
$PackageArchivePath = Join-Path $TempRoot 'agentic-action-bridge-1.2.10.zip'
$HarnessPath = Join-Path $TempRoot 'Invoke-HermeticInstaller.ps1'
$InstallerPath = Join-Path $PackageRoot 'Install-CompanionActionBridge.ps1'
$Commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$AssetSha = ''

try {
  New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
  Copy-Item -LiteralPath $InstallerSource -Destination $InstallerPath
  Copy-Item -LiteralPath $BridgeSource -Destination (Join-Path $PackageRoot 'companion_action_bridge.py')
  Write-JsonFile -Path (Join-Path $PackageRoot 'VERSION.json') -Value ([ordered]@{
    schema_version = '1.0.0'; ecosystem_version = '1.2.10'; component = 'action_bridge'; version = '1.2.10'; source_commit = $Commit
  })
  $PackageFiles = foreach ($File in Get-ChildItem -LiteralPath $PackageRoot -File | Sort-Object Name) {
    [ordered]@{ path = $File.Name; size_bytes = [long]$File.Length; sha256 = Get-Sha256 -Path $File.FullName }
  }
  Write-JsonFile -Path (Join-Path $PackageRoot 'MANIFEST.json') -Value ([ordered]@{
    schema_version = '1.0.0'; ecosystem_version = '1.2.10'; component = 'action_bridge'; source_commit = $Commit; files = @($PackageFiles)
  })
  [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $PackageArchivePath, [IO.Compression.CompressionLevel]::Optimal, $true)
  $AssetSha = Get-Sha256 -Path $PackageArchivePath
  Write-Utf8Text -Path $HarnessPath -Text @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Installer, [Parameter(Mandatory = $true)][string]$InvocationFile)
$ErrorActionPreference = 'Stop'
function Get-ScheduledTask { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function Export-ScheduledTask { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function Register-ScheduledTask { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function Unregister-ScheduledTask { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function New-ScheduledTaskAction { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function New-ScheduledTaskTrigger { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
function New-ScheduledTaskSettingsSet { throw 'REAL_SCHEDULED_TASK_API_FORBIDDEN' }
$Arguments = Get-Content -LiteralPath $InvocationFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
& $Installer @Arguments
'@

  $InstallerSourceText = Get-Content -LiteralPath $InstallerSource -Raw -Encoding UTF8
  Assert-True -Condition ($InstallerSourceText -match '\$TaskMutationStarted\s*=\s*\$true\s*\r?\n\s*Register-ScheduledTask') -Message 'Scheduled-task mutation guard is not armed immediately before registration.'
  Assert-True -Condition ($InstallerSourceText -match '\$TaskBackend\s*-eq\s*''Windows''\s*-and\s*\$TaskMutationStarted') -Message 'Scheduled-task rollback is not guarded by TaskMutationStarted.'

  $SuccessRoot = Join-Path $TempRoot 'success'
  $SuccessProject = Join-Path $SuccessRoot 'project'
  $SuccessInstall = Join-Path $SuccessRoot 'install'
  $SuccessRegistry = Join-Path $SuccessRoot 'registry\projects.json'
  $SuccessDescriptor = Join-Path $SuccessRoot 'task\definition.json'
  Initialize-ProjectFixture -Path $SuccessProject
  $UnrelatedToken = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  Write-JsonFile -Path $SuccessRegistry -Value ([ordered]@{
    schema_version = 'legacy'
    ecosystem_version = 'legacy'
    owner_note = 'preserve this top-level property'
    registry_extension = [ordered]@{ enabled = $true; threshold = 7 }
    projects = @([ordered]@{
      project_id = 'unrelated-project'; project_root = 'C:\unrelated'; logical_name = 'Unrelated'; ecosystem_version = '0.9.0'; capability_token = $UnrelatedToken; extension = [ordered]@{ preserve = 'yes' }
    })
  })
  $CommonArguments = [ordered]@{
    InstallRoot = $SuccessInstall
    RegistryPath = $SuccessRegistry
    ProjectRoot = $SuccessProject
    ProjectId = 'hermetic-project'
    LogicalName = 'Hermetic project'
    ExpectedSourceCommit = $Commit
    AssetSha256 = $AssetSha
    PackageArchivePath = $PackageArchivePath
    TaskName = 'HermeticActionBridgeTask'
    InboxPath = (Join-Path $SuccessRoot 'inbox')
    StateRoot = (Join-Path $SuccessRoot 'state')
    Apply = $true
    TaskBackend = 'Descriptor'
    TaskDescriptorPath = $SuccessDescriptor
    HermeticTestMode = $true
  }
  $InvocationOne = Join-Path $SuccessRoot 'invoke-one.json'
  New-InstallerInvocationFile -Path $InvocationOne -Arguments $CommonArguments

  $TamperedPackageRoot = Join-Path $TempRoot 'tampered-package'
  Copy-Item -LiteralPath $PackageRoot -Destination $TamperedPackageRoot -Recurse
  $TamperedBridgePath = Join-Path $TamperedPackageRoot 'companion_action_bridge.py'
  Write-Utf8Text -Path $TamperedBridgePath -Text ((Get-Content -LiteralPath $TamperedBridgePath -Raw -Encoding UTF8) + "`n# jointly tampered extracted payload`n")
  $TamperedManifestPath = Join-Path $TamperedPackageRoot 'MANIFEST.json'
  $TamperedManifest = Get-Content -LiteralPath $TamperedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $TamperedMember = @($TamperedManifest.files | Where-Object { [string]$_.path -eq 'companion_action_bridge.py' }) | Select-Object -First 1
  $TamperedMember.sha256 = Get-Sha256 -Path $TamperedBridgePath
  $TamperedMember.size_bytes = [long](Get-Item -LiteralPath $TamperedBridgePath).Length
  Write-JsonFile -Path $TamperedManifestPath -Value $TamperedManifest
  $TamperInvocation = Join-Path $TempRoot 'tamper-invocation.json'
  New-InstallerInvocationFile -Path $TamperInvocation -Arguments $CommonArguments
  $SuccessBeforeTamper = Get-TreeContentSnapshot -Path $SuccessRoot
  $TamperResult = Invoke-HermeticInstaller -InvocationFile $TamperInvocation -ExpectedExitCode 1 -Installer (Join-Path $TamperedPackageRoot 'Install-CompanionActionBridge.ps1')
  Assert-True -Condition (($TamperResult.stdout + $TamperResult.stderr) -match 'manifest does not match the exact verified archive') -Message 'Jointly tampered extracted manifest and member were not rejected by archive binding.'
  Assert-True -Condition ((Get-TreeContentSnapshot -Path $SuccessRoot) -ceq $SuccessBeforeTamper) -Message 'Archive-binding rejection changed the target fixture.'

  $UnboundArguments = [ordered]@{}
  foreach ($Key in $CommonArguments.Keys) { if ($Key -ne 'PackageArchivePath') { $UnboundArguments[$Key] = $CommonArguments[$Key] } }
  $UnboundInvocation = Join-Path $TempRoot 'unbound-invocation.json'
  New-InstallerInvocationFile -Path $UnboundInvocation -Arguments $UnboundArguments
  $UnboundResult = Invoke-HermeticInstaller -InvocationFile $UnboundInvocation -ExpectedExitCode 1
  Assert-True -Condition (($UnboundResult.stdout + $UnboundResult.stderr) -match 'PackageArchivePath is required') -Message 'Apply without an originating archive did not fail closed.'
  Assert-True -Condition ((Get-TreeContentSnapshot -Path $SuccessRoot) -ceq $SuccessBeforeTamper) -Message 'Missing-archive rejection changed the target fixture.'

  $ExtraFileArchive = Join-Path $TempRoot 'agentic-action-bridge-extra-file.zip'
  Copy-Item -LiteralPath $PackageArchivePath -Destination $ExtraFileArchive
  $WritableArchive = [IO.Compression.ZipFile]::Open($ExtraFileArchive, [IO.Compression.ZipArchiveMode]::Update)
  try {
    $ExtraEntry = $WritableArchive.CreateEntry('outside-package.txt')
    $ExtraStream = $ExtraEntry.Open()
    try {
      $ExtraBytes = $Utf8.GetBytes('unmanifested archive payload')
      $ExtraStream.Write($ExtraBytes, 0, $ExtraBytes.Length)
    }
    finally { $ExtraStream.Dispose() }
  }
  finally { $WritableArchive.Dispose() }
  $ExtraFileArguments = [ordered]@{}
  foreach ($Key in $CommonArguments.Keys) { $ExtraFileArguments[$Key] = $CommonArguments[$Key] }
  $ExtraFileArguments['PackageArchivePath'] = $ExtraFileArchive
  $ExtraFileArguments['AssetSha256'] = Get-Sha256 -Path $ExtraFileArchive
  $ExtraFileInvocation = Join-Path $TempRoot 'extra-file-invocation.json'
  New-InstallerInvocationFile -Path $ExtraFileInvocation -Arguments $ExtraFileArguments
  $ExtraFileResult = Invoke-HermeticInstaller -InvocationFile $ExtraFileInvocation -ExpectedExitCode 1
  Assert-True -Condition (($ExtraFileResult.stdout + $ExtraFileResult.stderr) -match 'outside its exact manifest-bound package set') -Message 'Unmanifested file outside the prefixed package root was not rejected.'
  Assert-True -Condition ((Get-TreeContentSnapshot -Path $SuccessRoot) -ceq $SuccessBeforeTamper) -Message 'Extra-archive-file rejection changed the target fixture.'

  $FirstResult = Invoke-HermeticInstaller -InvocationFile $InvocationOne -ExpectedExitCode 0
  Assert-True -Condition (-not (($FirstResult.stdout + $FirstResult.stderr) -match 'REAL_SCHEDULED_TASK_API_FORBIDDEN')) -Message 'Installer attempted to call a real Scheduled Task API.'

  $CapabilityPath = Join-Path $SuccessProject '.agy\ACTION_BRIDGE_CAPABILITY.json'
  $ReceiptPath = Join-Path $SuccessInstall 'INSTALLATION_RECEIPT.json'
  $InstalledCodePath = Join-Path $SuccessInstall 'companion_action_bridge.py'
  $OutputPaths = @($InstalledCodePath, $SuccessRegistry, $CapabilityPath, $ReceiptPath, $SuccessDescriptor)
  foreach ($Path in $OutputPaths) { Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "Installer output is missing: $Path" }
  Assert-True -Condition ((Get-Sha256 -Path $InstalledCodePath) -ceq (Get-Sha256 -Path $BridgeSource)) -Message 'Installed bridge code does not match the immutable package source.'

  $Registry = Get-Content -LiteralPath $SuccessRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
  $Unrelated = @($Registry.projects | Where-Object { [string]$_.project_id -eq 'unrelated-project' }) | Select-Object -First 1
  Assert-True -Condition ($null -ne $Unrelated -and [string]$Unrelated.capability_token -ceq $UnrelatedToken -and [string]$Unrelated.extension.preserve -ceq 'yes') -Message 'Installer did not preserve the unrelated registry entry.'
  Assert-True -Condition ([string]$Registry.owner_note -ceq 'preserve this top-level property' -and [int]$Registry.registry_extension.threshold -eq 7) -Message 'Installer did not preserve unrelated registry metadata.'
  $Capability = Get-Content -LiteralPath $CapabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Registration = @($Registry.projects | Where-Object { [string]$_.project_id -eq 'hermetic-project' }) | Select-Object -First 1
  Assert-True -Condition ([string]$Capability.capability_token -match '^[0-9a-f]{64}$' -and [string]$Capability.capability_token -ceq [string]$Registration.capability_token) -Message 'Local capability and registry registration disagree.'
  $Descriptor = Get-Content -LiteralPath $SuccessDescriptor -Raw -Encoding UTF8 | ConvertFrom-Json
  $ExecutableLeaf = (Split-Path -Leaf ([string]$Descriptor.execute)).ToLowerInvariant()
  Assert-True -Condition ([bool]$Descriptor.hidden -and $ExecutableLeaf -in @('pythonw.exe', 'wscript.exe')) -Message 'Task descriptor is not configured for hidden pythonw/wscript execution.'
  $ReceiptText = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8
  $DescriptorText = Get-Content -LiteralPath $SuccessDescriptor -Raw -Encoding UTF8
  Assert-True -Condition (-not $ReceiptText.Contains([string]$Capability.capability_token) -and -not $DescriptorText.Contains([string]$Capability.capability_token)) -Message 'Capability escaped into receipt or task definition.'

  $StateBeforeSecondApply = Get-FileState -Paths $OutputPaths
  $BackupCountBeforeSecondApply = Get-BackupArtifactCount -Path $SuccessRoot
  Start-Sleep -Milliseconds 1200
  $SecondResult = Invoke-HermeticInstaller -InvocationFile $InvocationOne -ExpectedExitCode 0
  $StateAfterSecondApply = Get-FileState -Paths $OutputPaths
  $BackupCountAfterSecondApply = Get-BackupArtifactCount -Path $SuccessRoot
  Assert-True -Condition ($StateAfterSecondApply -ceq $StateBeforeSecondApply) -Message 'Second identical apply rewrote a managed file or task descriptor.'
  Assert-True -Condition ($BackupCountAfterSecondApply -eq $BackupCountBeforeSecondApply) -Message 'Second identical apply changed the backup artifact count.'
  Assert-True -Condition ($SecondResult.stdout -match 'task_changed=false') -Message 'Second identical apply did not report an unchanged task definition.'

  [IO.File]::WriteAllText($InstalledCodePath, "preexisting-corrupt-code`n", $Utf8)
  $CorruptBaseline = Get-TreeContentSnapshot -Path $SuccessRoot
  $FaultArguments = [ordered]@{}
  foreach ($Key in $CommonArguments.Keys) { $FaultArguments[$Key] = $CommonArguments[$Key] }
  $FaultArguments['LogicalName'] = 'Changed only inside failed transaction'
  $FaultArguments['TaskName'] = 'HermeticChangedTask'
  $FaultArguments['FaultInjectionStep'] = 'AfterReceipt'
  $FaultInvocation = Join-Path $SuccessRoot 'invoke-fault.json'
  New-InstallerInvocationFile -Path $FaultInvocation -Arguments $FaultArguments
  $CorruptBaseline = Get-TreeContentSnapshot -Path $SuccessRoot
  $FaultResult = Invoke-HermeticInstaller -InvocationFile $FaultInvocation -ExpectedExitCode 1
  Assert-True -Condition (($FaultResult.stdout + $FaultResult.stderr) -match 'SIMULATED_ACTION_BRIDGE_INSTALL_FAILURE_AfterReceipt') -Message 'Expected installer fault marker was not observed.'
  Assert-True -Condition ((Get-TreeContentSnapshot -Path $SuccessRoot) -ceq $CorruptBaseline) -Message 'Injected failure did not roll back pre-existing files and task definition byte-for-byte.'
  Assert-True -Condition (-not (($FaultResult.stdout + $FaultResult.stderr) -match 'REAL_SCHEDULED_TASK_API_FORBIDDEN')) -Message 'Fault path attempted to call a real Scheduled Task API.'

  $FreshFailureRoot = Join-Path $TempRoot 'fresh-failure'
  $FreshProject = Join-Path $FreshFailureRoot 'project'
  Initialize-ProjectFixture -Path $FreshProject
  $FreshBaseline = Get-TreeContentSnapshot -Path $FreshFailureRoot
  $FreshArguments = [ordered]@{
    InstallRoot = (Join-Path $FreshFailureRoot 'install')
    RegistryPath = (Join-Path $FreshFailureRoot 'registry\projects.json')
    ProjectRoot = $FreshProject
    ProjectId = 'fresh-failure-project'
    LogicalName = 'Fresh failure'
    ExpectedSourceCommit = $Commit
    AssetSha256 = $AssetSha
    PackageArchivePath = $PackageArchivePath
    TaskName = 'HermeticFreshFailureTask'
    InboxPath = (Join-Path $FreshFailureRoot 'inbox')
    StateRoot = (Join-Path $FreshFailureRoot 'state')
    Apply = $true
    TaskBackend = 'Descriptor'
    TaskDescriptorPath = (Join-Path $FreshFailureRoot 'task\definition.json')
    HermeticTestMode = $true
    FaultInjectionStep = 'AfterReceipt'
  }
  $FreshInvocation = Join-Path $TempRoot 'fresh-failure-invocation.json'
  New-InstallerInvocationFile -Path $FreshInvocation -Arguments $FreshArguments
  $null = Invoke-HermeticInstaller -InvocationFile $FreshInvocation -ExpectedExitCode 1
  Assert-True -Condition ((Get-TreeContentSnapshot -Path $FreshFailureRoot) -ceq $FreshBaseline) -Message 'Fresh failed install left files or directories behind.'

  $SourceAfter = @($InstallerSource, $BridgeSource) | ForEach-Object { "$_|$(Get-Sha256 -Path $_)" }
  Assert-True -Condition (($SourceAfter -join "`n") -ceq ($SourceBefore -join "`n")) -Message 'Installer regression changed the source checkout.'
  $Completed = $true
  Write-Host "Action Bridge installer transaction acceptance passed. Assertions=$Assertions; scheduled_task_api_calls=0; live_writes=0; source_checkout_changed=false"
}
finally {
  if ($PreserveFailedFixture -and -not $Completed) { Write-Warning "Preserved failed installer fixture: $TempRoot" }
  elseif (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $ResolvedTemp = (Resolve-Path -LiteralPath $TempRoot).Path
    if (-not $ResolvedTemp.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Action Bridge installer cleanup target.' }
    Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
  }
}
