[CmdletBinding()]
param(
  [string]$CompanionZip = '',
  [string]$OutputRoot = "$env:USERPROFILE\Downloads\Agentic-Pipeline-Companion-1.2.23",
  [string]$CanonicalRepo = '',
  [string]$ExpectedAssetSha256 = '',
  [string]$ExpectedSourceCommit = '',
  [switch]$Force,
  [switch]$OpenFolder,
  [switch]$SkipClipboard
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$EcosystemVersion = '1.2.23'

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

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
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

function Test-PackageRoot {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$CanonicalRoot
  )
  $ManifestPath = Join-Path $PackageRoot 'MANIFEST.json'
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'Companion package MANIFEST.json is missing.' }
  $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$Manifest.ecosystem_version -ne $EcosystemVersion -or [string]$Manifest.companion_version -ne $EcosystemVersion) {
    throw 'Companion package version mismatch.'
  }
  if ([string]$Manifest.source.commit -notmatch '^[0-9a-f]{40}$' -or $Manifest.source.working_tree_clean -ne $true) {
    throw 'Companion package is not bound to an exact clean source commit.'
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -and [string]$Manifest.source.commit -ne $ExpectedSourceCommit) {
    throw "Companion source commit mismatch: expected=$ExpectedSourceCommit actual=$($Manifest.source.commit)"
  }
  $Instruction = [string]$Manifest.active_upload_set.project_instructions
  if ($Instruction -ne '01_PROJECT_INSTRUCTIONS_v1.2.23.md') { throw 'Unexpected active Project Instructions file.' }
  $ExpectedModules = @(
    '00_AGENTIC_PIPELINE_INDEX_v1.2.23.md', '01_CONTEXT_SPLIT_POLICY.md', '02_AGENT_TASK_PACK_CONTRACT_v1.2.23.md',
    '03_PRODUCT_EVIDENCE_CONTROL_PLANE.md', '04_PROJECT_AUDIT_AND_RECOVERY.md', '05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md',
    '06_RUNTIME_TRUTH_REVIEW_POLICY.md', '07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md', '08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md',
    '09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md', '10_STATUS_AND_FINDING_LIFECYCLE.md', '11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md',
    '12_GOLDEN_EVALS.md', '13_LOCAL_CONTROL_TOOLS.md', '14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md',
    '15_OWNER_OUTPUT_PRESENTATION.md'
  )
  $Modules = @($Manifest.active_upload_set.knowledge_modules)
  if ($Modules.Count -ne 16 -or (Compare-Object -ReferenceObject $ExpectedModules -DifferenceObject $Modules)) {
    throw 'Companion package must declare exactly one module for every number 00-15.'
  }
  for ($Index = 0; $Index -lt $ExpectedModules.Count; $Index++) {
    if ([string]$Modules[$Index] -cne $ExpectedModules[$Index]) { throw 'Companion knowledge upload order is not canonical.' }
  }
  $KnowledgeFiles = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'knowledge') -File -Filter '*.md' | Sort-Object Name)
  if ($KnowledgeFiles.Count -ne 16 -or (Compare-Object -ReferenceObject $ExpectedModules -DifferenceObject @($KnowledgeFiles.Name))) {
    throw 'Companion package knowledge directory differs from the exact active upload set.'
  }
  $Forbidden = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object {
      $_.Name -match 'SYSTEM_PROMPT|REPAIR_BUDGET|ACTION_BRIDGE_CAPABILITY|ACTION_PACKET\.json|\.env|token|secret|cookie'
    })
  if ($Forbidden.Count -gt 0) { throw "Companion package contains a forbidden or ambiguous file: $($Forbidden[0].Name)" }
  $ChecklistFiles = @(Get-ChildItem -LiteralPath $PackageRoot -File -Filter '*CHECKLIST*.txt')
  if ($ChecklistFiles.Count -ne 1 -or $ChecklistFiles[0].Name -ne 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt') {
    throw 'Companion package must contain exactly one UI checklist.'
  }
  $NumberedLines = @(Get-Content -LiteralPath $ChecklistFiles[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\d+\.\s' })
  if ($NumberedLines.Count -ne 3 -or $NumberedLines[0] -notmatch '^1\.' -or $NumberedLines[1] -notmatch '^2\.' -or $NumberedLines[2] -notmatch '^3\.') {
    throw 'Companion UI checklist must contain exactly three numbered steps.'
  }
  foreach ($RequiredSupport in @('VERSION.json', 'UPLOAD_ORDER.txt', 'NEW_CHAT_FIRST_MESSAGE.txt', 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $RequiredSupport) -PathType Leaf)) { throw "Required Companion support file is missing: $RequiredSupport" }
  }
  $ExpectedSupport = @('VERSION.json', 'UPLOAD_ORDER.txt', 'NEW_CHAT_FIRST_MESSAGE.txt', 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt')
  if (@($Manifest.support_files).Count -ne $ExpectedSupport.Count -or
      (Compare-Object -ReferenceObject $ExpectedSupport -DifferenceObject @($Manifest.support_files))) {
    throw 'Companion support-file set is not exact.'
  }
  $DeclaredFiles = @($Manifest.files)
  $ExpectedActivePaths = @($Instruction) + @($ExpectedModules | ForEach-Object { "knowledge/$_" })
  $ExpectedPayloadPaths = @($ExpectedActivePaths + $ExpectedSupport)
  $DeclaredPaths = @($DeclaredFiles | ForEach-Object { [string]$_.path })
  if ($DeclaredPaths.Count -ne $ExpectedPayloadPaths.Count -or
      (Compare-Object -ReferenceObject $ExpectedPayloadPaths -DifferenceObject $DeclaredPaths)) {
    throw 'Companion payload contains an undeclared role or is missing an exact required file.'
  }
  foreach ($Declared in $DeclaredFiles) {
    $Relative = [string]$Declared.path
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('\') -or $Relative -match '(^|/)\.\.(/|$)') {
      throw "Unsafe Companion manifest path: $Relative"
    }
    $Full = Join-Path $PackageRoot $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw "Declared Companion file is missing: $Relative" }
    if ((Get-Item -LiteralPath $Full).Length -ne [int64]$Declared.size_bytes -or (Get-Sha256 -Path $Full) -ne [string]$Declared.sha256) {
      throw "Companion manifest parity failure: $Relative"
    }
    $ExpectedRole = if ($ExpectedActivePaths -contains $Relative) { 'active_upload' } else { 'support_not_project_knowledge' }
    if ([string]$Declared.deployment_role -cne $ExpectedRole) { throw "Companion deployment role mismatch: $Relative" }
    $ExpectedCanonical = if ($Relative -eq $Instruction) {
      "docs/companion/$Instruction"
    } elseif ($Relative.StartsWith('knowledge/', [StringComparison]::Ordinal)) {
      'docs/companion/' + (Split-Path -Leaf $Relative)
    } elseif ($Relative -eq 'VERSION.json') {
      'docs/companion/VERSION.json'
    } else {
      ''
    }
    if ([string]$Declared.canonical_source -cne $ExpectedCanonical) { throw "Companion canonical-source binding mismatch: $Relative" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCanonical)) {
      $CanonicalPath = Join-Path $CanonicalRoot $ExpectedCanonical
      if (-not (Test-Path -LiteralPath $CanonicalPath -PathType Leaf)) { throw "Canonical Companion source is missing: $($Declared.canonical_source)" }
      if ((Get-Sha256 -Path $CanonicalPath) -ne [string]$Declared.sha256) { throw "Canonical/package parity failure: $($Declared.canonical_source)" }
    }
  }
  $Actual = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/')
    } | Sort-Object)
  $Expected = @((@($DeclaredFiles.path) + 'MANIFEST.json') | Sort-Object)
  if (Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual) { throw 'Companion package contains undeclared or missing files.' }
  return $Manifest
}

function Test-PreparedDeployment {
  param(
    [Parameter(Mandatory = $true)][string]$DeploymentRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedIdentity,
    [Parameter(Mandatory = $true)]$ExpectedPackageManifest,
    [Parameter(Mandatory = $true)][string]$ExpectedPackageManifestHash,
    [Parameter(Mandatory = $true)][string]$ExpectedAssetHash,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceCommit
  )
  $DeploymentManifestPath = Join-Path $DeploymentRoot 'DEPLOYMENT_MANIFEST.json'
  if (-not (Test-Path -LiteralPath $DeploymentManifestPath -PathType Leaf)) { return $false }
  try { $DeploymentManifest = Get-Content -LiteralPath $DeploymentManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { return $false }
  if ([string]$DeploymentManifest.deployment_identity_sha256 -ne $ExpectedIdentity) { return $false }
  if ([string]$DeploymentManifest.source.commit -ne $ExpectedSourceCommit -or $DeploymentManifest.source.clean -ne $true -or
      [string]$DeploymentManifest.companion_asset.sha256 -ne $ExpectedAssetHash -or
      [string]$DeploymentManifest.companion_asset.package_manifest_sha256 -ne $ExpectedPackageManifestHash) { return $false }
  $PackageManifestPath = Join-Path $DeploymentRoot 'MANIFEST.json'
  if (-not (Test-Path -LiteralPath $PackageManifestPath -PathType Leaf) -or (Get-Sha256 -Path $PackageManifestPath) -ne $ExpectedPackageManifestHash) { return $false }
  $ExpectedFiles = @($ExpectedPackageManifest.files)
  $DeploymentFiles = @($DeploymentManifest.package_files)
  if ($DeploymentFiles.Count -ne $ExpectedFiles.Count) { return $false }
  foreach ($ExpectedFile in $ExpectedFiles) {
    $Relative = [string]$ExpectedFile.path
    $DeploymentFileMatches = @($DeploymentFiles | Where-Object { [string]$_.path -ceq $Relative })
    if ($DeploymentFileMatches.Count -ne 1) { return $false }
    $File = $DeploymentFileMatches[0]
    if ([string]$File.sha256 -ne [string]$ExpectedFile.sha256 -or [int64]$File.size_bytes -ne [int64]$ExpectedFile.size_bytes -or
        [string]$File.deployment_role -cne [string]$ExpectedFile.deployment_role -or
        [string]$File.canonical_source -cne [string]$ExpectedFile.canonical_source) { return $false }
    $Path = Join-Path $DeploymentRoot $Relative
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne [int64]$File.size_bytes -or (Get-Sha256 -Path $Path) -ne [string]$File.sha256) { return $false }
  }
  $Knowledge = @(Get-ChildItem -LiteralPath (Join-Path $DeploymentRoot 'knowledge') -File -Filter '*.md' -ErrorAction SilentlyContinue)
  $Checklists = @(Get-ChildItem -LiteralPath $DeploymentRoot -File -Filter '*CHECKLIST*.txt' -ErrorAction SilentlyContinue)
  if ($Knowledge.Count -ne 16 -or $Checklists.Count -ne 1 -or $Checklists[0].Name -cne 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt') { return $false }
  $ChecklistSteps = @(Get-Content -LiteralPath $Checklists[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\d+\.\s' })
  if ($ChecklistSteps.Count -ne 3) { return $false }
  $AllowedPaths = @($ExpectedFiles.path) + @('MANIFEST.json', 'DEPLOYMENT_MANIFEST.json')
  if ($null -ne $DeploymentManifest.restart_bootstrap) {
    $RestartFile = [string]$DeploymentManifest.restart_bootstrap.file
    $RestartResult = [string]$DeploymentManifest.restart_bootstrap.result_file
    if ([string]::IsNullOrWhiteSpace($RestartFile) -or [string]::IsNullOrWhiteSpace($RestartResult) -or
        [IO.Path]::GetFileName($RestartFile) -cne $RestartFile -or [IO.Path]::GetFileName($RestartResult) -cne $RestartResult) { return $false }
    $RestartPath = Join-Path $DeploymentRoot $RestartFile
    $ResultPath = Join-Path $DeploymentRoot $RestartResult
    if (-not (Test-Path -LiteralPath $RestartPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or
        (Get-Sha256 -Path $RestartPath) -ne [string]$DeploymentManifest.restart_bootstrap.sha256) { return $false }
    try { $RestartReceipt = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if ([string]$RestartReceipt.zip_sha256 -ne [string]$DeploymentManifest.restart_bootstrap.sha256 -or
        [string]$RestartReceipt.input_identity_sha256 -ne [string]$DeploymentManifest.restart_bootstrap.input_identity_sha256 -or
        [string]$RestartReceipt.deployment_identity_sha256 -ne $ExpectedIdentity) { return $false }
    $AllowedPaths += @($RestartFile, $RestartResult)
  }
  $ActualPaths = @(Get-ChildItem -LiteralPath $DeploymentRoot -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($DeploymentRoot, $_.FullName).Replace('\', '/')
    })
  if ($ActualPaths.Count -ne $AllowedPaths.Count -or (Compare-Object -ReferenceObject $AllowedPaths -DifferenceObject $ActualPaths)) { return $false }
  return $true
}

if ([string]::IsNullOrWhiteSpace($CanonicalRepo)) {
  $CanonicalRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$CanonicalRoot = (Resolve-Path -LiteralPath $CanonicalRepo).Path
if ([string]::IsNullOrWhiteSpace($CompanionZip)) {
  $KitCandidate = Join-Path $PSScriptRoot 'prebuilt\agentic-companion-1.2.23.zip'
  $RepoCandidate = Join-Path $CanonicalRoot '.artifacts\release-kit\1.2.23\companion\agentic-companion-1.2.23.zip'
  if (Test-Path -LiteralPath $KitCandidate -PathType Leaf) { $CompanionZip = $KitCandidate }
  elseif (Test-Path -LiteralPath $RepoCandidate -PathType Leaf) { $CompanionZip = $RepoCandidate }
}
if ([string]::IsNullOrWhiteSpace($CompanionZip) -or -not (Test-Path -LiteralPath $CompanionZip -PathType Leaf)) {
  throw 'Companion 1.2.23 ZIP was not found. Pass -CompanionZip explicitly.'
}
$CompanionZipFull = (Resolve-Path -LiteralPath $CompanionZip).Path
$AssetHash = Get-Sha256 -Path $CompanionZipFull
if (-not [string]::IsNullOrWhiteSpace($ExpectedAssetSha256) -and $AssetHash -ne $ExpectedAssetSha256.ToLowerInvariant()) {
  throw "Companion asset hash mismatch: expected=$ExpectedAssetSha256 actual=$AssetHash"
}

$Protected = @($env:USERPROFILE, $CanonicalRoot, $CompanionZipFull, [IO.Path]::GetPathRoot($CanonicalRoot))
$OutputFull = Assert-SafeOutputLeaf -Path $OutputRoot -ProtectedPaths $Protected
$OutputParent = Split-Path -Parent $OutputFull
if (-not (Test-Path -LiteralPath $OutputParent -PathType Container)) { New-Item -ItemType Directory -Path $OutputParent -Force | Out-Null }
$OutputLeaf = Split-Path -Leaf $OutputFull
$OperationId = [guid]::NewGuid().ToString('N')
$Stage = Assert-SafeOutputLeaf -Path (Join-Path $OutputParent ".$OutputLeaf.stage-$OperationId") -ProtectedPaths $Protected
$Rollback = Assert-SafeOutputLeaf -Path (Join-Path $OutputParent "$OutputLeaf.rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$($OperationId.Substring(0, 8))") -ProtectedPaths $Protected
$ExtractRoot = Join-Path ([IO.Path]::GetTempPath()) ("companion-prepare-1.2.23-$OperationId")
$MovedAside = $false
$Installed = $false

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [IO.Compression.ZipFile]::OpenRead($CompanionZipFull)
  try {
    $Entries = @($Archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    if ($Entries.Count -lt 1) { throw 'Companion ZIP is empty.' }
    $Names = @($Entries | ForEach-Object { $_.FullName })
    $CaseFoldedNames = @($Names | ForEach-Object { $_.ToLowerInvariant() })
    if (@($CaseFoldedNames | Sort-Object -Unique).Count -ne $CaseFoldedNames.Count) { throw 'Companion ZIP contains duplicate or case-colliding entries.' }
    foreach ($Name in $Names) {
      if ($Name.Contains('\') -or $Name.StartsWith('/') -or $Name -match '^[A-Za-z]:' -or $Name -match '(^|/)\.\.(/|$)') {
        throw "Companion ZIP contains an unsafe path: $Name"
      }
      if (-not $Name.StartsWith('agentic-companion-1.2.23/', [StringComparison]::Ordinal)) {
        throw "Companion ZIP contains an unexpected package root: $Name"
      }
    }
  }
  finally { $Archive.Dispose() }

  Expand-Archive -LiteralPath $CompanionZipFull -DestinationPath $ExtractRoot
  $PackageRoot = Join-Path $ExtractRoot 'agentic-companion-1.2.23'
  $PackageManifest = Test-PackageRoot -PackageRoot $PackageRoot -CanonicalRoot $CanonicalRoot
  $PackageManifestHash = Get-Sha256 -Path (Join-Path $PackageRoot 'MANIFEST.json')
  $IdentityDocument = [ordered]@{
    ecosystem_version = $EcosystemVersion
    source_commit = [string]$PackageManifest.source.commit
    companion_asset_sha256 = $AssetHash
    active_upload_set = $PackageManifest.active_upload_set
    active_files = @($PackageManifest.files | Where-Object { [string]$_.deployment_role -eq 'active_upload' } | ForEach-Object {
        [ordered]@{ path = [string]$_.path; sha256 = [string]$_.sha256 }
      })
  }
  $DeploymentIdentity = Get-StringSha256 -Text ($IdentityDocument | ConvertTo-Json -Depth 20 -Compress)

  if ((Test-Path -LiteralPath $OutputFull -PathType Container) -and
      (Test-PreparedDeployment -DeploymentRoot $OutputFull -ExpectedIdentity $DeploymentIdentity -ExpectedPackageManifest $PackageManifest `
        -ExpectedPackageManifestHash $PackageManifestHash -ExpectedAssetHash $AssetHash -ExpectedSourceCommit ([string]$PackageManifest.source.commit))) {
    $InstructionsPath = Join-Path $OutputFull '01_PROJECT_INSTRUCTIONS_v1.2.23.md'
    if (-not $SkipClipboard) { Set-Clipboard -Value (Get-Content -LiteralPath $InstructionsPath -Raw -Encoding UTF8) }
    Write-Host "Companion deployment already matches the exact asset: $OutputFull"
    if ($OpenFolder) { Start-Process explorer.exe -ArgumentList "/select,`"$InstructionsPath`"" }
    return
  }
  if ((Test-Path -LiteralPath $OutputFull) -and -not $Force) { throw "Output exists and differs from the exact Companion asset: $OutputFull. Re-run with -Force to preserve it as rollback and replace it." }

  New-Item -ItemType Directory -Path $Stage -Force | Out-Null
  Get-ChildItem -LiteralPath $PackageRoot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Stage -Recurse
  }
  foreach ($File in @($PackageManifest.files)) {
    $PreparedPath = Join-Path $Stage ([string]$File.path)
    if (-not (Test-Path -LiteralPath $PreparedPath -PathType Leaf) -or
        (Get-Sha256 -Path $PreparedPath) -ne [string]$File.sha256 -or
        (Get-Item -LiteralPath $PreparedPath).Length -ne [int64]$File.size_bytes) {
      throw "Package/deployment parity failure: $($File.path)"
    }
  }
  $DeploymentManifest = [ordered]@{
    schema_version = '1.0.0'
    ecosystem_version = $EcosystemVersion
    component = 'companion_deployment'
    status = 'PREPARED'
    deployment_role = 'derived_chatgpt_upload_copy'
    source = [ordered]@{ commit = [string]$PackageManifest.source.commit; clean = $true }
    companion_asset = [ordered]@{
      path = $CompanionZipFull
      file = Split-Path -Leaf $CompanionZipFull
      sha256 = $AssetHash
      size_bytes = (Get-Item -LiteralPath $CompanionZipFull).Length
      package_manifest_sha256 = $PackageManifestHash
    }
    deployment_identity_sha256 = $DeploymentIdentity
    active_upload_set = $PackageManifest.active_upload_set
    package_files = @($PackageManifest.files)
    ui_checklist = 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt'
    ui_checklist_steps = 3
    upload_order = 'UPLOAD_ORDER.txt'
    first_message = 'NEW_CHAT_FIRST_MESSAGE.txt'
    restart_bootstrap = $null
    rollback = if (Test-Path -LiteralPath $OutputFull) { [ordered]@{ path = $Rollback; preserved = $true } } else { $null }
    validation = [ordered]@{ canonical_package_parity = 'PASS'; package_deployment_parity = 'PASS'; active_module_count = 16; active_instruction_count = 1 }
    prepared_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-Utf8File -Path (Join-Path $Stage 'DEPLOYMENT_MANIFEST.json') -Text ($DeploymentManifest | ConvertTo-Json -Depth 30)
  if (-not (Test-PreparedDeployment -DeploymentRoot $Stage -ExpectedIdentity $DeploymentIdentity -ExpectedPackageManifest $PackageManifest `
      -ExpectedPackageManifestHash $PackageManifestHash -ExpectedAssetHash $AssetHash -ExpectedSourceCommit ([string]$PackageManifest.source.commit))) {
    throw 'Prepared Companion deployment failed final parity validation.'
  }

  if (Test-Path -LiteralPath $OutputFull) { Move-Item -LiteralPath $OutputFull -Destination $Rollback; $MovedAside = $true }
  Move-Item -LiteralPath $Stage -Destination $OutputFull
  $Installed = $true
  $Instructions = Join-Path $OutputFull '01_PROJECT_INSTRUCTIONS_v1.2.23.md'
  if (-not $SkipClipboard) { Set-Clipboard -Value (Get-Content -LiteralPath $Instructions -Raw -Encoding UTF8) }
  Write-Host 'COMPANION 1.2.23 DEPLOYMENT PREPARED AND VERIFIED.' -ForegroundColor Green
  Write-Host "Deployment: $OutputFull"
  Write-Host "Project Instructions: $Instructions"
  Write-Host "Knowledge modules: $(Join-Path $OutputFull 'knowledge')"
  if ($MovedAside) { Write-Host "Rollback copy: $Rollback" }
  if ($OpenFolder) { Start-Process explorer.exe -ArgumentList "/select,`"$Instructions`"" }
}
catch {
  if ($Installed -and (Test-Path -LiteralPath $OutputFull)) { Remove-Item -LiteralPath $OutputFull -Recurse -Force }
  if ($MovedAside -and (Test-Path -LiteralPath $Rollback)) { Move-Item -LiteralPath $Rollback -Destination $OutputFull }
  throw
}
finally {
  if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
  Remove-SafeTemporaryDirectory -Path $ExtractRoot -LeafPrefix 'companion-prepare-1.2.23-'
}
