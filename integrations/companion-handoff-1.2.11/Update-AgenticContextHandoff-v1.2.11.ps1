[CmdletBinding()]
param(
  [string]$HandoffRoot = 'C:\Scripts\AntigravityProjects\companion-handoff',
  [string]$PackageRoot = '',
  [string]$PackageArchivePath = '',
  [string]$AssetSha256 = '',
  [string]$ExpectedSourceCommit = '',
  [string]$BackupRoot = '',
  [string]$HooksPath = "$env:USERPROFILE\.gemini\config\hooks.json",
  [string]$TaskName = 'AntigravityCompanionHandoffWorker',
  [string]$PythonwPath = '',
  [ValidateSet('Register', 'Plan')][string]$TaskMode = 'Register',
  [switch]$SkipTaskCanary,
  [switch]$AllowDevelopmentPackage,
  [switch]$Apply,
  [Parameter(DontShow = $true)][switch]$SimulateFailureAfterFileInstall
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$EcosystemVersion = '1.2.11'
$EngineSchemaVersion = '4.3.4'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$SafeAuthorityPaths = @(
  '.agy/ACTION_PACKET_RECEIPT.json',
  '.agy/PROGRESS_POLICY.json',
  '.agy/PROGRESS_STATE.json',
  '.agy/NEXT_ACTION.json',
  '.agy/CANDIDATE_MANIFEST.json',
  '.agy/CANDIDATE_MANIFEST_STATUS.json',
  '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md',
  '.agy/inbox/ACTIVE_ACTION_PACKET/OWNER_SUMMARY_RU.md'
)
$ForbiddenAuthorityPatterns = @('ACTION_PACKET.json', 'ACTION_BRIDGE_CAPABILITY', 'capability_token')
$RequiredPrivacyPatterns = @('.env*', '*credentials*', '*token*', '*capability*', 'ACTION_PACKET.json', '*.pem', '*.key')
$ExplicitExclusions = @(
  'install/finalize_v432.py',
  'install/finalize_v433.py',
  'install/finalize_v434.py',
  'install/fix_task.ps1'
)

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

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

function Get-RelativeForwardPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$Path
  )
  return [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
}

function Test-PathWithin {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Candidate
  )
  $ResolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $ResolvedCandidate = [IO.Path]::GetFullPath($Candidate)
  return $ResolvedCandidate.Equals($ResolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $ResolvedCandidate.StartsWith(($ResolvedRoot + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-RecordSetDigest {
  param([Parameter(Mandatory = $true)][object[]]$Records)
  $Canonical = @($Records | Sort-Object { [string]$_.path } | ForEach-Object {
    '{0}`t{1}`t{2}' -f [string]$_.path, [long]$_.size_bytes, [string]$_.sha256
  }) -join "`n"
  return Get-BytesSha256 -Bytes $Utf8NoBom.GetBytes($Canonical)
}

function ConvertTo-Utf8JsonText {
  param([Parameter(Mandatory = $true)][object]$Value)
  return (($Value | ConvertTo-Json -Depth 100) + "`n")
}

function Write-AtomicBytes {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )
  $Parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  $Temp = Join-Path $Parent ('.' + (Split-Path -Leaf $Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllBytes($Temp, $Bytes)
  try { [IO.File]::Move($Temp, $Path, $true) }
  finally { if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force } }
}

function Write-AtomicText {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  Write-AtomicBytes -Path $Path -Bytes $Utf8NoBom.GetBytes($Text)
}

function Set-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$Value
  )
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
  else { $Property.Value = $Value }
}

function Get-OptionalProperty {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][object]$Default = $null
  )
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return $Default }
  return $Property.Value
}

function Test-PowerShellSyntax {
  param([Parameter(Mandatory = $true)][string]$Path)
  $Tokens = $null
  $Errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
  if (@($Errors).Count -gt 0) {
    throw "PowerShell syntax failed: $Path :: $(@($Errors | ForEach-Object Message) -join ' | ')"
  }
}

function Invoke-PythonSyntaxCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Python
  )
  $PriorAstPath = $env:AGENTIC_HANDOFF_AST_FILE
  $PriorBytecode = $env:PYTHONDONTWRITEBYTECODE
  try {
    $env:AGENTIC_HANDOFF_AST_FILE = $Path
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $Output = @(& $Python -B -c "import ast,os,pathlib; p=pathlib.Path(os.environ['AGENTIC_HANDOFF_AST_FILE']); ast.parse(p.read_text(encoding='utf-8-sig'), filename=str(p))" 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) { throw "Python syntax failed: $Path :: $($Output -join [Environment]::NewLine)" }
  }
  finally {
    $env:AGENTIC_HANDOFF_AST_FILE = $PriorAstPath
    $env:PYTHONDONTWRITEBYTECODE = $PriorBytecode
  }
}

function Test-PackageIntegrity {
  param([Parameter(Mandatory = $true)][string]$Root)
  foreach ($Name in @('VERSION.json', 'MANIFEST.json', 'SOURCE_ATTESTATION.json', 'Update-AgenticContextHandoff-v1.2.11.ps1', 'source')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Name))) { throw "Package member missing: $Name" }
  }
  $Version = Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $Manifest = Get-Content -LiteralPath (Join-Path $Root 'MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $Attestation = Get-Content -LiteralPath (Join-Path $Root 'SOURCE_ATTESTATION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if (
    [string]$Version.ecosystem_version -ne $EcosystemVersion -or
    [string]$Version.version -ne $EcosystemVersion -or
    [string]$Manifest.ecosystem_version -ne $EcosystemVersion -or
    [string]$Manifest.version -ne $EcosystemVersion -or
    [string]$Attestation.ecosystem_version -ne $EcosystemVersion
  ) {
    throw 'Context Handoff package version mismatch.'
  }
  if (
    [string]$Version.engine_schema_version -ne $EngineSchemaVersion -or
    [string]$Manifest.engine_schema_version -ne $EngineSchemaVersion -or
    [string]$Attestation.engine_schema_version -ne $EngineSchemaVersion
  ) { throw 'Engine schema version mismatch.' }
  if (
    [string]$Manifest.source_commit -cne [string]$Version.source_commit -or
    [string]$Attestation.source_commit -cne [string]$Version.source_commit -or
    [bool]$Manifest.source_tree_dirty -ne [bool]$Version.source_tree_dirty -or
    [bool]$Attestation.source_tree_dirty -ne [bool]$Version.source_tree_dirty -or
    [string]$Manifest.source_payload_sha256 -cne [string]$Version.source_payload_sha256 -or
    [string]$Attestation.source_payload_sha256 -cne [string]$Version.source_payload_sha256
  ) { throw 'VERSION/MANIFEST/source attestation identity mismatch.' }
  $ExclusionDiff = @(Compare-Object -ReferenceObject ($ExplicitExclusions | Sort-Object) -DifferenceObject (@($Manifest.explicit_exclusions) | ForEach-Object { [string]$_ } | Sort-Object))
  $AttestationExclusionDiff = @(Compare-Object -ReferenceObject ($ExplicitExclusions | Sort-Object) -DifferenceObject (@($Attestation.explicit_exclusions) | ForEach-Object { [string]$_ } | Sort-Object))
  if ($ExclusionDiff.Count -gt 0 -or $AttestationExclusionDiff.Count -gt 0) { throw 'Explicit exclusion metadata mismatch.' }
  if ([bool]$Version.source_tree_dirty -and -not $AllowDevelopmentPackage) {
    throw 'A dirty development Context Handoff package cannot be installed without -AllowDevelopmentPackage.'
  }
  if ([string]$Version.source_commit -notmatch '^[0-9a-f]{40,64}$') { throw 'Package source commit is invalid.' }

  $ExpectedPaths = @($Manifest.files | ForEach-Object { [string]$_.path }) + @('MANIFEST.json')
  if (@($ExpectedPaths | Sort-Object -Unique).Count -ne $ExpectedPaths.Count) { throw 'Duplicate package manifest path.' }
  $ActualPaths = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object {
    Get-RelativeForwardPath -BasePath $Root -Path $_.FullName
  })
  $PathDiff = @(Compare-Object -ReferenceObject ($ExpectedPaths | Sort-Object) -DifferenceObject ($ActualPaths | Sort-Object))
  if ($PathDiff.Count -gt 0) { throw "Package file-set mismatch: $($PathDiff | ConvertTo-Json -Compress)" }

  foreach ($File in @($Manifest.files)) {
    $Relative = [string]$File.path
    $Candidate = [IO.Path]::GetFullPath((Join-Path $Root ($Relative.Replace('/', '\'))))
    if (-not (Test-PathWithin -Root $Root -Candidate $Candidate)) { throw "Package path escapes root: $Relative" }
    $Item = Get-Item -LiteralPath $Candidate
    if ([long]$Item.Length -ne [long]$File.size_bytes -or (Get-Sha256 -Path $Candidate) -cne [string]$File.sha256) {
      throw "Package manifest mismatch: $Relative"
    }
  }
  if ((Get-RecordSetDigest -Records @($Manifest.files)) -cne [string]$Manifest.package_payload_sha256) {
    throw 'Package payload digest mismatch.'
  }

  $SourceRecords = @($Attestation.source_files)
  $SourcePaths = @($SourceRecords | ForEach-Object { [string]$_.path })
  if (@($SourcePaths | Sort-Object -Unique).Count -ne $SourcePaths.Count) { throw 'Duplicate source attestation path.' }
  if ((Get-RecordSetDigest -Records $SourceRecords) -cne [string]$Attestation.source_payload_sha256) {
    throw 'Source attestation digest mismatch.'
  }
  if ([string]$Attestation.source_payload_sha256 -cne [string]$Manifest.source_payload_sha256) {
    throw 'Package manifest/source attestation digest mismatch.'
  }
  $ManifestSourceRecords = @($Manifest.files | Where-Object { [string]$_.role -ceq 'immutable_source' })
  if ($ManifestSourceRecords.Count -ne $SourceRecords.Count) { throw 'Manifest/source attestation file count mismatch.' }
  $ManifestSourceByPath = @{}
  foreach ($Record in $ManifestSourceRecords) { $ManifestSourceByPath[[string]$Record.path] = $Record }
  foreach ($Record in $SourceRecords) {
    $ManifestRecord = $ManifestSourceByPath[[string]$Record.path]
    if (
      $null -eq $ManifestRecord -or
      [long]$ManifestRecord.size_bytes -ne [long]$Record.size_bytes -or
      [string]$ManifestRecord.sha256 -cne [string]$Record.sha256
    ) { throw "Manifest/source attestation record mismatch: $($Record.path)" }
  }
  foreach ($Excluded in $ExplicitExclusions) {
    if (Test-Path -LiteralPath (Join-Path $Root ('source\' + $Excluded.Replace('/', '\')))) {
      throw "Excluded legacy file is present in package: $Excluded"
    }
  }
  return [pscustomobject]@{ version = $Version; manifest = $Manifest; attestation = $Attestation }
}

function Test-PackageArchiveBinding {
  param(
    [Parameter(Mandatory = $true)][string]$ExtractedRoot,
    [Parameter(Mandatory = $true)][object]$Manifest,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$ExpectedAssetSha256
  )

  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -or [IO.Path]::GetExtension($ArchivePath) -ine '.zip') {
    throw 'PackageArchivePath must identify the originating Context Handoff release ZIP.'
  }
  if ($ExpectedAssetSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A verified 64-hex Context Handoff AssetSha256 is required.' }
  $ResolvedArchive = (Resolve-Path -LiteralPath $ArchivePath).Path
  $ActualAssetSha256 = Get-Sha256 -Path $ResolvedArchive
  if ($ActualAssetSha256 -cne $ExpectedAssetSha256.ToLowerInvariant()) { throw 'Context Handoff archive SHA-256 does not match AssetSha256.' }

  $Archive = [IO.Compression.ZipFile]::OpenRead($ResolvedArchive)
  try {
    $ArchiveEntries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $ArchiveFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $TotalExpandedBytes = [int64]0
    foreach ($Entry in $Archive.Entries) {
      $Name = $Entry.FullName.Replace('\', '/')
      if (
        [string]::IsNullOrWhiteSpace($Name) -or
        $Name.StartsWith('/') -or
        $Name -match '^[A-Za-z]:' -or
        $Name -match '(^|/)\.\.(/|$)' -or
        -not $ArchiveEntries.TryAdd($Name, $Entry)
      ) { throw 'Context Handoff archive contains an unsafe or duplicate member.' }
      if (-not $Name.EndsWith('/')) {
        [void]$ArchiveFiles.Add($Name)
        $TotalExpandedBytes += [int64]$Entry.Length
        if ($TotalExpandedBytes -gt 128MB) { throw 'Context Handoff archive expanded size exceeds the 128 MiB safety limit.' }
      }
    }

    $ArchiveManifestEntries = @($Archive.Entries | Where-Object {
      -not $_.FullName.Replace('\', '/').EndsWith('/') -and $_.FullName.Replace('\', '/') -match '(^|/)MANIFEST\.json$'
    })
    if ($ArchiveManifestEntries.Count -ne 1) { throw "Context Handoff archive must contain exactly one MANIFEST.json; found $($ArchiveManifestEntries.Count)." }
    $ArchiveManifestName = $ArchiveManifestEntries[0].FullName.Replace('\', '/')
    $ArchivePrefix = $ArchiveManifestName.Substring(0, $ArchiveManifestName.Length - 'MANIFEST.json'.Length)
    $ArchiveManifestStream = $ArchiveManifestEntries[0].Open()
    try { $ArchiveManifestSha256 = Get-StreamSha256 -Stream $ArchiveManifestStream }
    finally { $ArchiveManifestStream.Dispose() }
    if ((Get-Sha256 -Path (Join-Path $ExtractedRoot 'MANIFEST.json')) -cne $ArchiveManifestSha256) {
      throw 'Extracted Context Handoff MANIFEST.json does not match the raw manifest in the verified archive.'
    }

    $ExpectedArchiveFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$ExpectedArchiveFiles.Add($ArchiveManifestName)
    foreach ($ManifestEntry in @($Manifest.files)) {
      $RelativeMember = ([string]$ManifestEntry.path).Replace('\', '/')
      $ArchiveMemberName = $ArchivePrefix + $RelativeMember
      if (-not $ExpectedArchiveFiles.Add($ArchiveMemberName)) { throw "Duplicate Context Handoff manifest member: $RelativeMember" }
      if (-not $ArchiveEntries.ContainsKey($ArchiveMemberName)) { throw "Verified Context Handoff archive is missing manifest member: $RelativeMember" }
      $ArchiveMember = $ArchiveEntries[$ArchiveMemberName]
      if ([int64]$ArchiveMember.Length -ne [int64]$ManifestEntry.size_bytes) { throw "Context Handoff archive member size mismatch: $RelativeMember" }
      $ArchiveMemberStream = $ArchiveMember.Open()
      try { $ArchiveMemberSha256 = Get-StreamSha256 -Stream $ArchiveMemberStream }
      finally { $ArchiveMemberStream.Dispose() }
      if ($ArchiveMemberSha256 -cne ([string]$ManifestEntry.sha256).ToLowerInvariant()) { throw "Context Handoff archive member hash mismatch: $RelativeMember" }
    }
    if ($ArchiveFiles.Count -ne $ExpectedArchiveFiles.Count -or @($ArchiveFiles | Where-Object { -not $ExpectedArchiveFiles.Contains($_) }).Count -gt 0) {
      throw 'Context Handoff archive contains files outside its exact global manifest-bound member set.'
    }
  }
  finally { $Archive.Dispose() }
  return $ActualAssetSha256
}

function Get-InstalledImmutableFiles {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string[]]$DirectoryNames,
    [Parameter(Mandatory = $true)][string[]]$RootFileNames
  )
  $Files = [Collections.Generic.List[object]]::new()
  foreach ($DirectoryName in $DirectoryNames) {
    $Directory = Join-Path $Root $DirectoryName
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { continue }
    foreach ($File in Get-ChildItem -LiteralPath $Directory -File -Recurse -Force) {
      [void]$Files.Add([pscustomobject]@{
        path = Get-RelativeForwardPath -BasePath $Root -Path $File.FullName
        full_path = $File.FullName
        size_bytes = [long]$File.Length
        sha256 = Get-Sha256 -Path $File.FullName
      })
    }
  }
  foreach ($RootFileName in $RootFileNames) {
    $Path = Join-Path $Root $RootFileName
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $Item = Get-Item -LiteralPath $Path
      [void]$Files.Add([pscustomobject]@{
        path = $RootFileName.Replace('\', '/')
        full_path = $Item.FullName
        size_bytes = [long]$Item.Length
        sha256 = Get-Sha256 -Path $Item.FullName
      })
    }
  }
  return @($Files | Sort-Object path -Unique)
}

function Test-InstalledSource {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][object[]]$ExpectedRecords,
    [Parameter(Mandatory = $true)][string[]]$DirectoryNames,
    [Parameter(Mandatory = $true)][string[]]$RootFileNames,
    [Parameter(Mandatory = $true)][string]$Python
  )
  $ActualRecords = Get-InstalledImmutableFiles -Root $Root -DirectoryNames $DirectoryNames -RootFileNames $RootFileNames
  $ExpectedPaths = @($ExpectedRecords | ForEach-Object { [string]$_.path })
  $ActualPaths = @($ActualRecords | ForEach-Object { [string]$_.path })
  $Diff = @(Compare-Object -ReferenceObject ($ExpectedPaths | Sort-Object) -DifferenceObject ($ActualPaths | Sort-Object))
  if ($Diff.Count -gt 0) { throw "Installed immutable file-set mismatch: $($Diff | ConvertTo-Json -Compress)" }
  $ActualByPath = @{}
  foreach ($Record in $ActualRecords) { $ActualByPath[[string]$Record.path] = $Record }
  foreach ($Expected in $ExpectedRecords) {
    $Actual = $ActualByPath[[string]$Expected.path]
    if ([long]$Actual.size_bytes -ne [long]$Expected.size_bytes -or [string]$Actual.sha256 -cne [string]$Expected.sha256) {
      throw "Installed source parity mismatch: $($Expected.path)"
    }
  }
  foreach ($Excluded in $ExplicitExclusions) {
    if (Test-Path -LiteralPath (Join-Path $Root $Excluded.Replace('/', '\'))) {
      throw "Excluded legacy file remains active: $Excluded"
    }
  }

  $ConfigPath = Join-Path $Root 'handoff.config.json'
  $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$Config.ecosystem_version -ne $EcosystemVersion -or [string]$Config.engine_schema_version -ne $EngineSchemaVersion) {
    throw 'Installed config version mismatch.'
  }
  foreach ($AuthorityPath in @($Config.additional_authority_paths)) {
    foreach ($Forbidden in $ForbiddenAuthorityPatterns) {
      if ([string]$AuthorityPath -match [regex]::Escape($Forbidden)) { throw "Unsafe authority path is active: $AuthorityPath" }
    }
  }
  $InstalledAuthorityPaths = @($Config.additional_authority_paths | ForEach-Object { [string]$_ })
  if (
    $InstalledAuthorityPaths.Count -ne $SafeAuthorityPaths.Count -or
    @(Compare-Object -ReferenceObject $SafeAuthorityPaths -DifferenceObject $InstalledAuthorityPaths -SyncWindow 0).Count -gt 0
  ) { throw 'Safe authority path set is incomplete, reordered, or contains extras.' }
  $Privacy = Get-OptionalProperty -Object $Config -Name 'privacy' -Default $null
  $InstalledPrivacyPatterns = @(Get-OptionalProperty -Object $Privacy -Name 'fail_closed_patterns' -Default @() | ForEach-Object { [string]$_ })
  foreach ($RequiredPrivacyPattern in $RequiredPrivacyPatterns) {
    if ($InstalledPrivacyPatterns -notcontains $RequiredPrivacyPattern) { throw "Required privacy pattern is missing: $RequiredPrivacyPattern" }
  }

  foreach ($Record in $ExpectedRecords) {
    $Path = Join-Path $Root ([string]$Record.path).Replace('/', '\')
    if ($Path.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
      try { $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
      catch { throw "Installed JSON invalid: $Path :: $($_.Exception.Message)" }
    }
    elseif ($Path.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { Test-PowerShellSyntax -Path $Path }
    elseif ($Path.EndsWith('.py', [StringComparison]::OrdinalIgnoreCase)) { Invoke-PythonSyntaxCheck -Path $Path -Python $Python }
  }
  return $ActualRecords
}

function Test-TaskDefinitionMatches {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][object]$Descriptor
  )
  $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if (@($Task).Count -ne 1) { return $false }
  if (@($Task.Actions).Count -ne 1 -or @($Task.Triggers).Count -ne 1) { return $false }
  $Action = @($Task.Actions) | Select-Object -First 1
  $Trigger = @($Task.Triggers) | Select-Object -First 1
  if (-not $Action -or -not $Trigger) { return $false }
  return (
    [string]$Action.Execute -ieq [string]$Descriptor.execute -and
    [string]$Action.Arguments -ceq [string]$Descriptor.arguments -and
    [string]$Action.WorkingDirectory -ieq [string]$Descriptor.working_directory -and
    [string]$Trigger.Repetition.Interval -eq 'PT1M' -and
    [bool]$Task.Settings.Enabled -and
    [bool]$Task.Settings.Hidden -and
    [string]$Task.Settings.MultipleInstances -eq 'IgnoreNew' -and
    [string]$Task.Settings.ExecutionTimeLimit -eq 'PT5M' -and
    [bool]$Task.Settings.StartWhenAvailable
  )
}

function Wait-TaskQuiesced {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$TimeoutSeconds = 30
  )
  $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $Task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
    $State = [string]$Task.State
    if (-not [bool]$Task.Settings.Enabled -and $State -notin @('Running', 'Queued')) { return $Task }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $Deadline)
  throw "Scheduled task did not quiesce before Context Handoff writes: $Name state=$State enabled=$([bool]$Task.Settings.Enabled)"
}

function Assert-TaskQuiescedBeforeWrite {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$ExistedAtSnapshot
  )
  $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if (-not $ExistedAtSnapshot) {
    if ($null -ne $Task) { throw "Scheduled task appeared after the transaction snapshot: $Name" }
    return
  }
  if ($null -eq $Task) { throw "Scheduled task disappeared after the transaction snapshot: $Name" }
  $State = [string]$Task.State
  if ([bool]$Task.Settings.Enabled -or $State -in @('Running', 'Queued')) {
    throw "Scheduled task is not quiesced before Context Handoff writes: $Name state=$State enabled=$([bool]$Task.Settings.Enabled)"
  }
}

function Get-NormalizedTaskXml {
  param([Parameter(Mandatory = $true)][string]$Xml)
  return $Xml.Replace("`r`n", "`n").Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = $PSScriptRoot }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$PackageState = Test-PackageIntegrity -Root $PackageRoot
$Version = $PackageState.version
$Manifest = $PackageState.manifest
$Attestation = $PackageState.attestation
$PackageSourceCommit = ([string]$Version.source_commit).ToLowerInvariant()
$HasArchivePath = -not [string]::IsNullOrWhiteSpace($PackageArchivePath)
$HasAssetSha256 = -not [string]::IsNullOrWhiteSpace($AssetSha256)
$NormalizedAssetSha256 = $null

if (-not $AllowDevelopmentPackage) {
  if (-not $HasArchivePath) { throw 'PackageArchivePath is required to bind the extracted Context Handoff release package to its ZIP.' }
  if (-not $HasAssetSha256) { throw 'AssetSha256 is required to bind the extracted Context Handoff release package to its ZIP.' }
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) { throw 'ExpectedSourceCommit is required for a Context Handoff release package.' }
}
if ($HasArchivePath -xor $HasAssetSha256) { throw 'PackageArchivePath and AssetSha256 must be supplied together.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
  if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$' -or $PackageSourceCommit -cne $ExpectedSourceCommit.ToLowerInvariant()) {
    throw 'Context Handoff package source commit does not exactly match ExpectedSourceCommit.'
  }
}
if ($HasArchivePath) {
  $NormalizedAssetSha256 = Test-PackageArchiveBinding -ExtractedRoot $PackageRoot -Manifest $Manifest -ArchivePath $PackageArchivePath -ExpectedAssetSha256 $AssetSha256
}

$RootExisted = Test-Path -LiteralPath $HandoffRoot -PathType Container
$ResolvedHandoffRoot = if ($RootExisted) { (Resolve-Path -LiteralPath $HandoffRoot).Path } else { [IO.Path]::GetFullPath($HandoffRoot) }
if ([string]::IsNullOrWhiteSpace((Split-Path -Leaf $ResolvedHandoffRoot))) { throw 'Unsafe HandoffRoot.' }
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
  $BackupRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AgenticPipeline\Backups\ContextHandoff'
}
$ResolvedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
if (Test-PathWithin -Root $ResolvedHandoffRoot -Candidate $ResolvedBackupRoot) {
  throw 'BackupRoot must be external to HandoffRoot.'
}
$ResolvedHooksPath = [IO.Path]::GetFullPath($HooksPath)

if ([string]::IsNullOrWhiteSpace($PythonwPath)) {
  $PythonwCommand = Get-Command pythonw -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($PythonwCommand) { $PythonwPath = $PythonwCommand.Source }
  else {
    $PythonCommand = Get-Command python -ErrorAction Stop | Select-Object -First 1
    $SiblingPythonw = Join-Path (Split-Path -Parent $PythonCommand.Source) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $SiblingPythonw -PathType Leaf)) { throw 'pythonw.exe is required for hidden background execution.' }
    $PythonwPath = $SiblingPythonw
  }
}
$ResolvedPythonw = (Resolve-Path -LiteralPath $PythonwPath).Path
if ((Split-Path -Leaf $ResolvedPythonw) -ine 'pythonw.exe') { throw 'PythonwPath must identify pythonw.exe; console Python is not allowed.' }
$Python = (Get-Command python -ErrorAction Stop | Select-Object -First 1).Source
$Wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $Wscript -PathType Leaf)) { throw "wscript.exe missing: $Wscript" }

$ExpectedSourceRecords = @($Attestation.source_files | ForEach-Object {
  $PackagePath = [string]$_.path
  if (-not $PackagePath.StartsWith('source/', [StringComparison]::Ordinal)) { throw "Invalid source attestation path: $PackagePath" }
  [pscustomobject]@{
    path = $PackagePath.Substring(7)
    package_path = $PackagePath
    size_bytes = [long]$_.size_bytes
    sha256 = [string]$_.sha256
  }
})
$ImmutableDirectoryNames = @($ExpectedSourceRecords | ForEach-Object {
  $Path = [string]$_.path
  if ($Path.Contains('/')) { $Path.Split('/')[0] }
} | Sort-Object -Unique)
$ImmutableRootFileNames = @($ExpectedSourceRecords | ForEach-Object {
  $Path = [string]$_.path
  if (-not $Path.Contains('/')) { $Path }
} | Sort-Object -Unique)

$ConfigSourcePath = Join-Path $PackageRoot 'source\handoff.config.example.json'
if (-not (Test-Path -LiteralPath $ConfigSourcePath -PathType Leaf)) { throw 'Package config template is missing.' }
$InstalledConfigPath = Join-Path $ResolvedHandoffRoot 'handoff.config.json'
$Config = if (Test-Path -LiteralPath $InstalledConfigPath -PathType Leaf) {
  Get-Content -LiteralPath $InstalledConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  Get-Content -LiteralPath $ConfigSourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
Set-ObjectProperty -Object $Config -Name 'version' -Value $EngineSchemaVersion
Set-ObjectProperty -Object $Config -Name 'engine_schema_version' -Value $EngineSchemaVersion
Set-ObjectProperty -Object $Config -Name 'ecosystem_version' -Value $EcosystemVersion
Set-ObjectProperty -Object $Config -Name 'local_root' -Value $ResolvedHandoffRoot
Set-ObjectProperty -Object $Config -Name 'additional_authority_paths' -Value ([string[]]$SafeAuthorityPaths)
$Privacy = Get-OptionalProperty -Object $Config -Name 'privacy' -Default $null
if ($null -eq $Privacy) {
  $Privacy = [pscustomobject]@{ fail_closed_patterns = @(); raw_biometrics_excluded = $true }
  Set-ObjectProperty -Object $Config -Name 'privacy' -Value $Privacy
}
$ExistingPrivacyPatterns = @(Get-OptionalProperty -Object $Privacy -Name 'fail_closed_patterns' -Default @())
$MergedPrivacyPatterns = @($ExistingPrivacyPatterns + $RequiredPrivacyPatterns | ForEach-Object { [string]$_ } | Sort-Object -Unique)
Set-ObjectProperty -Object $Privacy -Name 'fail_closed_patterns' -Value ([string[]]$MergedPrivacyPatterns)
Set-ObjectProperty -Object $Privacy -Name 'raw_biometrics_excluded' -Value $true
$DesiredConfigText = ConvertTo-Utf8JsonText -Value $Config

$DeploymentRoot = Join-Path $ResolvedHandoffRoot '.deployment'
$LauncherPath = Join-Path $DeploymentRoot 'run_worker_hidden.vbs'
$WorkerScriptPath = Join-Path $ResolvedHandoffRoot 'src\run_ag_handoff_worker.py'
$VbsPython = $ResolvedPythonw.Replace('"', '""')
$VbsWorker = $WorkerScriptPath.Replace('"', '""')
$DesiredLauncherText = @"
' Generated by Agentic Context Handoff $EcosystemVersion. No console fallback.
Option Explicit
Dim shell, fso, pythonExe, workerScript, commandLine, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
pythonExe = "$VbsPython"
workerScript = "$VbsWorker"
If Not fso.FileExists(pythonExe) Then WScript.Quit 2
If Not fso.FileExists(workerScript) Then WScript.Quit 3
commandLine = """" & pythonExe & """ -B -X utf8 """ & workerScript & """"
exitCode = shell.Run(commandLine, 0, True)
WScript.Quit exitCode
"@
$DesiredLauncherText = $DesiredLauncherText.Replace("`r`n", "`n")

$TaskDescriptor = [ordered]@{
  schema_version = '1.0.0'
  ecosystem_version = $EcosystemVersion
  task_name = $TaskName
  execute = $Wscript
  arguments = '"' + $LauncherPath + '"'
  working_directory = $ResolvedHandoffRoot
  repetition_interval = 'PT1M'
  execution_time_limit = 'PT5M'
  multiple_instances = 'IgnoreNew'
  hidden = $true
}
$DesiredTaskDescriptorText = ConvertTo-Utf8JsonText -Value $TaskDescriptor
$TaskDescriptorPath = Join-Path $DeploymentRoot 'TASK_DEFINITION.json'

$InstalledSourceManifest = [ordered]@{
  schema_version = '1.0.0'
  ecosystem_version = $EcosystemVersion
  component = 'context_handoff_installed_source'
  engine_schema_version = $EngineSchemaVersion
  source_commit = [string]$Version.source_commit
  source_tree_dirty = [bool]$Version.source_tree_dirty
  release_asset_sha256 = $NormalizedAssetSha256
  package_manifest_sha256 = Get-Sha256 -Path (Join-Path $PackageRoot 'MANIFEST.json')
  source_payload_sha256 = [string]$Attestation.source_payload_sha256
  explicit_exclusions = $ExplicitExclusions
  source_files = @($ExpectedSourceRecords | ForEach-Object {
    [ordered]@{ path = [string]$_.path; size_bytes = [long]$_.size_bytes; sha256 = [string]$_.sha256 }
  })
}
$DesiredSourceManifestText = ConvertTo-Utf8JsonText -Value $InstalledSourceManifest
$InstalledSourceManifestPath = Join-Path $DeploymentRoot 'SOURCE_INSTALLATION_MANIFEST.json'

$HooksObject = if (Test-Path -LiteralPath $ResolvedHooksPath -PathType Leaf) {
  Get-Content -LiteralPath $ResolvedHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { [pscustomobject]@{} }
$HookPython = $ResolvedPythonw.Replace('\', '/')
$HookScript = $WorkerScriptPath.Replace('run_ag_handoff_worker.py', 'enqueue_ag_handoff.py').Replace('\', '/')
$HookCommand = '"' + $HookPython + '" "' + $HookScript + '"'
$HookDefinition = [ordered]@{
  enabled = $true
  Stop = @([ordered]@{ type = 'command'; command = $HookCommand; timeout = 15 })
}
Set-ObjectProperty -Object $HooksObject -Name 'companion-handoff-on-stop' -Value $HookDefinition
$DesiredHooksText = ConvertTo-Utf8JsonText -Value $HooksObject

$Changes = [Collections.Generic.List[string]]::new()
$CurrentImmutable = if ($RootExisted) {
  Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
} else { @() }
$CurrentByPath = @{}
foreach ($Record in $CurrentImmutable) { $CurrentByPath[[string]$Record.path] = $Record }
$ExpectedByPath = @{}
foreach ($Record in $ExpectedSourceRecords) { $ExpectedByPath[[string]$Record.path] = $Record }
foreach ($Expected in $ExpectedSourceRecords) {
  $Current = $CurrentByPath[[string]$Expected.path]
  if ($null -eq $Current -or [string]$Current.sha256 -cne [string]$Expected.sha256 -or [long]$Current.size_bytes -ne [long]$Expected.size_bytes) {
    [void]$Changes.Add("immutable:$($Expected.path)")
  }
}
foreach ($Current in $CurrentImmutable) {
  if (-not $ExpectedByPath.ContainsKey([string]$Current.path)) { [void]$Changes.Add("remove-extra:$($Current.path)") }
}

$DesiredTextFiles = [ordered]@{
  $InstalledConfigPath = $DesiredConfigText
  $LauncherPath = $DesiredLauncherText
  $TaskDescriptorPath = $DesiredTaskDescriptorText
  $InstalledSourceManifestPath = $DesiredSourceManifestText
  $ResolvedHooksPath = $DesiredHooksText
}
foreach ($Pair in $DesiredTextFiles.GetEnumerator()) {
  $CurrentText = if (Test-Path -LiteralPath $Pair.Key -PathType Leaf) { Get-Content -LiteralPath $Pair.Key -Raw -Encoding UTF8 } else { $null }
  if ($null -eq $CurrentText -or $CurrentText -cne [string]$Pair.Value) { [void]$Changes.Add("text:$($Pair.Key)") }
}
if ($TaskMode -eq 'Register' -and -not (Test-TaskDefinitionMatches -Name $TaskName -Descriptor ([pscustomobject]$TaskDescriptor))) {
  [void]$Changes.Add("task:$TaskName")
}
$Changes = [Collections.Generic.List[string]]::new([string[]]@($Changes | Sort-Object -Unique))

$Plan = [ordered]@{
  status = if ($Changes.Count -eq 0) { 'ALREADY_DESIRED' } else { 'CHANGES_REQUIRED' }
  apply = [bool]$Apply
  ecosystem_version = $EcosystemVersion
  source_commit = [string]$Version.source_commit
  source_tree_dirty = [bool]$Version.source_tree_dirty
  release_asset_sha256 = $NormalizedAssetSha256
  source_payload_sha256 = [string]$Attestation.source_payload_sha256
  handoff_root = $ResolvedHandoffRoot
  backup_root = $ResolvedBackupRoot
  hooks_path = $ResolvedHooksPath
  task_name = $TaskName
  task_mode = $TaskMode
  changes = [string[]]@($Changes)
  safe_authority_paths = $SafeAuthorityPaths
  excluded_files = $ExplicitExclusions
}
if (-not $Apply) {
  $Plan | ConvertTo-Json -Depth 20
  exit 0
}

$BackupPath = $null
$TaskExisted = $false
$TaskXml = $null
$TaskSnapshotCaptured = $false
$TaskOriginalEnabled = $false
$TaskOriginalState = $null
$TaskWasRunning = $false
$TaskQuiesced = $false
$PreImmutable = @($CurrentImmutable)
$PreDeploymentFiles = @()
$PreConfigExisted = Test-Path -LiteralPath $InstalledConfigPath -PathType Leaf
$PreHooksExisted = Test-Path -LiteralPath $ResolvedHooksPath -PathType Leaf

function Restore-Transaction {
  param([Parameter(Mandatory = $true)][string]$TransactionBackup)
  $RollbackErrors = [Collections.Generic.List[string]]::new()
  try {
    $Current = Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
    foreach ($File in $Current) {
      if (Test-Path -LiteralPath $File.full_path -PathType Leaf) { Remove-Item -LiteralPath $File.full_path -Force }
    }
    $OriginalInstall = Join-Path $TransactionBackup 'original\installation'
    if (Test-Path -LiteralPath $OriginalInstall -PathType Container) {
      foreach ($File in Get-ChildItem -LiteralPath $OriginalInstall -File -Recurse -Force) {
        $Relative = Get-RelativeForwardPath -BasePath $OriginalInstall -Path $File.FullName
        $Target = Join-Path $ResolvedHandoffRoot $Relative.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
        Copy-Item -LiteralPath $File.FullName -Destination $Target -Force
      }
    }
  }
  catch { [void]$RollbackErrors.Add("immutable:$($_.Exception.Message)") }

  try {
    if (Test-Path -LiteralPath $InstalledConfigPath -PathType Leaf) { Remove-Item -LiteralPath $InstalledConfigPath -Force }
    $BackupConfig = Join-Path $TransactionBackup 'original\handoff.config.json'
    if (Test-Path -LiteralPath $BackupConfig -PathType Leaf) { Copy-Item -LiteralPath $BackupConfig -Destination $InstalledConfigPath -Force }
  }
  catch { [void]$RollbackErrors.Add("config:$($_.Exception.Message)") }

  try {
    if (Test-Path -LiteralPath $DeploymentRoot -PathType Container) {
      foreach ($File in Get-ChildItem -LiteralPath $DeploymentRoot -File -Recurse -Force) { Remove-Item -LiteralPath $File.FullName -Force }
    }
    $BackupDeployment = Join-Path $TransactionBackup 'original\deployment'
    if (Test-Path -LiteralPath $BackupDeployment -PathType Container) {
      foreach ($File in Get-ChildItem -LiteralPath $BackupDeployment -File -Recurse -Force) {
        $Relative = Get-RelativeForwardPath -BasePath $BackupDeployment -Path $File.FullName
        $Target = Join-Path $DeploymentRoot $Relative.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
        Copy-Item -LiteralPath $File.FullName -Destination $Target -Force
      }
    }
  }
  catch { [void]$RollbackErrors.Add("deployment:$($_.Exception.Message)") }

  try {
    if (Test-Path -LiteralPath $ResolvedHooksPath -PathType Leaf) { Remove-Item -LiteralPath $ResolvedHooksPath -Force }
    $BackupHooks = Join-Path $TransactionBackup 'original\hooks.json'
    if (Test-Path -LiteralPath $BackupHooks -PathType Leaf) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResolvedHooksPath) | Out-Null
      Copy-Item -LiteralPath $BackupHooks -Destination $ResolvedHooksPath -Force
    }
  }
  catch { [void]$RollbackErrors.Add("hooks:$($_.Exception.Message)") }

  if ($TaskMode -eq 'Register' -and $TaskSnapshotCaptured) {
    try {
      if ($TaskExisted -and -not [string]::IsNullOrWhiteSpace($TaskXml)) {
        Register-ScheduledTask -TaskName $TaskName -Xml $TaskXml -Force | Out-Null
        if ($TaskOriginalEnabled) { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
        if ($TaskWasRunning) { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
        $RestoredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ([bool]$RestoredTask.Settings.Enabled -ne $TaskOriginalEnabled) {
          throw "Scheduled task enabled state was not restored: $TaskName"
        }
        $RestoredXml = Export-ScheduledTask -TaskName $TaskName
        if ((Get-NormalizedTaskXml -Xml $RestoredXml) -cne (Get-NormalizedTaskXml -Xml $TaskXml)) {
          throw "Scheduled task XML was not restored exactly: $TaskName"
        }
      }
      else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
      }
    }
    catch { [void]$RollbackErrors.Add("task:$($_.Exception.Message)") }
  }
  $RollbackResult = [ordered]@{ status = if ($RollbackErrors.Count -eq 0) { 'PASS' } else { 'FAIL' }; errors = [string[]]$RollbackErrors }
  Write-AtomicText -Path (Join-Path $TransactionBackup 'ROLLBACK_RESULT.json') -Text (ConvertTo-Utf8JsonText -Value $RollbackResult)
  if ($RollbackErrors.Count -gt 0) { throw "Rollback incomplete: $($RollbackErrors -join ' | ')" }
}

if ($Changes.Count -eq 0) {
  $Before = Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
  for ($Run = 1; $Run -le 2; $Run++) {
    $null = Test-InstalledSource -Root $ResolvedHandoffRoot -ExpectedRecords $ExpectedSourceRecords -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames -Python $Python
    $After = Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
    if (($Before | ConvertTo-Json -Depth 10 -Compress) -cne ($After | ConvertTo-Json -Depth 10 -Compress)) {
      throw "Installed source changed during idempotent validation run $Run."
    }
  }
  if ($TaskMode -eq 'Register') {
    $TaskState = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    if ([string]$TaskState.State -ne 'Ready' -or [int]$TaskInfo.LastTaskResult -ne 0) {
      throw "Context Handoff task is not healthy on idempotent apply. State=$($TaskState.State) LastTaskResult=$($TaskInfo.LastTaskResult)"
    }
  }
  [ordered]@{
    status = 'PASS'
    ecosystem_version = $EcosystemVersion
    source_commit = [string]$Version.source_commit
    release_asset_sha256 = $NormalizedAssetSha256
    source_payload_sha256 = [string]$Attestation.source_payload_sha256
    handoff_root = $ResolvedHandoffRoot
    changes_applied = 0
    backup_created = $false
    validation_runs = 2
    idempotent = $true
  } | ConvertTo-Json -Depth 20 -Compress
  exit 0
}

try {
  New-Item -ItemType Directory -Force -Path $ResolvedBackupRoot | Out-Null
  $BackupPath = Join-Path $ResolvedBackupRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
  if (Test-PathWithin -Root $ResolvedHandoffRoot -Candidate $BackupPath) { throw 'Transaction backup resolved inside HandoffRoot.' }
  New-Item -ItemType Directory -Force -Path (Join-Path $BackupPath 'original\installation') | Out-Null

  if ($TaskMode -eq 'Register') {
    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $TaskExisted = $null -ne $ExistingTask
    if ($TaskExisted) {
      $TaskXml = Export-ScheduledTask -TaskName $TaskName
      $TaskOriginalEnabled = [bool]$ExistingTask.Settings.Enabled
      $TaskOriginalState = [string]$ExistingTask.State
      $TaskWasRunning = $TaskOriginalState -eq 'Running'
      [IO.File]::WriteAllText((Join-Path $BackupPath 'original\task.xml'), $TaskXml, $Utf8NoBom)
    }
    Write-AtomicText -Path (Join-Path $BackupPath 'original\task_state.json') -Text (ConvertTo-Utf8JsonText -Value ([ordered]@{
      task_existed = $TaskExisted
      enabled = if ($TaskExisted) { $TaskOriginalEnabled } else { $null }
      state = $TaskOriginalState
    }))
    $TaskSnapshotCaptured = $true
    if ($TaskExisted) {
      Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
      $DisabledTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      if ([string]$DisabledTask.State -in @('Running', 'Queued')) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      }
      $null = Wait-TaskQuiesced -Name $TaskName
    }
    $TaskQuiesced = $true
    $PreImmutable = @(Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames)
  }

  foreach ($File in $PreImmutable) {
    $Destination = Join-Path $BackupPath ('original\installation\' + ([string]$File.path).Replace('/', '\'))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $File.full_path -Destination $Destination
  }
  if ($PreConfigExisted) { Copy-Item -LiteralPath $InstalledConfigPath -Destination (Join-Path $BackupPath 'original\handoff.config.json') }
  if (Test-Path -LiteralPath $DeploymentRoot -PathType Container) {
    $PreDeploymentFiles = @(Get-ChildItem -LiteralPath $DeploymentRoot -File -Recurse -Force)
    foreach ($File in $PreDeploymentFiles) {
      $Relative = Get-RelativeForwardPath -BasePath $DeploymentRoot -Path $File.FullName
      $Destination = Join-Path $BackupPath ('original\deployment\' + $Relative.Replace('/', '\'))
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
      Copy-Item -LiteralPath $File.FullName -Destination $Destination
    }
  }
  if ($PreHooksExisted) {
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupPath 'original') | Out-Null
    Copy-Item -LiteralPath $ResolvedHooksPath -Destination (Join-Path $BackupPath 'original\hooks.json')
  }
  $PreState = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    handoff_root_existed = $RootExisted
    config_existed = $PreConfigExisted
    hooks_existed = $PreHooksExisted
    task_existed = $TaskExisted
    task_enabled = if ($TaskExisted) { $TaskOriginalEnabled } else { $null }
    task_state = $TaskOriginalState
    task_quiesced_before_write = $TaskQuiesced
    immutable_files = @($PreImmutable | ForEach-Object { [ordered]@{ path = $_.path; size_bytes = $_.size_bytes; sha256 = $_.sha256 } })
    deployment_files = @($PreDeploymentFiles | ForEach-Object { Get-RelativeForwardPath -BasePath $DeploymentRoot -Path $_.FullName })
  }
  [IO.File]::WriteAllText((Join-Path $BackupPath 'PRE_STATE.json'), (ConvertTo-Utf8JsonText -Value $PreState), $Utf8NoBom)

  if ($TaskMode -eq 'Register') {
    Assert-TaskQuiescedBeforeWrite -Name $TaskName -ExistedAtSnapshot $TaskExisted
  }
  New-Item -ItemType Directory -Force -Path $ResolvedHandoffRoot | Out-Null
  foreach ($Expected in $ExpectedSourceRecords) {
    $Source = Join-Path $PackageRoot ([string]$Expected.package_path).Replace('/', '\')
    $Destination = Join-Path $ResolvedHandoffRoot ([string]$Expected.path).Replace('/', '\')
    $NeedsWrite = -not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Get-Sha256 -Path $Destination) -cne [string]$Expected.sha256
    if ($NeedsWrite) { Write-AtomicBytes -Path $Destination -Bytes ([IO.File]::ReadAllBytes($Source)) }
  }
  foreach ($Current in $PreImmutable) {
    if (-not $ExpectedByPath.ContainsKey([string]$Current.path) -and (Test-Path -LiteralPath $Current.full_path -PathType Leaf)) {
      if (-not (Test-PathWithin -Root $ResolvedHandoffRoot -Candidate $Current.full_path)) { throw "Refusing to move extra file outside HandoffRoot: $($Current.full_path)" }
      $RemovedDestination = Join-Path $BackupPath ('removed-active\' + ([string]$Current.path).Replace('/', '\'))
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $RemovedDestination) | Out-Null
      Move-Item -LiteralPath $Current.full_path -Destination $RemovedDestination
    }
  }
  Write-AtomicText -Path $InstalledConfigPath -Text $DesiredConfigText
  Write-AtomicText -Path $LauncherPath -Text $DesiredLauncherText
  Write-AtomicText -Path $TaskDescriptorPath -Text $DesiredTaskDescriptorText
  Write-AtomicText -Path $InstalledSourceManifestPath -Text $DesiredSourceManifestText

  if ($SimulateFailureAfterFileInstall) { throw 'SIMULATED_CONTEXT_HANDOFF_INSTALL_FAILURE' }

  $ImmutableBeforeTests = Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
  for ($Run = 1; $Run -le 2; $Run++) {
    $null = Test-InstalledSource -Root $ResolvedHandoffRoot -ExpectedRecords $ExpectedSourceRecords -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames -Python $Python
    $ImmutableAfterTest = Get-InstalledImmutableFiles -Root $ResolvedHandoffRoot -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames
    if (($ImmutableBeforeTests | ConvertTo-Json -Depth 10 -Compress) -cne ($ImmutableAfterTest | ConvertTo-Json -Depth 10 -Compress)) {
      throw "Installed immutable source changed during validation run $Run."
    }
  }

  Write-AtomicText -Path $ResolvedHooksPath -Text $DesiredHooksText

  if ($TaskMode -eq 'Register') {
    if (-not (Test-TaskDefinitionMatches -Name $TaskName -Descriptor ([pscustomobject]$TaskDescriptor))) {
      $Action = New-ScheduledTaskAction -Execute $Wscript -Argument $TaskDescriptor.arguments -WorkingDirectory $ResolvedHandoffRoot
      $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
      $Settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -StartWhenAvailable
      Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Description "Agentic Context Handoff $EcosystemVersion queue worker (hidden)." -Force | Out-Null
      Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
    if (-not (Test-TaskDefinitionMatches -Name $TaskName -Descriptor ([pscustomobject]$TaskDescriptor))) {
      throw 'Scheduled task definition does not match the installed Context Handoff source.'
    }
    $DesiredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if (-not [bool]$DesiredTask.Settings.Enabled -or [string]$DesiredTask.State -ne 'Ready') {
      throw "Scheduled task is not enabled and Ready after Context Handoff activation. State=$($DesiredTask.State) Enabled=$([bool]$DesiredTask.Settings.Enabled)"
    }
    if (-not $SkipTaskCanary) {
      Start-ScheduledTask -TaskName $TaskName
      $Deadline = (Get-Date).AddSeconds(30)
      do {
        Start-Sleep -Milliseconds 500
        $TaskState = Get-ScheduledTask -TaskName $TaskName
      } while ([string]$TaskState.State -eq 'Running' -and (Get-Date) -lt $Deadline)
      $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
      if ([string]$TaskState.State -ne 'Ready' -or [int]$TaskInfo.LastTaskResult -ne 0) {
        throw "Context Handoff task canary failed. State=$($TaskState.State) LastTaskResult=$($TaskInfo.LastTaskResult)"
      }
    }
  }

  $FinalRecords = Test-InstalledSource -Root $ResolvedHandoffRoot -ExpectedRecords $ExpectedSourceRecords -DirectoryNames $ImmutableDirectoryNames -RootFileNames $ImmutableRootFileNames -Python $Python
  $FinalDigest = Get-RecordSetDigest -Records @($FinalRecords | ForEach-Object {
    [pscustomobject]@{ path = 'source/' + [string]$_.path; size_bytes = $_.size_bytes; sha256 = $_.sha256 }
  })
  if ($FinalDigest -cne [string]$Attestation.source_payload_sha256) { throw 'Final installed source digest mismatch.' }

  $InstallationReport = [ordered]@{
    schema_version = '1.0.0'
    status = 'PASS'
    ecosystem_version = $EcosystemVersion
    engine_schema_version = $EngineSchemaVersion
    source_commit = [string]$Version.source_commit
    source_tree_dirty = [bool]$Version.source_tree_dirty
    release_asset_sha256 = $NormalizedAssetSha256
    package_manifest_sha256 = Get-Sha256 -Path (Join-Path $PackageRoot 'MANIFEST.json')
    source_payload_sha256 = [string]$Attestation.source_payload_sha256
    installed_source_sha256 = $FinalDigest
    installed_source_files = $ExpectedSourceRecords.Count
    handoff_root = $ResolvedHandoffRoot
    backup_path = $BackupPath
    hooks_path = $ResolvedHooksPath
    hook_command_sha256 = Get-BytesSha256 -Bytes $Utf8NoBom.GetBytes($HookCommand)
    task_name = $TaskName
    task_mode = $TaskMode
    task_quiesced_before_write = $TaskQuiesced
    task_action = $Wscript
    task_arguments = $TaskDescriptor.arguments
    safe_authority_paths = $SafeAuthorityPaths
    explicit_exclusions = $ExplicitExclusions
    mutable_paths_preserved = @('handoff.config.json', 'queue', 'state', 'logs', 'handoffs', 'release')
    validation_runs = 2
    installed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  $InstallationReportPath = Join-Path $DeploymentRoot 'INSTALLATION_REPORT.json'
  Write-AtomicText -Path $InstallationReportPath -Text (ConvertTo-Utf8JsonText -Value $InstallationReport)
  Write-AtomicText -Path (Join-Path $BackupPath 'TRANSACTION_COMMITTED.json') -Text (ConvertTo-Utf8JsonText -Value ([ordered]@{
    status = 'PASS'; ecosystem_version = $EcosystemVersion; handoff_root = $ResolvedHandoffRoot; committed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }))

  [ordered]@{
    status = 'PASS'
    ecosystem_version = $EcosystemVersion
    source_commit = [string]$Version.source_commit
    release_asset_sha256 = $NormalizedAssetSha256
    source_payload_sha256 = [string]$Attestation.source_payload_sha256
    handoff_root = $ResolvedHandoffRoot
    backup_path = $BackupPath
    changes_applied = $Changes.Count
    validation_runs = 2
    idempotent = $false
    task_mode = $TaskMode
    task_quiesced_before_write = $TaskQuiesced
  } | ConvertTo-Json -Depth 20 -Compress
}
catch {
  $Failure = $_
  if ($BackupPath -and (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    try { Restore-Transaction -TransactionBackup $BackupPath }
    catch { throw "Context Handoff update failed: $($Failure.Exception.Message). Rollback also failed: $($_.Exception.Message)" }
  }
  throw $Failure
}
