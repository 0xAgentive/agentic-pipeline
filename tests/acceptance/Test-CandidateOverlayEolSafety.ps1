[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Overlay = Join-Path $Root 'scripts\release\Apply-CandidateOverlay.ps1'
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('agentic-overlay-eol-юникод-' + [Guid]::NewGuid().ToString('N'))
$Repo = Join-Path $Temp 'repo with spaces'
$Payload = Join-Path $Temp 'payload'
New-Item -ItemType Directory -Force -Path $Repo, $Payload | Out-Null
$Utf8 = [Text.UTF8Encoding]::new($false)
try {
  & git -C $Repo init --quiet
  if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
  & git -C $Repo config user.email 'regression@example.invalid'
  & git -C $Repo config user.name 'Regression'
  [IO.File]::WriteAllText((Join-Path $Repo '.gitattributes'), "*.ps1 text eol=crlf`n", $Utf8)
  [IO.File]::WriteAllText((Join-Path $Repo 'sample.ps1'), "Write-Host 'same'`n", $Utf8)
  & git -C $Repo add .
  & git -C $Repo commit --quiet -m baseline
  if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
  & git -C $Repo checkout --quiet --force HEAD
  [IO.File]::WriteAllText((Join-Path $Payload 'sample.ps1'), "Write-Host 'same'`n", $Utf8)
  $Before = (Get-FileHash -LiteralPath (Join-Path $Repo 'sample.ps1') -Algorithm SHA256).Hash

  & pwsh -NoProfile -File $Overlay -CandidateRoot $Repo -PayloadRoot $Payload -Apply | Out-Null
  if ($LASTEXITCode -ne 0) { throw 'Empty overlay failed' }
  & pwsh -NoProfile -File $Overlay -CandidateRoot $Repo -PayloadRoot $Payload -ExpectedPaths 'sample.ps1' -Apply | Out-Null
  if ($LASTEXITCode -ne 0) { throw 'Identical overlay failed' }
  $After = (Get-FileHash -LiteralPath (Join-Path $Repo 'sample.ps1') -Algorithm SHA256).Hash
  if ($Before -ne $After) { throw 'Blob-identical LF payload changed the CRLF working-tree bytes.' }
  $Status = @(& git -C $Repo status --porcelain=v1)
  if ($LASTEXITCODE -ne 0 -or $Status.Count -ne 0) { throw "Blob-identical overlay dirtied the worktree: $($Status -join '; ')" }

  [IO.File]::WriteAllText((Join-Path $Payload 'sample.ps1'), "Write-Host 'changed'`n", $Utf8)
  & pwsh -NoProfile -File $Overlay -CandidateRoot $Repo -PayloadRoot $Payload -ExpectedPaths 'sample.ps1' -Apply | Out-Null
  if ($LASTEXITCode -ne 0) { throw 'Changed overlay failed' }
  $Bytes = [IO.File]::ReadAllBytes((Join-Path $Repo 'sample.ps1'))
  $Text = [Text.Encoding]::UTF8.GetString($Bytes)
  if (-not $Text.Contains("`r`n")) { throw 'Changed PowerShell payload was not materialized with Git CRLF attributes.' }
  if (@(& git -C $Repo status --porcelain=v1).Count -ne 1) { throw 'Changed overlay did not produce exactly one expected Git change.' }
  Write-Host 'Candidate overlay EOL safety regression passed.'
}
finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
