[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HelperPath = Join-Path $Root 'scripts\release\common\CompanionRestartHandoffArchive.ps1'
$ProductionPath = Join-Path $Root 'scripts\release\Create-Companion-Restart-Bootstrap-v1.2.25.ps1'
$script:Assertions = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

function Assert-Throws {
  param([scriptblock]$Action, [string]$MessagePattern, [string]$Label)
  try { & $Action }
  catch {
    if ($_.Exception.Message -notlike $MessagePattern) {
      throw "$Label returned an unexpected error: $($_.Exception.Message)"
    }
    $script:Assertions++
    return
  }
  throw "$Label did not fail closed."
}

function New-FixtureArchive {
  param([string]$Path, [string[]]$Entries)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $Archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    foreach ($Name in $Entries) {
      $Entry = $Archive.CreateEntry($Name, [IO.Compression.CompressionLevel]::NoCompression)
      $Writer = [IO.StreamWriter]::new($Entry.Open(), [Text.UTF8Encoding]::new($false))
      try { $Writer.Write("fixture:$Name") }
      finally { $Writer.Dispose() }
    }
  }
  finally {
    $Archive.Dispose()
    $Stream.Dispose()
  }
}

$HelperTokens = $null
$HelperErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$HelperTokens, [ref]$HelperErrors)
Assert-True (@($HelperErrors).Count -eq 0) 'Archive-root helper must parse.'
. $HelperPath

$ProductionText = Get-Content -LiteralPath $ProductionPath -Raw -Encoding UTF8
Assert-True ($ProductionText.Contains(". (Join-Path `$PSScriptRoot 'common\CompanionRestartHandoffArchive.ps1')")) 'Production bootstrap must import the archive-root helper.'
Assert-True ($ProductionText.Contains("Test-ZipSafety -ArchivePath `$HandoffArchiveFull -RequiredRootEntry 'COMPANION_ENTRY.md'")) 'Production bootstrap must bind the exact root full-name before extraction.'
Assert-True ($ProductionText.Contains('Resolve-ExactHandoffArchiveRoot -ExtractRoot $HandoffExtract')) 'Production bootstrap must resolve the exact archive-root entry.'
Assert-True (-not $ProductionText.Contains("Get-ChildItem -LiteralPath `$HandoffExtract -Recurse -File -Filter 'COMPANION_ENTRY.md'")) 'Production bootstrap must not search COMPANION_ENTRY.md recursively.'

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-restart-root-entry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempRoot | Out-Null
try {
  $PositiveZip = Join-Path $TempRoot 'positive.zip'
  New-FixtureArchive -Path $PositiveZip -Entries @(
    'COMPANION_ENTRY.md',
    'HANDOFF/COMPANION_ENTRY.md',
    'SOURCE_SNAPSHOTS/snapshot-1/.agy/COMPANION_ENTRY.md'
  )
  Test-ZipSafety -ArchivePath $PositiveZip -RequiredRootEntry 'COMPANION_ENTRY.md'
  $PositiveExtract = Join-Path $TempRoot 'positive'
  Expand-Archive -LiteralPath $PositiveZip -DestinationPath $PositiveExtract
  $Resolved = Resolve-ExactHandoffArchiveRoot -ExtractRoot $PositiveExtract
  Assert-True ([string]::Equals($Resolved, (Resolve-Path -LiteralPath $PositiveExtract).Path, [StringComparison]::OrdinalIgnoreCase)) 'Nested snapshot entry must not make the valid root entry ambiguous.'
  Assert-True (Test-Path -LiteralPath (Join-Path $PositiveExtract 'HANDOFF\COMPANION_ENTRY.md') -PathType Leaf) 'Positive fixture must retain the restart-output HANDOFF copy.'
  Assert-True (Test-Path -LiteralPath (Join-Path $PositiveExtract 'SOURCE_SNAPSHOTS\snapshot-1\.agy\COMPANION_ENTRY.md') -PathType Leaf) 'Positive fixture must retain the nested snapshot duplicate.'

  $MissingZip = Join-Path $TempRoot 'missing.zip'
  New-FixtureArchive -Path $MissingZip -Entries @('SOURCE_SNAPSHOTS/snapshot-1/.agy/COMPANION_ENTRY.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $MissingZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*missing required exact root entry*' -Label 'Missing archive-root entry'

  $WrongCaseZip = Join-Path $TempRoot 'wrong-case.zip'
  New-FixtureArchive -Path $WrongCaseZip -Entries @('companion_entry.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $WrongCaseZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*incorrect case*' -Label 'Wrong-case archive-root entry'

  $CaseCollisionZip = Join-Path $TempRoot 'case-collision.zip'
  New-FixtureArchive -Path $CaseCollisionZip -Entries @('COMPANION_ENTRY.md', 'companion_entry.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $CaseCollisionZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*duplicate or case-colliding paths*' -Label 'Case-colliding archive-root entries'

  $ExactDuplicateZip = Join-Path $TempRoot 'exact-duplicate.zip'
  New-FixtureArchive -Path $ExactDuplicateZip -Entries @('COMPANION_ENTRY.md', 'COMPANION_ENTRY.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $ExactDuplicateZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*duplicate or case-colliding paths*' -Label 'Duplicate archive-root entries'

  $BackslashAliasZip = Join-Path $TempRoot 'backslash-alias.zip'
  New-FixtureArchive -Path $BackslashAliasZip -Entries @('folder\COMPANION_ENTRY.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $BackslashAliasZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*unsafe path*' -Label 'Backslash alias archive-root entry'

  $DirectoryOnlyZip = Join-Path $TempRoot 'directory-only.zip'
  New-FixtureArchive -Path $DirectoryOnlyZip -Entries @('COMPANION_ENTRY.md', 'EXTRA_DIRECTORY/')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $DirectoryOnlyZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*directory-only entries*' -Label 'Any directory-only ZIP entry'

  $DotAliasZip = Join-Path $TempRoot 'dot-alias.zip'
  New-FixtureArchive -Path $DotAliasZip -Entries @('COMPANION_ENTRY.md', './COMPANION_ENTRY.md')
  Assert-Throws -Action { Test-ZipSafety -ArchivePath $DotAliasZip -RequiredRootEntry 'COMPANION_ENTRY.md' } -MessagePattern '*unsafe path*' -Label 'Extra dot-alias archive-root entry'
}
finally {
  $FullTemp = [IO.Path]::GetFullPath($TempRoot)
  $SystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ($FullTemp.StartsWith($SystemTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $FullTemp).StartsWith('agentic-restart-root-entry-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $FullTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Companion restart handoff archive-root regression passed: $script:Assertions assertions."
exit 0
