[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Generator = Join-Path $Root 'scripts\release\Create-Companion-Restart-Bootstrap-v1.2.27.ps1'
$CompanionPreparer = Join-Path $Root 'scripts\release\Prepare-AgenticPipeline-Companion-v1.2.27.ps1'
$CompanionBuilder = Join-Path $Root 'scripts\windows\companion\Build-CompanionPack-v1.2.27.ps1'
$Distribution = Join-Path $Root 'scripts\windows\Test-DistributionIntegrity.ps1'
$HardValidator = Join-Path $Root 'scripts\windows\Validate-AgenticPipelinePackage.ps1'
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-bootstrap-session-delta-' + [guid]::NewGuid().ToString('N'))
$Assertions = 0

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

function Write-Utf8Text {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
  )
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-Json {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  Write-Utf8Text -Path $Path -Text ($Value | ConvertTo-Json -Depth 30)
}

function Invoke-Capture {
  param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $PreviousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $Output = @(& $FilePath @Arguments 2>&1)
    $Code = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $PreviousPreference }
  return [pscustomobject]@{ Code = [int]$Code; Text = ([object[]]$Output -join "`n") }
}

function Invoke-Git {
  param([Parameter(Mandatory = $true)][string]$GitRoot, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $Result = Invoke-Capture -FilePath 'git' -Arguments (@('-C', $GitRoot) + $Arguments)
  if ($Result.Code -ne 0) { throw "git failed in ${GitRoot}: $($Result.Text)" }
  return $Result.Text.Trim()
}

function Initialize-CleanGitRepository {
  param([Parameter(Mandatory = $true)][string]$Path)
  $Init = Invoke-Capture -FilePath 'git' -Arguments @('init', $Path)
  if ($Init.Code -ne 0) { throw "git init failed: $($Init.Text)" }
  Invoke-Git -GitRoot $Path -Arguments @('config', 'user.email', 'fixture@example.invalid') | Out-Null
  Invoke-Git -GitRoot $Path -Arguments @('config', 'user.name', 'Fixture') | Out-Null
  Invoke-Git -GitRoot $Path -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
  Invoke-Git -GitRoot $Path -Arguments @('add', '-A') | Out-Null
  Invoke-Git -GitRoot $Path -Arguments @('commit', '-m', 'fixture') | Out-Null
  Assert-True -Condition ([string]::IsNullOrWhiteSpace((Invoke-Git -GitRoot $Path -Arguments @('status', '--porcelain=v1', '--untracked-files=all')))) -Message "Fixture repository is not clean: $Path"
}

function Copy-RepositoryFixture {
  param([Parameter(Mandatory = $true)][string]$Destination)
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($Item in Get-ChildItem -LiteralPath $Root -Force) {
    if ($Item.Name -in @('.git', '.artifacts')) { continue }
    Copy-Item -LiteralPath $Item.FullName -Destination $Destination -Recurse -Force
  }
  Initialize-CleanGitRepository -Path $Destination
}

function New-ProjectFixture {
  param(
    [Parameter(Mandatory = $true)][string]$PipelineRoot,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
  )
  Copy-Item -LiteralPath (Join-Path $PipelineRoot 'templates\agy-project-base') -Destination $ProjectRoot -Recurse -Force
  $Agy = Join-Path $ProjectRoot '.agy'
  $WorkItemId = 'WI-SESSION-DELTA-FIXTURE'
  Write-Json -Path (Join-Path $Agy 'WORK_ITEM.json') -Value ([ordered]@{
      schema_version = '1.0.0'; work_item_id = $WorkItemId; goal_epoch = 1; goal = 'Validate optional empty session members.'
      status = 'active'; assurance_mode = 'strict'; stage_profile = 'verification'
    })
  Write-Json -Path (Join-Path $Agy 'EXECUTION_LEASE.json') -Value ([ordered]@{
      schema_version = '1.0.0'; work_item_id = $WorkItemId; goal_epoch = 1; worktree_root = $ProjectRoot
    })
  Write-Json -Path (Join-Path $Agy 'INSTALLATION_MANIFEST.json') -Value ([ordered]@{
      schema_version = '1.0.0'; package_version = '1.2.27'; runtime_version = '1.2.27'; companion_version = '1.2.27'
    })
  Initialize-CleanGitRepository -Path $ProjectRoot
}

function New-HandoffArchive {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$FixtureName,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionMembers,
    [switch]$EmptyCompanionEntry
  )
  $HandoffRoot = Join-Path $TempRoot ('handoff-' + $FixtureName)
  New-Item -ItemType Directory -Path $HandoffRoot -Force | Out-Null
  Write-Utf8Text -Path (Join-Path $HandoffRoot 'COMPANION_ENTRY.md') -Text $(if ($EmptyCompanionEntry) { '' } else { "# Session delta fixture`n" })
  Write-Json -Path (Join-Path $HandoffRoot 'CURRENT_AUTHORITY.json') -Value ([ordered]@{
      schema_version = '1.0.0'; logical_project_slug = 'Session Delta Fixture'; runtime_root = $ProjectRoot
    })
  Write-Json -Path (Join-Path $HandoffRoot 'CONTEXT_READINESS.json') -Value ([ordered]@{
      schema_version = '1.0.0'; transport_verdict = 'PASS'; conversation_resume_verdict = 'READY'
      implementation_resume_verdict = 'READY'; continuation_readiness = 'READY'; synthetic = $false
    })
  Write-Json -Path (Join-Path $HandoffRoot 'PRIVACY_REPORT.json') -Value ([ordered]@{ schema_version = '1.0.0'; status = 'PASS' })
  foreach ($Entry in $SessionMembers.GetEnumerator()) {
    Write-Utf8Text -Path (Join-Path $HandoffRoot ('SESSION_DELTA\' + [string]$Entry.Key)) -Text ([string]$Entry.Value)
  }

  $Generation = 'GEN-' + $FixtureName
  $Files = [ordered]@{}
  foreach ($File in Get-ChildItem -LiteralPath $HandoffRoot -Recurse -File | Sort-Object FullName) {
    $Relative = [IO.Path]::GetRelativePath($HandoffRoot, $File.FullName).Replace('\', '/')
    $Files[$Relative] = [ordered]@{
      file_path = $Relative
      size = [int64]$File.Length
      sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  Write-Json -Path (Join-Path $HandoffRoot 'MANIFEST.json') -Value ([ordered]@{
      schema_version = '1.0.0'; generation_id = $Generation; file_count = $Files.Count; files = $Files
      self_excluded_files = @('MANIFEST.json', 'MANIFEST_VALIDATION.json')
    })
  Write-Json -Path (Join-Path $HandoffRoot 'MANIFEST_VALIDATION.json') -Value ([ordered]@{
      schema_version = '1.0.0'; generation_id = $Generation; manifest_verdict = 'PASS'
      declared_file_count = $Files.Count + 1; missing_file_count = 0; mismatched_file_count = 0
    })

  $Archive = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($File in Get-ChildItem -LiteralPath $HandoffRoot -Recurse -File | Sort-Object FullName) {
      $Relative = [IO.Path]::GetRelativePath($HandoffRoot, $File.FullName).Replace('\', '/')
      $ZipEntry = $Archive.CreateEntry($Relative, [IO.Compression.CompressionLevel]::Optimal)
      $InputStream = $File.OpenRead()
      $OutputStream = $ZipEntry.Open()
      try { $InputStream.CopyTo($OutputStream) }
      finally { $OutputStream.Dispose(); $InputStream.Dispose() }
    }
  }
  finally { $Archive.Dispose() }
  return $ArchivePath
}

function Copy-DeploymentFixture {
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
  return $Destination
}

function Invoke-Bootstrap {
  param(
    [Parameter(Mandatory = $true)][string]$PipelineRoot,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$DeploymentRoot,
    [Parameter(Mandatory = $true)][string]$HandoffArchive,
    [Parameter(Mandatory = $true)][string]$CompanionAsset,
    [Parameter(Mandatory = $true)][string]$ProjectId
  )
  return Invoke-Capture -FilePath $Pwsh -Arguments @(
    '-NoLogo', '-NoProfile', '-File', $Generator,
    '-ProjectRoot', $ProjectRoot, '-PipelineRepo', $PipelineRoot, '-OutputRoot', $DeploymentRoot,
    '-HandoffArchive', $HandoffArchive, '-CompanionAsset', $CompanionAsset,
    '-DeploymentManifest', (Join-Path $DeploymentRoot 'DEPLOYMENT_MANIFEST.json'),
    '-LogicalName', 'Session Delta Fixture', '-ProjectId', $ProjectId
  )
}

function Get-ZipEntryText {
  param([Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive, [Parameter(Mandatory = $true)][string]$Name)
  $Entry = $Archive.GetEntry($Name)
  if (-not $Entry) { return $null }
  $Reader = [IO.StreamReader]::new($Entry.Open(), [Text.UTF8Encoding]::new($false, $true), $true)
  try { return $Reader.ReadToEnd() }
  finally { $Reader.Dispose() }
}

if (-not (Test-Path -LiteralPath $Generator -PathType Leaf)) { throw "Missing generator: $Generator" }
$SourceFiles = @($Generator, $CompanionPreparer, $CompanionBuilder, $Distribution, $HardValidator)
$BeforeHashes = @{}; foreach ($Path in $SourceFiles) { $BeforeHashes[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  $Pipeline = Join-Path $TempRoot 'pipeline'
  Copy-RepositoryFixture -Destination $Pipeline
  $PipelineHead = Invoke-Git -GitRoot $Pipeline -Arguments @('rev-parse', 'HEAD')

  $AssetRoot = Join-Path $TempRoot 'asset'
  $Build = Invoke-Capture -FilePath $Pwsh -Arguments @(
    '-NoLogo', '-NoProfile', '-File', (Join-Path $Pipeline 'scripts\windows\companion\Build-CompanionPack-v1.2.27.ps1'),
    '-RepoRoot', $Pipeline, '-OutputRoot', $AssetRoot, '-Force', '-SourceCommit', $PipelineHead
  )
  Assert-True -Condition ($Build.Code -eq 0) -Message "Companion fixture build failed: $($Build.Text)"
  $CompanionAsset = Join-Path $AssetRoot 'agentic-companion-1.2.27.zip'
  Assert-True -Condition (Test-Path -LiteralPath $CompanionAsset -PathType Leaf) -Message 'Companion fixture asset is missing.'

  $DeploymentTemplate = Join-Path $TempRoot 'deployment-template'
  $Prepare = Invoke-Capture -FilePath $Pwsh -Arguments @(
    '-NoLogo', '-NoProfile', '-File', (Join-Path $Pipeline 'scripts\release\Prepare-AgenticPipeline-Companion-v1.2.27.ps1'),
    '-CompanionZip', $CompanionAsset, '-OutputRoot', $DeploymentTemplate, '-CanonicalRepo', $Pipeline,
    '-ExpectedSourceCommit', $PipelineHead, '-Force', '-SkipClipboard'
  )
  Assert-True -Condition ($Prepare.Code -eq 0) -Message "Companion fixture preparation failed: $($Prepare.Text)"

  $Project = Join-Path $TempRoot 'project'
  New-ProjectFixture -PipelineRoot $Pipeline -ProjectRoot $Project

  $MixedArchive = New-HandoffArchive -ArchivePath (Join-Path $TempRoot 'mixed.zip') -FixtureName 'mixed' -ProjectRoot $Project -SessionMembers ([ordered]@{
      'LAST_MODEL_RESPONSE.md' = "Verified response.`n"
      'LAST_OWNER_REQUEST.md' = "Verified request.`n"
      'TOOL_EVENTS.jsonl' = ''
      'TRANSCRIPT_DELTA.jsonl' = "{`"event`":`"verified`"}`n"
    })
  $MixedDeployment = Copy-DeploymentFixture -Source $DeploymentTemplate -Destination (Join-Path $TempRoot 'deployment-mixed')
  $Mixed = Invoke-Bootstrap -PipelineRoot $Pipeline -ProjectRoot $Project -DeploymentRoot $MixedDeployment -HandoffArchive $MixedArchive -CompanionAsset $CompanionAsset -ProjectId 'mixed'
  Assert-True -Condition ($Mixed.Code -eq 0) -Message "Mixed empty/non-empty bootstrap failed: $($Mixed.Text)"
  $MixedZip = Join-Path $MixedDeployment 'COMPANION_RESTART_BOOTSTRAP_mixed_1.2.27.zip'
  $MixedObject = [IO.Compression.ZipFile]::OpenRead($MixedZip)
  try {
    Assert-True -Condition ($null -ne $MixedObject.GetEntry('HANDOFF/SESSION_DELTA/LAST_MODEL_RESPONSE.md')) -Message 'Non-empty session member was not packaged.'
    $ZeroEntry = $MixedObject.GetEntry('HANDOFF/SESSION_DELTA/TOOL_EVENTS.jsonl')
    Assert-True -Condition ($null -ne $ZeroEntry -and $ZeroEntry.Length -eq 0) -Message 'Zero-byte tool events member was not preserved exactly.'
    $Included = @(Get-ZipEntryText -Archive $MixedObject -Name 'INCLUDED_FILES.json' | ConvertFrom-Json -DateKind String)
    $IncludedZero = @($Included | Where-Object { [string]$_.path -ceq 'HANDOFF/SESSION_DELTA/TOOL_EVENTS.jsonl' })
    Assert-True -Condition ($IncludedZero.Count -eq 1 -and [long]$IncludedZero[0].size_bytes -eq 0 -and [string]$IncludedZero[0].sha256 -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') -Message 'INCLUDED_FILES does not bind the exact zero-byte member.'
    $BootstrapManifest = Get-ZipEntryText -Archive $MixedObject -Name 'MANIFEST.json' | ConvertFrom-Json -DateKind String
    $ManifestZero = @($BootstrapManifest.files | Where-Object { [string]$_.path -ceq 'HANDOFF/SESSION_DELTA/TOOL_EVENTS.jsonl' })
    Assert-True -Condition ($ManifestZero.Count -eq 1 -and [long]$ManifestZero[0].size_bytes -eq 0 -and [string]$ManifestZero[0].sha256 -ceq [string]$IncludedZero[0].sha256) -Message 'Bootstrap manifest lost zero-byte member parity.'
    $Exclusions = Get-ZipEntryText -Archive $MixedObject -Name 'EXCLUSIONS.json'
    Assert-True -Condition ($Exclusions -notmatch 'TOOL_EVENTS\.jsonl') -Message 'Preserved zero-byte member was incorrectly reported as excluded.'
  }
  finally { $MixedObject.Dispose() }
  $MixedHashBefore = (Get-FileHash -LiteralPath $MixedZip -Algorithm SHA256).Hash
  $MixedResult = [IO.Path]::ChangeExtension($MixedZip, '.result.json')
  $MixedResultHashBefore = (Get-FileHash -LiteralPath $MixedResult -Algorithm SHA256).Hash
  $MixedRepeat = Invoke-Bootstrap -PipelineRoot $Pipeline -ProjectRoot $Project -DeploymentRoot $MixedDeployment -HandoffArchive $MixedArchive -CompanionAsset $CompanionAsset -ProjectId 'mixed'
  Assert-True -Condition ($MixedRepeat.Code -eq 0 -and $MixedRepeat.Text -match 'already matches live bound state') -Message "Zero-byte bootstrap is not idempotently reusable: $($MixedRepeat.Text)"
  Assert-True -Condition ((Get-FileHash -LiteralPath $MixedZip -Algorithm SHA256).Hash -eq $MixedHashBefore -and (Get-FileHash -LiteralPath $MixedResult -Algorithm SHA256).Hash -eq $MixedResultHashBefore) -Message 'Idempotent reuse changed the bound bootstrap artifacts.'

  $NoEventsText = '{"schema_version":"1.0.0","status":"NO_NEW_EVENTS"}'
  $NoEventsArchive = New-HandoffArchive -ArchivePath (Join-Path $TempRoot 'no-events.zip') -FixtureName 'no-events' -ProjectRoot $Project -SessionMembers ([ordered]@{
      'LAST_MODEL_RESPONSE.md' = ''
      'LAST_OWNER_REQUEST.md' = ''
      'NO_NEW_EVENTS.json' = $NoEventsText
    })
  $NoEventsDeployment = Copy-DeploymentFixture -Source $DeploymentTemplate -Destination (Join-Path $TempRoot 'deployment-no-events')
  $NoEvents = Invoke-Bootstrap -PipelineRoot $Pipeline -ProjectRoot $Project -DeploymentRoot $NoEventsDeployment -HandoffArchive $NoEventsArchive -CompanionAsset $CompanionAsset -ProjectId 'no-events'
  Assert-True -Condition ($NoEvents.Code -eq 0) -Message "NO_NEW_EVENTS bootstrap failed: $($NoEvents.Text)"
  $NoEventsZip = Join-Path $NoEventsDeployment 'COMPANION_RESTART_BOOTSTRAP_no-events_1.2.27.zip'
  $NoEventsObject = [IO.Compression.ZipFile]::OpenRead($NoEventsZip)
  try {
    Assert-True -Condition ((Get-ZipEntryText -Archive $NoEventsObject -Name 'HANDOFF/SESSION_DELTA/NO_NEW_EVENTS.json') -ceq $NoEventsText) -Message 'NO_NEW_EVENTS receipt was not copied exactly.'
    $EmptyResponse = $NoEventsObject.GetEntry('HANDOFF/SESSION_DELTA/LAST_MODEL_RESPONSE.md')
    Assert-True -Condition ($null -ne $EmptyResponse -and $EmptyResponse.Length -eq 0) -Message 'Empty response must remain an exact zero-byte member when receipt is present.'
  }
  finally { $NoEventsObject.Dispose() }

  $AllEmptyArchive = New-HandoffArchive -ArchivePath (Join-Path $TempRoot 'all-empty.zip') -FixtureName 'all-empty' -ProjectRoot $Project -SessionMembers ([ordered]@{
      'LAST_MODEL_RESPONSE.md' = ''
      'LAST_OWNER_REQUEST.md' = ''
      'TOOL_EVENTS.jsonl' = ''
      'TRANSCRIPT_DELTA.jsonl' = ''
      'NO_NEW_EVENTS.json' = ''
    })
  $AllEmptyDeployment = Copy-DeploymentFixture -Source $DeploymentTemplate -Destination (Join-Path $TempRoot 'deployment-all-empty')
  $ManifestPath = Join-Path $AllEmptyDeployment 'DEPLOYMENT_MANIFEST.json'
  $ManifestBefore = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
  $AllEmpty = Invoke-Bootstrap -PipelineRoot $Pipeline -ProjectRoot $Project -DeploymentRoot $AllEmptyDeployment -HandoffArchive $AllEmptyArchive -CompanionAsset $CompanionAsset -ProjectId 'all-empty'
  Assert-True -Condition ($AllEmpty.Code -ne 0) -Message 'All-empty session delta must fail closed.'
  Assert-True -Condition ($AllEmpty.Text -match 'neither a non-empty session delta' -and $AllEmpty.Text -match 'no-new-events receipt') -Message "All-empty failure reason is not semantic: $($AllEmpty.Text)"
  Assert-True -Condition ($AllEmpty.Text -notmatch 'Cannot bind argument') -Message 'All-empty input regressed to a PowerShell binder failure.'
  Assert-True -Condition ((Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash -eq $ManifestBefore) -Message 'Failed all-empty generation changed the deployment manifest.'
  Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $AllEmptyDeployment 'COMPANION_RESTART_BOOTSTRAP_all-empty_1.2.27.zip'))) -Message 'Failed all-empty generation left a bootstrap ZIP.'

  $RequiredEmptyArchive = New-HandoffArchive -ArchivePath (Join-Path $TempRoot 'required-empty.zip') -FixtureName 'required-empty' -ProjectRoot $Project -SessionMembers ([ordered]@{
      'LAST_MODEL_RESPONSE.md' = "Verified response.`n"
    }) -EmptyCompanionEntry
  $RequiredEmptyDeployment = Copy-DeploymentFixture -Source $DeploymentTemplate -Destination (Join-Path $TempRoot 'deployment-required-empty')
  $RequiredEmptyResult = Invoke-Bootstrap -PipelineRoot $Pipeline -ProjectRoot $Project -DeploymentRoot $RequiredEmptyDeployment -HandoffArchive $RequiredEmptyArchive -CompanionAsset $CompanionAsset -ProjectId 'required-empty'
  Assert-True -Condition ($RequiredEmptyResult.Code -ne 0) -Message 'Empty required COMPANION_ENTRY.md must fail closed.'
  Assert-True -Condition ($RequiredEmptyResult.Text -match 'Required bootstrap input is empty' -and $RequiredEmptyResult.Text -match 'COMPANION_ENTRY\.md' -and $RequiredEmptyResult.Text -notmatch 'Cannot bind argument') -Message "Required empty failure is not semantic: $($RequiredEmptyResult.Text)"

  $Tokens = $null; $ParseErrors = $null
  $ProductionAst = [Management.Automation.Language.Parser]::ParseFile($Generator, [ref]$Tokens, [ref]$ParseErrors)
  Assert-True -Condition ($ParseErrors.Count -eq 0) -Message 'Cannot parse production bootstrap functions for helper regression.'
  foreach ($FunctionName in @('Ensure-Directory', 'Write-Utf8File', 'Read-StrictUtf8Text', 'Get-Sha256', 'Assert-SafeRelativePath', 'Assert-NoSecretLiteral', 'Add-AllowlistedTextFile')) {
    $Definitions = @($ProductionAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $FunctionName }, $true))
    Assert-True -Condition ($Definitions.Count -eq 1) -Message "Production helper definition is missing or ambiguous: $FunctionName"
    . ([scriptblock]::Create($Definitions[0].Extent.Text))
  }
  $script:StageRoot = Join-Path $TempRoot 'helper-stage'
  $script:MaxFileBytes = 1MB; $script:MaxTotalBytes = 2MB; $script:TotalBytes = [int64]0; $script:Included = @(); $script:Excluded = @()
  $RequiredEmpty = Join-Path $TempRoot 'required-empty.json'
  Write-Utf8Text -Path $RequiredEmpty -Text ''
  $RequiredMessage = ''
  try { Add-AllowlistedTextFile -Source $RequiredEmpty -RelativePath 'STATE/required-empty.json' -Category 'required_fixture' -Required }
  catch { $RequiredMessage = $_.Exception.Message }
  Assert-True -Condition ($RequiredMessage -like '*Required bootstrap input is empty*') -Message 'Required zero-byte input does not fail with a semantic reason.'
  $ForbiddenEmpty = Join-Path $TempRoot 'ACTION_PACKET.json'
  Write-Utf8Text -Path $ForbiddenEmpty -Text ''
  $ForbiddenMessage = ''
  try { Add-AllowlistedTextFile -Source $ForbiddenEmpty -RelativePath 'STATE/ACTION_PACKET.json' -Category 'forbidden_fixture' }
  catch { $ForbiddenMessage = $_.Exception.Message }
  Assert-True -Condition ($ForbiddenMessage -like '*Forbidden secret or raw packet file selected*') -Message 'Forbidden zero-byte file name bypassed privacy validation.'

  $DistributionText = [IO.File]::ReadAllText($Distribution, [Text.Encoding]::UTF8)
  $HardText = [IO.File]::ReadAllText($HardValidator, [Text.Encoding]::UTF8)
  Assert-True -Condition ($DistributionText.Contains('Test-CompanionRestartSessionDelta.ps1')) -Message 'Session-delta regression is not wired into Distribution Core.'
  Assert-True -Condition ($HardText.Contains('Test-CompanionRestartSessionDelta.ps1')) -Message 'Session-delta regression is not required by hard package validation.'

  foreach ($Path in $SourceFiles) {
    Assert-True -Condition ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $BeforeHashes[$Path]) -Message "Regression mutated source: $Path"
  }
  Write-Host "Companion restart session-delta regression passed. Assertions=$Assertions; source_changed=false"
}
finally {
  $FullTemp = [IO.Path]::GetFullPath($TempRoot)
  $SystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ($FullTemp.StartsWith($SystemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $FullTemp).StartsWith('agentic-bootstrap-session-delta-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $FullTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
