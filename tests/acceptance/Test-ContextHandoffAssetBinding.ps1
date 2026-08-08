[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$CanonicalUpdater = Join-Path $Root 'integrations\companion-handoff-1.2.9\Update-AgenticContextHandoff-v1.2.9.ps1'
$CompleteScript = Join-Path $Root 'scripts\release\Complete-AgenticPipeline-v1.2.9-Deployment.ps1'
$Pwsh = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
$Pythonw = (Get-Command pythonw -ErrorAction Stop | Select-Object -First 1).Source
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Commit = 'a' * 40
$PackageName = 'agentic-context-handoff-1.2.9'
$ExplicitExclusions = @('install/finalize_v432.py','install/finalize_v433.py','install/finalize_v434.py','install/fix_task.ps1')
$Assertions = 0

foreach ($Required in @($CanonicalUpdater, $CompleteScript)) {
  if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required asset-binding input is missing: $Required" }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

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

function Get-RelativeForwardPath {
  param([string]$BasePath, [string]$Path)
  return [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
}

function Get-RecordSetDigest {
  param([Parameter(Mandatory = $true)][object[]]$Records)
  $Canonical = @($Records | Sort-Object { [string]$_.path } | ForEach-Object {
    '{0}`t{1}`t{2}' -f [string]$_.path, [long]$_.size_bytes, [string]$_.sha256
  }) -join "`n"
  return Get-BytesSha256 -Bytes $Utf8NoBom.GetBytes($Canonical)
}

function Write-Utf8Text {
  param([string]$Path, [string]$Text)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
  param([string]$Path, [object]$Value)
  Write-Utf8Text -Path $Path -Text (($Value | ConvertTo-Json -Depth 100) + "`n")
}

function New-FileRecord {
  param([string]$BasePath, [IO.FileInfo]$File, [string]$Role = '')
  $Record = [ordered]@{
    path = Get-RelativeForwardPath -BasePath $BasePath -Path $File.FullName
    size_bytes = [long]$File.Length
    sha256 = Get-Sha256 -Path $File.FullName
  }
  if (-not [string]::IsNullOrWhiteSpace($Role)) { $Record['role'] = $Role }
  return $Record
}

function Invoke-CapturedProcess {
  param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 30)
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
    if (-not $Process.Start()) { throw 'Unable to start Context Handoff test process.' }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
      $Process.Kill($true)
      throw 'Context Handoff test process timed out.'
    }
    $Process.WaitForExit()
    return [pscustomobject]@{
      exit_code = $Process.ExitCode
      stdout = $StdoutTask.GetAwaiter().GetResult()
      stderr = $StderrTask.GetAwaiter().GetResult()
    }
  }
  finally { $Process.Dispose() }
}

function Invoke-Updater {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string[]]$ExtraArguments = @()
  )
  $Arguments = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PackageRoot 'Update-AgenticContextHandoff-v1.2.9.ps1'),
    '-PackageRoot',$PackageRoot,
    '-HandoffRoot',(Join-Path $TempRoot 'never-live-handoff'),
    '-BackupRoot',(Join-Path $TempRoot 'never-live-backups'),
    '-HooksPath',(Join-Path $TempRoot 'never-live-hooks.json'),
    '-PythonwPath',$Pythonw,
    '-TaskMode','Plan'
  ) + $ExtraArguments
  return Invoke-CapturedProcess -FilePath $Pwsh -ArgumentList $Arguments
}

function New-ContextPackageFixture {
  param([Parameter(Mandatory = $true)][string]$ParentRoot)
  $PackageRoot = Join-Path $ParentRoot $PackageName
  New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot 'source\src') | Out-Null
  Copy-Item -LiteralPath $CanonicalUpdater -Destination (Join-Path $PackageRoot 'Update-AgenticContextHandoff-v1.2.9.ps1')
  Write-Utf8Text -Path (Join-Path $PackageRoot 'README.md') -Text "Hermetic Context Handoff asset-binding fixture.`n"
  Write-JsonFile -Path (Join-Path $PackageRoot 'source\handoff.config.example.json') -Value ([ordered]@{
    version = '4.3.4'
    engine_schema_version = '4.3.4'
    ecosystem_version = '1.2.9'
    local_root = ''
    privacy = [ordered]@{ fail_closed_patterns = @(); raw_biometrics_excluded = $true }
  })
  Write-Utf8Text -Path (Join-Path $PackageRoot 'source\src\run_ag_handoff_worker.py') -Text "raise SystemExit(0)`n"
  Write-Utf8Text -Path (Join-Path $PackageRoot 'source\src\enqueue_ag_handoff.py') -Text "raise SystemExit(0)`n"

  $SourceRecords = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'source') -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
    New-FileRecord -BasePath $PackageRoot -File $_
  })
  $SourceDigest = Get-RecordSetDigest -Records $SourceRecords
  Write-JsonFile -Path (Join-Path $PackageRoot 'VERSION.json') -Value ([ordered]@{
    schema_version = '1.0.0'; ecosystem_version = '1.2.9'; component = 'context_handoff'; version = '1.2.9'; engine_schema_version = '4.3.4'; source_commit = $Commit; source_tree_dirty = $false; source_payload_sha256 = $SourceDigest
  })
  Write-JsonFile -Path (Join-Path $PackageRoot 'SOURCE_ATTESTATION.json') -Value ([ordered]@{
    schema_version = '1.0.0'; ecosystem_version = '1.2.9'; component = 'context_handoff_source'; engine_schema_version = '4.3.4'; source_commit = $Commit; source_tree_dirty = $false; source_payload_sha256 = $SourceDigest; explicit_exclusions = $ExplicitExclusions; source_files = $SourceRecords
  })
  $ManifestRecords = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Where-Object Name -ne 'MANIFEST.json' | Sort-Object FullName | ForEach-Object {
    $Relative = Get-RelativeForwardPath -BasePath $PackageRoot -Path $_.FullName
    New-FileRecord -BasePath $PackageRoot -File $_ -Role $(if ($Relative.StartsWith('source/')) { 'immutable_source' } else { 'package_control' })
  })
  Write-JsonFile -Path (Join-Path $PackageRoot 'MANIFEST.json') -Value ([ordered]@{
    schema_version = '1.0.0'; ecosystem_version = '1.2.9'; component = 'context_handoff'; version = '1.2.9'; engine_schema_version = '4.3.4'; source_commit = $Commit; source_tree_dirty = $false; built_at_utc = '2026-08-08T00:00:00Z'; source_payload_sha256 = $SourceDigest; package_payload_sha256 = Get-RecordSetDigest -Records $ManifestRecords; explicit_exclusions = $ExplicitExclusions; files = $ManifestRecords
  })
  return $PackageRoot
}

function New-ZipFromDirectory {
  param([string]$SourceDirectory, [string]$ArchivePath)
  if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
  [IO.Compression.ZipFile]::CreateFromDirectory($SourceDirectory, $ArchivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
}

function Assert-Rejected {
  param([object]$Result, [string]$Pattern, [string]$Label)
  Assert-True -Condition ($Result.exit_code -ne 0) -Message "$Label unexpectedly succeeded."
  Assert-True -Condition (($Result.stdout + $Result.stderr) -match $Pattern) -Message "$Label rejection reason mismatch."
  Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $TempRoot 'never-live-handoff'))) -Message "$Label wrote a handoff target before rejecting the package."
}

$AuditedPaths = @($CanonicalUpdater, $CompleteScript, $PSCommandPath)
$BeforeHashes = @($AuditedPaths | ForEach-Object { "$_|$(Get-Sha256 -Path $_)" }) -join "`n"
$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TempRoot = [IO.Path]::GetFullPath((Join-Path $TempBase ('context-handoff-binding-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TempRoot.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Context Handoff test root.' }

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  $BuildParent = Join-Path $TempRoot 'build'
  New-Item -ItemType Directory -Force -Path $BuildParent | Out-Null
  $BuiltPackage = New-ContextPackageFixture -ParentRoot $BuildParent
  $ArchivePath = Join-Path $TempRoot 'agentic-context-handoff-1.2.9.zip'
  New-ZipFromDirectory -SourceDirectory $BuildParent -ArchivePath $ArchivePath
  $AssetSha256 = Get-Sha256 -Path $ArchivePath
  $ExtractRoot = Join-Path $TempRoot 'extracted'
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot
  $PackageRoot = Join-Path $ExtractRoot $PackageName

  $BindingArguments = @('-PackageArchivePath',$ArchivePath,'-AssetSha256',$AssetSha256,'-ExpectedSourceCommit',$Commit)
  $Happy = Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments $BindingArguments
  Assert-True -Condition ($Happy.exit_code -eq 0) -Message 'Exactly bound release package dry-run failed.'
  $HappyPlan = $Happy.stdout | ConvertFrom-Json
  Assert-True -Condition ([string]$HappyPlan.release_asset_sha256 -ceq $AssetSha256) -Message 'Bound release asset SHA is missing from the plan.'
  Assert-True -Condition ([string]$HappyPlan.source_commit -ceq $Commit) -Message 'Bound source commit is missing from the plan.'

  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-ExpectedSourceCommit',$Commit)) -Pattern 'PackageArchivePath is required' -Label 'Missing archive binding'
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-PackageArchivePath',$ArchivePath,'-ExpectedSourceCommit',$Commit)) -Pattern 'AssetSha256 is required' -Label 'Missing asset hash binding'
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-PackageArchivePath',$ArchivePath,'-AssetSha256',$AssetSha256)) -Pattern 'ExpectedSourceCommit is required' -Label 'Missing source commit binding'
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-PackageArchivePath',$ArchivePath,'-AssetSha256',$AssetSha256,'-ExpectedSourceCommit',('b' * 40))) -Pattern 'does not exactly match ExpectedSourceCommit' -Label 'Wrong source commit binding'
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-PackageArchivePath',$ArchivePath,'-AssetSha256',('0' * 64),'-ExpectedSourceCommit',$Commit)) -Pattern 'archive SHA-256 does not match' -Label 'Wrong asset hash binding'

  $Development = Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-AllowDevelopmentPackage')
  Assert-True -Condition ($Development.exit_code -eq 0) -Message 'Explicit development package unexpectedly required an archive.'
  $DevelopmentPlan = $Development.stdout | ConvertFrom-Json
  Assert-True -Condition ($null -eq $DevelopmentPlan.release_asset_sha256) -Message 'Unbound development plan claims a release asset hash.'

  $TamperedRoot = Join-Path $TempRoot 'tampered-package'
  Copy-Item -LiteralPath $PackageRoot -Destination $TamperedRoot -Recurse
  $TamperedReadme = Join-Path $TamperedRoot 'README.md'
  Write-Utf8Text -Path $TamperedReadme -Text "Jointly tampered extracted payload.`n"
  $TamperedManifestPath = Join-Path $TamperedRoot 'MANIFEST.json'
  $TamperedManifest = Get-Content -LiteralPath $TamperedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $ReadmeRecord = @($TamperedManifest.files | Where-Object { [string]$_.path -eq 'README.md' })[0]
  $ReadmeRecord.size_bytes = [long](Get-Item -LiteralPath $TamperedReadme).Length
  $ReadmeRecord.sha256 = Get-Sha256 -Path $TamperedReadme
  $TamperedManifest.package_payload_sha256 = Get-RecordSetDigest -Records @($TamperedManifest.files)
  Write-JsonFile -Path $TamperedManifestPath -Value $TamperedManifest
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $TamperedRoot -ExtraArguments $BindingArguments) -Pattern 'raw manifest in the verified archive' -Label 'Joint extracted payload/manifest tamper'

  $ExtraParent = Join-Path $TempRoot 'extra-archive-root'
  New-Item -ItemType Directory -Force -Path $ExtraParent | Out-Null
  Copy-Item -LiteralPath $BuiltPackage -Destination (Join-Path $ExtraParent $PackageName) -Recurse
  Write-Utf8Text -Path (Join-Path $ExtraParent 'UNDECLARED-GLOBAL.txt') -Text "must be rejected`n"
  $ExtraArchive = Join-Path $TempRoot 'context-handoff-extra-member.zip'
  New-ZipFromDirectory -SourceDirectory $ExtraParent -ArchivePath $ExtraArchive
  $ExtraArchiveSha = Get-Sha256 -Path $ExtraArchive
  Assert-Rejected -Result (Invoke-Updater -PackageRoot $PackageRoot -ExtraArguments @('-PackageArchivePath',$ExtraArchive,'-AssetSha256',$ExtraArchiveSha,'-ExpectedSourceCommit',$Commit)) -Pattern 'exact global manifest-bound member set' -Label 'Undeclared global archive member'

  $CompleteText = Get-Content -LiteralPath $CompleteScript -Raw -Encoding UTF8
  Assert-True -Condition ($CompleteText -match '(?s)RuntimeArguments\s*=.*?ExpectedSourceCommit\s*=\s*\$SourceCommit') -Message 'Complete does not bind the runtime updater to final SourceCommit.'
  Assert-True -Condition ($CompleteText -match '(?s)HandoffArguments\s*=.*?PackageArchivePath\s*=\s*\$Assets\.context_handoff.*?AssetSha256\s*=\s*\$HandoffHash.*?ExpectedSourceCommit\s*=\s*\$SourceCommit') -Message 'Complete does not construct exact Context Handoff asset binding arguments.'
  Assert-True -Condition ([regex]::Matches($CompleteText, '&\s*\$HandoffUpdater\s+@HandoffArguments').Count -eq 3) -Message 'Complete does not pass the same Context Handoff binding through dry/apply/apply.'
  Assert-True -Condition ($CompleteText -match '\$HandoffArguments\.Apply\s*=\s*\$true') -Message 'Complete does not switch the bound Context Handoff arguments from dry-run to apply.'

  $AfterHashes = @($AuditedPaths | ForEach-Object { "$_|$(Get-Sha256 -Path $_)" }) -join "`n"
  Assert-True -Condition ($AfterHashes -ceq $BeforeHashes) -Message 'Context Handoff asset-binding test changed audited source files.'
  Write-Host "Context Handoff asset-binding acceptance passed. Assertions=$Assertions; live_writes=0; source_changed=false"
}
finally {
  if (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $ResolvedTemp = (Resolve-Path -LiteralPath $TempRoot).Path
    if (-not $ResolvedTemp.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Context Handoff test cleanup target.' }
    Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
  }
}
