function Test-ZipSafety {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [string]$RequiredRootEntry = ''
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $AllEntries = @($Archive.Entries)
    $Entries = @($AllEntries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    if ($Entries.Count -ne $AllEntries.Count) { throw "ZIP contains unexpected directory-only entries: $ArchivePath" }
    if ($Entries.Count -lt 1) { throw "ZIP is empty: $ArchivePath" }
    $Names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $AllEntries) {
      $Name = [string]$Entry.FullName
      if (-not $Names.Add($Name)) { throw "ZIP contains duplicate or case-colliding paths: $ArchivePath" }
      if ($Name.Contains('\') -or $Name.StartsWith('/') -or $Name -match '^[A-Za-z]:' -or $Name -match '(^|/)\.\.?(/|$)') {
        throw "ZIP contains an unsafe path: $Name"
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredRootEntry)) {
      if ($RequiredRootEntry.Contains('/') -or $RequiredRootEntry.Contains('\') -or [IO.Path]::IsPathRooted($RequiredRootEntry)) {
        throw "Required ZIP root entry must be one exact file name: $RequiredRootEntry"
      }
      $RootCandidates = @($Entries | Where-Object {
          [string]::Equals([string]$_.FullName, $RequiredRootEntry, [StringComparison]::OrdinalIgnoreCase)
        })
      if ($RootCandidates.Count -eq 0) {
        throw "ZIP is missing required exact root entry: $RequiredRootEntry"
      }
      if ($RootCandidates.Count -ne 1) {
        throw "ZIP contains ambiguous required root entries: $RequiredRootEntry"
      }
      if ([string]$RootCandidates[0].FullName -cne $RequiredRootEntry) {
        throw "ZIP required root entry has incorrect case: $($RootCandidates[0].FullName)"
      }
    }
  }
  finally { $Archive.Dispose() }
}

function Resolve-ExactHandoffArchiveRoot {
  param([Parameter(Mandatory = $true)][string]$ExtractRoot)

  if (-not (Test-Path -LiteralPath $ExtractRoot -PathType Container)) {
    throw "Exact handoff extraction root is missing: $ExtractRoot"
  }
  $Root = (Resolve-Path -LiteralPath $ExtractRoot).Path
  $RootCandidates = @(Get-ChildItem -LiteralPath $Root -Force -File | Where-Object {
      [string]::Equals($_.Name, 'COMPANION_ENTRY.md', [StringComparison]::OrdinalIgnoreCase)
    })
  if ($RootCandidates.Count -eq 0) {
    throw 'Exact handoff archive must contain COMPANION_ENTRY.md at the archive root.'
  }
  if ($RootCandidates.Count -ne 1) {
    throw 'Exact handoff archive root contains ambiguous COMPANION_ENTRY.md entries.'
  }
  $Entry = $RootCandidates[0]
  if ([string]$Entry.Name -cne 'COMPANION_ENTRY.md') {
    throw 'Exact handoff archive root entry must use the exact path and case COMPANION_ENTRY.md.'
  }
  if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Exact handoff archive root entry must not be a reparse point.'
  }
  $ExpectedEntry = Join-Path $Root 'COMPANION_ENTRY.md'
  if (-not [string]::Equals([IO.Path]::GetFullPath($Entry.FullName), [IO.Path]::GetFullPath($ExpectedEntry), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Exact handoff archive root entry escaped the extraction root.'
  }
  return $Root
}
