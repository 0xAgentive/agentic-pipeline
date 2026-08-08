[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:LOCALAPPDATA\AgenticPipeline\ActionBridge",
  [string]$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json",
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [string]$ProjectId = '',
  [string]$LogicalName = '',
  [string]$ExpectedSourceCommit = '',
  [string]$AssetSha256 = '',
  [string]$PackageArchivePath = '',
  [string]$TaskName = 'AgenticPipelineCompanionActionBridge',
  [string]$InboxPath = "$env:USERPROFILE\Downloads",
  [string]$StateRoot = "$env:USERPROFILE\.agentic-pipeline\action-bridge",
  [switch]$Apply,
  [Parameter(DontShow = $true)][ValidateSet('Windows', 'Descriptor')][string]$TaskBackend = 'Windows',
  [Parameter(DontShow = $true)][string]$TaskDescriptorPath = '',
  [Parameter(DontShow = $true)][switch]$HermeticTestMode,
  [Parameter(DontShow = $true)][string]$FaultInjectionStep = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8 = [Text.UTF8Encoding]::new($false)
$EcosystemVersion = '1.2.12'
$BridgeSchemaVersion = '1.2.9'
$TaskDescriptionBase = 'Imports validated Companion 1.2.12 JSON Action Packets from Downloads into registered Agentic Pipeline projects.'
$CreatedDirectories = [Collections.Generic.List[string]]::new()

function Get-BytesSha256 {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Get-StreamSha256 {
  param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash($Stream))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function ConvertTo-Utf8Bytes {
  param([Parameter(Mandatory = $true)][string]$Text)
  return $Utf8.GetBytes($Text)
}

function Test-FileBytesEqual {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $Item = Get-Item -LiteralPath $Path
  if ([long]$Item.Length -ne [long]$Bytes.Length) { return $false }
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq (Get-BytesSha256 -Bytes $Bytes))
}

function Ensure-TrackedDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  $FullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $FullPath -PathType Container) { return }
  if (Test-Path -LiteralPath $FullPath) { throw "A file blocks required directory: $FullPath" }
  $Missing = [Collections.Generic.List[string]]::new()
  $Cursor = $FullPath
  while (-not (Test-Path -LiteralPath $Cursor -PathType Container)) {
    [void]$Missing.Add($Cursor)
    $Parent = Split-Path -Parent $Cursor
    if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $Cursor) { throw "Unable to resolve a safe parent for: $FullPath" }
    $Cursor = $Parent
  }
  foreach ($Directory in @($Missing.ToArray()) | Sort-Object { $_.Length }) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    [void]$CreatedDirectories.Add($Directory)
  }
}

function Write-FileAtomicallyIfChanged {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )
  if (Test-FileBytesEqual -Path $Path -Bytes $Bytes) { return $false }
  $Parent = Split-Path -Parent $Path
  Ensure-TrackedDirectory -Path $Parent
  if (Test-Path -LiteralPath $Path -PathType Container) { throw "A directory blocks required file: $Path" }
  $TemporaryPath = Join-Path $Parent ('.' + (Split-Path -Leaf $Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllBytes($TemporaryPath, $Bytes)
    [IO.File]::Move($TemporaryPath, $Path, $true)
  }
  finally {
    if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force }
  }
  return $true
}

function New-FileSnapshot {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (Test-Path -LiteralPath $Path -PathType Container) { throw "A directory blocks transactional file target: $Path" }
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $Item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{ path = $Path; existed = $true; bytes = [IO.File]::ReadAllBytes($Path); attributes = $Item.Attributes; last_write_time_utc = $Item.LastWriteTimeUtc }
  }
  return [pscustomobject]@{ path = $Path; existed = $false; bytes = $null; attributes = $null; last_write_time_utc = $null }
}

function Restore-FileSnapshot {
  param([Parameter(Mandatory = $true)][object]$Snapshot)
  if ([bool]$Snapshot.existed) {
    [void](Write-FileAtomicallyIfChanged -Path ([string]$Snapshot.path) -Bytes ([byte[]]$Snapshot.bytes))
    [IO.File]::SetAttributes(([string]$Snapshot.path), [IO.FileAttributes]$Snapshot.attributes)
    [IO.File]::SetLastWriteTimeUtc(([string]$Snapshot.path), [datetime]$Snapshot.last_write_time_utc)
  }
  elseif (Test-Path -LiteralPath ([string]$Snapshot.path) -PathType Leaf) {
    Remove-Item -LiteralPath ([string]$Snapshot.path) -Force
  }
}

function Read-JsonIfValid {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String) }
  catch { return $null }
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $InputObject) { return $null }
  $Property = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $Property) { return $null }
  return $Property.Value
}

function ConvertTo-OrderedObjectWithOverrides {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Overrides
  )
  $Result = [ordered]@{}
  if ($null -ne $InputObject) {
    foreach ($Property in $InputObject.PSObject.Properties) {
      if ($Overrides.Contains($Property.Name)) { $Result[$Property.Name] = $Overrides[$Property.Name] }
      else { $Result[$Property.Name] = $Property.Value }
    }
  }
  foreach ($Key in $Overrides.Keys) {
    if (-not $Result.Contains($Key)) { $Result[$Key] = $Overrides[$Key] }
  }
  return $Result
}

function Quote-WindowsArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value.Contains('"')) { throw 'Action Bridge task arguments cannot contain a double quote.' }
  return '"' + $Value + '"'
}

function Assert-FaultInjection {
  param([Parameter(Mandatory = $true)][string]$Step)
  if ($FaultInjectionStep -eq $Step) { throw "SIMULATED_ACTION_BRIDGE_INSTALL_FAILURE_$Step" }
}

function Get-WindowsTaskSnapshot {
  param([Parameter(Mandatory = $true)][string]$Name)
  $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if ($null -eq $Task) { return [pscustomobject]@{ existed = $false; xml = $null } }
  return [pscustomobject]@{ existed = $true; xml = [string](Export-ScheduledTask -TaskName $Name -ErrorAction Stop) }
}

function Restore-WindowsTaskSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][object]$Snapshot
  )
  if ([bool]$Snapshot.existed) {
    Register-ScheduledTask -TaskName $Name -Xml ([string]$Snapshot.xml) -Force | Out-Null
  }
  else {
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
  }
}

if ($FaultInjectionStep -notin @('', 'AfterInstallCode', 'AfterRegistry', 'AfterCapability', 'AfterTask', 'AfterReceipt')) {
  throw 'Unknown Action Bridge installer fault-injection step.'
}
if (($TaskBackend -eq 'Descriptor' -or -not [string]::IsNullOrWhiteSpace($FaultInjectionStep)) -and -not $HermeticTestMode) {
  throw 'Descriptor task backend and fault injection are available only in explicit hermetic test mode.'
}
if (-not [string]::IsNullOrWhiteSpace($FaultInjectionStep) -and $TaskBackend -ne 'Descriptor') { throw 'Fault injection requires the non-operational descriptor task backend.' }
if ($TaskName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'TaskName must be one safe scheduled-task name.' }

$ResolvedProject = if (Test-Path -LiteralPath $ProjectRoot -PathType Container) { (Resolve-Path -LiteralPath $ProjectRoot).Path } else { throw "Project root is missing: $ProjectRoot" }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$RegistryPath = [IO.Path]::GetFullPath($RegistryPath)
$InboxPath = [IO.Path]::GetFullPath($InboxPath)
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
if ($InstallRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\')) { throw 'InstallRoot cannot be a filesystem root.' }
if (-not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agy') -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agents') -PathType Container)) { throw 'Project is not an installed Agentic Pipeline project.' }

$InstalledManifestPath = Join-Path $ResolvedProject '.agy\INSTALLATION_MANIFEST.json'
if (-not (Test-Path -LiteralPath $InstalledManifestPath -PathType Leaf)) { throw 'Project installation manifest is missing.' }
$InstalledManifest = Get-Content -LiteralPath $InstalledManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$InstalledManifest.package_version -ne $EcosystemVersion -or [string]$InstalledManifest.runtime_version -ne $EcosystemVersion) { throw 'Action Bridge requires an installed project runtime 1.2.12.' }

$Leaf = Split-Path -Leaf $ResolvedProject
if ([string]::IsNullOrWhiteSpace($LogicalName)) { $LogicalName = $Leaf }
if ([string]::IsNullOrWhiteSpace($ProjectId)) {
  $ProjectId = ($Leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'ProjectId cannot be derived. Supply -ProjectId explicitly.' }
}
if ($ProjectId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $ProjectId -in @('.', '..')) { throw 'ProjectId must be one safe identifier component.' }

$Source = Join-Path $PSScriptRoot 'companion_action_bridge.py'
$PackageVersionPath = Join-Path $PSScriptRoot 'VERSION.json'
$PackageManifestPath = Join-Path $PSScriptRoot 'MANIFEST.json'
foreach ($RequiredPackageFile in @($Source, $PackageVersionPath, $PackageManifestPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPackageFile -PathType Leaf)) { throw "Action Bridge package file is missing: $RequiredPackageFile" }
}
$PackageVersion = Get-Content -LiteralPath $PackageVersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$PackageManifest = Get-Content -LiteralPath $PackageManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$PackageVersion.ecosystem_version -ne $EcosystemVersion -or [string]$PackageVersion.version -ne $EcosystemVersion -or [string]$PackageVersion.component -ne 'action_bridge' -or [string]$PackageManifest.ecosystem_version -ne $EcosystemVersion -or [string]$PackageManifest.component -ne 'action_bridge' -or [string]$PackageVersion.source_commit -ne [string]$PackageManifest.source_commit) { throw 'Action Bridge package version/source identity is inconsistent.' }
$SourceCommit = ([string]$PackageManifest.source_commit).ToLowerInvariant()
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Action Bridge package source commit is invalid.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
  if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$' -or $SourceCommit -cne $ExpectedSourceCommit.ToLowerInvariant()) { throw 'Action Bridge package source commit does not match ExpectedSourceCommit.' }
}
if ([string]::IsNullOrWhiteSpace($PackageArchivePath) -or -not (Test-Path -LiteralPath $PackageArchivePath -PathType Leaf)) { throw 'PackageArchivePath is required to bind the extracted Action Bridge package to its release ZIP.' }
if ($AssetSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A verified 64-hex Action Bridge AssetSha256 is required.' }
$PackageArchivePath = (Resolve-Path -LiteralPath $PackageArchivePath).Path
$ActualAssetSha256 = (Get-FileHash -LiteralPath $PackageArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AssetSha256.ToLowerInvariant() -cne $ActualAssetSha256) { throw 'Action Bridge archive SHA-256 does not match AssetSha256.' }
$NormalizedAssetSha256 = $ActualAssetSha256
$ManifestMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Entry in @($PackageManifest.files)) {
  $RelativeMember = [string]$Entry.path
  if ([IO.Path]::IsPathRooted($RelativeMember) -or $RelativeMember -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe package member path: $RelativeMember" }
  if (-not $ManifestMembers.Add($RelativeMember.Replace('/', '\'))) { throw "Duplicate package manifest member: $RelativeMember" }
  $Member = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $RelativeMember))
  $PackageRootPrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
  if (-not $Member.StartsWith($PackageRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Member -PathType Leaf)) { throw "Package member missing or unsafe: $RelativeMember" }
  if ((Get-FileHash -LiteralPath $Member -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$Entry.sha256).ToLowerInvariant()) { throw "Package member hash mismatch: $RelativeMember" }
}
foreach ($RequiredManifestMember in @('companion_action_bridge.py', 'Install-CompanionActionBridge.ps1', 'VERSION.json')) {
  if (-not $ManifestMembers.Contains($RequiredManifestMember)) { throw "Required package member is not hash-bound by MANIFEST.json: $RequiredManifestMember" }
}

$Archive = [IO.Compression.ZipFile]::OpenRead($PackageArchivePath)
try {
  $ArchiveEntries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
  $TotalExpandedBytes = [int64]0
  foreach ($ArchiveEntry in $Archive.Entries) {
    $ArchiveName = $ArchiveEntry.FullName.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($ArchiveName) -or $ArchiveName.StartsWith('/') -or $ArchiveName -match '^[A-Za-z]:' -or $ArchiveName -match '(^|/)\.\.(/|$)' -or -not $ArchiveEntries.TryAdd($ArchiveName, $ArchiveEntry)) { throw 'Action Bridge archive contains an unsafe or duplicate member.' }
    $TotalExpandedBytes += [int64]$ArchiveEntry.Length
    if ($TotalExpandedBytes -gt 64MB) { throw 'Action Bridge archive expanded size exceeds the 64 MiB safety limit.' }
  }
  $ArchiveManifestEntries = @($Archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -match '(^|/)MANIFEST\.json$' })
  if ($ArchiveManifestEntries.Count -ne 1) { throw "Action Bridge archive must contain exactly one MANIFEST.json; found $($ArchiveManifestEntries.Count)." }
  $ArchiveManifestName = $ArchiveManifestEntries[0].FullName.Replace('\', '/')
  $ArchivePrefix = $ArchiveManifestName.Substring(0, $ArchiveManifestName.Length - 'MANIFEST.json'.Length)
  $ArchiveManifestStream = $ArchiveManifestEntries[0].Open()
  try { $ArchiveManifestSha256 = Get-StreamSha256 -Stream $ArchiveManifestStream }
  finally { $ArchiveManifestStream.Dispose() }
  if ((Get-FileHash -LiteralPath $PackageManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ArchiveManifestSha256) { throw 'Extracted Action Bridge manifest does not match the exact verified archive.' }

  $ExpectedArchiveFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  [void]$ExpectedArchiveFiles.Add($ArchiveManifestName)
  foreach ($Entry in @($PackageManifest.files)) {
    $RelativeMember = ([string]$Entry.path).Replace('\', '/')
    $ArchiveMemberName = $ArchivePrefix + $RelativeMember
    [void]$ExpectedArchiveFiles.Add($ArchiveMemberName)
    if (-not $ArchiveEntries.ContainsKey($ArchiveMemberName)) { throw "Verified Action Bridge archive is missing manifest member: $RelativeMember" }
    $ArchiveMember = $ArchiveEntries[$ArchiveMemberName]
    if ([int64]$ArchiveMember.Length -ne [int64]$Entry.size_bytes) { throw "Action Bridge archive member size mismatch: $RelativeMember" }
    $ArchiveMemberStream = $ArchiveMember.Open()
    try { $ArchiveMemberSha256 = Get-StreamSha256 -Stream $ArchiveMemberStream }
    finally { $ArchiveMemberStream.Dispose() }
    if ($ArchiveMemberSha256 -cne ([string]$Entry.sha256).ToLowerInvariant()) { throw "Action Bridge archive member hash mismatch: $RelativeMember" }
  }
  $UnexpectedArchiveFiles = @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') -and -not $ExpectedArchiveFiles.Contains($_.FullName.Replace('\', '/')) })
  if ($UnexpectedArchiveFiles.Count -gt 0) { throw 'Action Bridge archive contains files outside its exact manifest-bound package set.' }
}
finally { $Archive.Dispose() }

$PythonwCommand = Get-Command pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$PythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $PythonCommand) { $PythonCommand = Get-Command python -ErrorAction Stop | Select-Object -First 1 }
if (-not $PythonwCommand) {
  $SiblingPythonw = Join-Path (Split-Path -Parent $PythonCommand.Source) 'pythonw.exe'
  if (Test-Path -LiteralPath $SiblingPythonw -PathType Leaf) { $PythonwCommand = Get-Item -LiteralPath $SiblingPythonw }
}
$InstalledScript = Join-Path $InstallRoot 'companion_action_bridge.py'
$InstalledWrapper = Join-Path $InstallRoot 'Run-ActionBridgeHidden.vbs'
$WorkerArguments = @($InstalledScript, 'scan', '--inbox', $InboxPath, '--registry', $RegistryPath, '--state-root', $StateRoot)
$WrapperBytes = $null
if ($PythonwCommand) {
  $BackgroundExecutable = [IO.Path]::GetFullPath($PythonwCommand.Source)
  $TaskArguments = ($WorkerArguments | ForEach-Object { Quote-WindowsArgument -Value ([string]$_) }) -join ' '
  $BackgroundMode = 'pythonw'
}
else {
  $WscriptCommand = Get-Command wscript.exe -ErrorAction Stop | Select-Object -First 1
  $BackgroundExecutable = [IO.Path]::GetFullPath($WscriptCommand.Source)
  $WrapperText = @'
Set shell = CreateObject("WScript.Shell")
command = ""
For index = 0 To WScript.Arguments.Count - 1
  If index > 0 Then command = command & " "
  command = command & Chr(34) & Replace(WScript.Arguments(index), Chr(34), Chr(34) & Chr(34)) & Chr(34)
Next
shell.Run command, 0, False
'@
  $WrapperBytes = ConvertTo-Utf8Bytes -Text $WrapperText
  $TaskArguments = (@('//B', '//Nologo', $InstalledWrapper, [IO.Path]::GetFullPath($PythonCommand.Source)) + $WorkerArguments | ForEach-Object { Quote-WindowsArgument -Value ([string]$_) }) -join ' '
  $BackgroundMode = 'wscript'
}
if ((Split-Path -Leaf $BackgroundExecutable).ToLowerInvariant() -notin @('pythonw.exe', 'wscript.exe')) { throw 'Scheduled Action Bridge must use pythonw.exe or wscript.exe.' }

$TaskConfiguration = [ordered]@{
  schema_version = '1.0.0'
  task_name = $TaskName
  execute = $BackgroundExecutable
  arguments = $TaskArguments
  description = $TaskDescriptionBase
  hidden = $true
  repetition_interval = 'PT1M'
  execution_time_limit = 'PT5M'
  multiple_instances = 'IgnoreNew'
}
$TaskConfigurationBytes = ConvertTo-Utf8Bytes -Text ($TaskConfiguration | ConvertTo-Json -Depth 10 -Compress)
$TaskConfigurationSha256 = Get-BytesSha256 -Bytes $TaskConfigurationBytes
$TaskDescription = "$TaskDescriptionBase [configuration-sha256:$TaskConfigurationSha256]"

if ($TaskBackend -eq 'Descriptor') {
  if ([string]::IsNullOrWhiteSpace($TaskDescriptorPath)) { throw 'TaskDescriptorPath is required for the hermetic descriptor backend.' }
  $TaskDescriptorPath = [IO.Path]::GetFullPath($TaskDescriptorPath)
  $TempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $TaskDescriptorPath.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Hermetic task descriptor must remain below the system temporary directory.' }
  foreach ($HermeticPath in @($ResolvedProject, $InstallRoot, $RegistryPath, $InboxPath, $StateRoot)) {
    if (-not [IO.Path]::GetFullPath($HermeticPath).StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Hermetic descriptor mode cannot reference a path outside the system temporary directory: $HermeticPath" }
  }
  $TaskDescriptor = [ordered]@{}
  foreach ($Key in $TaskConfiguration.Keys) { $TaskDescriptor[$Key] = $TaskConfiguration[$Key] }
  $TaskDescriptor['configuration_sha256'] = $TaskConfigurationSha256
  $TaskDescriptor['description_with_identity'] = $TaskDescription
  $TaskDescriptorBytes = ConvertTo-Utf8Bytes -Text ($TaskDescriptor | ConvertTo-Json -Depth 10)
}

$CapabilityPath = Join-Path $ResolvedProject '.agy\ACTION_BRIDGE_CAPABILITY.json'
$ReceiptPath = Join-Path $InstallRoot 'INSTALLATION_RECEIPT.json'
$ExistingCapability = Read-JsonIfValid -Path $CapabilityPath
$ExistingRegistry = Read-JsonIfValid -Path $RegistryPath
$ExistingReceipt = Read-JsonIfValid -Path $ReceiptPath
if ((Test-Path -LiteralPath $CapabilityPath -PathType Leaf) -and $null -eq $ExistingCapability) { throw 'Existing project capability JSON is invalid; refusing to overwrite it.' }
if ((Test-Path -LiteralPath $RegistryPath -PathType Leaf) -and $null -eq $ExistingRegistry) { throw 'Existing project registry JSON is invalid; refusing to discard unrelated registrations.' }
if ((Test-Path -LiteralPath $ReceiptPath -PathType Leaf) -and $null -eq $ExistingReceipt) { throw 'Existing Action Bridge installation receipt JSON is invalid; refusing an ambiguous repair.' }
$CapabilityToken = $null
if ($null -ne $ExistingCapability -and [string](Get-OptionalPropertyValue -InputObject $ExistingCapability -Name 'project_id') -eq $ProjectId -and [string](Get-OptionalPropertyValue -InputObject $ExistingCapability -Name 'capability_token') -match '^[0-9a-f]{64}$') { $CapabilityToken = [string](Get-OptionalPropertyValue -InputObject $ExistingCapability -Name 'capability_token') }
if (-not $CapabilityToken -and $null -ne $ExistingRegistry) {
  $ExistingRegistration = @((Get-OptionalPropertyValue -InputObject $ExistingRegistry -Name 'projects') | Where-Object { [string](Get-OptionalPropertyValue -InputObject $_ -Name 'project_id') -eq $ProjectId }) | Select-Object -First 1
  if ($ExistingRegistration -and [string](Get-OptionalPropertyValue -InputObject $ExistingRegistration -Name 'capability_token') -match '^[0-9a-f]{64}$') { $CapabilityToken = [string](Get-OptionalPropertyValue -InputObject $ExistingRegistration -Name 'capability_token') }
}
if (-not $CapabilityToken) {
  $RandomBytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Fill($RandomBytes)
  $CapabilityToken = ([Convert]::ToHexString($RandomBytes)).ToLowerInvariant()
}

$Projects = [Collections.Generic.List[object]]::new()
$RegistrationReplaced = $false
if ($null -ne $ExistingRegistry) {
  foreach ($Item in @((Get-OptionalPropertyValue -InputObject $ExistingRegistry -Name 'projects'))) {
    if ([string](Get-OptionalPropertyValue -InputObject $Item -Name 'project_id') -eq $ProjectId) {
      if (-not $RegistrationReplaced) {
        [void]$Projects.Add([ordered]@{ project_id = $ProjectId; project_root = $ResolvedProject; logical_name = $LogicalName; ecosystem_version = $EcosystemVersion; capability_token = $CapabilityToken })
        $RegistrationReplaced = $true
      }
    }
    else { [void]$Projects.Add($Item) }
  }
}
if (-not $RegistrationReplaced) { [void]$Projects.Add([ordered]@{ project_id = $ProjectId; project_root = $ResolvedProject; logical_name = $LogicalName; ecosystem_version = $EcosystemVersion; capability_token = $CapabilityToken }) }
$RegistryOverrides = [ordered]@{ schema_version = $BridgeSchemaVersion; ecosystem_version = $EcosystemVersion; projects = [object[]]$Projects.ToArray() }
$DesiredRegistry = ConvertTo-OrderedObjectWithOverrides -InputObject $ExistingRegistry -Overrides $RegistryOverrides
$RegistryBytes = ConvertTo-Utf8Bytes -Text ($DesiredRegistry | ConvertTo-Json -Depth 30)

$ExistingCapabilityProjectId = [string](Get-OptionalPropertyValue -InputObject $ExistingCapability -Name 'project_id')
$ExistingCapabilityCreatedAt = [string](Get-OptionalPropertyValue -InputObject $ExistingCapability -Name 'created_at_utc')
$CreatedAtUtc = if ($null -ne $ExistingCapability -and $ExistingCapabilityProjectId -eq $ProjectId -and -not [string]::IsNullOrWhiteSpace($ExistingCapabilityCreatedAt)) { $ExistingCapabilityCreatedAt } else { (Get-Date).ToUniversalTime().ToString('o') }
$CapabilityOverrides = [ordered]@{ schema_version = $BridgeSchemaVersion; ecosystem_version = $EcosystemVersion; project_id = $ProjectId; capability_token = $CapabilityToken; purpose = 'companion_action_packet_import'; created_at_utc = $CreatedAtUtc }
$DesiredCapability = ConvertTo-OrderedObjectWithOverrides -InputObject $(if ($null -ne $ExistingCapability -and $ExistingCapabilityProjectId -eq $ProjectId) { $ExistingCapability } else { $null }) -Overrides $CapabilityOverrides
$CapabilityBytes = ConvertTo-Utf8Bytes -Text ($DesiredCapability | ConvertTo-Json -Depth 10)
$InstalledCodeBytes = [IO.File]::ReadAllBytes($Source)
$InstalledCodeSha256 = Get-BytesSha256 -Bytes $InstalledCodeBytes
$PackageManifestSha256 = (Get-FileHash -LiteralPath $PackageManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

if (-not $Apply) {
  Write-Host "DRY RUN: install Companion Action Bridge to $InstallRoot"
  Write-Host "Register: $ProjectId -> $ResolvedProject"
  Write-Host "Background mode: $BackgroundMode; scheduled task: $TaskName"
  Write-Host 'A project capability will be preserved or generated.'
  return
}

$FileTargets = [Collections.Generic.List[string]]::new()
foreach ($Target in @($InstalledScript, $RegistryPath, $CapabilityPath, $ReceiptPath)) { [void]$FileTargets.Add($Target) }
if ($null -ne $WrapperBytes) { [void]$FileTargets.Add($InstalledWrapper) }
if ($TaskBackend -eq 'Descriptor') { [void]$FileTargets.Add($TaskDescriptorPath) }
$UniqueTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Target in $FileTargets) {
  if (-not $UniqueTargets.Add([IO.Path]::GetFullPath($Target))) { throw "Transactional file targets overlap: $Target" }
}
$PackageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
foreach ($Target in $FileTargets) {
  if ([IO.Path]::GetFullPath($Target).StartsWith($PackageRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Installer destinations cannot overlap immutable package source files.' }
}

$FileSnapshots = [Collections.Generic.List[object]]::new()
foreach ($Target in $FileTargets) { [void]$FileSnapshots.Add((New-FileSnapshot -Path $Target)) }
$TaskSnapshot = if ($TaskBackend -eq 'Windows') { Get-WindowsTaskSnapshot -Name $TaskName } else { $null }
$TaskChanged = $false
$TaskMutationStarted = $false
$RollbackErrors = [Collections.Generic.List[string]]::new()

try {
  [void](Write-FileAtomicallyIfChanged -Path $InstalledScript -Bytes $InstalledCodeBytes)
  if ($null -ne $WrapperBytes) { [void](Write-FileAtomicallyIfChanged -Path $InstalledWrapper -Bytes $WrapperBytes) }
  Assert-FaultInjection -Step 'AfterInstallCode'

  [void](Write-FileAtomicallyIfChanged -Path $RegistryPath -Bytes $RegistryBytes)
  Assert-FaultInjection -Step 'AfterRegistry'

  [void](Write-FileAtomicallyIfChanged -Path $CapabilityPath -Bytes $CapabilityBytes)
  Assert-FaultInjection -Step 'AfterCapability'

  if ($TaskBackend -eq 'Descriptor') {
    $TaskChanged = Write-FileAtomicallyIfChanged -Path $TaskDescriptorPath -Bytes $TaskDescriptorBytes
    $TaskDefinitionSha256 = (Get-FileHash -LiteralPath $TaskDescriptorPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  else {
    $CurrentTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $CurrentTaskXml = if ($null -ne $CurrentTask) { [string](Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } else { $null }
    $CurrentTaskSha256 = if ($null -ne $CurrentTaskXml) { Get-BytesSha256 -Bytes (ConvertTo-Utf8Bytes -Text $CurrentTaskXml) } else { $null }
    $TaskAction = if ($null -ne $CurrentTask) { @($CurrentTask.Actions) | Select-Object -First 1 } else { $null }
    $TaskIsExact = $null -ne $CurrentTask -and $null -ne $TaskAction -and [string]$TaskAction.Execute -ieq $BackgroundExecutable -and [string]$TaskAction.Arguments -ceq $TaskArguments -and [string]$CurrentTask.Description -ceq $TaskDescription -and [bool]$CurrentTask.Settings.Hidden -and $null -ne $ExistingReceipt -and [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'task_configuration_sha256') -ceq $TaskConfigurationSha256 -and [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'task_definition_sha256') -ceq $CurrentTaskSha256
    if (-not $TaskIsExact) {
      $Action = New-ScheduledTaskAction -Execute $BackgroundExecutable -Argument $TaskArguments
      $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
      $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -Hidden
      $TaskMutationStarted = $true
      Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Description $TaskDescription -Force | Out-Null
      $TaskChanged = $true
      $CurrentTaskXml = [string](Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
    }
    $TaskDefinitionSha256 = Get-BytesSha256 -Bytes (ConvertTo-Utf8Bytes -Text $CurrentTaskXml)
  }
  Assert-FaultInjection -Step 'AfterTask'

  $ReceiptIdentityMatches = $null -ne $ExistingReceipt -and [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'project_id') -eq $ProjectId -and [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'project_root') -ieq $ResolvedProject -and [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'source_commit') -ceq $SourceCommit
  $ExistingInstalledAtUtc = [string](Get-OptionalPropertyValue -InputObject $ExistingReceipt -Name 'installed_at_utc')
  $InstalledAtUtc = if ($ReceiptIdentityMatches -and -not [string]::IsNullOrWhiteSpace($ExistingInstalledAtUtc)) { $ExistingInstalledAtUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
  $Receipt = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    status = 'PASS'
    project_id = $ProjectId
    project_root = $ResolvedProject
    source_commit = $SourceCommit
    release_asset_sha256 = $NormalizedAssetSha256
    package_manifest_sha256 = $PackageManifestSha256
    installed_code_sha256 = $InstalledCodeSha256
    source_code_sha256 = $InstalledCodeSha256
    scheduled_task = $TaskName
    task_backend = $TaskBackend.ToLowerInvariant()
    task_configuration_sha256 = $TaskConfigurationSha256
    task_definition_sha256 = $TaskDefinitionSha256
    background_executable = $BackgroundExecutable
    background_mode = $BackgroundMode
    hidden_execution = $true
    installed_at_utc = $InstalledAtUtc
  }
  if ($null -ne $WrapperBytes) { $Receipt['installed_wrapper_sha256'] = Get-BytesSha256 -Bytes $WrapperBytes }
  $ReceiptBytes = ConvertTo-Utf8Bytes -Text ($Receipt | ConvertTo-Json -Depth 10)
  [void](Write-FileAtomicallyIfChanged -Path $ReceiptPath -Bytes $ReceiptBytes)
  Assert-FaultInjection -Step 'AfterReceipt'
}
catch {
  $OriginalFailure = $_.Exception.Message
  if ($TaskBackend -eq 'Windows' -and $TaskMutationStarted) {
    try { Restore-WindowsTaskSnapshot -Name $TaskName -Snapshot $TaskSnapshot }
    catch { [void]$RollbackErrors.Add("scheduled task: $($_.Exception.Message)") }
  }
  foreach ($Snapshot in @($FileSnapshots.ToArray()) | Sort-Object { [string]$_.path } -Descending) {
    try { Restore-FileSnapshot -Snapshot $Snapshot }
    catch { [void]$RollbackErrors.Add("$($Snapshot.path): $($_.Exception.Message)") }
  }
  foreach ($Directory in @($CreatedDirectories.ToArray()) | Sort-Object { $_.Length } -Descending) {
    try {
      if ((Test-Path -LiteralPath $Directory -PathType Container) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -eq 0) { Remove-Item -LiteralPath $Directory -Force }
    }
    catch { [void]$RollbackErrors.Add("${Directory}: $($_.Exception.Message)") }
  }
  if ($RollbackErrors.Count -gt 0) { throw "Action Bridge installation failed: $OriginalFailure. Rollback failures: $($RollbackErrors -join '; ')" }
  throw
}

Write-Host "Companion Action Bridge installed transactionally. task_changed=$($TaskChanged.ToString().ToLowerInvariant())"
