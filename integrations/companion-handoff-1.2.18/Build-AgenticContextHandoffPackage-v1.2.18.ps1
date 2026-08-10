[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = '',
  [switch]$Force,
  [switch]$AllowDirty
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$EcosystemVersion = '1.2.18'
$EngineSchemaVersion = '4.3.4'
$PackageName = "agentic-context-handoff-$EcosystemVersion"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$ExplicitExclusions = @(
  'install/finalize_v432.py',
  'install/finalize_v433.py',
  'install/finalize_v434.py',
  'install/fix_task.ps1'
)
$ForbiddenPrefixes = @('release/', 'queue/', 'state/', 'logs/', 'handoffs/', 'fixtures/', '__pycache__/')

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RelativeForwardPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$Path
  )
  return [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
}

function Get-RecordSetDigest {
  param([Parameter(Mandatory = $true)][object[]]$Records)
  $Canonical = @($Records | Sort-Object { [string]$_.path } | ForEach-Object {
    '{0}`t{1}`t{2}' -f [string]$_.path, [long]$_.size_bytes, [string]$_.sha256
  }) -join "`n"
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([Convert]::ToHexString($Hasher.ComputeHash($Utf8NoBom.GetBytes($Canonical)))).ToLowerInvariant()
  }
  finally {
    $Hasher.Dispose()
  }
}

function Write-Utf8Json {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + "`n"), $Utf8NoBom)
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList
  )
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $FilePath
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  foreach ($Argument in $ArgumentList) { [void]$StartInfo.ArgumentList.Add($Argument) }
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw "Unable to start native command: $FilePath" }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    $Process.WaitForExit()
    $Stdout = $StdoutTask.GetAwaiter().GetResult()
    $Stderr = $StderrTask.GetAwaiter().GetResult()
    if ($Process.ExitCode -ne 0) {
      throw "Native command failed. File=$FilePath ExitCode=$($Process.ExitCode) Stderr=$($Stderr.Trim())"
    }
    return [pscustomobject]@{ stdout = $Stdout; stderr = $Stderr; exit_code = $Process.ExitCode }
  }
  finally {
    $Process.Dispose()
  }
}

function Get-TreeSnapshot {
  param([Parameter(Mandatory = $true)][string]$Root)
  return @(
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
      Sort-Object FullName |
      ForEach-Object {
        [ordered]@{
          path = Get-RelativeForwardPath -BasePath $Root -Path $_.FullName
          size_bytes = [long]$_.Length
          sha256 = Get-Sha256 -Path $_.FullName
        }
      }
  )
}

function Assert-SnapshotsEqual {
  param(
    [Parameter(Mandatory = $true)][object[]]$Before,
    [Parameter(Mandatory = $true)][object[]]$After,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $BeforeJson = $Before | ConvertTo-Json -Depth 10 -Compress
  $AfterJson = $After | ConvertTo-Json -Depth 10 -Compress
  if ($BeforeJson -cne $AfterJson) { throw "$Label changed during package validation." }
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

function Test-PythonSyntax {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Python
  )
  $PriorAstPath = $env:AGENTIC_HANDOFF_AST_FILE
  $PriorBytecode = $env:PYTHONDONTWRITEBYTECODE
  try {
    $env:AGENTIC_HANDOFF_AST_FILE = $Path
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $Result = Invoke-NativeCapture -FilePath $Python -ArgumentList @(
      '-B', '-c',
      "import ast,os,pathlib; p=pathlib.Path(os.environ['AGENTIC_HANDOFF_AST_FILE']); ast.parse(p.read_text(encoding='utf-8-sig'), filename=str(p))"
    )
    if (-not [string]::IsNullOrWhiteSpace($Result.stderr)) {
      throw "Python syntax emitted stderr: $($Result.stderr.Trim())"
    }
  }
  finally {
    $env:AGENTIC_HANDOFF_AST_FILE = $PriorAstPath
    $env:PYTHONDONTWRITEBYTECODE = $PriorBytecode
  }
}

function Test-PackageRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Python
  )

  $ManifestPath = Join-Path $Root 'MANIFEST.json'
  $VersionPath = Join-Path $Root 'VERSION.json'
  $AttestationPath = Join-Path $Root 'SOURCE_ATTESTATION.json'
  foreach ($Required in @($ManifestPath, $VersionPath, $AttestationPath, (Join-Path $Root 'Update-AgenticContextHandoff-v1.2.18.ps1'))) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required package file is missing: $Required" }
  }

  $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Version = Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Attestation = Get-Content -LiteralPath $AttestationPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (
    [string]$Manifest.ecosystem_version -ne $EcosystemVersion -or
    [string]$Manifest.version -ne $EcosystemVersion -or
    [string]$Version.ecosystem_version -ne $EcosystemVersion -or
    [string]$Version.version -ne $EcosystemVersion -or
    [string]$Attestation.ecosystem_version -ne $EcosystemVersion
  ) {
    throw 'Package ecosystem version mismatch.'
  }
  if (
    [string]$Manifest.engine_schema_version -ne $EngineSchemaVersion -or
    [string]$Version.engine_schema_version -ne $EngineSchemaVersion -or
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
    $RootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Manifest path escapes package root: $Relative"
    }
    $Item = Get-Item -LiteralPath $Candidate
    if ([long]$Item.Length -ne [long]$File.size_bytes -or (Get-Sha256 -Path $Candidate) -cne [string]$File.sha256) {
      throw "Manifest hash/size mismatch: $Relative"
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
  if ([string]$Manifest.source_payload_sha256 -cne [string]$Attestation.source_payload_sha256) {
    throw 'Manifest/source attestation digest disagreement.'
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
      throw "Explicitly excluded legacy file was shipped: $Excluded"
    }
  }

  foreach ($JsonFile in Get-ChildItem -LiteralPath $Root -File -Recurse -Filter '*.json') {
    try { $null = Get-Content -LiteralPath $JsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Invalid JSON: $($JsonFile.FullName) :: $($_.Exception.Message)" }
  }
  foreach ($PowerShellFile in Get-ChildItem -LiteralPath $Root -File -Recurse -Filter '*.ps1') {
    Test-PowerShellSyntax -Path $PowerShellFile.FullName
  }
  foreach ($PythonFile in Get-ChildItem -LiteralPath $Root -File -Recurse -Filter '*.py') {
    Test-PythonSyntax -Path $PythonFile.FullName -Python $Python
  }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$IntegrationRoot = Join-Path $Root 'integrations\companion-handoff-1.2.18'
$SourceRoot = Join-Path $IntegrationRoot 'source'
$UpdaterPath = Join-Path $IntegrationRoot 'Update-AgenticContextHandoff-v1.2.18.ps1'
$ReadmePath = Join-Path $IntegrationRoot 'README.md'
foreach ($Required in @($SourceRoot, $UpdaterPath, $ReadmePath)) {
  if (-not (Test-Path -LiteralPath $Required)) { throw "Context Handoff build input is missing: $Required" }
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root '.artifacts\release-kit\1.2.18\context-handoff'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$Git = (Get-Command git -ErrorAction Stop).Source
$Python = (Get-Command python -ErrorAction Stop).Source
$CommitResult = Invoke-NativeCapture -FilePath $Git -ArgumentList @('-C', $Root, 'rev-parse', 'HEAD')
$SourceCommit = $CommitResult.stdout.Trim()
if ($SourceCommit -notmatch '^[0-9a-f]{40,64}$') { throw "Invalid source commit identity: $SourceCommit" }
$StatusResult = Invoke-NativeCapture -FilePath $Git -ArgumentList @('-C', $Root, 'status', '--porcelain=v1', '--untracked-files=all')
$SourceTreeDirty = -not [string]::IsNullOrWhiteSpace($StatusResult.stdout)
if ($SourceTreeDirty -and -not $AllowDirty) {
  throw 'Release package build requires a clean source tree. Use -AllowDirty only for isolated development tests.'
}

$CanonicalBefore = Get-TreeSnapshot -Root $SourceRoot
$Stage = Join-Path ([IO.Path]::GetTempPath()) ("context-handoff-build-$EcosystemVersion-" + [guid]::NewGuid().ToString('N'))
$Stage = [IO.Path]::GetFullPath($Stage)
$TempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $Stage.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe build staging path.' }
$Pack = Join-Path $Stage $PackageName
$ZipPath = Join-Path $OutputRoot "$PackageName.zip"

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $Pack 'source') | Out-Null
  foreach ($File in Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force | Sort-Object FullName) {
    $Relative = Get-RelativeForwardPath -BasePath $SourceRoot -Path $File.FullName
    $Lower = $Relative.ToLowerInvariant()
    if ($ExplicitExclusions -contains $Lower) { continue }
    if ($ForbiddenPrefixes | Where-Object { $Lower.StartsWith($_, [StringComparison]::Ordinal) }) {
      throw "Forbidden source prefix found: $Relative"
    }
    if ($Lower.EndsWith('.pyc') -or $Lower.EndsWith('.zip') -or $Lower.EndsWith('.db') -or $Lower.EndsWith('.sqlite')) {
      throw "Forbidden source artifact found: $Relative"
    }
    if ($Lower -eq 'handoff.config.json') { throw 'Active mutable handoff.config.json must not be shipped.' }
    $Destination = Join-Path $Pack ('source\' + $Relative.Replace('/', '\'))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $File.FullName -Destination $Destination
  }

  Copy-Item -LiteralPath $UpdaterPath -Destination (Join-Path $Pack 'Update-AgenticContextHandoff-v1.2.18.ps1')
  Copy-Item -LiteralPath $ReadmePath -Destination (Join-Path $Pack 'README.md')

  $SourceRecords = @(
    Get-ChildItem -LiteralPath (Join-Path $Pack 'source') -File -Recurse -Force |
      Sort-Object FullName |
      ForEach-Object {
        [ordered]@{
          path = Get-RelativeForwardPath -BasePath $Pack -Path $_.FullName
          size_bytes = [long]$_.Length
          sha256 = Get-Sha256 -Path $_.FullName
        }
      }
  )
  $SourcePayloadDigest = Get-RecordSetDigest -Records $SourceRecords
  $BuiltAt = (Get-Date).ToUniversalTime().ToString('o')
  $Version = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    component = 'context_handoff'
    version = $EcosystemVersion
    engine_schema_version = $EngineSchemaVersion
    source_commit = $SourceCommit
    source_tree_dirty = $SourceTreeDirty
    source_payload_sha256 = $SourcePayloadDigest
  }
  Write-Utf8Json -Path (Join-Path $Pack 'VERSION.json') -Value $Version

  $Attestation = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    component = 'context_handoff_source'
    engine_schema_version = $EngineSchemaVersion
    source_commit = $SourceCommit
    source_tree_dirty = $SourceTreeDirty
    source_payload_sha256 = $SourcePayloadDigest
    explicit_exclusions = $ExplicitExclusions
    source_files = $SourceRecords
  }
  Write-Utf8Json -Path (Join-Path $Pack 'SOURCE_ATTESTATION.json') -Value $Attestation

  $ManifestRecords = @(
    Get-ChildItem -LiteralPath $Pack -File -Recurse -Force |
      Where-Object { $_.Name -ne 'MANIFEST.json' } |
      Sort-Object FullName |
      ForEach-Object {
        $Relative = Get-RelativeForwardPath -BasePath $Pack -Path $_.FullName
        [ordered]@{
          path = $Relative
          role = if ($Relative.StartsWith('source/', [StringComparison]::Ordinal)) { 'immutable_source' } else { 'package_control' }
          size_bytes = [long]$_.Length
          sha256 = Get-Sha256 -Path $_.FullName
        }
      }
  )
  $Manifest = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    component = 'context_handoff'
    version = $EcosystemVersion
    engine_schema_version = $EngineSchemaVersion
    source_commit = $SourceCommit
    source_tree_dirty = $SourceTreeDirty
    built_at_utc = $BuiltAt
    source_payload_sha256 = $SourcePayloadDigest
    package_payload_sha256 = Get-RecordSetDigest -Records $ManifestRecords
    explicit_exclusions = $ExplicitExclusions
    files = $ManifestRecords
  }
  Write-Utf8Json -Path (Join-Path $Pack 'MANIFEST.json') -Value $Manifest

  for ($Run = 1; $Run -le 2; $Run++) {
    Test-PackageRoot -Root $Pack -Python $Python
    Assert-SnapshotsEqual -Before $CanonicalBefore -After (Get-TreeSnapshot -Root $SourceRoot) -Label "Canonical Context Handoff source (validation run $Run)"
  }

  if (Test-Path -LiteralPath $ZipPath) {
    if (-not $Force) { throw "Release package already exists: $ZipPath" }
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -LiteralPath $Pack -DestinationPath $ZipPath -CompressionLevel Optimal

  $VerifyRoot = Join-Path $Stage 'verify'
  New-Item -ItemType Directory -Force -Path $VerifyRoot | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $VerifyRoot
  $ExtractedRoot = Join-Path $VerifyRoot $PackageName
  Test-PackageRoot -Root $ExtractedRoot -Python $Python
  Assert-SnapshotsEqual -Before $CanonicalBefore -After (Get-TreeSnapshot -Root $SourceRoot) -Label 'Canonical Context Handoff source (post-archive verification)'

  $Result = [ordered]@{
    status = 'PASS'
    ecosystem_version = $EcosystemVersion
    source_commit = $SourceCommit
    source_tree_dirty = $SourceTreeDirty
    source_payload_sha256 = $SourcePayloadDigest
    package_path = $ZipPath
    package_sha256 = Get-Sha256 -Path $ZipPath
    packaged_source_files = $SourceRecords.Count
    excluded_files = $ExplicitExclusions
    validation_runs = 2
    canonical_source_modified = $false
  }
  Write-Host "Context Handoff package built: $ZipPath"
  $Result | ConvertTo-Json -Depth 20 -Compress
}
finally {
  if (Test-Path -LiteralPath $Stage) {
    $ResolvedStage = (Resolve-Path -LiteralPath $Stage).Path
    if (-not $ResolvedStage.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Unsafe build staging cleanup target.'
    }
    Remove-Item -LiteralPath $ResolvedStage -Recurse -Force
  }
}
