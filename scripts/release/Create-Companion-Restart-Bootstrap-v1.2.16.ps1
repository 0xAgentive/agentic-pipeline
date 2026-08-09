[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [string]$PipelineRepo = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutputRoot = '',
  [Parameter(Mandatory = $true)][string]$HandoffArchive,
  [Parameter(Mandatory = $true)][string]$CompanionAsset,
  [string]$DeploymentManifest = '',
  [string]$LogicalName = '',
  [string]$ProjectId = '',
  [int]$MaxTotalMB = 40,
  [int]$MaxFileMB = 10,
  [switch]$AllowDirtyPipeline,
  [switch]$OpenFolder
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$EcosystemVersion = '1.2.16'

function Get-AbsolutePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [IO.Path]::GetFullPath($Path)
}

function Test-SamePath {
  param(
    [Parameter(Mandatory = $true)][string]$Left,
    [Parameter(Mandatory = $true)][string]$Right
  )
  return [string]::Equals(
    (Get-AbsolutePath -Path $Left).TrimEnd('\', '/'),
    (Get-AbsolutePath -Path $Right).TrimEnd('\', '/'),
    [StringComparison]::OrdinalIgnoreCase
  )
}

function Assert-SafeOutputLeaf {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$ProtectedPaths
  )
  if ($Path.IndexOfAny([char[]]'*?[]') -ge 0) { throw "Output path contains wildcard characters: $Path" }
  $Full = Get-AbsolutePath -Path $Path
  $Root = [IO.Path]::GetPathRoot($Full)
  $Parent = Split-Path -Parent $Full
  $Leaf = Split-Path -Leaf $Full
  if ([string]::IsNullOrWhiteSpace($Leaf) -or (Test-SamePath -Left $Full -Right $Root) -or (Test-SamePath -Left $Parent -Right $Root)) {
    throw "Output must be a leaf below a non-root parent: $Full"
  }
  foreach ($Protected in $ProtectedPaths) {
    if ([string]::IsNullOrWhiteSpace($Protected)) { continue }
    $ProtectedFull = (Get-AbsolutePath -Path $Protected).TrimEnd('\', '/')
    $Candidate = $Full.TrimEnd('\', '/')
    if ([string]::Equals($Candidate, $ProtectedFull, [StringComparison]::OrdinalIgnoreCase) -or
        $ProtectedFull.StartsWith($Candidate + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Output path is a protected path or its ancestor: $Full"
    }
  }
  $Probe = $Full
  while (-not [string]::IsNullOrWhiteSpace($Probe)) {
    if (Test-Path -LiteralPath $Probe) {
      $Item = Get-Item -LiteralPath $Probe -Force
      if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Output path must not traverse a reparse point: $Probe" }
      if ((Test-SamePath -Left $Probe -Right $Full) -and -not $Item.PSIsContainer) { throw "Output path exists and is not a directory: $Full" }
    }
    $Next = Split-Path -Parent $Probe
    if ([string]::IsNullOrWhiteSpace($Next) -or (Test-SamePath -Left $Next -Right $Probe)) { break }
    $Probe = $Next
  }
  return $Full
}

function Remove-SafeTemporaryDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$LeafPrefix
  )
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $Full = Get-AbsolutePath -Path $Path
  $TempRoot = (Get-AbsolutePath -Path ([IO.Path]::GetTempPath())).TrimEnd('\', '/')
  $Leaf = Split-Path -Leaf $Full
  if (-not $Full.StartsWith($TempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
      -not $Leaf.StartsWith($LeafPrefix, [StringComparison]::Ordinal)) {
    throw "Refusing to remove unexpected temporary directory: $Full"
  }
  Remove-Item -LiteralPath $Full -Recurse -Force
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  Ensure-Directory -Path (Split-Path -Parent $Path)
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-Utf8FileAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $Parent = Split-Path -Parent $Path
  Ensure-Directory -Path $Parent
  $Temporary = Join-Path $Parent ('.' + (Split-Path -Leaf $Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($Temporary, $Text, $Utf8NoBom)
    [IO.File]::Move($Temporary, $Path, $true)
  }
  finally { if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force } }
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
  param([Parameter(Mandatory = $true)][string]$Text)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($Hasher.ComputeHash($Utf8NoBom.GetBytes($Text))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Get-BytesSha256 {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($Hasher.ComputeHash($Bytes)).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Read-JsonMap {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

function Get-MapValue {
  param(
    [Parameter(Mandatory = $true)]$Map,
    [Parameter(Mandatory = $true)][string]$Key,
    $Default = $null
  )
  if ($Map -is [Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }
  return $Default
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList
  )
  $Command = Get-Command $FilePath -ErrorAction Stop | Select-Object -First 1
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $Command.Source
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = $Utf8NoBom
  $StartInfo.StandardErrorEncoding = $Utf8NoBom
  foreach ($Argument in $ArgumentList) { [void]$StartInfo.ArgumentList.Add($Argument) }
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  if (-not $Process.Start()) { throw "Failed to start native command: $FilePath" }
  $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
  $StderrTask = $Process.StandardError.ReadToEndAsync()
  $Process.WaitForExit()
  $Stdout = $StdoutTask.GetAwaiter().GetResult()
  $Stderr = $StderrTask.GetAwaiter().GetResult()
  $ExitCode = $Process.ExitCode
  $Process.Dispose()
  return [pscustomobject]@{ ExitCode = $ExitCode; Stdout = $Stdout; Stderr = $Stderr }
}

function Invoke-GitCapture {
  param(
    [Parameter(Mandatory = $true)][string]$GitRoot,
    [Parameter(Mandatory = $true)][string[]]$GitArguments
  )
  $Result = Invoke-NativeCapture -FilePath 'git' -ArgumentList (@('-C', $GitRoot) + $GitArguments)
  if ($Result.ExitCode -ne 0) { throw "git failed (exit $($Result.ExitCode)): $($Result.Stderr.Trim())" }
  return $Result
}

function Get-GitSnapshot {
  param([Parameter(Mandatory = $true)][string]$GitRoot)
  $Top = (Invoke-GitCapture -GitRoot $GitRoot -GitArguments @('rev-parse', '--show-toplevel')).Stdout.Trim()
  $Head = (Invoke-GitCapture -GitRoot $GitRoot -GitArguments @('rev-parse', 'HEAD')).Stdout.Trim()
  $BranchResult = Invoke-GitCapture -GitRoot $GitRoot -GitArguments @('branch', '--show-current')
  $StatusResult = Invoke-GitCapture -GitRoot $GitRoot -GitArguments @('status', '--porcelain=v2', '-z', '--untracked-files=all')
  $StatusBytes = $Utf8NoBom.GetBytes($StatusResult.Stdout)
  $RecordCount = 0
  foreach ($Byte in $StatusBytes) { if ($Byte -eq 0) { $RecordCount++ } }
  return [ordered]@{
    requested_root = $GitRoot
    git_root = $Top
    branch = $BranchResult.Stdout.Trim()
    head = $Head
    status_format = 'porcelain_v2_z_base64_utf8'
    status_record_count = $RecordCount
    status_base64 = [Convert]::ToBase64String($StatusBytes)
    stderr = [ordered]@{
      top = (Invoke-GitCapture -GitRoot $GitRoot -GitArguments @('rev-parse', '--show-toplevel')).Stderr.Trim()
      branch = $BranchResult.Stderr.Trim()
      status = $StatusResult.Stderr.Trim()
    }
  }
}

function Assert-SafeRelativePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $Normalized = $RelativePath.Replace('\', '/')
  if ([IO.Path]::IsPathRooted($RelativePath) -or $Normalized.StartsWith('/') -or $Normalized -match '(^|/)\.\.(/|$)') {
    throw "Unsafe relative path: $RelativePath"
  }
  return $Normalized
}

function Assert-NoSecretLiteral {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $Name = [IO.Path]::GetFileName($Path)
  if ($Name -match '^(ACTION_BRIDGE_CAPABILITY|ACTION_PACKET)\.json$' -or $Name -match '^AGENTIC_ACTION_PACKET_.*\.json$' -or $Name -match '^\.env' -or
      $Name -match '(?i)(access[_-]?token|refresh[_-]?token|client[_-]?secret|private[_-]?key|cookie)') {
    throw "Forbidden secret or raw packet file selected for bootstrap: $Name"
  }
  $InspectionText = $Text.Replace('\"', '"')
  if (($InspectionText -match '(?i)"packet_id"\s*:' -and
       $InspectionText -match '(?i)"technical_task_markdown"\s*:' -and
       $InspectionText -match '(?i)"owner_summary_ru"\s*:') -or
      $InspectionText -match '(?i)"capability_token"\s*:\s*"[^"]+"') {
    throw "Raw Action Packet or capability material detected in selected bootstrap input: $Path"
  }
  $SecretPatterns = @(
    '(?i)"capability_token"\s*:\s*"[0-9a-f]{64}"',
    '(?i)"(?:access_token|refresh_token|client_secret|api_key|password|private_key)"\s*:\s*"[^"\r\n]+"',
    '(?i)\bgh[pousr]_[A-Za-z0-9_]{20,}\b',
    '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '\bAKIA[0-9A-Z]{16}\b',
    '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}'
  )
  foreach ($Pattern in $SecretPatterns) {
    if ($Text -match $Pattern) { throw "Secret-like literal detected in selected bootstrap input: $Path" }
  }
}

function Add-AllowlistedTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Category,
    [switch]$Required
  )
  $SafeRelative = Assert-SafeRelativePath -RelativePath $RelativePath
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    if ($Required) { throw "Required bootstrap input is missing: $Source" }
    $script:Excluded += , [ordered]@{ path = $SafeRelative; category = $Category; reason = 'not_present' }
    return
  }
  $Item = Get-Item -LiteralPath $Source
  if ($Item.Length -gt $script:MaxFileBytes) { throw "Selected bootstrap input exceeds MaxFileMB: $Source" }
  if (($script:TotalBytes + $Item.Length) -gt $script:MaxTotalBytes) { throw "Selected bootstrap inputs exceed MaxTotalMB at: $Source" }
  $Extension = [IO.Path]::GetExtension($Source).ToLowerInvariant()
  if ($Extension -notin @('.md', '.txt', '.json', '.jsonl', '.ndjson', '.cjs')) { throw "Non-text file selected for bootstrap: $Source" }
  $Text = Get-Content -LiteralPath $Source -Raw -Encoding UTF8
  Assert-NoSecretLiteral -Path $Source -Text $Text
  $Destination = Join-Path $script:StageRoot $SafeRelative
  Write-Utf8File -Path $Destination -Text $Text
  $Hash = Get-Sha256 -Path $Destination
  $script:TotalBytes += (Get-Item -LiteralPath $Destination).Length
  $script:Included += , [ordered]@{ path = $SafeRelative; category = $Category; size_bytes = (Get-Item -LiteralPath $Destination).Length; sha256 = $Hash }
}

function Test-ZipSafety {
  param([Parameter(Mandatory = $true)][string]$ArchivePath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $Entries = @($Archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    if ($Entries.Count -lt 1) { throw "ZIP is empty: $ArchivePath" }
    $Names = @($Entries | ForEach-Object { $_.FullName })
    $CaseFolded = @($Names | ForEach-Object { $_.ToLowerInvariant() })
    if (@($CaseFolded | Sort-Object -Unique).Count -ne $CaseFolded.Count) { throw "ZIP contains duplicate or case-colliding paths: $ArchivePath" }
    foreach ($Name in $Names) {
      if ($Name.Contains('\') -or $Name.StartsWith('/') -or $Name -match '^[A-Za-z]:' -or $Name -match '(^|/)\.\.(/|$)') {
        throw "ZIP contains an unsafe path: $Name"
      }
    }
  }
  finally { $Archive.Dispose() }
}

function Test-ExporterManifest {
  param(
    [Parameter(Mandatory = $true)][string]$ExtractRoot,
    [Parameter(Mandatory = $true)][string]$HandoffRoot
  )
  $ManifestPath = Join-Path $HandoffRoot 'MANIFEST.json'
  $ValidationPath = Join-Path $HandoffRoot 'MANIFEST_VALIDATION.json'
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ValidationPath -PathType Leaf)) {
    throw 'Exact exporter archive is missing its manifest or validation receipt.'
  }
  $Manifest = Read-JsonMap -Path $ManifestPath
  $Validation = Read-JsonMap -Path $ValidationPath
  $Declared = Get-MapValue -Map $Manifest -Key 'files'
  if ($Declared -isnot [Collections.IDictionary]) { throw 'Exact exporter MANIFEST.json files map is invalid.' }
  $SelfExcluded = @((Get-MapValue -Map $Manifest -Key 'self_excluded_files' -Default @()) | ForEach-Object { [string]$_ })
  $ExpectedSelfExcluded = @('MANIFEST.json', 'MANIFEST_VALIDATION.json')
  if ($SelfExcluded.Count -ne 2 -or (Compare-Object -CaseSensitive -ReferenceObject $ExpectedSelfExcluded -DifferenceObject $SelfExcluded)) {
    throw 'Exact exporter manifest has an unexpected self-excluded set.'
  }
  if ([int](Get-MapValue -Map $Manifest -Key 'file_count' -Default -1) -ne $Declared.Count) {
    throw 'Exact exporter manifest file_count does not match its files map.'
  }
  $DeclaredPaths = @()
  foreach ($Entry in $Declared.GetEnumerator()) {
    $Relative = Assert-SafeRelativePath -RelativePath ([string]$Entry.Key)
    if ($Relative -cne [string]$Entry.Key -or [string](Get-MapValue -Map $Entry.Value -Key 'file_path') -cne $Relative) {
      throw "Exact exporter manifest path identity mismatch: $($Entry.Key)"
    }
    $Full = Join-Path $HandoffRoot $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf) -or
        (Get-Item -LiteralPath $Full).Length -ne [int64](Get-MapValue -Map $Entry.Value -Key 'size') -or
        (Get-Sha256 -Path $Full) -ne [string](Get-MapValue -Map $Entry.Value -Key 'sha256')) {
      throw "Exact exporter manifest parity failure: $Relative"
    }
    $DeclaredPaths += $Relative
  }
  $ActualPaths = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File | ForEach-Object {
      $RelativeToHandoff = [IO.Path]::GetRelativePath($HandoffRoot, $_.FullName).Replace('\', '/')
      if ($RelativeToHandoff -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($RelativeToHandoff)) {
        throw "Exact exporter archive contains a member outside its handoff root: $($_.FullName)"
      }
      $RelativeToHandoff
    })
  $ExpectedPaths = @($DeclaredPaths + $ExpectedSelfExcluded)
  if ($ActualPaths.Count -ne $ExpectedPaths.Count -or
      (Compare-Object -CaseSensitive -ReferenceObject $ExpectedPaths -DifferenceObject $ActualPaths)) {
    throw 'Exact exporter archive member set differs from MANIFEST.json.'
  }
  if ([string](Get-MapValue -Map $Validation -Key 'manifest_verdict') -ne 'PASS' -or
      [int](Get-MapValue -Map $Validation -Key 'declared_file_count' -Default -1) -ne ($Declared.Count + 1) -or
      [int](Get-MapValue -Map $Validation -Key 'missing_file_count' -Default -1) -ne 0 -or
      [int](Get-MapValue -Map $Validation -Key 'mismatched_file_count' -Default -1) -ne 0) {
    throw 'Exact exporter manifest-validation receipt is inconsistent.'
  }
  $ManifestGeneration = [string](Get-MapValue -Map $Manifest -Key 'generation_id')
  $ValidationGeneration = [string](Get-MapValue -Map $Validation -Key 'generation_id')
  if (-not [string]::IsNullOrWhiteSpace($ManifestGeneration) -and $ManifestGeneration -ne $ValidationGeneration) {
    throw 'Exact exporter generation identity is inconsistent.'
  }
}

function Test-ExistingBootstrapArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$ExpectedInputIdentity,
    [Parameter(Mandatory = $true)][string]$CheckRoot
  )
  try {
    Test-ZipSafety -ArchivePath $ArchivePath
    Ensure-Directory -Path $CheckRoot
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $CheckRoot
    $ManifestPath = Join-Path $CheckRoot 'MANIFEST.json'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
    $Manifest = Read-JsonMap -Path $ManifestPath
    if ([string](Get-MapValue -Map $Manifest -Key 'artifact') -ne 'COMPANION_RESTART_BOOTSTRAP' -or
        [string](Get-MapValue -Map $Manifest -Key 'input_identity_sha256') -ne $ExpectedInputIdentity -or
        (Get-MapValue -Map $Manifest -Key 'publication_allowed') -ne $false) { return $false }
    $Declared = @(Get-MapValue -Map $Manifest -Key 'files' -Default @())
    $DeclaredPaths = @()
    foreach ($File in $Declared) {
      $Relative = Assert-SafeRelativePath -RelativePath ([string](Get-MapValue -Map $File -Key 'path'))
      if ($DeclaredPaths -contains $Relative) { return $false }
      $DeclaredPaths += $Relative
      $Full = Join-Path $CheckRoot $Relative
      if (-not (Test-Path -LiteralPath $Full -PathType Leaf) -or
          (Get-Item -LiteralPath $Full).Length -ne [int64](Get-MapValue -Map $File -Key 'size_bytes') -or
          (Get-Sha256 -Path $Full) -ne [string](Get-MapValue -Map $File -Key 'sha256')) { return $false }
    }
    if ([int](Get-MapValue -Map $Manifest -Key 'file_count' -Default -1) -ne $Declared.Count) { return $false }
    $ActualPaths = @(Get-ChildItem -LiteralPath $CheckRoot -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($CheckRoot, $_.FullName).Replace('\', '/')
      })
    $ExpectedPaths = @($DeclaredPaths + 'MANIFEST.json')
    if ($ActualPaths.Count -ne $ExpectedPaths.Count -or
        (Compare-Object -CaseSensitive -ReferenceObject $ExpectedPaths -DifferenceObject $ActualPaths)) { return $false }
    foreach ($SelectedFile in Get-ChildItem -LiteralPath $CheckRoot -Recurse -File) {
      $Relative = [IO.Path]::GetRelativePath($CheckRoot, $SelectedFile.FullName).Replace('\', '/')
      if ($Relative -match '(^|/)(ACTION_PACKET\.json|ACTION_BRIDGE_CAPABILITY\.json|AGENT_TASK\.md|OWNER_SUMMARY_RU\.md)$' -or
          $Relative -match '(?i)(^|/)(data|raw|logs?|cache|__pycache__)(/|$)') { return $false }
      Assert-NoSecretLiteral -Path $SelectedFile.FullName -Text (Get-Content -LiteralPath $SelectedFile.FullName -Raw -Encoding UTF8)
    }
    return $true
  }
  catch { return $false }
}

function New-DeterministicZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )
  Add-Type -AssemblyName System.IO.Compression
  if (Test-Path -LiteralPath $DestinationPath) { throw "ZIP destination already exists: $DestinationPath" }
  Ensure-Directory -Path (Split-Path -Parent $DestinationPath)
  $FileStream = [IO.FileStream]::new($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $Archive = [IO.Compression.ZipArchive]::new($FileStream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
    try {
      $FixedTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      foreach ($File in Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | Sort-Object FullName) {
        $Relative = [IO.Path]::GetRelativePath($SourceRoot, $File.FullName).Replace('\', '/')
        $Entry = $Archive.CreateEntry($Relative, [IO.Compression.CompressionLevel]::Optimal)
        $Entry.LastWriteTime = $FixedTime
        $InputStream = [IO.File]::OpenRead($File.FullName)
        $OutputStream = $Entry.Open()
        try { $InputStream.CopyTo($OutputStream) }
        finally { $OutputStream.Dispose(); $InputStream.Dispose() }
      }
    }
    finally { $Archive.Dispose() }
  }
  finally { $FileStream.Dispose() }
}

function Update-DeploymentBootstrapBinding {
  param(
    [Parameter(Mandatory = $true)][string]$ZipFile,
    [Parameter(Mandatory = $true)][string]$ZipHash,
    [Parameter(Mandatory = $true)][string]$ResultFile,
    [Parameter(Mandatory = $true)][string]$InputIdentity,
    [Parameter(Mandatory = $true)][string]$HandoffHash
  )
  $Current = Read-JsonMap -Path $script:DeploymentManifestFull
  $ExistingBinding = Get-MapValue -Map $Current -Key 'restart_bootstrap'
  if ($ExistingBinding -and
      [string](Get-MapValue -Map $ExistingBinding -Key 'file') -eq (Split-Path -Leaf $ZipFile) -and
      [string](Get-MapValue -Map $ExistingBinding -Key 'sha256') -eq $ZipHash -and
      [string](Get-MapValue -Map $ExistingBinding -Key 'input_identity_sha256') -eq $InputIdentity -and
      [string](Get-MapValue -Map $ExistingBinding -Key 'handoff_archive_sha256') -eq $HandoffHash -and
      [string](Get-MapValue -Map $Current -Key 'status') -eq 'READY') {
    return
  }
  $Current['status'] = 'READY'
  $Current['restart_bootstrap'] = [ordered]@{
    file = Split-Path -Leaf $ZipFile
    path = $ZipFile
    sha256 = $ZipHash
    result_file = Split-Path -Leaf $ResultFile
    input_identity_sha256 = $InputIdentity
    handoff_archive_sha256 = $HandoffHash
    private = $true
    publication_allowed = $false
  }
  $Current['validated_at_utc'] = (Get-Date).ToUniversalTime().ToString('o')
  Write-Utf8FileAtomic -Path $script:DeploymentManifestFull -Text ($Current | ConvertTo-Json -Depth 40)
}

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline = (Resolve-Path -LiteralPath $PipelineRepo).Path
$HandoffArchiveFull = (Resolve-Path -LiteralPath $HandoffArchive).Path
$CompanionAssetFull = (Resolve-Path -LiteralPath $CompanionAsset).Path
if ([IO.Path]::GetExtension($HandoffArchiveFull) -ne '.zip') { throw 'HandoffArchive must be the exact exporter ZIP.' }
if ([IO.Path]::GetExtension($CompanionAssetFull) -ne '.zip') { throw 'CompanionAsset must be a ZIP.' }
$Leaf = Split-Path -Leaf $Project
if ([string]::IsNullOrWhiteSpace($LogicalName)) { $LogicalName = $Leaf }
if ([string]::IsNullOrWhiteSpace($ProjectId)) { $ProjectId = ($Leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-') }
if ([string]::IsNullOrWhiteSpace($ProjectId) -or $ProjectId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $ProjectId -in @('.', '..')) {
  throw 'ProjectId must be a single safe filename component (letters, digits, dot, underscore or hyphen).'
}
if ($MaxTotalMB -lt 1 -or $MaxFileMB -lt 1 -or $MaxFileMB -gt $MaxTotalMB) {
  throw 'MaxTotalMB and MaxFileMB must be positive, and MaxFileMB must not exceed MaxTotalMB.'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $env:USERPROFILE (Join-Path 'Documents\antigravity\companion-deployments' (Join-Path $ProjectId $EcosystemVersion))
}
$Protected = @($Project, $Pipeline, $env:USERPROFILE, $HandoffArchiveFull, $CompanionAssetFull, [IO.Path]::GetPathRoot($Project))
$OutputFull = Assert-SafeOutputLeaf -Path $OutputRoot -ProtectedPaths $Protected
Ensure-Directory -Path $OutputFull
if ([string]::IsNullOrWhiteSpace($DeploymentManifest)) { $DeploymentManifest = Join-Path $OutputFull 'DEPLOYMENT_MANIFEST.json' }
$script:DeploymentManifestFull = (Resolve-Path -LiteralPath $DeploymentManifest).Path
if (-not (Test-SamePath -Left (Split-Path -Parent $script:DeploymentManifestFull) -Right $OutputFull)) {
  throw 'DeploymentManifest must belong to the exact OutputRoot deployment leaf.'
}

$Version = Read-JsonMap -Path (Join-Path $Pipeline 'VERSION.json')
foreach ($Property in @('ecosystem_version', 'package_version', 'runtime_version', 'companion_version')) {
  if ([string](Get-MapValue -Map $Version -Key $Property) -ne $EcosystemVersion) { throw "Unified version mismatch: $Property" }
}
$PipelineGit = Get-GitSnapshot -GitRoot $Pipeline
if ([string]$PipelineGit.head -notmatch '^[0-9a-f]{40}$') { throw 'Pipeline source commit is invalid.' }
if ($PipelineGit.status_record_count -gt 0 -and -not $AllowDirtyPipeline) {
  throw 'Restart bootstrap requires a clean Pipeline source worktree.'
}

$Deployment = Read-JsonMap -Path $script:DeploymentManifestFull
if ([string](Get-MapValue -Map $Deployment -Key 'ecosystem_version') -ne $EcosystemVersion -or
    [string](Get-MapValue -Map $Deployment -Key 'deployment_role') -ne 'derived_chatgpt_upload_copy') {
  throw 'Deployment manifest is not the Companion 1.2.16 derivative deployment.'
}
$DeploymentSource = Get-MapValue -Map $Deployment -Key 'source'
$DeploymentAsset = Get-MapValue -Map $Deployment -Key 'companion_asset'
$DeploymentIdentity = [string](Get-MapValue -Map $Deployment -Key 'deployment_identity_sha256')
if ($DeploymentIdentity -notmatch '^[0-9a-f]{64}$') { throw 'Deployment identity is missing or invalid.' }
$CompanionAssetHash = Get-Sha256 -Path $CompanionAssetFull
if ([string](Get-MapValue -Map $DeploymentSource -Key 'commit') -ne [string]$PipelineGit.head -or
    (Get-MapValue -Map $DeploymentSource -Key 'clean') -ne $true -or
    [string](Get-MapValue -Map $DeploymentAsset -Key 'sha256') -ne $CompanionAssetHash) {
  throw 'Pipeline commit, Companion asset and deployment manifest are not bound to the same source.'
}

Test-ZipSafety -ArchivePath $CompanionAssetFull
Add-Type -AssemblyName System.IO.Compression.FileSystem
$CompanionZipObject = [IO.Compression.ZipFile]::OpenRead($CompanionAssetFull)
try {
  $AssetFileEntries = @($CompanionZipObject.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
  if ($AssetFileEntries.Count -ne $CompanionZipObject.Entries.Count) { throw 'Companion asset contains unexpected directory-only ZIP entries.' }
  $CompanionManifestEntry = $CompanionZipObject.GetEntry('agentic-companion-1.2.16/MANIFEST.json')
  if (-not $CompanionManifestEntry) { throw 'Companion asset manifest is missing.' }
  $ManifestStream = $CompanionManifestEntry.Open()
  $ManifestMemory = [IO.MemoryStream]::new()
  try { $ManifestStream.CopyTo($ManifestMemory); $CompanionManifestBytes = $ManifestMemory.ToArray() }
  finally { $ManifestMemory.Dispose(); $ManifestStream.Dispose() }
  $CompanionPackageManifest = $Utf8NoBom.GetString($CompanionManifestBytes) | ConvertFrom-Json -AsHashtable
  $PackageSource = Get-MapValue -Map $CompanionPackageManifest -Key 'source'
  if ([string](Get-MapValue -Map $PackageSource -Key 'commit') -ne [string]$PipelineGit.head -or
      (Get-MapValue -Map $PackageSource -Key 'working_tree_clean') -ne $true) {
    throw 'Companion asset manifest is not bound to the clean Pipeline HEAD.'
  }
  $PackageManifestHash = Get-BytesSha256 -Bytes $CompanionManifestBytes
  if ($PackageManifestHash -ne [string](Get-MapValue -Map $DeploymentAsset -Key 'package_manifest_sha256')) {
    throw 'Companion asset manifest hash does not match the deployment binding.'
  }
  $DeployedPackageManifest = Join-Path $OutputFull 'MANIFEST.json'
  if (-not (Test-Path -LiteralPath $DeployedPackageManifest -PathType Leaf) -or
      (Get-Sha256 -Path $DeployedPackageManifest) -ne $PackageManifestHash) {
    throw 'Deployed package manifest does not match the exact Companion asset manifest.'
  }

  $ExpectedModules = @(
    '00_AGENTIC_PIPELINE_INDEX_v1.2.16.md', '01_CONTEXT_SPLIT_POLICY.md', '02_AGENT_TASK_PACK_CONTRACT_v1.2.16.md',
    '03_PRODUCT_EVIDENCE_CONTROL_PLANE.md', '04_PROJECT_AUDIT_AND_RECOVERY.md', '05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md',
    '06_RUNTIME_TRUTH_REVIEW_POLICY.md', '07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md', '08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md',
    '09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md', '10_STATUS_AND_FINDING_LIFECYCLE.md', '11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md',
    '12_GOLDEN_EVALS.md', '13_LOCAL_CONTROL_TOOLS.md', '14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md',
    '15_OWNER_OUTPUT_PRESENTATION.md'
  )
  $PackageActiveSet = Get-MapValue -Map $CompanionPackageManifest -Key 'active_upload_set'
  $PackageModules = @(Get-MapValue -Map $PackageActiveSet -Key 'knowledge_modules' -Default @())
  if ([string](Get-MapValue -Map $PackageActiveSet -Key 'project_instructions') -ne '01_PROJECT_INSTRUCTIONS_v1.2.16.md' -or
      [int](Get-MapValue -Map $PackageActiveSet -Key 'knowledge_module_count' -Default -1) -ne 16 -or
      $PackageModules.Count -ne 16 -or (Compare-Object -CaseSensitive -ReferenceObject $ExpectedModules -DifferenceObject $PackageModules)) {
    throw 'Companion asset does not contain the exact active upload set.'
  }
  for ($Index = 0; $Index -lt $ExpectedModules.Count; $Index++) {
    if ([string]$PackageModules[$Index] -cne $ExpectedModules[$Index]) { throw 'Companion asset knowledge upload order is not canonical.' }
  }
  $DeploymentActiveSet = Get-MapValue -Map $Deployment -Key 'active_upload_set'
  $DeploymentModules = @(Get-MapValue -Map $DeploymentActiveSet -Key 'knowledge_modules' -Default @())
  if ([string](Get-MapValue -Map $DeploymentActiveSet -Key 'project_instructions') -ne '01_PROJECT_INSTRUCTIONS_v1.2.16.md' -or
      [int](Get-MapValue -Map $DeploymentActiveSet -Key 'knowledge_module_count' -Default -1) -ne 16 -or
      $DeploymentModules.Count -ne 16 -or (Compare-Object -CaseSensitive -ReferenceObject $ExpectedModules -DifferenceObject $DeploymentModules)) {
    throw 'Deployment manifest active upload set differs from the exact Companion asset.'
  }
  for ($Index = 0; $Index -lt $ExpectedModules.Count; $Index++) {
    if ([string]$DeploymentModules[$Index] -cne $ExpectedModules[$Index]) { throw 'Deployment manifest knowledge upload order is not canonical.' }
  }
  $PackageFiles = @(Get-MapValue -Map $CompanionPackageManifest -Key 'files' -Default @())
  $ExpectedActivePaths = @('01_PROJECT_INSTRUCTIONS_v1.2.16.md') + @($ExpectedModules | ForEach-Object { "knowledge/$_" })
  $ExpectedSupportPaths = @('VERSION.json', 'UPLOAD_ORDER.txt', 'NEW_CHAT_FIRST_MESSAGE.txt', 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt')
  $ExpectedPayloadPaths = @($ExpectedActivePaths + $ExpectedSupportPaths)
  $PackagePaths = @($PackageFiles | ForEach-Object { [string](Get-MapValue -Map $_ -Key 'path') })
  if ($PackagePaths.Count -ne $ExpectedPayloadPaths.Count -or
      (Compare-Object -CaseSensitive -ReferenceObject $ExpectedPayloadPaths -DifferenceObject $PackagePaths)) {
    throw 'Companion asset payload member set is not exact.'
  }
  $DeploymentFiles = @(Get-MapValue -Map $Deployment -Key 'package_files' -Default @())
  if ($DeploymentFiles.Count -ne $PackageFiles.Count) { throw 'Deployment package-file declaration count differs from the exact Companion asset.' }
  foreach ($File in $PackageFiles) {
    $Relative = Assert-SafeRelativePath -RelativePath ([string](Get-MapValue -Map $File -Key 'path'))
    $ExpectedRole = if ($ExpectedActivePaths -contains $Relative) { 'active_upload' } else { 'support_not_project_knowledge' }
    if ([string](Get-MapValue -Map $File -Key 'deployment_role') -cne $ExpectedRole) { throw "Companion asset role mismatch: $Relative" }
    $DeploymentMatches = @($DeploymentFiles | Where-Object { [string](Get-MapValue -Map $_ -Key 'path') -ceq $Relative })
    if ($DeploymentMatches.Count -ne 1) { throw "Deployment declaration is missing or duplicates an exact package file: $Relative" }
    $DeploymentFile = $DeploymentMatches[0]
    foreach ($Property in @('sha256', 'size_bytes', 'deployment_role', 'canonical_source')) {
      if ([string](Get-MapValue -Map $DeploymentFile -Key $Property) -cne [string](Get-MapValue -Map $File -Key $Property)) {
        throw "Deployment declaration differs from the Companion asset for ${Relative}: $Property"
      }
    }
    $Full = Join-Path $OutputFull $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf) -or
        (Get-Item -LiteralPath $Full).Length -ne [int64](Get-MapValue -Map $File -Key 'size_bytes') -or
        (Get-Sha256 -Path $Full) -ne [string](Get-MapValue -Map $File -Key 'sha256')) {
      throw "Deployment/package parity failure before bootstrap: $Relative"
    }
    $AssetEntry = $CompanionZipObject.GetEntry("agentic-companion-1.2.16/$Relative")
    if (-not $AssetEntry -or $AssetEntry.Length -ne [int64](Get-MapValue -Map $File -Key 'size_bytes')) {
      throw "Companion asset member size mismatch: $Relative"
    }
    $EntryStream = $AssetEntry.Open()
    $EntryMemory = [IO.MemoryStream]::new()
    try { $EntryStream.CopyTo($EntryMemory); $EntryBytes = $EntryMemory.ToArray() }
    finally { $EntryMemory.Dispose(); $EntryStream.Dispose() }
    if ((Get-BytesSha256 -Bytes $EntryBytes) -ne [string](Get-MapValue -Map $File -Key 'sha256')) {
      throw "Companion asset member hash mismatch: $Relative"
    }
  }
  $ExpectedAssetEntryNames = @($ExpectedPayloadPaths | ForEach-Object { "agentic-companion-1.2.16/$_" }) + 'agentic-companion-1.2.16/MANIFEST.json'
  $ActualAssetEntryNames = @($AssetFileEntries | ForEach-Object { $_.FullName })
  if ($ActualAssetEntryNames.Count -ne $ExpectedAssetEntryNames.Count -or
      (Compare-Object -CaseSensitive -ReferenceObject $ExpectedAssetEntryNames -DifferenceObject $ActualAssetEntryNames)) {
    throw 'Companion asset ZIP member set differs from its exact package manifest.'
  }
  if ([string](Get-MapValue -Map $Deployment -Key 'ui_checklist') -ne 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt' -or
      [int](Get-MapValue -Map $Deployment -Key 'ui_checklist_steps' -Default -1) -ne 3 -or
      [string](Get-MapValue -Map $Deployment -Key 'upload_order') -ne 'UPLOAD_ORDER.txt' -or
      [string](Get-MapValue -Map $Deployment -Key 'first_message') -ne 'NEW_CHAT_FIRST_MESSAGE.txt') {
    throw 'Deployment support-file binding is not the exact three-step Companion contract.'
  }
  $ChecklistPath = Join-Path $OutputFull 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt'
  $ChecklistSteps = @(Get-Content -LiteralPath $ChecklistPath -Encoding UTF8 | Where-Object { $_ -match '^\d+\.\s' })
  if ($ChecklistSteps.Count -ne 3) { throw 'Deployment must contain exactly one three-step UI checklist.' }
  $AllowedDeploymentPaths = @($ExpectedPayloadPaths + @('MANIFEST.json', 'DEPLOYMENT_MANIFEST.json'))
  $ExistingRestart = Get-MapValue -Map $Deployment -Key 'restart_bootstrap'
  if ($ExistingRestart) {
    foreach ($Key in @('file', 'result_file')) {
      $ExistingLeaf = [string](Get-MapValue -Map $ExistingRestart -Key $Key)
      if ([string]::IsNullOrWhiteSpace($ExistingLeaf) -or [IO.Path]::GetFileName($ExistingLeaf) -cne $ExistingLeaf) {
        throw 'Deployment restart-bootstrap binding contains an unsafe file identity.'
      }
      $AllowedDeploymentPaths += $ExistingLeaf
    }
  }
  $ActualDeploymentPaths = @(Get-ChildItem -LiteralPath $OutputFull -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($OutputFull, $_.FullName).Replace('\', '/')
    })
  if ($ActualDeploymentPaths.Count -ne $AllowedDeploymentPaths.Count -or
      (Compare-Object -CaseSensitive -ReferenceObject $AllowedDeploymentPaths -DifferenceObject $ActualDeploymentPaths)) {
    throw 'Companion deployment contains files outside its exact package and bound private artifacts.'
  }
  $IdentityDocument = [ordered]@{
    ecosystem_version = $EcosystemVersion
    source_commit = [string]$PipelineGit.head
    companion_asset_sha256 = $CompanionAssetHash
    active_upload_set = $PackageActiveSet
    active_files = @($PackageFiles | Where-Object { [string](Get-MapValue -Map $_ -Key 'deployment_role') -eq 'active_upload' } | ForEach-Object {
        [ordered]@{ path = [string](Get-MapValue -Map $_ -Key 'path'); sha256 = [string](Get-MapValue -Map $_ -Key 'sha256') }
      })
  }
  if ((Get-StringSha256 -Text ($IdentityDocument | ConvertTo-Json -Depth 20 -Compress)) -ne $DeploymentIdentity) {
    throw 'Deployment identity cannot be reproduced from the exact Companion asset and Pipeline commit.'
  }
}
finally { $CompanionZipObject.Dispose() }

$AgyRoot = Join-Path $Project '.agy'
$AgentsRoot = Join-Path $Project '.agents'
if (-not (Test-Path -LiteralPath $AgyRoot -PathType Container) -or -not (Test-Path -LiteralPath $AgentsRoot -PathType Container)) {
  throw 'Project does not contain installed .agy and .agents runtime roots.'
}
$WorkItemPath = Join-Path $AgyRoot 'WORK_ITEM.json'
$LeasePath = Join-Path $AgyRoot 'EXECUTION_LEASE.json'
$InstallationPath = Join-Path $AgyRoot 'INSTALLATION_MANIFEST.json'
foreach ($RequiredPath in @($WorkItemPath, $LeasePath, $InstallationPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) { throw "Required live authority is missing: $RequiredPath" }
}
$WorkItem = Read-JsonMap -Path $WorkItemPath
$Lease = Read-JsonMap -Path $LeasePath
$Installation = Read-JsonMap -Path $InstallationPath
$WorkItemId = [string](Get-MapValue -Map $WorkItem -Key 'work_item_id')
$GoalEpoch = [int](Get-MapValue -Map $WorkItem -Key 'goal_epoch' -Default 0)
if ([string]::IsNullOrWhiteSpace($WorkItemId) -or $GoalEpoch -lt 1) { throw 'Active work-item identity is invalid.' }
if ([string](Get-MapValue -Map $Lease -Key 'work_item_id') -ne $WorkItemId -or
    [int](Get-MapValue -Map $Lease -Key 'goal_epoch' -Default 0) -ne $GoalEpoch) {
  throw 'Execution lease does not match the active work item.'
}
$LeaseRootText = [string](Get-MapValue -Map $Lease -Key 'worktree_root')
if ([string]::IsNullOrWhiteSpace($LeaseRootText) -or -not (Test-Path -LiteralPath $LeaseRootText -PathType Container)) {
  throw 'Execution lease worktree_root is missing or unavailable.'
}
$SourceRoot = (Resolve-Path -LiteralPath $LeaseRootText).Path
foreach ($Property in @('package_version', 'runtime_version', 'companion_version')) {
  if ([string](Get-MapValue -Map $Installation -Key $Property) -ne $EcosystemVersion) { throw "Installed project runtime version mismatch: $Property" }
}
$ProjectGit = Get-GitSnapshot -GitRoot $Project
$SourceGit = if (Test-SamePath -Left $SourceRoot -Right $Project) { $ProjectGit } else { Get-GitSnapshot -GitRoot $SourceRoot }

$OperationId = [guid]::NewGuid().ToString('N')
$OperationRoot = Join-Path ([IO.Path]::GetTempPath()) ("companion-bootstrap-1.2.16-$OperationId")
$script:StageRoot = Join-Path $OperationRoot 'stage'
$HandoffExtract = Join-Path $OperationRoot 'handoff'
$ArtifactStage = Join-Path $OperationRoot 'artifacts'
Ensure-Directory -Path $script:StageRoot
Ensure-Directory -Path $HandoffExtract
Ensure-Directory -Path $ArtifactStage
$script:MaxTotalBytes = [int64]$MaxTotalMB * 1MB
$script:MaxFileBytes = [int64]$MaxFileMB * 1MB
$script:TotalBytes = [int64]0
$script:Included = @()
$script:Excluded = @(
  [ordered]@{ category = 'privacy'; reason = 'recursive .agy capture disabled; only explicit current authorities are eligible' },
  [ordered]@{ category = 'privacy'; reason = 'local capability material and raw action packets are never eligible' },
  [ordered]@{ category = 'privacy'; reason = 'product source, raw health data, databases, logs, caches and handoff source snapshots are not eligible' }
)

$ZipName = "COMPANION_RESTART_BOOTSTRAP_${ProjectId}_1.2.16.zip"
$ZipPath = Join-Path $OutputFull $ZipName
$ResultPath = Join-Path $OutputFull ([IO.Path]::ChangeExtension($ZipName, '.result.json'))
$StagedZip = Join-Path $ArtifactStage $ZipName
$StagedResult = Join-Path $ArtifactStage ([IO.Path]::ChangeExtension($ZipName, '.result.json'))
$ZipBackup = Join-Path $OutputFull ('.' + $ZipName + '.backup-' + $OperationId)
$ResultBackup = Join-Path $OutputFull ('.' + (Split-Path -Leaf $ResultPath) + '.backup-' + $OperationId)
$ZipMovedAside = $false
$ResultMovedAside = $false
$ZipInstalled = $false
$ResultInstalled = $false
$OriginalDeploymentText = Get-Content -LiteralPath $script:DeploymentManifestFull -Raw -Encoding UTF8

try {
  $AuthorityAllowlist = @(
    'WORK_ITEM.json', 'PROGRESS_STATE.json', 'NEXT_ACTION.json', 'FINDINGS.json', 'FINDING_DELTA.json',
    'REPAIR_DELTA.json', 'RUN_RESULT.json', 'CLOSURE_STATE.json', 'PHASE_RESULT.json', 'EXECUTION_SCOPE.json',
    'EXECUTION_LEASE.json', 'STAGE_FIREWALL.json', 'RUNTIME_HANDSHAKE.json', 'RUNTIME_STATUS.json',
    'INSTALLATION_MANIFEST.json', 'ACTION_PACKET_RECEIPT.json'
  )
  foreach ($Name in $AuthorityAllowlist) {
    $IsRequired = $Name -in @('WORK_ITEM.json', 'EXECUTION_LEASE.json', 'INSTALLATION_MANIFEST.json')
    Add-AllowlistedTextFile -Source (Join-Path $AgyRoot $Name) -RelativePath ("STATE/.agy/$Name") -Category 'current_project_authority' -Required:$IsRequired
  }
  $RuntimeAllowlist = @(
    'AGENTS.md', 'COMMAND_INVENTORY.json', 'hooks.json',
    'rules\05-runtime-contract.md', 'rules\61-autonomous-audit-convergence.md', 'rules\62-protected-reviewer.md',
    'rules\63-scientific-stage-firewall.md', 'rules\64-owner-autonomy.md',
    'workflows\nextphase.md', 'workflows\auditphase.md', 'workflows\fixcritical.md'
  )
  foreach ($Relative in $RuntimeAllowlist) {
    Add-AllowlistedTextFile -Source (Join-Path $AgentsRoot $Relative) -RelativePath ("RUNTIME/.agents/" + $Relative.Replace('\', '/')) -Category 'installed_runtime_contract'
  }

  Test-ZipSafety -ArchivePath $HandoffArchiveFull
  Expand-Archive -LiteralPath $HandoffArchiveFull -DestinationPath $HandoffExtract
  $EntryCandidates = @(Get-ChildItem -LiteralPath $HandoffExtract -Recurse -File -Filter 'COMPANION_ENTRY.md')
  if ($EntryCandidates.Count -ne 1) { throw 'Exact handoff archive must contain one unambiguous COMPANION_ENTRY.md.' }
  $HandoffRoot = Split-Path -Parent $EntryCandidates[0].FullName
  $HandoffValidationPath = Join-Path $HandoffRoot 'MANIFEST_VALIDATION.json'
  $HandoffReadinessPath = Join-Path $HandoffRoot 'CONTEXT_READINESS.json'
  $HandoffAuthorityPath = Join-Path $HandoffRoot 'CURRENT_AUTHORITY.json'
  $HandoffPrivacyPath = Join-Path $HandoffRoot 'PRIVACY_REPORT.json'
  $HandoffManifestPath = Join-Path $HandoffRoot 'MANIFEST.json'
  foreach ($RequiredPath in @($HandoffManifestPath, $HandoffValidationPath, $HandoffReadinessPath, $HandoffAuthorityPath, $HandoffPrivacyPath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) { throw "Exact handoff archive is missing required authority: $RequiredPath" }
  }
  Test-ExporterManifest -ExtractRoot $HandoffExtract -HandoffRoot $HandoffRoot
  $HandoffValidation = Read-JsonMap -Path $HandoffValidationPath
  $HandoffReadiness = Read-JsonMap -Path $HandoffReadinessPath
  $HandoffAuthority = Read-JsonMap -Path $HandoffAuthorityPath
  if ([string](Get-MapValue -Map $HandoffValidation -Key 'manifest_verdict') -ne 'PASS') { throw 'Exact handoff archive manifest validation did not pass.' }
  if ([string](Get-MapValue -Map $HandoffReadiness -Key 'transport_verdict') -ne 'PASS' -or
      [string](Get-MapValue -Map $HandoffReadiness -Key 'conversation_resume_verdict') -notmatch '^READY(?:_|$)') {
    throw 'Exact handoff archive is not truthfully ready for conversation continuation.'
  }
  $ImplementationReadiness = [string](Get-MapValue -Map $HandoffReadiness -Key 'implementation_resume_verdict')
  $ContinuationReadiness = [string](Get-MapValue -Map $HandoffReadiness -Key 'continuation_readiness')
  if ($ImplementationReadiness -notmatch '^READY(?:_|$)' -and $ContinuationReadiness -notmatch '^READY(?:_|$)') {
    throw 'Exact handoff archive is not ready for implementation continuation.'
  }
  if ((Get-MapValue -Map $HandoffReadiness -Key 'synthetic' -Default $false) -eq $true) { throw 'Synthetic handoff evidence cannot be used for the real restart bootstrap.' }
  $HandoffLogicalName = [string](Get-MapValue -Map $HandoffAuthority -Key 'logical_project_slug')
  if (-not [string]::IsNullOrWhiteSpace($HandoffLogicalName) -and $HandoffLogicalName -ne $LogicalName) {
    throw "Handoff logical project mismatch: expected=$LogicalName actual=$HandoffLogicalName"
  }
  $HandoffRuntimeRoot = [string](Get-MapValue -Map $HandoffAuthority -Key 'runtime_root')
  if (-not [string]::IsNullOrWhiteSpace($HandoffRuntimeRoot) -and -not (Test-SamePath -Left $HandoffRuntimeRoot -Right $Project)) {
    throw 'Handoff runtime root does not match ProjectRoot.'
  }

  $HandoffTopLevelAllowlist = @(
    'COMPANION_ENTRY.md', 'CURRENT_AUTHORITY.json', 'CONTEXT_READINESS.json', 'CONTINUATION_POLICY.json',
    'RESULT_IDENTITY.json', 'GIT_OVERVIEW.json', 'TOUCHED_FILES.json', 'RUNTIME_STATUS.json', 'RUNTIME_TARGET.json',
    'MANIFEST_VALIDATION.json', 'PRIVACY_REPORT.json'
  )
  foreach ($Name in $HandoffTopLevelAllowlist) {
    $Required = $Name -in @('COMPANION_ENTRY.md', 'CURRENT_AUTHORITY.json', 'CONTEXT_READINESS.json', 'MANIFEST_VALIDATION.json', 'PRIVACY_REPORT.json')
    Add-AllowlistedTextFile -Source (Join-Path $HandoffRoot $Name) -RelativePath ("HANDOFF/$Name") -Category 'exact_exporter_handoff' -Required:$Required
  }
  $SessionAllowlist = @('LAST_MODEL_RESPONSE.md', 'LAST_OWNER_REQUEST.md', 'TOOL_EVENTS.jsonl', 'TRANSCRIPT_DELTA.jsonl', 'NO_NEW_EVENTS.json')
  $SessionFilesCopied = 0
  foreach ($Name in $SessionAllowlist) {
    $SessionPath = Join-Path $HandoffRoot (Join-Path 'SESSION_DELTA' $Name)
    if (Test-Path -LiteralPath $SessionPath -PathType Leaf) {
      Add-AllowlistedTextFile -Source $SessionPath -RelativePath ("HANDOFF/SESSION_DELTA/$Name") -Category 'exact_incremental_session_delta'
      if ((Get-Item -LiteralPath $SessionPath).Length -gt 0) { $SessionFilesCopied++ }
    }
  }
  if ($SessionFilesCopied -lt 1) { throw 'Exact handoff archive has neither a non-empty session delta nor a no-new-events receipt.' }

  Write-Utf8File -Path (Join-Path $script:StageRoot 'GIT\PROJECT_RUNTIME.json') -Text ($ProjectGit | ConvertTo-Json -Depth 20)
  Write-Utf8File -Path (Join-Path $script:StageRoot 'GIT\SOURCE_WORKTREE.json') -Text ($SourceGit | ConvertTo-Json -Depth 20)
  $CurrentState = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    project = $LogicalName
    project_id = $ProjectId
    runtime_root = $Project
    result_worktree = $SourceRoot
    work_item_id = $WorkItemId
    goal_epoch = $GoalEpoch
    goal = [string](Get-MapValue -Map $WorkItem -Key 'goal')
    work_item_status = [string](Get-MapValue -Map $WorkItem -Key 'status')
    assurance_mode = [string](Get-MapValue -Map $WorkItem -Key 'assurance_mode')
    stage_profile = [string](Get-MapValue -Map $WorkItem -Key 'stage_profile')
    next_route = if (Test-Path -LiteralPath (Join-Path $AgyRoot 'NEXT_ACTION.json')) { [string](Get-MapValue -Map (Read-JsonMap -Path (Join-Path $AgyRoot 'NEXT_ACTION.json')) -Key 'route') } else { $null }
    pipeline_commit = [string]$PipelineGit.head
    project_head = [string]$ProjectGit.head
    result_worktree_head = [string]$SourceGit.head
  }
  Write-Utf8File -Path (Join-Path $script:StageRoot 'CURRENT_STATE.json') -Text ($CurrentState | ConvertTo-Json -Depth 20)
  $Bindings = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    pipeline = [ordered]@{ commit = [string]$PipelineGit.head; clean = ($PipelineGit.status_record_count -eq 0) }
    companion_asset = [ordered]@{ file = Split-Path -Leaf $CompanionAssetFull; sha256 = $CompanionAssetHash }
    deployment = [ordered]@{ manifest = Split-Path -Leaf $script:DeploymentManifestFull; identity_sha256 = $DeploymentIdentity }
    handoff = [ordered]@{
      exporter_archive_path = $HandoffArchiveFull
      exporter_archive_sha256 = Get-Sha256 -Path $HandoffArchiveFull
      manifest_verdict = [string](Get-MapValue -Map $HandoffValidation -Key 'manifest_verdict')
      transport_verdict = [string](Get-MapValue -Map $HandoffReadiness -Key 'transport_verdict')
      conversation_resume_verdict = [string](Get-MapValue -Map $HandoffReadiness -Key 'conversation_resume_verdict')
      implementation_resume_verdict = $ImplementationReadiness
      continuation_readiness = $ContinuationReadiness
      selected_files_only = $true
    }
  }
  Write-Utf8File -Path (Join-Path $script:StageRoot 'BINDINGS.json') -Text ($Bindings | ConvertTo-Json -Depth 20)
  $EntryText = @"
# Companion Restart Bootstrap

Project: $LogicalName

Read in this order:

1. `CURRENT_STATE.json` and `BINDINGS.json`.
2. Current files under `STATE/.agy/` and `RUNTIME/.agents/`.
3. `HANDOFF/CONTEXT_READINESS.json`, `HANDOFF/CURRENT_AUTHORITY.json`, and `HANDOFF/SESSION_DELTA/`.
4. Git identity under `GIT/` only when technical reconciliation is needed.

Treat the previous Companion chat as retired. Explain the confirmed current product state in four short Russian sections. Do not ask for an internal repair count, do not reopen a closed goal from stale history, and do not create an Action Packet until the owner explicitly confirms the next product goal. When confirmed, create one token-free `AGENTIC_ACTION_PACKET_*.json`; local authorization is added only by the installed Action Bridge.
"@.Trim()
  Write-Utf8File -Path (Join-Path $script:StageRoot 'COMPANION_ENTRY.md') -Text $EntryText
  Write-Utf8File -Path (Join-Path $script:StageRoot 'INCLUDED_FILES.json') -Text ($script:Included | ConvertTo-Json -Depth 10)
  Write-Utf8File -Path (Join-Path $script:StageRoot 'EXCLUSIONS.json') -Text ($script:Excluded | ConvertTo-Json -Depth 10)

  foreach ($SelectedFile in Get-ChildItem -LiteralPath $script:StageRoot -Recurse -File) {
    $SelectedText = Get-Content -LiteralPath $SelectedFile.FullName -Raw -Encoding UTF8
    Assert-NoSecretLiteral -Path $SelectedFile.FullName -Text $SelectedText
    $RelativeSelected = [IO.Path]::GetRelativePath($script:StageRoot, $SelectedFile.FullName).Replace('\', '/')
    if ($RelativeSelected -match '(^|/)(ACTION_PACKET\.json|ACTION_BRIDGE_CAPABILITY\.json|AGENT_TASK\.md|OWNER_SUMMARY_RU\.md)$') {
      throw "Raw action/capability material reached the bootstrap stage: $RelativeSelected"
    }
  }

  $StateFingerprintItems = @(Get-ChildItem -LiteralPath $script:StageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
      [ordered]@{ path = [IO.Path]::GetRelativePath($script:StageRoot, $_.FullName).Replace('\', '/'); sha256 = Get-Sha256 -Path $_.FullName }
    })
  $InputIdentityDocument = [ordered]@{
    ecosystem_version = $EcosystemVersion
    project_id = $ProjectId
    pipeline_commit = [string]$PipelineGit.head
    companion_asset_sha256 = $CompanionAssetHash
    deployment_identity_sha256 = $DeploymentIdentity
    handoff_archive_sha256 = [string]$Bindings.handoff.exporter_archive_sha256
    work_item_id = $WorkItemId
    goal_epoch = $GoalEpoch
    project_head = [string]$ProjectGit.head
    result_worktree_head = [string]$SourceGit.head
    selected_state = $StateFingerprintItems
  }
  $InputIdentity = Get-StringSha256 -Text ($InputIdentityDocument | ConvertTo-Json -Depth 30 -Compress)

  if ((Test-Path -LiteralPath $ZipPath -PathType Leaf) -and (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
    try { $ExistingResult = Read-JsonMap -Path $ResultPath }
    catch { $ExistingResult = $null }
    if ($ExistingResult -and [string](Get-MapValue -Map $ExistingResult -Key 'input_identity_sha256') -eq $InputIdentity -and
        [string](Get-MapValue -Map $ExistingResult -Key 'zip_sha256') -eq (Get-Sha256 -Path $ZipPath) -and
        (Test-ExistingBootstrapArtifact -ArchivePath $ZipPath -ExpectedInputIdentity $InputIdentity -CheckRoot (Join-Path $OperationRoot 'existing-check'))) {
      Update-DeploymentBootstrapBinding -ZipFile $ZipPath -ZipHash (Get-Sha256 -Path $ZipPath) -ResultFile $ResultPath -InputIdentity $InputIdentity -HandoffHash ([string]$Bindings.handoff.exporter_archive_sha256)
      Write-Host "Companion restart bootstrap already matches live bound state: $ZipPath"
      if ($OpenFolder) { Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`"" }
      return
    }
  }

  $ManifestFiles = @(Get-ChildItem -LiteralPath $script:StageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path = [IO.Path]::GetRelativePath($script:StageRoot, $_.FullName).Replace('\', '/')
        size_bytes = $_.Length
        sha256 = Get-Sha256 -Path $_.FullName
      }
    })
  $BootstrapManifest = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    artifact = 'COMPANION_RESTART_BOOTSTRAP'
    privacy_class = 'local_private_bootstrap'
    publication_allowed = $false
    project = $LogicalName
    project_id = $ProjectId
    input_identity_sha256 = $InputIdentity
    bindings = $Bindings
    file_count = $ManifestFiles.Count
    files = $ManifestFiles
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-Utf8File -Path (Join-Path $script:StageRoot 'MANIFEST.json') -Text ($BootstrapManifest | ConvertTo-Json -Depth 40)
  New-DeterministicZip -SourceRoot $script:StageRoot -DestinationPath $StagedZip
  Test-ZipSafety -ArchivePath $StagedZip

  $CheckRoot = Join-Path $OperationRoot 'check'
  Expand-Archive -LiteralPath $StagedZip -DestinationPath $CheckRoot
  $CheckedManifest = Read-JsonMap -Path (Join-Path $CheckRoot 'MANIFEST.json')
  if ([string](Get-MapValue -Map $CheckedManifest -Key 'input_identity_sha256') -ne $InputIdentity -or
      (Get-MapValue -Map $CheckedManifest -Key 'publication_allowed') -ne $false) {
    throw 'Restart bootstrap manifest binding or privacy classification failed.'
  }
  foreach ($File in @(Get-MapValue -Map $CheckedManifest -Key 'files' -Default @())) {
    $Relative = Assert-SafeRelativePath -RelativePath ([string](Get-MapValue -Map $File -Key 'path'))
    $Full = Join-Path $CheckRoot $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf) -or
        (Get-Item -LiteralPath $Full).Length -ne [int64](Get-MapValue -Map $File -Key 'size_bytes') -or
        (Get-Sha256 -Path $Full) -ne [string](Get-MapValue -Map $File -Key 'sha256')) {
      throw "Restart bootstrap extracted parity failure: $Relative"
    }
  }
  $CheckedDeclaredPaths = @((Get-MapValue -Map $CheckedManifest -Key 'files' -Default @()) | ForEach-Object {
      [string](Get-MapValue -Map $_ -Key 'path')
    })
  $CheckedActualPaths = @(Get-ChildItem -LiteralPath $CheckRoot -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($CheckRoot, $_.FullName).Replace('\', '/')
    })
  $CheckedExpectedPaths = @($CheckedDeclaredPaths + 'MANIFEST.json')
  if ($CheckedActualPaths.Count -ne $CheckedExpectedPaths.Count -or
      (Compare-Object -CaseSensitive -ReferenceObject $CheckedExpectedPaths -DifferenceObject $CheckedActualPaths)) {
    throw 'Restart bootstrap contains undeclared or missing extracted members.'
  }
  $ForbiddenMembers = @(Get-ChildItem -LiteralPath $CheckRoot -Recurse -File | Where-Object {
      $_.Name -match '^(ACTION_PACKET|ACTION_BRIDGE_CAPABILITY)\.json$' -or $_.Name -in @('AGENT_TASK.md', 'OWNER_SUMMARY_RU.md') -or
      $_.FullName -match '(?i)(\\|/)(data|raw|logs?|cache|__pycache__)(\\|/)'
  })
  if ($ForbiddenMembers.Count -gt 0) { throw "Restart bootstrap contains forbidden member: $($ForbiddenMembers[0].FullName)" }
  foreach ($CheckedFile in Get-ChildItem -LiteralPath $CheckRoot -Recurse -File) {
    Assert-NoSecretLiteral -Path $CheckedFile.FullName -Text (Get-Content -LiteralPath $CheckedFile.FullName -Raw -Encoding UTF8)
  }

  $ZipHash = Get-Sha256 -Path $StagedZip
  $Result = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    status = 'PASS'
    project = $LogicalName
    project_id = $ProjectId
    zip_path = $ZipPath
    zip_sha256 = $ZipHash
    input_identity_sha256 = $InputIdentity
    deployment_identity_sha256 = $DeploymentIdentity
    handoff_archive_sha256 = [string]$Bindings.handoff.exporter_archive_sha256
    pipeline_commit = [string]$PipelineGit.head
    work_item_id = $WorkItemId
    goal_epoch = $GoalEpoch
    selected_file_count = $ManifestFiles.Count
    publication_allowed = $false
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-Utf8File -Path $StagedResult -Text ($Result | ConvertTo-Json -Depth 20)

  if (Test-Path -LiteralPath $ZipPath) { Move-Item -LiteralPath $ZipPath -Destination $ZipBackup; $ZipMovedAside = $true }
  if (Test-Path -LiteralPath $ResultPath) { Move-Item -LiteralPath $ResultPath -Destination $ResultBackup; $ResultMovedAside = $true }
  Move-Item -LiteralPath $StagedZip -Destination $ZipPath
  $ZipInstalled = $true
  Move-Item -LiteralPath $StagedResult -Destination $ResultPath
  $ResultInstalled = $true
  Update-DeploymentBootstrapBinding -ZipFile $ZipPath -ZipHash $ZipHash -ResultFile $ResultPath -InputIdentity $InputIdentity -HandoffHash ([string]$Bindings.handoff.exporter_archive_sha256)
  if ($ZipMovedAside) { Remove-Item -LiteralPath $ZipBackup -Force; $ZipMovedAside = $false }
  if ($ResultMovedAside) { Remove-Item -LiteralPath $ResultBackup -Force; $ResultMovedAside = $false }
  Write-Host 'COMPANION RESTART BOOTSTRAP READY AND BOUND.' -ForegroundColor Green
  Write-Host "Output: $ZipPath"
  if ($OpenFolder) { Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`"" }
}
catch {
  if ($ResultInstalled -and (Test-Path -LiteralPath $ResultPath)) { Remove-Item -LiteralPath $ResultPath -Force }
  if ($ZipInstalled -and (Test-Path -LiteralPath $ZipPath)) { Remove-Item -LiteralPath $ZipPath -Force }
  if ($ResultMovedAside -and (Test-Path -LiteralPath $ResultBackup)) { Move-Item -LiteralPath $ResultBackup -Destination $ResultPath }
  if ($ZipMovedAside -and (Test-Path -LiteralPath $ZipBackup)) { Move-Item -LiteralPath $ZipBackup -Destination $ZipPath }
  if (Test-Path -LiteralPath $script:DeploymentManifestFull) {
    Write-Utf8FileAtomic -Path $script:DeploymentManifestFull -Text $OriginalDeploymentText
  }
  throw
}
finally {
  Remove-SafeTemporaryDirectory -Path $OperationRoot -LeafPrefix 'companion-bootstrap-1.2.16-'
}
