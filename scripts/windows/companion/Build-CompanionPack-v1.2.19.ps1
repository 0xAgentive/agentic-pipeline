[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = '',
  [switch]$Force,
  [switch]$AllowDirtySource,
  [string]$SourceCommit = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$EcosystemVersion = '1.2.19'

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
      if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Output path must not traverse a reparse point: $Probe"
      }
      if ((Test-SamePath -Left $Probe -Right $Full) -and -not $Item.PSIsContainer) {
        throw "Output path exists and is not a directory: $Full"
      }
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

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
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
  if ($Result.ExitCode -ne 0) {
    throw "git failed (exit $($Result.ExitCode)): $($Result.Stderr.Trim())"
  }
  return $Result
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-DeterministicZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )
  Add-Type -AssemblyName System.IO.Compression
  if (Test-Path -LiteralPath $DestinationPath) { throw "ZIP destination already exists: $DestinationPath" }
  $DestinationParent = Split-Path -Parent $DestinationPath
  if (-not (Test-Path -LiteralPath $DestinationParent -PathType Container)) {
    New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null
  }
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

function Test-PackageTree {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)
  $ManifestPath = Join-Path $PackageRoot 'MANIFEST.json'
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'Companion package MANIFEST.json is missing.' }
  $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$Manifest.ecosystem_version -ne $EcosystemVersion -or [string]$Manifest.companion_version -ne $EcosystemVersion) {
    throw 'Companion package version mismatch.'
  }
  $ExpectedInstruction = '01_PROJECT_INSTRUCTIONS_v1.2.19.md'
  if ([string]$Manifest.active_upload_set.project_instructions -ne $ExpectedInstruction) {
    throw 'Companion package has an unexpected Project Instructions identity.'
  }
  $ExpectedModules = @(
    '00_AGENTIC_PIPELINE_INDEX_v1.2.19.md',
    '01_CONTEXT_SPLIT_POLICY.md',
    '02_AGENT_TASK_PACK_CONTRACT_v1.2.19.md',
    '03_PRODUCT_EVIDENCE_CONTROL_PLANE.md',
    '04_PROJECT_AUDIT_AND_RECOVERY.md',
    '05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md',
    '06_RUNTIME_TRUTH_REVIEW_POLICY.md',
    '07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md',
    '08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md',
    '09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md',
    '10_STATUS_AND_FINDING_LIFECYCLE.md',
    '11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md',
    '12_GOLDEN_EVALS.md',
    '13_LOCAL_CONTROL_TOOLS.md',
    '14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md',
    '15_OWNER_OUTPUT_PRESENTATION.md'
  )
  $ActualModules = @($Manifest.active_upload_set.knowledge_modules)
  if ($ActualModules.Count -ne 16 -or (Compare-Object -ReferenceObject $ExpectedModules -DifferenceObject $ActualModules)) {
    throw 'Companion package must contain exactly one active knowledge module for every number 00-15.'
  }
  $KnowledgeFiles = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'knowledge') -File -Filter '*.md' | Sort-Object Name)
  if ($KnowledgeFiles.Count -ne 16 -or (Compare-Object -ReferenceObject $ExpectedModules -DifferenceObject @($KnowledgeFiles.Name))) {
    throw 'Extracted Companion knowledge directory differs from the declared active upload set.'
  }
  if (Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object { $_.Name -match 'SYSTEM_PROMPT|REPAIR_BUDGET' }) {
    throw 'Companion package contains a duplicate system prompt or active repair-budget file.'
  }
  $ChecklistFiles = @(Get-ChildItem -LiteralPath $PackageRoot -File -Filter '*CHECKLIST*.txt')
  if ($ChecklistFiles.Count -ne 1 -or $ChecklistFiles[0].Name -ne 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt') {
    throw 'Companion package must contain exactly one UI checklist.'
  }
  $NumberedChecklistLines = @(Get-Content -LiteralPath $ChecklistFiles[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\d+\.\s' })
  if ($NumberedChecklistLines.Count -ne 3 -or $NumberedChecklistLines[0] -notmatch '^1\.' -or
      $NumberedChecklistLines[1] -notmatch '^2\.' -or $NumberedChecklistLines[2] -notmatch '^3\.') {
    throw 'The UI checklist must contain exactly three numbered steps.'
  }
  $DeclaredFiles = @($Manifest.files)
  foreach ($Declared in $DeclaredFiles) {
    $Relative = [string]$Declared.path
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|/)\.\.(/|$)' -or $Relative.Contains('\')) {
      throw "Unsafe package manifest path: $Relative"
    }
    $Full = Join-Path $PackageRoot $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw "Declared package file is missing: $Relative" }
    if ((Get-Item -LiteralPath $Full).Length -ne [int64]$Declared.size_bytes) { throw "Package size mismatch: $Relative" }
    if ((Get-Sha256 -Path $Full) -ne [string]$Declared.sha256) { throw "Package hash mismatch: $Relative" }
  }
  $ActualRelativeFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/')
    } | Sort-Object)
  $ExpectedRelativeFiles = @((@($DeclaredFiles.path) + 'MANIFEST.json') | Sort-Object)
  if (Compare-Object -ReferenceObject $ExpectedRelativeFiles -DifferenceObject $ActualRelativeFiles) {
    throw 'Companion package contains undeclared or missing files.'
  }
  return $Manifest
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$VersionPath = Join-Path $Root 'VERSION.json'
if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) { throw "VERSION.json is missing: $VersionPath" }
$Version = Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($Property in @('ecosystem_version', 'package_version', 'runtime_version', 'companion_version')) {
  if ([string]$Version.$Property -ne $EcosystemVersion) { throw "Unified version mismatch: $Property" }
}

$HeadResult = Invoke-GitCapture -GitRoot $Root -GitArguments @('rev-parse', 'HEAD')
$HeadCommit = $HeadResult.Stdout.Trim()
if ($HeadCommit -notmatch '^[0-9a-f]{40}$') { throw "Invalid source commit: $HeadCommit" }
if (-not [string]::IsNullOrWhiteSpace($SourceCommit) -and $SourceCommit -ne $HeadCommit) {
  throw "Requested source commit does not match repository HEAD: requested=$SourceCommit actual=$HeadCommit"
}
$StatusResult = Invoke-GitCapture -GitRoot $Root -GitArguments @('status', '--porcelain=v2', '-z', '--untracked-files=all')
$SourceIsClean = [string]::IsNullOrEmpty($StatusResult.Stdout)
if (-not $SourceIsClean -and -not $AllowDirtySource) {
  throw 'Companion release package requires a clean source worktree. Use -AllowDirtySource only for non-release development tests.'
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root '.artifacts\release-kit\1.2.19\companion'
}
$Protected = @($Root, $env:USERPROFILE, [IO.Path]::GetPathRoot($Root))
$OutputFull = Assert-SafeOutputLeaf -Path $OutputRoot -ProtectedPaths $Protected
if ((Test-Path -LiteralPath $OutputFull) -and -not $Force) { throw "Output exists: $OutputFull" }
$OutputParent = Split-Path -Parent $OutputFull
if (-not (Test-Path -LiteralPath $OutputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputParent -Force | Out-Null
}
$OutputLeaf = Split-Path -Leaf $OutputFull
$OperationId = [guid]::NewGuid().ToString('N')
$OutputStage = Assert-SafeOutputLeaf -Path (Join-Path $OutputParent ".$OutputLeaf.stage-$OperationId") -ProtectedPaths $Protected
$OutputBackup = Assert-SafeOutputLeaf -Path (Join-Path $OutputParent ".$OutputLeaf.backup-$OperationId") -ProtectedPaths $Protected
$BuildStage = Join-Path ([IO.Path]::GetTempPath()) ("companion-1.2.19-$OperationId")
$CheckStage = Join-Path ([IO.Path]::GetTempPath()) ("companion-check-1.2.19-$OperationId")
$PackageRoot = Join-Path $BuildStage 'agentic-companion-1.2.19'
$KnowledgeRoot = Join-Path $PackageRoot 'knowledge'
$OutputMovedAside = $false
$OutputInstalled = $false

$KnowledgeFiles = @(
  '00_AGENTIC_PIPELINE_INDEX_v1.2.19.md',
  '01_CONTEXT_SPLIT_POLICY.md',
  '02_AGENT_TASK_PACK_CONTRACT_v1.2.19.md',
  '03_PRODUCT_EVIDENCE_CONTROL_PLANE.md',
  '04_PROJECT_AUDIT_AND_RECOVERY.md',
  '05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md',
  '06_RUNTIME_TRUTH_REVIEW_POLICY.md',
  '07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md',
  '08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md',
  '09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md',
  '10_STATUS_AND_FINDING_LIFECYCLE.md',
  '11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md',
  '12_GOLDEN_EVALS.md',
  '13_LOCAL_CONTROL_TOOLS.md',
  '14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md',
  '15_OWNER_OUTPUT_PRESENTATION.md'
)

try {
  New-Item -ItemType Directory -Path $KnowledgeRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $OutputStage -Force | Out-Null

  $InstructionName = '01_PROJECT_INSTRUCTIONS_v1.2.19.md'
  $InstructionSource = Join-Path $Root "docs\companion\$InstructionName"
  if (-not (Test-Path -LiteralPath $InstructionSource -PathType Leaf)) { throw "Companion source missing: $InstructionName" }
  Copy-Item -LiteralPath $InstructionSource -Destination (Join-Path $PackageRoot $InstructionName)
  foreach ($Name in $KnowledgeFiles) {
    $Source = Join-Path $Root "docs\companion\$Name"
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Companion source missing: $Name" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $KnowledgeRoot $Name)
  }
  Copy-Item -LiteralPath (Join-Path $Root 'docs\companion\VERSION.json') -Destination (Join-Path $PackageRoot 'VERSION.json')

  $UploadOrder = @"
Project Instructions (replace the field contents; do not upload as Knowledge):
$InstructionName

Project Knowledge (upload exactly one copy of each file in this order):
$($KnowledgeFiles | ForEach-Object { "- $_" } | Out-String)
Do not upload VERSION.json, MANIFEST.json, this file, the UI checklist, the first-message file, or the restart bootstrap as Project Knowledge.
Attach the restart bootstrap only to the first message of the new chat.
"@.Trim()
  Write-Utf8File -Path (Join-Path $PackageRoot 'UPLOAD_ORDER.txt') -Text $UploadOrder

  $FirstMessage = 'Открой приложенный архив и начни с COMPANION_ENTRY.md. Восстанови только подтверждённое текущее состояние проекта, затем ответь четырьмя короткими разделами на русском. Не создавай Action Packet, пока я явно не подтвержу следующую продуктовую цель.'
  Write-Utf8File -Path (Join-Path $PackageRoot 'NEW_CHAT_FIRST_MESSAGE.txt') -Text $FirstMessage

  $Checklist = @"
1. В настройках ChatGPT Project полностью замените Project Instructions содержимым $InstructionName.
2. Удалите старые файлы Project Knowledge и загрузите ровно по одной копии 16 файлов из knowledge в порядке из UPLOAD_ORDER.txt.
3. Создайте новый чат в том же Project, приложите указанный в DEPLOYMENT_MANIFEST.json COMPANION_RESTART_BOOTSTRAP_*.zip и отправьте текст из NEW_CHAT_FIRST_MESSAGE.txt.
"@.Trim()
  Write-Utf8File -Path (Join-Path $PackageRoot 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt') -Text $Checklist

  $CanonicalMap = [ordered]@{}
  $CanonicalMap[$InstructionName] = "docs/companion/$InstructionName"
  foreach ($Name in $KnowledgeFiles) { $CanonicalMap["knowledge/$Name"] = "docs/companion/$Name" }
  $CanonicalMap['VERSION.json'] = 'docs/companion/VERSION.json'

  $PayloadFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
      $Relative = [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/')
      $CanonicalSource = if ($CanonicalMap.Contains($Relative)) { [string]$CanonicalMap[$Relative] } else { $null }
      [ordered]@{
        path = $Relative
        canonical_source = $CanonicalSource
        deployment_role = if ($Relative -eq $InstructionName -or $Relative.StartsWith('knowledge/')) { 'active_upload' } else { 'support_not_project_knowledge' }
        size_bytes = $_.Length
        sha256 = Get-Sha256 -Path $_.FullName
      }
    })
  $Manifest = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    companion_version = $EcosystemVersion
    component = 'companion'
    source = [ordered]@{
      type = 'git_worktree'
      commit = $HeadCommit
      working_tree_clean = $SourceIsClean
    }
    active_upload_set = [ordered]@{
      project_instructions = $InstructionName
      knowledge_modules = $KnowledgeFiles
      knowledge_module_count = 16
    }
    support_files = @('VERSION.json', 'UPLOAD_ORDER.txt', 'NEW_CHAT_FIRST_MESSAGE.txt', 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt')
    action_packet_extension = '.json'
    ui_checklist_steps = 3
    files = $PayloadFiles
  }
  Write-Utf8File -Path (Join-Path $PackageRoot 'MANIFEST.json') -Text ($Manifest | ConvertTo-Json -Depth 20)
  [void](Test-PackageTree -PackageRoot $PackageRoot)

  $ZipPath = Join-Path $OutputStage 'agentic-companion-1.2.19.zip'
  New-DeterministicZip -SourceRoot $BuildStage -DestinationPath $ZipPath
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $EntryNames = @($Zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) } | ForEach-Object { $_.FullName })
    if ($EntryNames.Count -ne @($EntryNames | Sort-Object -Unique).Count) { throw 'Companion ZIP contains duplicate entries.' }
    foreach ($EntryName in $EntryNames) {
      if ($EntryName.Contains('\') -or $EntryName.StartsWith('/') -or $EntryName -match '^[A-Za-z]:' -or $EntryName -match '(^|/)\.\.(/|$)') {
        throw "Companion ZIP contains an unsafe entry: $EntryName"
      }
    }
  }
  finally { $Zip.Dispose() }

  Expand-Archive -LiteralPath $ZipPath -DestinationPath $CheckStage
  [void](Test-PackageTree -PackageRoot (Join-Path $CheckStage 'agentic-companion-1.2.19'))
  $AssetHash = Get-Sha256 -Path $ZipPath
  Write-Utf8File -Path (Join-Path $OutputStage 'agentic-companion-1.2.19.zip.sha256') -Text "$AssetHash  agentic-companion-1.2.19.zip`n"
  $BuildResult = [ordered]@{
    schema_version = '1.0.0'
    status = 'PASS'
    ecosystem_version = $EcosystemVersion
    source_commit = $HeadCommit
    source_worktree_clean = $SourceIsClean
    asset = [ordered]@{ file = 'agentic-companion-1.2.19.zip'; sha256 = $AssetHash; size_bytes = (Get-Item -LiteralPath $ZipPath).Length }
    active_upload_file_count = 17
    ui_checklist_steps = 3
    built_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-Utf8File -Path (Join-Path $OutputStage 'BUILD_RESULT.json') -Text ($BuildResult | ConvertTo-Json -Depth 10)

  if (Test-Path -LiteralPath $OutputFull) {
    Move-Item -LiteralPath $OutputFull -Destination $OutputBackup
    $OutputMovedAside = $true
  }
  Move-Item -LiteralPath $OutputStage -Destination $OutputFull
  $OutputInstalled = $true
  if ($OutputMovedAside) { Remove-Item -LiteralPath $OutputBackup -Recurse -Force; $OutputMovedAside = $false }
  Write-Host "Companion pack built and verified: $(Join-Path $OutputFull 'agentic-companion-1.2.19.zip')"
}
catch {
  if ($OutputInstalled -and (Test-Path -LiteralPath $OutputFull)) { Remove-Item -LiteralPath $OutputFull -Recurse -Force }
  if ($OutputMovedAside -and (Test-Path -LiteralPath $OutputBackup)) { Move-Item -LiteralPath $OutputBackup -Destination $OutputFull }
  throw
}
finally {
  if (Test-Path -LiteralPath $OutputStage) { Remove-Item -LiteralPath $OutputStage -Recurse -Force }
  Remove-SafeTemporaryDirectory -Path $BuildStage -LeafPrefix 'companion-1.2.19-'
  Remove-SafeTemporaryDirectory -Path $CheckStage -LeafPrefix 'companion-check-1.2.19-'
}
