[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$ProjectRoot = '.',
  [AllowEmptyString()][string]$VerificationReceiptPath = '',
  [AllowEmptyString()][string]$AuditResultPath = '',
  [switch]$Apply,
  [ValidateRange(1, 900)][int]$TimeoutSeconds = 120,
  [Parameter(DontShow = $true)][switch]$Worker,
  [Parameter(DontShow = $true)][string]$WorkerToken = '',
  [Parameter(DontShow = $true)][string]$WorkerOutputPath = '',
  [Parameter(DontShow = $true)][string]$ExpectedReceiptSha256 = '',
  [Parameter(DontShow = $true)][ValidateRange(0, 4)][int]$FaultInjectionAfterPublishes = 0
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$script:PathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

function Throw-ResultAuthorityError {
  param([Parameter(Mandatory = $true)][string]$Code, [Parameter(Mandatory = $true)][string]$Message)
  throw "[$Code] $Message"
}

function Get-RequiredValue {
  param($Object, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Code)
  if ($null -eq $Object) { Throw-ResultAuthorityError $Code "Object containing '$Name' is missing." }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { Throw-ResultAuthorityError $Code "Required property '$Name' is missing." }
  return $Property.Value
}

function Get-OptionalValue {
  param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return $Default }
  return $Property.Value
}

function Get-RequiredString {
  param($Object, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Code)
  $Value = [string](Get-RequiredValue $Object $Name $Code)
  if ([string]::IsNullOrWhiteSpace($Value)) { Throw-ResultAuthorityError $Code "Required property '$Name' is empty." }
  return $Value
}

function Get-RequiredUtcTimestamp {
  param($Object, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Code)
  $Text = Get-RequiredString $Object $Name $Code
  if ($Text -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
    Throw-ResultAuthorityError $Code "Property '$Name' must be an ISO-8601 timestamp with an explicit UTC offset."
  }
  $Parsed = [DateTimeOffset]::MinValue
  $Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  if (-not [DateTimeOffset]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Parsed)) {
    Throw-ResultAuthorityError $Code "Property '$Name' is not a valid UTC timestamp."
  }
  return $Parsed.ToUniversalTime()
}

function Get-Sha256Bytes {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-Sha256File {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertFrom-JsonBytes {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][string]$Description)
  try {
    $Text = $script:Utf8Strict.GetString($Bytes)
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    return $Text | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  catch {
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_INVALID_JSON' "$Description is not strict UTF-8 JSON: $($_.Exception.Message)"
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Description)
  return ConvertFrom-JsonBytes ([IO.File]::ReadAllBytes($Path)) $Description
}

function Get-OptionalJsonCapture {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)][string]$Description)
  $Path = Join-Path $Root $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Exists = $false; Value = $null; Sha256 = 'missing'; Bytes = $null } }
  $Path = Get-ConfinedFile $Root $RelativePath 'RESULT_AUTHORITY_PAYLOAD_AUTHORITY' '.agy'
  $Bytes = [IO.File]::ReadAllBytes($Path)
  return [pscustomobject]@{ Exists = $true; Value = ConvertFrom-JsonBytes $Bytes $Description; Sha256 = Get-Sha256Bytes $Bytes; Bytes = $Bytes }
}

function Test-PathWithin {
  param([Parameter(Mandatory = $true)][string]$BasePath, [Parameter(Mandatory = $true)][string]$CandidatePath)
  $Base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $Candidate = [IO.Path]::GetFullPath($CandidatePath)
  $Prefix = $Base + [IO.Path]::DirectorySeparatorChar
  return $Candidate.Equals($Base, $script:PathComparison) -or $Candidate.StartsWith($Prefix, $script:PathComparison)
}

function Assert-NoReparsePoint {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Code)
  $RootFull = [IO.Path]::GetFullPath($Root)
  $Probe = [IO.Path]::GetFullPath($Path)
  while (-not (Test-Path -LiteralPath $Probe)) {
    $Parent = Split-Path -Parent $Probe
    if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $Probe) { Throw-ResultAuthorityError $Code "Unable to resolve an existing path ancestor: $Path" }
    $Probe = $Parent
  }
  $Current = Get-Item -LiteralPath $Probe -Force -ErrorAction Stop
  while ($null -ne $Current) {
    if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$Current.LinkType)) {
      Throw-ResultAuthorityError $Code "Reparse points are not permitted in validated paths: $($Current.FullName)"
    }
    if ($Current.FullName.Equals($RootFull, $script:PathComparison)) { break }
    $Current = if ($Current -is [IO.FileInfo]) { $Current.Directory } else { $Current.Parent }
  }
}

function Get-ConfinedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$Code,
    [string]$RequiredSubtree = ''
  )
  $RootFull = [IO.Path]::GetFullPath($Root)
  $Full = if ([IO.Path]::IsPathRooted($InputPath)) { [IO.Path]::GetFullPath($InputPath) } else { [IO.Path]::GetFullPath((Join-Path $RootFull $InputPath)) }
  if (-not (Test-PathWithin $RootFull $Full)) { Throw-ResultAuthorityError $Code "Path escapes the project root: $InputPath" }
  if (-not [string]::IsNullOrWhiteSpace($RequiredSubtree)) {
    $Subtree = [IO.Path]::GetFullPath((Join-Path $RootFull $RequiredSubtree))
    if (-not (Test-PathWithin $Subtree $Full)) { Throw-ResultAuthorityError $Code "Path is outside required subtree '$RequiredSubtree': $InputPath" }
  }
  if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { Throw-ResultAuthorityError $Code "Required file is missing: $InputPath" }
  Assert-NoReparsePoint $RootFull $Full $Code
  return $Full
}

function Get-CanonicalRelativePath {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
  $Relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), [IO.Path]::GetFullPath($Path)).Replace('\', '/')
  if ([IO.Path]::IsPathRooted($Relative) -or $Relative -eq '..' -or $Relative.StartsWith('../', [StringComparison]::Ordinal)) {
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_PATH_ESCAPE' "Unable to produce a confined project-relative path: $Path"
  }
  return $Relative
}

function Normalize-DeclaredRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Code)
  if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') { Throw-ResultAuthorityError $Code "Path must be a non-empty project-relative path: $Path" }
  $Normalized = $Path.Replace('\', '/')
  if ($Normalized.StartsWith('./', [StringComparison]::Ordinal)) { $Normalized = $Normalized.Substring(2) }
  $Segments = @($Normalized.Split('/'))
  if ($Segments.Count -eq 0 -or @($Segments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -in @('.', '..') }).Count -gt 0) { Throw-ResultAuthorityError $Code "Path contains an empty, dot, or parent segment: $Path" }
  if ($Normalized.IndexOfAny([char[]]@([char]0, [char]1, [char]2, [char]3, [char]4, [char]5, [char]6, [char]7, [char]8, [char]9, [char]10, [char]11, [char]12, [char]13, [char]14, [char]15, [char]16, [char]17, [char]18, [char]19, [char]20, [char]21, [char]22, [char]23, [char]24, [char]25, [char]26, [char]27, [char]28, [char]29, [char]30, [char]31, [char]127, '<', '>', ':', '"', '|', '?', '*')) -ge 0) { Throw-ResultAuthorityError $Code "Path contains a control or non-portable character: $Path" }
  foreach ($Segment in $Segments) {
    if ($Segment.EndsWith(' ', [StringComparison]::Ordinal) -or $Segment.EndsWith('.', [StringComparison]::Ordinal)) { Throw-ResultAuthorityError $Code "Path segment has a non-portable trailing character: $Path" }
    $DeviceStem = $Segment.Split('.')[0]
    if ($DeviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { Throw-ResultAuthorityError $Code "Path contains a reserved device segment: $Path" }
  }
  return $Normalized
}

function Write-AtomicBytes {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
  $Directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $Directory -Force) }
  $Temporary = Join-Path $Directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllBytes($Temporary, $Bytes)
    [IO.File]::Move($Temporary, $Path, $true)
  }
  finally {
    if (Test-Path -LiteralPath $Temporary -PathType Leaf) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

function Write-AtomicJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value, [int]$Depth = 60)
  Write-AtomicBytes $Path $script:Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Depth $Depth))
}

function Invoke-BoundedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [ValidateRange(1, 900)][int]$TimeoutSeconds = 30
  )
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $FilePath
  $StartInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardInput = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = $script:Utf8NoBom
  $StartInfo.StandardErrorEncoding = $script:Utf8NoBom
  foreach ($Argument in $ArgumentList) { [void]$StartInfo.ArgumentList.Add([string]$Argument) }
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw "Failed to start process: $FilePath" }
    $Process.StandardInput.Close()
    $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
    $StdErrTask = $Process.StandardError.ReadToEndAsync()
    $TimedOut = -not $Process.WaitForExit($TimeoutSeconds * 1000)
    if ($TimedOut) {
      try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
      [void]$Process.WaitForExit(5000)
    }
    else { $Process.WaitForExit() }
    $StdOut = $StdOutTask.GetAwaiter().GetResult()
    $StdErr = $StdErrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
      TimedOut = $TimedOut
      ExitCode = if ($Process.HasExited) { [int]$Process.ExitCode } else { -1 }
      StdOut = [string]$StdOut
      StdErr = [string]$StdErr
      ProcessId = [int]$Process.Id
    }
  }
  finally { $Process.Dispose() }
}

function Invoke-Git {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $Git = (Get-Command git -ErrorAction Stop).Source
  $Result = Invoke-BoundedProcess $Git (@('-C', $Root) + $Arguments) $Root 15
  if ($Result.TimedOut) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_GIT_TIMEOUT' "git $($Arguments -join ' ') exceeded 15 seconds." }
  if ($Result.ExitCode -ne 0) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_GIT_FAILED' "git $($Arguments -join ' ') failed with exit code $($Result.ExitCode)." }
  return $Result.StdOut.TrimEnd([char]13, [char]10)
}

function Get-GitContext {
  param([Parameter(Mandatory = $true)][string]$Root)
  $Branch = Invoke-Git $Root @('branch', '--show-current')
  $Head = Invoke-Git $Root @('rev-parse', 'HEAD')
  $Status = Invoke-Git $Root @('status', '--porcelain=v2', '-z', '--untracked-files=all')
  $StableStatus = Invoke-Git $Root @('status', '--porcelain=v2', '-z', '--untracked-files=all', '--', '.', ':(exclude,top).agy/VERIFICATION_RECEIPT.json', ':(exclude,top).agy/CLOSURE_STATE.json', ':(exclude,top).agy/RUN_RESULT.json', ':(exclude,top).agy/NEXT_ACTION.json', ':(exclude,top).agy/.runtime/**')
  return [pscustomobject]@{ Branch = $Branch; Head = $Head; Status = $Status; StableStatus = $StableStatus }
}

function Assert-EqualString {
  param([string]$Actual, [string]$Expected, [string]$Code, [string]$Description, [switch]$IgnoreCase)
  $Comparison = if ($IgnoreCase) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if (-not ([string]$Actual).Equals([string]$Expected, $Comparison)) { Throw-ResultAuthorityError $Code "$Description does not match current authority." }
}

function Get-ValidatedCompilationContext {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ReceiptInput,
    [string]$AuditInput = '',
    [string]$ExpectedReceiptHash = '',
    [Collections.IDictionary]$PublishedControlHashes = $null
  )
  if ($null -ne $PublishedControlHashes) {
    foreach ($PublishedPath in @($PublishedControlHashes.Keys)) {
      if ([string]$PublishedPath -cne '.agy/NEXT_ACTION.json' -or [string]$PublishedControlHashes[$PublishedPath] -cnotmatch '^[0-9a-f]{64}$') {
        Throw-ResultAuthorityError 'RESULT_AUTHORITY_INTERNAL_CONTRACT' 'Published control hash override is not the exact NEXT_ACTION output contract.'
      }
    }
  }
  $Root = (Resolve-Path -LiteralPath $Root).Path
  $Agy = Join-Path $Root '.agy'
  if (-not (Test-Path -LiteralPath $Agy -PathType Container)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_STATE_MISSING' '.agy directory is missing.' }
  $ReceiptPath = Get-ConfinedFile $Root $ReceiptInput 'RESULT_AUTHORITY_RECEIPT_PATH' '.agy'
  $ReceiptBytes = [IO.File]::ReadAllBytes($ReceiptPath)
  $ReceiptHash = Get-Sha256Bytes $ReceiptBytes
  if (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptHash)) {
    if ($ExpectedReceiptHash -notmatch '^[0-9a-f]{64}$') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_INTERNAL_CONTRACT' 'Expected receipt hash is malformed.' }
    Assert-EqualString $ReceiptHash $ExpectedReceiptHash 'RESULT_AUTHORITY_RECEIPT_CHANGED' 'Verification receipt hash' -IgnoreCase
  }
  $Receipt = ConvertFrom-JsonBytes $ReceiptBytes 'Verification receipt'
  if ((Get-RequiredString $Receipt 'schema_version' 'RESULT_AUTHORITY_RECEIPT_SCHEMA') -ne '1.0.0') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_SCHEMA' 'Verification receipt schema_version must be 1.0.0.' }
  $WorkItemPath = Get-ConfinedFile $Root '.agy/WORK_ITEM.json' 'RESULT_AUTHORITY_STATE_MISSING' '.agy'
  $LeasePath = Get-ConfinedFile $Root '.agy/EXECUTION_LEASE.json' 'RESULT_AUTHORITY_STATE_MISSING' '.agy'
  $CandidateStatusPath = Get-ConfinedFile $Root '.agy/CANDIDATE_MANIFEST_STATUS.json' 'RESULT_AUTHORITY_CANDIDATE_MISSING' '.agy'
  $CandidatePath = Get-ConfinedFile $Root '.agy/CANDIDATE_MANIFEST.json' 'RESULT_AUTHORITY_CANDIDATE_MISSING' '.agy'
  $WorkItemBytes = [IO.File]::ReadAllBytes($WorkItemPath); $WorkItem = ConvertFrom-JsonBytes $WorkItemBytes 'WORK_ITEM.json'
  $LeaseBytes = [IO.File]::ReadAllBytes($LeasePath); $Lease = ConvertFrom-JsonBytes $LeaseBytes 'EXECUTION_LEASE.json'
  $CandidateStatusBytes = [IO.File]::ReadAllBytes($CandidateStatusPath); $CandidateStatus = ConvertFrom-JsonBytes $CandidateStatusBytes 'CANDIDATE_MANIFEST_STATUS.json'
  $CandidateBytes = [IO.File]::ReadAllBytes($CandidatePath); $Candidate = ConvertFrom-JsonBytes $CandidateBytes 'CANDIDATE_MANIFEST.json'
  $Git = Get-GitContext $Root

  $WorkItemId = Get-RequiredString $WorkItem 'work_item_id' 'RESULT_AUTHORITY_WORK_ITEM_BINDING'
  $GoalEpoch = [int](Get-RequiredValue $WorkItem 'goal_epoch' 'RESULT_AUTHORITY_WORK_ITEM_BINDING')
  $LeaseId = Get-RequiredString $Lease 'lease_id' 'RESULT_AUTHORITY_LEASE_BINDING'
  if ((Get-RequiredString $Lease 'status' 'RESULT_AUTHORITY_LEASE_BINDING') -ne 'active') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_LEASE_BINDING' 'Execution lease is not active.' }
  Assert-EqualString (Get-RequiredString $Lease 'work_item_id' 'RESULT_AUTHORITY_LEASE_BINDING') $WorkItemId 'RESULT_AUTHORITY_LEASE_BINDING' 'Lease work_item_id'
  if ([int](Get-RequiredValue $Lease 'goal_epoch' 'RESULT_AUTHORITY_LEASE_BINDING') -ne $GoalEpoch) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_LEASE_BINDING' 'Lease goal_epoch does not match the current work item.' }
  Assert-EqualString (Get-RequiredString $Lease 'branch' 'RESULT_AUTHORITY_LEASE_BINDING') $Git.Branch 'RESULT_AUTHORITY_LEASE_BINDING' 'Lease branch'
  Assert-EqualString (Get-RequiredString $Lease 'baseline_head' 'RESULT_AUTHORITY_LEASE_BINDING') $Git.Head 'RESULT_AUTHORITY_LEASE_BINDING' 'Lease baseline_head' -IgnoreCase

  Assert-EqualString (Get-RequiredString $Receipt 'work_item_id' 'RESULT_AUTHORITY_RECEIPT_BINDING') $WorkItemId 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt work_item_id'
  if ([int](Get-RequiredValue $Receipt 'goal_epoch' 'RESULT_AUTHORITY_RECEIPT_BINDING') -ne $GoalEpoch) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt goal_epoch does not match the current work item.' }
  Assert-EqualString (Get-RequiredString $Receipt 'branch' 'RESULT_AUTHORITY_RECEIPT_BINDING') $Git.Branch 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt branch'
  Assert-EqualString (Get-RequiredString $Receipt 'head' 'RESULT_AUTHORITY_RECEIPT_BINDING') $Git.Head 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt head' -IgnoreCase
  Assert-EqualString (Get-RequiredString $Receipt 'execution_lease_id' 'RESULT_AUTHORITY_RECEIPT_BINDING') $LeaseId 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt execution_lease_id'

  if ((Get-RequiredString $CandidateStatus 'status' 'RESULT_AUTHORITY_CANDIDATE_BINDING') -ne 'current') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate manifest status is not current.' }
  $CandidateHash = Get-Sha256Bytes $CandidateBytes
  Assert-EqualString (Get-RequiredString $CandidateStatus 'manifest_sha256' 'RESULT_AUTHORITY_CANDIDATE_BINDING') $CandidateHash 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate status manifest hash' -IgnoreCase
  Assert-EqualString (Get-RequiredString $Candidate 'work_item_id' 'RESULT_AUTHORITY_CANDIDATE_BINDING') $WorkItemId 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate work_item_id'
  Assert-EqualString (Get-RequiredString $Candidate 'lease_id' 'RESULT_AUTHORITY_CANDIDATE_BINDING') $LeaseId 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate lease_id'
  Assert-EqualString (Get-RequiredString $Candidate 'branch' 'RESULT_AUTHORITY_CANDIDATE_BINDING') $Git.Branch 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate branch'
  Assert-EqualString (Get-RequiredString $Candidate 'head' 'RESULT_AUTHORITY_CANDIDATE_BINDING') $Git.Head 'RESULT_AUTHORITY_CANDIDATE_BINDING' 'Candidate head' -IgnoreCase
  Assert-EqualString (Get-RequiredString $Receipt 'candidate_manifest_sha256' 'RESULT_AUTHORITY_RECEIPT_BINDING') $CandidateHash 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt candidate_manifest_sha256' -IgnoreCase

  $CandidatePaths = @()
  foreach ($File in @((Get-RequiredValue $Candidate 'candidate_files' 'RESULT_AUTHORITY_CANDIDATE_BINDING'))) {
    $DeclaredPath = Get-RequiredString $File 'path' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    $NormalizedPath = Normalize-DeclaredRelativePath $DeclaredPath 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    if ($DeclaredPath.Replace('\', '/') -cne $NormalizedPath) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate path is not canonical: $DeclaredPath" }
    $CandidateFull = [IO.Path]::GetFullPath((Join-Path $Root $NormalizedPath))
    if (-not (Test-PathWithin $Root $CandidateFull)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate path escapes project root: $DeclaredPath" }
    Assert-NoReparsePoint $Root $CandidateFull 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    $ExistsValue = Get-RequiredValue $File 'exists' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    if ($ExistsValue -isnot [bool]) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate exists flag is not boolean: $DeclaredPath" }
    if ([bool]$ExistsValue) {
      if (-not (Test-Path -LiteralPath $CandidateFull -PathType Leaf)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate file declared present is missing: $DeclaredPath" }
      Assert-NoReparsePoint $Root $CandidateFull 'RESULT_AUTHORITY_CANDIDATE_BINDING'
      $Size = [long](Get-RequiredValue $File 'size_bytes' 'RESULT_AUTHORITY_CANDIDATE_BINDING')
      $Hash = Get-RequiredString $File 'sha256' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
      $CurrentCandidateBytes = [IO.File]::ReadAllBytes($CandidateFull)
      if ($Hash -cnotmatch '^[0-9a-f]{64}$' -or $CurrentCandidateBytes.Length -ne $Size -or (Get-Sha256Bytes $CurrentCandidateBytes) -ne $Hash) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate file identity changed: $DeclaredPath" }
    }
    else {
      if (Test-Path -LiteralPath $CandidateFull) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate file declared absent now exists: $DeclaredPath" }
      if ($null -ne (Get-OptionalValue $File 'size_bytes' $null) -or $null -ne (Get-OptionalValue $File 'sha256' $null)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Absent candidate file has a size or hash: $DeclaredPath" }
    }
    $CandidatePaths += $NormalizedPath
  }
  $ControlPaths = @()
  foreach ($File in @((Get-RequiredValue $Candidate 'control_plane_files' 'RESULT_AUTHORITY_CANDIDATE_BINDING'))) {
    $DeclaredPath = Get-RequiredString $File 'path' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    $NormalizedPath = Normalize-DeclaredRelativePath $DeclaredPath 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    if ($DeclaredPath.Replace('\', '/') -cne $NormalizedPath) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Control-plane path is not canonical: $DeclaredPath" }
    $Size = [long](Get-RequiredValue $File 'size_bytes' 'RESULT_AUTHORITY_CANDIDATE_BINDING')
    $Hash = Get-RequiredString $File 'sha256' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
    if ($Size -lt 0 -or $Hash -cnotmatch '^[0-9a-f]{64}$') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Control-plane manifest identity is malformed: $DeclaredPath" }
    $PublishedHash = if ($null -ne $PublishedControlHashes -and $PublishedControlHashes.Contains($NormalizedPath)) { [string]$PublishedControlHashes[$NormalizedPath] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($PublishedHash)) {
      $ControlFull = Get-ConfinedFile $Root $NormalizedPath 'RESULT_AUTHORITY_PUBLICATION_VERIFY' '.agy'
      $CurrentControlHash = Get-Sha256File $ControlFull
      if ($CurrentControlHash -ne $PublishedHash) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_PUBLICATION_VERIFY' "Published control-plane output hash mismatch: $DeclaredPath" }
    }
    elseif ($NormalizedPath -cne '.agy/NEXT_ACTION.json') {
      $ControlFull = Get-ConfinedFile $Root $NormalizedPath 'RESULT_AUTHORITY_CANDIDATE_BINDING' '.agy'
      $ControlBytes = [IO.File]::ReadAllBytes($ControlFull)
      if ($ControlBytes.Length -ne $Size -or (Get-Sha256Bytes $ControlBytes) -ne $Hash) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Control-plane file identity changed: $DeclaredPath" }
    }
    $ControlPaths += $NormalizedPath
  }
  $ChangedPaths = @()
  foreach ($Path in @((Get-RequiredValue $Receipt 'changed_files' 'RESULT_AUTHORITY_RECEIPT_BINDING'))) {
    $DeclaredChangedPath = [string]$Path
    $NormalizedChangedPath = Normalize-DeclaredRelativePath $DeclaredChangedPath 'RESULT_AUTHORITY_RECEIPT_BINDING'
    if ($DeclaredChangedPath.Replace('\', '/') -cne $NormalizedChangedPath) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_BINDING' "Receipt changed_files path is not canonical: $DeclaredChangedPath" }
    $ChangedPaths += $NormalizedChangedPath
  }
  $CandidateUnique = @($CandidatePaths | Sort-Object -CaseSensitive -Unique)
  $ChangedUnique = @($ChangedPaths | Sort-Object -CaseSensitive -Unique)
  $CandidatePortableUnique = @($CandidatePaths | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
  $ChangedPortableUnique = @($ChangedPaths | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
  if ($CandidateUnique.Count -ne $CandidatePaths.Count -or $ChangedUnique.Count -ne $ChangedPaths.Count -or $CandidatePortableUnique.Count -ne $CandidatePaths.Count -or $ChangedPortableUnique.Count -ne $ChangedPaths.Count) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Candidate or receipt changed_files contains duplicate or case-colliding paths.' }
  if (($CandidateUnique -join "`n") -cne ($ChangedUnique -join "`n")) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_BINDING' 'Receipt changed_files is not the exact candidate file set.' }

  $ReceiptCompleted = Get-RequiredUtcTimestamp $Receipt 'completed_at_utc' 'RESULT_AUTHORITY_RECEIPT_FRESHNESS'
  $Now = [DateTimeOffset]::UtcNow
  if ($ReceiptCompleted -gt $Now) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_FRESHNESS' 'Receipt completed_at_utc is in the future.' }
  $CandidateGenerated = Get-RequiredUtcTimestamp $Candidate 'generated_at_utc' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
  $CandidateUpdated = Get-RequiredUtcTimestamp $CandidateStatus 'updated_at_utc' 'RESULT_AUTHORITY_CANDIDATE_BINDING'
  $LeaseIssued = Get-RequiredUtcTimestamp $Lease 'issued_at_utc' 'RESULT_AUTHORITY_LEASE_BINDING'
  foreach ($Boundary in @($CandidateGenerated, $CandidateUpdated, $LeaseIssued)) {
    if ($ReceiptCompleted -lt $Boundary) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_FRESHNESS' 'Receipt predates current candidate or execution authority.' }
  }

  $NormalizedTests = @()
  $RequiredCount = 0
  foreach ($Test in @((Get-RequiredValue $Receipt 'tests' 'RESULT_AUTHORITY_TEST_BINDING'))) {
    $RunId = Get-RequiredString $Test 'run_id' 'RESULT_AUTHORITY_TEST_BINDING'
    $RequiredValue = Get-RequiredValue $Test 'required' 'RESULT_AUTHORITY_TEST_BINDING'
    if ($RequiredValue -isnot [bool]) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_BINDING' "Test '$RunId' required must be boolean." }
    $IsRequired = [bool]$RequiredValue
    $ExitCode = [int](Get-RequiredValue $Test 'exit_code' 'RESULT_AUTHORITY_TEST_BINDING')
    $Completed = Get-RequiredUtcTimestamp $Test 'completed_at_utc' 'RESULT_AUTHORITY_TEST_BINDING'
    $StartedText = [string](Get-OptionalValue $Test 'started_at_utc' '')
    $Started = $null
    if ($IsRequired -and [string]::IsNullOrWhiteSpace($StartedText)) {
      Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_BINDING' "Required test '$RunId' is missing started_at_utc."
    }
    if (-not [string]::IsNullOrWhiteSpace($StartedText)) {
      $Temporary = [pscustomobject]@{ started_at_utc = $StartedText }
      $Started = Get-RequiredUtcTimestamp $Temporary 'started_at_utc' 'RESULT_AUTHORITY_TEST_BINDING'
      if ($Started -gt $Completed) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_BINDING' "Test '$RunId' starts after it completes." }
    }
    if ($Completed -gt $ReceiptCompleted) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_BINDING' "Test '$RunId' completes after the verification receipt." }
    $EvidenceDeclared = Get-RequiredString $Test 'evidence_path' 'RESULT_AUTHORITY_TEST_EVIDENCE'
    $EvidencePath = Get-ConfinedFile $Root $EvidenceDeclared 'RESULT_AUTHORITY_TEST_EVIDENCE' '.agy/verification'
    $EvidenceRelative = Get-CanonicalRelativePath $Root $EvidencePath
    if ($EvidenceDeclared.Replace('\', '/') -cne $EvidenceRelative) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence_path is not canonical." }
    if ($EvidenceRelative -match '(?i)(^|/)(\.env(?:\.|$)|[^/]*(?:capability|credential|secret|token|password|passwd|api[-_]?key|private[-_]?key|id_rsa|id_ed25519)[^/]*)') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence_path has a forbidden sensitive name." }
    $EvidenceHash = Get-RequiredString $Test 'evidence_sha256' 'RESULT_AUTHORITY_TEST_EVIDENCE'
    if ($EvidenceHash -cnotmatch '^[0-9a-f]{64}$') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence_sha256 must be lowercase SHA-256." }
    $EvidenceSize = [long](Get-RequiredValue $Test 'evidence_size_bytes' 'RESULT_AUTHORITY_TEST_EVIDENCE')
    if ($EvidenceSize -lt 0) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence_size_bytes is negative." }
    $EvidenceItem = Get-Item -LiteralPath $EvidencePath -Force
    $EvidenceBytes = [IO.File]::ReadAllBytes($EvidencePath)
    if ([long]$EvidenceBytes.Length -ne $EvidenceSize) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence size does not match." }
    Assert-EqualString (Get-Sha256Bytes $EvidenceBytes) $EvidenceHash 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence hash" -IgnoreCase
    $EvidenceModified = [DateTimeOffset]::new($EvidenceItem.LastWriteTimeUtc)
    if ($EvidenceModified -gt $Completed) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_EVIDENCE' "Test '$RunId' evidence was modified after test completion." }
    if ($IsRequired) {
      $RequiredCount++
      if ($ExitCode -ne 0) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_FAILED' "Required test '$RunId' failed with exit code $ExitCode." }
      if ($CandidateGenerated -gt $Started -or $CandidateUpdated -gt $Started) {
        Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_TEST_ORDER' "Candidate authority was published after required test '$RunId' started."
      }
    }
    $NormalizedTests += [ordered]@{
      run_id = $RunId
      required = $IsRequired
      exit_code = $ExitCode
      started_at_utc = if ($null -ne $Started) { $Started.ToString('o') } else { $null }
      finished_at_utc = $Completed.ToString('o')
      completed_at_utc = $Completed.ToString('o')
      evidence_path = $EvidenceRelative
      evidence_sha256 = $EvidenceHash
      evidence_size_bytes = $EvidenceSize
      supersedes_run_id = [string](Get-OptionalValue $Test 'supersedes_run_id' '')
      summary = [string](Get-OptionalValue $Test 'summary' '')
    }
  }
  if ($RequiredCount -eq 0) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_TEST_BINDING' 'Verification receipt has no required tests.' }

  $ArtifactCollections = @{}
  foreach ($Name in @('evidence_artifacts', 'product_artifacts')) {
    $Normalized = @()
    foreach ($Declared in @((Get-RequiredValue $Receipt $Name 'RESULT_AUTHORITY_RECEIPT_BINDING'))) {
      $ArtifactPath = Get-ConfinedFile $Root ([string]$Declared) 'RESULT_AUTHORITY_RECEIPT_BINDING'
      $ArtifactRelative = Get-CanonicalRelativePath $Root $ArtifactPath
      if (([string]$Declared).Replace('\', '/') -cne $ArtifactRelative) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_BINDING' "Receipt $Name contains a non-canonical path." }
      if ([DateTimeOffset]::new((Get-Item -LiteralPath $ArtifactPath -Force).LastWriteTimeUtc) -gt $ReceiptCompleted) {
        Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_FRESHNESS' "Receipt predates referenced artifact: $ArtifactRelative"
      }
      $Normalized += $ArtifactRelative
    }
    $ArtifactCollections[$Name] = @($Normalized)
  }

  $Audit = $null
  $AuditHash = $null
  if (-not [string]::IsNullOrWhiteSpace($AuditInput)) {
    $AuditPath = Get-ConfinedFile $Root $AuditInput 'RESULT_AUTHORITY_AUDIT_BINDING' '.agy'
    $AuditBytes = [IO.File]::ReadAllBytes($AuditPath)
    $AuditHash = Get-Sha256Bytes $AuditBytes
    $Audit = ConvertFrom-JsonBytes $AuditBytes 'Audit result'
    Assert-EqualString (Get-RequiredString $Audit 'work_item_id' 'RESULT_AUTHORITY_AUDIT_BINDING') $WorkItemId 'RESULT_AUTHORITY_AUDIT_BINDING' 'Audit work_item_id'
    Assert-EqualString (Get-RequiredString $Audit 'target_commit' 'RESULT_AUTHORITY_AUDIT_BINDING') $Git.Head 'RESULT_AUTHORITY_AUDIT_BINDING' 'Audit target_commit' -IgnoreCase
    if ((Get-RequiredUtcTimestamp $Audit 'audit_timestamp_utc' 'RESULT_AUTHORITY_AUDIT_BINDING') -gt $ReceiptCompleted) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_AUDIT_BINDING' 'Audit result postdates the verification receipt.' }
  }

  $FindingsCapture = Get-OptionalJsonCapture $Root '.agy/FINDINGS.json' 'FINDINGS.json'
  $ProgressCapture = Get-OptionalJsonCapture $Root '.agy/PROGRESS_STATE.json' 'PROGRESS_STATE.json'
  $AttestationCapture = Get-OptionalJsonCapture $Root '.agy/REVIEWER_ATTESTATION.json' 'REVIEWER_ATTESTATION.json'
  $CoverageCapture = Get-OptionalJsonCapture $Root '.agy/AUDIT_COVERAGE_MATRIX.json' 'AUDIT_COVERAGE_MATRIX.json'
  $RequiredControlPaths = @('.agy/WORK_ITEM.json', '.agy/EXECUTION_LEASE.json')
  if ($FindingsCapture.Exists) { $RequiredControlPaths += '.agy/FINDINGS.json' }
  if ($ProgressCapture.Exists) { $RequiredControlPaths += '.agy/PROGRESS_STATE.json' }
  if ($AttestationCapture.Exists) { $RequiredControlPaths += '.agy/REVIEWER_ATTESTATION.json' }
  if ($CoverageCapture.Exists) { $RequiredControlPaths += '.agy/AUDIT_COVERAGE_MATRIX.json' }
  foreach ($RequiredControlPath in $RequiredControlPaths) {
    if ($ControlPaths -cnotcontains $RequiredControlPath) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_CANDIDATE_BINDING' "Candidate manifest does not bind payload authority: $RequiredControlPath" }
  }
  $TaskPath = Join-Path $Root '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
  $TaskHash = if (Test-Path -LiteralPath $TaskPath -PathType Leaf) { Get-Sha256File (Get-ConfinedFile $Root '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md' 'RESULT_AUTHORITY_TASK_BINDING' '.agy') } else { 'missing' }
  $AuthorityHashes = [ordered]@{
    work_item = Get-Sha256Bytes $WorkItemBytes
    execution_lease = Get-Sha256Bytes $LeaseBytes
    candidate_status = Get-Sha256Bytes $CandidateStatusBytes
    candidate_manifest = Get-Sha256Bytes $CandidateBytes
    findings = $FindingsCapture.Sha256
    progress_state = $ProgressCapture.Sha256
    reviewer_attestation = $AttestationCapture.Sha256
    audit_coverage = $CoverageCapture.Sha256
    active_task = $TaskHash
    audit_result = if ($AuditHash) { $AuditHash } else { 'missing' }
    git_status = Get-Sha256Bytes $script:Utf8NoBom.GetBytes([string]$Git.StableStatus)
  }

  return [pscustomobject]@{
    Root = $Root
    Agy = $Agy
    ReceiptPath = $ReceiptPath
    ReceiptRelative = Get-CanonicalRelativePath $Root $ReceiptPath
    ReceiptBytes = $ReceiptBytes
    ReceiptSha256 = $ReceiptHash
    Receipt = $Receipt
    ReceiptCompleted = $ReceiptCompleted
    WorkItem = $WorkItem
    WorkItemId = $WorkItemId
    GoalEpoch = $GoalEpoch
    Lease = $Lease
    LeaseId = $LeaseId
    Candidate = $Candidate
    CandidateSha256 = $CandidateHash
    CandidateStatus = $CandidateStatus
    Git = $Git
    ChangedFiles = $ChangedUnique
    Tests = $NormalizedTests
    EvidenceArtifacts = @($ArtifactCollections['evidence_artifacts'])
    ProductArtifacts = @($ArtifactCollections['product_artifacts'])
    Audit = $Audit
    AuditSha256 = $AuditHash
    Findings = $FindingsCapture.Value
    FindingsSha256 = $FindingsCapture.Sha256
    Progress = $ProgressCapture.Value
    Attestation = $AttestationCapture.Value
    AuditCoverage = $CoverageCapture.Value
    ActiveTaskExists = ($TaskHash -ne 'missing')
    AuthorityHashes = $AuthorityHashes
  }
}

function Get-RequestFingerprint {
  param([Parameter(Mandatory = $true)]$Context, [bool]$ApplyRequested)
  $Identity = [ordered]@{
    work_item_id = $Context.WorkItemId
    goal_epoch = $Context.GoalEpoch
    head = $Context.Git.Head
    execution_lease_id = $Context.LeaseId
    candidate_manifest_sha256 = $Context.CandidateSha256
    verification_receipt_sha256 = $Context.ReceiptSha256
    audit_result_sha256 = $Context.AuditSha256
    payload_authority = $Context.AuthorityHashes
    apply = $ApplyRequested
  } | ConvertTo-Json -Compress
  return Get-Sha256Bytes $script:Utf8NoBom.GetBytes($Identity)
}

function Convert-FindingToBlocker {
  param($Finding)
  return [ordered]@{
    code = ([string]$Finding.finding_id).ToUpperInvariant().Replace('-', '_')
    message = [string]$Finding.title
    category = [string]$Finding.category
    auto_repairable = [bool]$Finding.auto_repairable
  }
}

function New-CompilationPayload {
  param([Parameter(Mandatory = $true)]$Context)
  $Root = $Context.Root
  $Agy = $Context.Agy
  $WorkItem = $Context.WorkItem
  $Findings = if ($null -ne $Context.Findings) { @($Context.Findings.findings) } else { @() }
  $FindingPath = Join-Path $Agy 'FINDINGS.json'
  if ($null -ne $Context.Findings) {
    & (Join-Path $Root 'scripts/windows/companion/Test-FindingSet.ps1') -ProjectRoot $Root -FindingSetPath $FindingPath | Out-Null
    if ($LASTEXITCODE -ne 0) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_FINDINGS_INVALID' 'Finding set validation failed.' }
    if ((Get-Sha256File $FindingPath) -ne $Context.FindingsSha256) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_INPUT_CHANGED' 'FINDINGS.json changed during validation.' }
  }
  $Progress = if ($null -ne $Context.Progress) { $Context.Progress } else { [pscustomobject]@{ status = 'unknown'; observations_count = 0; consecutive_no_progress = 0; same_failure_count = 0; owner_decision_required = $false } }
  $Attestation = $Context.Attestation
  $Open = @($Findings | Where-Object { $_.lifecycle_status -eq 'open_confirmed' })
  $Product = @($Open | Where-Object { $_.materiality -eq 'product_blocker' })
  $VerificationBlockers = @($Open | Where-Object { $_.materiality -eq 'verification_blocker' })
  $ReleaseBlockers = @($Open | Where-Object { $_.materiality -eq 'release_blocker' })
  $OwnerDecisions = @($Open | Where-Object { $_.owner_decision_required -eq $true })
  $VerificationPassed = (@($Context.Tests | Where-Object { $_.required -and [int]$_.exit_code -ne 0 }).Count -eq 0)
  $Mode = [string]$WorkItem.assurance_mode
  $Independent = ($null -ne $Attestation -and [string](Get-OptionalValue $Attestation 'independence_status' '') -eq 'independent')
  $AuditStatusValue = if ($null -ne $Context.Audit) { [string](Get-OptionalValue $Context.Audit 'status' (Get-OptionalValue $Context.Audit 'verdict' '')) } else { '' }
  $AuditPassed = ($null -ne $Context.Audit -and $AuditStatusValue -eq 'passed' -and $Independent)
  $ConsecutiveNoProgress = [int](Get-OptionalValue $Progress 'consecutive_no_progress' 0)
  $SameFailureCount = [int](Get-OptionalValue $Progress 'same_failure_count' 0)
  $Stalled = ([string](Get-OptionalValue $Progress 'status' 'unknown') -eq 'stalled' -or $ConsecutiveNoProgress -ge 2 -or $SameFailureCount -ge 2)
  $OwnerDecisionRequired = ($OwnerDecisions.Count -gt 0 -or [bool](Get-OptionalValue $Progress 'owner_decision_required' $false))
  $NextWorkflow = $null
  $HardStop = $false
  if ($OwnerDecisionRequired) {
    $Acceptance = 'blocked'; $Implementation = 'blocked'; $VerificationStatus = 'blocked'; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'blocked' }; $Reason = 'true_owner_decision_required'; $HardStop = $true
  }
  elseif ($Product.Count -gt 0 -and -not $Stalled) {
    $Acceptance = 'not_evaluated'; $Implementation = 'in_progress'; $VerificationStatus = if ($VerificationPassed) { 'partial' } else { 'not_run' }; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'pending' }; $Reason = 'repair_continues_automatically'; $NextWorkflow = '/fixcritical'
  }
  elseif ($Product.Count -gt 0) {
    $Acceptance = 'blocked'; $Implementation = 'blocked'; $VerificationStatus = if ($VerificationPassed) { 'partial' } else { 'failed' }; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'blocked' }; $Reason = 'repeated_no_progress'; $HardStop = $true
  }
  elseif (-not $VerificationPassed) {
    $Acceptance = 'not_evaluated'; $Implementation = 'completed'; $VerificationStatus = 'blocked'; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'pending' }; $Reason = 'verification_continues_automatically'; $NextWorkflow = '/auditphase'
  }
  elseif ($Mode -ne 'flow' -and -not $AuditPassed) {
    $Acceptance = 'completed_with_verification_debt'; $Implementation = 'completed'; $VerificationStatus = 'partial'; $AuditStatus = 'blocked'; $Reason = 'protected_review_unavailable'
  }
  elseif ($VerificationBlockers.Count -gt 0 -or $ReleaseBlockers.Count -gt 0) {
    $Acceptance = 'completed_with_verification_debt'; $Implementation = 'completed'; $VerificationStatus = 'partial'; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'passed' }; $Reason = 'verification_or_release_debt'
  }
  else {
    $Acceptance = 'accepted'; $Implementation = 'completed'; $VerificationStatus = 'passed'; $AuditStatus = if ($Mode -eq 'flow') { 'not_required' } else { 'passed' }; $Reason = 'all_material_gates_passed'
  }
  $CompiledAt = [DateTimeOffset]::UtcNow
  if ($CompiledAt -lt $Context.ReceiptCompleted) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_RECEIPT_FRESHNESS' 'Compiler time predates receipt completion.' }
  $Now = $CompiledAt.ToString('o')
  $Closure = [ordered]@{
    schema_version = '1.0.0'; work_item_id = $Context.WorkItemId; implementation_status = $Implementation; verification_status = $VerificationStatus; audit_status = $AuditStatus; acceptance_status = $Acceptance
    release_status = if ($Acceptance -eq 'accepted' -and $Mode -eq 'release') { 'open' } elseif ($Mode -eq 'release' -or $Acceptance -eq 'completed_with_verification_debt' -or $HardStop) { 'blocked' } else { 'not_applicable' }
    next_owner_goal_allowed = ($Acceptance -in @('accepted', 'completed_with_verification_debt')); closure_reason = $Reason; open_finding_ids = @($Open | ForEach-Object { [string]$_.finding_id }); generated_at_utc = $Now
  }
  $ObservationCount = [int](Get-OptionalValue $Progress 'observations_count' 0)
  $ReceiptProvenance = [ordered]@{
    path = '.agy/VERIFICATION_RECEIPT.json'
    sha256 = $Context.ReceiptSha256
    completed_at_utc = $Context.ReceiptCompleted.ToString('o')
    work_item_id = $Context.WorkItemId
    head = $Context.Git.Head
    execution_lease_id = $Context.LeaseId
    candidate_manifest_sha256 = $Context.CandidateSha256
  }
  $Run = [ordered]@{
    schema_version = '1.0.0'; work_item_id = $Context.WorkItemId; assurance_mode = $Mode; branch = $Context.Git.Branch; head = $Context.Git.Head; git_state = if ([string]::IsNullOrEmpty($Context.Git.Status)) { 'clean' } else { 'dirty' }
    implementation_status = $Implementation; verification_status = $VerificationStatus; audit_status = $AuditStatus; acceptance_status = $Acceptance
    product_blockers = @($Product | ForEach-Object { Convert-FindingToBlocker $_ }); verification_blockers = @($VerificationBlockers | ForEach-Object { Convert-FindingToBlocker $_ }); release_blockers = @($ReleaseBlockers | ForEach-Object { Convert-FindingToBlocker $_ }); service_warnings = @()
    changed_files = @($Context.ChangedFiles); tests = @($Context.Tests); next_workflow = $NextWorkflow; no_progress = $Stalled; hard_stop = $HardStop; generated_at_utc = $Now; compiled_at_utc = $Now; verification_receipt = $ReceiptProvenance
    evidence_artifacts = @($Context.EvidenceArtifacts); product_artifacts = @($Context.ProductArtifacts); execution_lease_id = $Context.LeaseId
    audit_coverage_status = if ($null -ne $Context.AuditCoverage) { [string](Get-OptionalValue $Context.AuditCoverage 'status' 'blocked') } else { 'not_required' }
    reviewer_independence_status = if ($Mode -eq 'flow') { 'not_required' } elseif ($null -ne $Attestation) { [string](Get-OptionalValue $Attestation 'independence_status' 'unavailable') } else { 'unavailable' }
    progress_observations = $ObservationCount; progress_status = [string](Get-OptionalValue $Progress 'status' 'unknown'); consecutive_no_progress = $ConsecutiveNoProgress; same_failure_count = $SameFailureCount; closure_state_path = '.agy/CLOSURE_STATE.json'
  }
  $TaskRelative = '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
  $NextAction = [ordered]@{
    schema_version = '1.1.0'; work_item_id = $Context.WorkItemId; route = $NextWorkflow; auto_continue = ([bool]$NextWorkflow -and -not $OwnerDecisionRequired); owner_decision_required = $OwnerDecisionRequired
    owner_decision_reason = if ($OwnerDecisionRequired) { $Reason } else { $null }; technical_task_path = if ($Context.ActiveTaskExists) { $TaskRelative } else { $null }; updated_at_utc = $Now
  }
  return [ordered]@{ closure = $Closure; run_result = $Run; next_action = $NextAction }
}

function Read-SharedLockMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
      if ($Stream.Length -eq 0) { return $null }
      $Bytes = [byte[]]::new($Stream.Length)
      [void]$Stream.Read($Bytes, 0, $Bytes.Length)
      return ConvertFrom-JsonBytes $Bytes 'Result-authority lock metadata'
    }
    finally { $Stream.Dispose() }
  }
  catch { return $null }
}

function Get-CompilationMutexName {
  param([Parameter(Mandatory = $true)][string]$Root)
  $Identity = [IO.Path]::GetFullPath($Root).Replace('\', '/')
  if ($IsWindows) { $Identity = $Identity.ToUpperInvariant() }
  return 'AgenticPipelineResultAuthority-' + (Get-Sha256Bytes $script:Utf8NoBom.GetBytes($Identity))
}

function Open-OwnerLock {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$MutexName)
  $Mutex = $null
  $Owned = $false
  try {
    $Mutex = [Threading.Mutex]::new($false, $MutexName)
    try { $Owned = $Mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $Owned = $true }
    if (-not $Owned) { $Mutex.Dispose(); return $null }
    $Share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, $Share)
    return [pscustomobject]@{ Stream = $Stream; Mutex = $Mutex }
  }
  catch {
    if ($Owned -and $null -ne $Mutex) { try { $Mutex.ReleaseMutex() } catch {} }
    if ($null -ne $Mutex) { $Mutex.Dispose() }
    throw
  }
}

function Write-LockMetadata {
  param([Parameter(Mandatory = $true)][IO.FileStream]$Stream, [Parameter(Mandatory = $true)]$Value)
  $Bytes = $script:Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Depth 20))
  $Stream.Position = 0
  $Stream.SetLength(0)
  $Stream.Write($Bytes, 0, $Bytes.Length)
  $Stream.Flush($true)
}

function New-LockMetadata {
  param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Fingerprint, [Parameter(Mandatory = $true)][string]$Token, [int]$Timeout)
  $Started = [DateTimeOffset]::UtcNow
  return [ordered]@{
    schema_version = '1.0.0'; state = 'running'; token = $Token; request_fingerprint = $Fingerprint; project_root = $Context.Root; work_item_id = $Context.WorkItemId; goal_epoch = $Context.GoalEpoch; head = $Context.Git.Head
    owner_pid = $PID; owner_process_start_utc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); started_at_utc = $Started.ToString('o'); deadline_at_utc = $Started.AddSeconds($Timeout).ToString('o'); updated_at_utc = $Started.ToString('o')
  }
}

function Acquire-CompilationLease {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Fingerprint, [Parameter(Mandatory = $true)][string]$Token, [int]$Timeout)
  $LockPath = Join-Path $RuntimeRoot 'compile.lock'
  $PendingPath = Join-Path $RuntimeRoot 'pending.json'
  $MutexName = Get-CompilationMutexName $Context.Root
  $OwnerLock = Open-OwnerLock $LockPath $MutexName
  if ($null -ne $OwnerLock) {
    try {
      $Metadata = New-LockMetadata $Context $Fingerprint $Token $Timeout
      Write-LockMetadata $OwnerLock.Stream $Metadata
      return [pscustomobject]@{ State = 'owner'; Stream = $OwnerLock.Stream; Mutex = $OwnerLock.Mutex; Metadata = $Metadata; LockPath = $LockPath }
    }
    catch {
      $OwnerLock.Stream.Dispose()
      try { $OwnerLock.Mutex.ReleaseMutex() } finally { $OwnerLock.Mutex.Dispose() }
      throw
    }
  }
  $Active = Read-SharedLockMetadata $LockPath
  if ($null -ne $Active -and [string](Get-OptionalValue $Active 'state' '') -eq 'running' -and [string](Get-OptionalValue $Active 'request_fingerprint' '') -eq $Fingerprint) {
    return [pscustomobject]@{ State = 'coalesced_active'; Stream = $null; Mutex = $null; Metadata = $Active; LockPath = $LockPath }
  }
  $Pending = [ordered]@{ schema_version = '1.0.0'; token = $Token; request_fingerprint = $Fingerprint; requested_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
  Write-AtomicJson $PendingPath $Pending 10
  $WaitDeadline = [DateTimeOffset]::UtcNow.AddSeconds($Timeout + 15)
  if ($null -ne $Active) {
    try {
      $OwnerDeadline = Get-RequiredUtcTimestamp $Active 'deadline_at_utc' 'RESULT_AUTHORITY_LOCK_METADATA'
      if ($OwnerDeadline.AddSeconds(15) -gt $WaitDeadline) { $WaitDeadline = $OwnerDeadline.AddSeconds(15) }
    }
    catch {}
  }
  while ([DateTimeOffset]::UtcNow -lt $WaitDeadline) {
    Start-Sleep -Milliseconds 100
    $Latest = if (Test-Path -LiteralPath $PendingPath -PathType Leaf) { Read-JsonFile $PendingPath 'Result-authority pending request' } else { $null }
    if ($null -eq $Latest -or [string](Get-OptionalValue $Latest 'token' '') -ne $Token) {
      return [pscustomobject]@{ State = 'superseded'; Stream = $null; Metadata = $Latest; LockPath = $LockPath }
    }
    $OwnerLock = Open-OwnerLock $LockPath $MutexName
    if ($null -ne $OwnerLock) {
      try {
        $Metadata = New-LockMetadata $Context $Fingerprint $Token $Timeout
        Write-LockMetadata $OwnerLock.Stream $Metadata
        return [pscustomobject]@{ State = 'owner'; Stream = $OwnerLock.Stream; Mutex = $OwnerLock.Mutex; Metadata = $Metadata; LockPath = $LockPath }
      }
      catch {
        $OwnerLock.Stream.Dispose()
        try { $OwnerLock.Mutex.ReleaseMutex() } finally { $OwnerLock.Mutex.Dispose() }
        throw
      }
    }
  }
  Throw-ResultAuthorityError 'RESULT_AUTHORITY_COALESCE_TIMEOUT' 'Timed out waiting for the active result-authority compiler.'
}

function Set-CompilerStatus {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)]$Value)
  Write-AtomicJson (Join-Path $RuntimeRoot 'status.json') $Value 30
}

function Get-CompilerStatus {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
  $Path = Join-Path $RuntimeRoot 'status.json'
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Read-JsonFile $Path 'Result-authority status' } catch { return $null }
}

function Restore-PublicationJournal {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RuntimeRoot)
  $JournalPath = Join-Path $RuntimeRoot 'publication-journal.json'
  if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return }
  $Journal = Read-JsonFile $JournalPath 'Result-authority publication journal'
  $Status = Get-RequiredString $Journal 'status' 'RESULT_AUTHORITY_JOURNAL_INVALID'
  if ($Status -notin @('prepared', 'writing', 'committed')) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' "Unsupported publication journal status: $Status" }
  $Token = Get-RequiredString $Journal 'token' 'RESULT_AUTHORITY_JOURNAL_INVALID'
  if ($Token -cnotmatch '^[A-Za-z0-9._-]+$') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal token is not portable.' }
  $TransactionPath = Normalize-DeclaredRelativePath (Get-RequiredString $Journal 'transaction_path' 'RESULT_AUTHORITY_JOURNAL_INVALID') 'RESULT_AUTHORITY_JOURNAL_INVALID'
  $ExpectedTransactionPath = ".agy/.runtime/result-authority/transactions/$Token"
  if ($TransactionPath -cne $ExpectedTransactionPath) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal transaction path is not canonical.' }
  $TransactionFull = [IO.Path]::GetFullPath((Join-Path $Root $TransactionPath))
  $TransactionsRoot = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'transactions'))
  if (-not (Test-PathWithin $TransactionsRoot $TransactionFull) -or $TransactionFull.Equals($TransactionsRoot, $script:PathComparison)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal transaction directory is not confined.' }
  if (Test-Path -LiteralPath $TransactionFull) { Assert-NoReparsePoint $Root $TransactionFull 'RESULT_AUTHORITY_JOURNAL_INVALID' }
  $ExpectedTargets = @('.agy/VERIFICATION_RECEIPT.json', '.agy/CLOSURE_STATE.json', '.agy/RUN_RESULT.json', '.agy/NEXT_ACTION.json')
  $Targets = @((Get-RequiredValue $Journal 'targets' 'RESULT_AUTHORITY_JOURNAL_INVALID'))
  if ($Targets.Count -ne $ExpectedTargets.Count) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal does not contain the exact output set.' }
  $ValidatedTargets = @()
  for ($Index = 0; $Index -lt $Targets.Count; $Index++) {
    $Target = $Targets[$Index]
    $TargetRelative = Normalize-DeclaredRelativePath (Get-RequiredString $Target 'path' 'RESULT_AUTHORITY_JOURNAL_INVALID') 'RESULT_AUTHORITY_JOURNAL_INVALID'
    if ($TargetRelative -cne $ExpectedTargets[$Index]) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal output order or path is not canonical.' }
    $TargetPath = [IO.Path]::GetFullPath((Join-Path $Root $TargetRelative))
    Assert-NoReparsePoint $Root $TargetPath 'RESULT_AUTHORITY_JOURNAL_INVALID'
    $IntendedHash = Get-RequiredString $Target 'intended_sha256' 'RESULT_AUTHORITY_JOURNAL_INVALID'
    if ($IntendedHash -cnotmatch '^[0-9a-f]{64}$') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal contains a malformed intended hash.' }
    $ExistedValue = Get-RequiredValue $Target 'existed' 'RESULT_AUTHORITY_JOURNAL_INVALID'
    if ($ExistedValue -isnot [bool]) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal existed flag must be boolean.' }
    $BackupPath = $null
    $BackupRelative = [string](Get-OptionalValue $Target 'backup_path' '')
    if ([bool]$ExistedValue) {
      $ExpectedBackup = "$TransactionPath/$Index.backup"
      if ($BackupRelative -cne $ExpectedBackup) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal backup path is not canonical.' }
      $BackupPath = Get-ConfinedFile $Root $BackupRelative 'RESULT_AUTHORITY_JOURNAL_INVALID' '.agy/.runtime/result-authority/transactions'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($BackupRelative)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_INVALID' 'Publication journal has a backup for a previously absent output.' }
    $ValidatedTargets += [pscustomobject]@{ Path=$TargetPath; Existed=[bool]$ExistedValue; BackupPath=$BackupPath; IntendedHash=$IntendedHash }
  }
  if ($Status -eq 'committed') {
    foreach ($Target in $ValidatedTargets) {
      if (-not (Test-Path -LiteralPath $Target.Path -PathType Leaf) -or (Get-Sha256File $Target.Path) -ne $Target.IntendedHash) {
        Throw-ResultAuthorityError 'RESULT_AUTHORITY_JOURNAL_CONFLICT' 'Committed publication journal does not match current outputs.'
      }
    }
  }
  else {
    foreach ($Target in $ValidatedTargets) {
      if ($Target.Existed) {
        Write-AtomicBytes $Target.Path ([IO.File]::ReadAllBytes($Target.BackupPath))
      }
      elseif (Test-Path -LiteralPath $Target.Path -PathType Leaf) { Remove-Item -LiteralPath $Target.Path -Force }
    }
  }
  if (Test-Path -LiteralPath $TransactionFull -PathType Container) { Remove-Item -LiteralPath $TransactionFull -Recurse -Force }
  Remove-Item -LiteralPath $JournalPath -Force
}

function Publish-CompilationTransaction {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$ReceiptInput,
    [string]$AuditInput,
    [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
    [int]$FaultAfter
  )
  $Root = $Context.Root
  $TransactionRoot = Join-Path (Join-Path $RuntimeRoot 'transactions') $Token
  [void](New-Item -ItemType Directory -Path $TransactionRoot -Force)
  $Targets = @(
    [pscustomobject]@{ Path = '.agy/VERIFICATION_RECEIPT.json'; Bytes = [byte[]]$Context.ReceiptBytes },
    [pscustomobject]@{ Path = '.agy/CLOSURE_STATE.json'; Bytes = $script:Utf8NoBom.GetBytes(($Payload.closure | ConvertTo-Json -Depth 40)) },
    [pscustomobject]@{ Path = '.agy/RUN_RESULT.json'; Bytes = $script:Utf8NoBom.GetBytes(($Payload.run_result | ConvertTo-Json -Depth 60)) },
    [pscustomobject]@{ Path = '.agy/NEXT_ACTION.json'; Bytes = $script:Utf8NoBom.GetBytes(($Payload.next_action | ConvertTo-Json -Depth 20)) }
  )
  $Records = @()
  for ($Index = 0; $Index -lt $Targets.Count; $Index++) {
    $TargetFull = [IO.Path]::GetFullPath((Join-Path $Root $Targets[$Index].Path))
    if (-not (Test-PathWithin $Context.Agy $TargetFull)) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_PUBLICATION_PATH' 'Publication target escapes .agy.' }
    $Existed = Test-Path -LiteralPath $TargetFull -PathType Leaf
    $BackupRelative = $null
    if ($Existed) {
      $BackupFull = Join-Path $TransactionRoot ("$Index.backup")
      [IO.File]::Copy($TargetFull, $BackupFull, $true)
      $BackupRelative = Get-CanonicalRelativePath $Root $BackupFull
    }
    $Records += [ordered]@{ path = $Targets[$Index].Path; existed = $Existed; backup_path = $BackupRelative; intended_sha256 = Get-Sha256Bytes $Targets[$Index].Bytes }
  }
  $JournalPath = Join-Path $RuntimeRoot 'publication-journal.json'
  $Journal = [ordered]@{ schema_version = '1.0.0'; token = $Token; status = 'prepared'; transaction_path = Get-CanonicalRelativePath $Root $TransactionRoot; published_count = 0; targets = $Records; updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
  Write-AtomicJson $JournalPath $Journal 30
  try {
    for ($Index = 0; $Index -lt $Targets.Count; $Index++) {
      Write-AtomicBytes ([IO.Path]::GetFullPath((Join-Path $Root $Targets[$Index].Path))) $Targets[$Index].Bytes
      $Journal.status = 'writing'; $Journal.published_count = $Index + 1; $Journal.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
      Write-AtomicJson $JournalPath $Journal 30
      if ($FaultAfter -gt 0 -and ($Index + 1) -eq $FaultAfter) { throw "Injected result-authority publication failure after target $($Index + 1)." }
    }
    foreach ($Record in $Records) {
      $TargetFull = [IO.Path]::GetFullPath((Join-Path $Root $Record.path))
      if ((Get-Sha256File $TargetFull) -ne $Record.intended_sha256) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_PUBLICATION_VERIFY' "Published output hash mismatch: $($Record.path)" }
    }
    if ($Records.Count -ne 4 -or [string]$Records[3].path -cne '.agy/NEXT_ACTION.json') { Throw-ResultAuthorityError 'RESULT_AUTHORITY_INTERNAL_CONTRACT' 'Publication output order does not contain the exact NEXT_ACTION target.' }
    $PublishedControlHashes = [ordered]@{ '.agy/NEXT_ACTION.json' = [string]$Records[3].intended_sha256 }
    $PublicationContext = Get-ValidatedCompilationContext $Root $ReceiptInput $AuditInput $Context.ReceiptSha256 $PublishedControlHashes
    if ((Get-RequestFingerprint $PublicationContext $true) -ne $ExpectedFingerprint) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_INPUT_CHANGED' 'Payload authority changed during publication.' }
    $Journal.status = 'committed'; $Journal.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-AtomicJson $JournalPath $Journal 30
    Remove-Item -LiteralPath $TransactionRoot -Recurse -Force
    Remove-Item -LiteralPath $JournalPath -Force
    return $Records
  }
  catch {
    Restore-PublicationJournal $Root $RuntimeRoot
    throw
  }
}

function Test-CompletedOutputsCurrent {
  param($Status, [Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Fingerprint)
  if ($null -eq $Status -or [string](Get-OptionalValue $Status 'state' '') -ne 'completed' -or [string](Get-OptionalValue $Status 'request_fingerprint' '') -ne $Fingerprint) { return $false }
  $Hashes = Get-OptionalValue $Status 'output_sha256' $null
  if ($null -eq $Hashes) { return $false }
  foreach ($Relative in @('.agy/VERIFICATION_RECEIPT.json', '.agy/CLOSURE_STATE.json', '.agy/RUN_RESULT.json', '.agy/NEXT_ACTION.json')) {
    $Path = Join-Path $Context.Root $Relative
    $Expected = [string](Get-OptionalValue $Hashes $Relative '')
    if ([string]::IsNullOrWhiteSpace($Expected) -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Sha256File $Path) -ne $Expected) { return $false }
  }
  $Run = Read-JsonFile (Join-Path $Context.Root '.agy/RUN_RESULT.json') 'RUN_RESULT.json'
  $Provenance = Get-OptionalValue $Run 'verification_receipt' $null
  return ($null -ne $Provenance -and [string](Get-OptionalValue $Provenance 'path' '') -eq '.agy/VERIFICATION_RECEIPT.json' -and [string](Get-OptionalValue $Provenance 'sha256' '') -eq $Context.ReceiptSha256 -and [string](Get-OptionalValue $Run 'work_item_id' '') -eq $Context.WorkItemId -and [string](Get-OptionalValue $Run 'head' '') -eq $Context.Git.Head)
}

if ([string]::IsNullOrWhiteSpace($VerificationReceiptPath)) {
  Throw-ResultAuthorityError 'RESULT_AUTHORITY_VERIFICATION_RECEIPT_REQUIRED' 'VerificationReceiptPath is required; interactive prompting is forbidden.'
}

$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$RuntimeRoot = Join-Path $Agy '.runtime/result-authority'

if ($Worker) {
  if ([string]::IsNullOrWhiteSpace($WorkerToken) -or [string]::IsNullOrWhiteSpace($WorkerOutputPath) -or $ExpectedReceiptSha256 -cnotmatch '^[0-9a-f]{64}$') {
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_WORKER_UNAUTHORIZED' 'Worker invocation is incomplete.'
  }
  $Lock = Read-SharedLockMetadata (Join-Path $RuntimeRoot 'compile.lock')
  if ($null -eq $Lock -or [string](Get-OptionalValue $Lock 'state' '') -ne 'running' -or [string](Get-OptionalValue $Lock 'token' '') -ne $WorkerToken) {
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_WORKER_UNAUTHORIZED' 'Worker token does not match the active compiler lease.'
  }
  $WorkerOutputFull = [IO.Path]::GetFullPath($WorkerOutputPath)
  if (-not (Test-PathWithin $RuntimeRoot $WorkerOutputFull) -or [IO.Path]::GetFileName($WorkerOutputFull) -cne ("worker-$WorkerToken.json")) {
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_WORKER_UNAUTHORIZED' 'Worker output path is not confined to the active runtime request.'
  }
  $WorkerContext = Get-ValidatedCompilationContext $Root $VerificationReceiptPath $AuditResultPath $ExpectedReceiptSha256
  $Payload = New-CompilationPayload $WorkerContext
  Write-AtomicJson $WorkerOutputFull $Payload 70
  return
}

if (-not [string]::IsNullOrWhiteSpace($WorkerToken) -or -not [string]::IsNullOrWhiteSpace($WorkerOutputPath) -or -not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256)) {
  Throw-ResultAuthorityError 'RESULT_AUTHORITY_INTERNAL_CONTRACT' 'Internal worker parameters require -Worker.'
}

# This validation intentionally happens before creating lock, status, journal, or output files.
$Context = Get-ValidatedCompilationContext $Root $VerificationReceiptPath $AuditResultPath
$Fingerprint = Get-RequestFingerprint $Context ([bool]$Apply)
$Token = [Guid]::NewGuid().ToString('N')
[void](New-Item -ItemType Directory -Path $RuntimeRoot -Force)
$Lease = Acquire-CompilationLease $RuntimeRoot $Context $Fingerprint $Token $TimeoutSeconds
if ($Lease.State -ne 'owner') {
  [ordered]@{ schema_version = '1.0.0'; status = $Lease.State; request_fingerprint = $Fingerprint; work_item_id = $Context.WorkItemId; head = $Context.Git.Head } | ConvertTo-Json -Compress
  return
}

$Outcome = 'failed'
$StatusWasWritten = $false
$WorkerOutput = Join-Path $RuntimeRoot ("worker-$Token.json")
try {
  Restore-PublicationJournal $Root $RuntimeRoot
  $PreviousStatus = Get-CompilerStatus $RuntimeRoot
  if ($Apply -and (Test-CompletedOutputsCurrent $PreviousStatus $Context $Fingerprint)) {
    $Outcome = 'already_completed'
    [ordered]@{ schema_version = '1.0.0'; status = 'already_completed'; request_fingerprint = $Fingerprint; work_item_id = $Context.WorkItemId; head = $Context.Git.Head; verification_receipt_sha256 = $Context.ReceiptSha256 } | ConvertTo-Json -Compress
    return
  }
  $Deadline = [string]$Lease.Metadata.deadline_at_utc
  $Status = [ordered]@{ schema_version = '1.0.0'; state = 'running'; request_fingerprint = $Fingerprint; token = $Token; work_item_id = $Context.WorkItemId; goal_epoch = $Context.GoalEpoch; head = $Context.Git.Head; owner_pid = $PID; started_at_utc = [string]$Lease.Metadata.started_at_utc; deadline_at_utc = $Deadline; updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
  Set-CompilerStatus $RuntimeRoot $Status
  $StatusWasWritten = $true
  if (Test-Path -LiteralPath $WorkerOutput -PathType Leaf) { Remove-Item -LiteralPath $WorkerOutput -Force }
  $Pwsh = (Get-Process -Id $PID).Path
  $WorkerArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ProjectRoot', $Root, '-VerificationReceiptPath', $Context.ReceiptPath, '-TimeoutSeconds', [string]$TimeoutSeconds, '-Worker', '-WorkerToken', $Token, '-WorkerOutputPath', $WorkerOutput, '-ExpectedReceiptSha256', $Context.ReceiptSha256)
  if (-not [string]::IsNullOrWhiteSpace($AuditResultPath)) { $WorkerArguments += @('-AuditResultPath', $AuditResultPath) }
  $WorkerResult = Invoke-BoundedProcess $Pwsh $WorkerArguments $Root $TimeoutSeconds
  if ($WorkerResult.TimedOut) {
    $Outcome = 'timed_out'
    $Status.state = 'timed_out'; $Status.error_code = 'RESULT_AUTHORITY_TIMEOUT'; $Status.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    Set-CompilerStatus $RuntimeRoot $Status
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_TIMEOUT' "Result-authority worker exceeded $TimeoutSeconds seconds and its process tree was terminated."
  }
  if ($WorkerResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $WorkerOutput -PathType Leaf)) {
    $Outcome = 'worker_failed'
    $Status.state = 'failed'; $Status.error_code = 'RESULT_AUTHORITY_WORKER_FAILED'; $Status.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    Set-CompilerStatus $RuntimeRoot $Status
    $Detail = ($WorkerResult.StdErr + "`n" + $WorkerResult.StdOut).Trim()
    Throw-ResultAuthorityError 'RESULT_AUTHORITY_WORKER_FAILED' "Worker failed with exit code $($WorkerResult.ExitCode): $Detail"
  }
  $Payload = Read-JsonFile $WorkerOutput 'Result-authority worker output'
  $CurrentContext = Get-ValidatedCompilationContext $Root $VerificationReceiptPath $AuditResultPath $Context.ReceiptSha256
  $CurrentFingerprint = Get-RequestFingerprint $CurrentContext ([bool]$Apply)
  if ($CurrentFingerprint -ne $Fingerprint) { Throw-ResultAuthorityError 'RESULT_AUTHORITY_INPUT_CHANGED' 'Authority or receipt changed while the compiler was running.' }
  $OutputHashes = [ordered]@{}
  if ($Apply) {
    $Status.state = 'applying'; $Status.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    Set-CompilerStatus $RuntimeRoot $Status
    $Records = Publish-CompilationTransaction $CurrentContext $Payload $RuntimeRoot $Token $VerificationReceiptPath $AuditResultPath $Fingerprint $FaultInjectionAfterPublishes
    foreach ($Record in $Records) { $OutputHashes[$Record.path] = $Record.intended_sha256 }
  }
  $Outcome = 'completed'
  $Status.state = 'completed'; $Status.compiled_at_utc = [string]$Payload.run_result.compiled_at_utc; $Status.verification_receipt_sha256 = $CurrentContext.ReceiptSha256; $Status.output_sha256 = $OutputHashes; $Status.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
  Set-CompilerStatus $RuntimeRoot $Status
  if ($Apply) {
    [ordered]@{ schema_version = '1.0.0'; status = 'completed'; request_fingerprint = $Fingerprint; work_item_id = $CurrentContext.WorkItemId; head = $CurrentContext.Git.Head; compiled_at_utc = [string]$Payload.run_result.compiled_at_utc; verification_receipt = $Payload.run_result.verification_receipt } | ConvertTo-Json -Depth 20 -Compress
  }
  else { $Payload | ConvertTo-Json -Depth 70 }
}
catch {
  if ($StatusWasWritten -and $Outcome -notin @('timed_out', 'worker_failed')) {
    try {
      $FailureStatus = Get-CompilerStatus $RuntimeRoot
      if ($null -ne $FailureStatus) {
        $FailureStatus.state = 'failed'; $FailureStatus.error_code = 'RESULT_AUTHORITY_FAILED'; $FailureStatus.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        Set-CompilerStatus $RuntimeRoot $FailureStatus
      }
    }
    catch {}
  }
  throw
}
finally {
  if (Test-Path -LiteralPath $WorkerOutput -PathType Leaf) { Remove-Item -LiteralPath $WorkerOutput -Force }
  if ($null -ne $Lease.Stream) {
    try {
      $Released = $Lease.Metadata
      $Released.state = 'released'; $Released.outcome = $Outcome; $Released.released_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); $Released.updated_at_utc = $Released.released_at_utc
      Write-LockMetadata $Lease.Stream $Released
    }
    catch {}
    $Lease.Stream.Dispose()
    if ($null -ne $Lease.Mutex) {
      try { $Lease.Mutex.ReleaseMutex() }
      finally { $Lease.Mutex.Dispose() }
    }
  }
}
